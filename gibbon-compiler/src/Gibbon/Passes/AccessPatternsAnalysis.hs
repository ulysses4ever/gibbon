module Gibbon.Passes.AccessPatternsAnalysis
  ( generateAccessGraphs,
    getGreedyOrder,
    generateSolverEdges, 
    FieldMap,
    DataConAccessMap,
  )
where

-- Gibbon imports

import Control.Monad as Mo
import Data.Graph as G
import Data.List as L
import Data.Map as M
import Data.Maybe as Mb
import Data.Set as S
import Gibbon.Common
import Gibbon.Language
import Gibbon.Language.Syntax
import Gibbon.L1.Syntax as L1
import Gibbon.Passes.ControlFlowGraph (CFGfunctionMap)

import Gibbon.Passes.DefinitionUseChains
  ( DefUseChainsFunctionMap (..),
    generateDefUseChainsFunction,
    progToVEnv,
    getDefinitionsReachingLetExp,
    UseDefChainsFunctionMap (..)
  )


-- Haskell imports

import Text.PrettyPrint.GenericPretty
import Prelude as P

-- | Type VariableMap: Stores mapping from Variable to wheather it comes from a particular datacon
-- | index position in data con.
type VariableMap = M.Map Var (Maybe (DataCon, Integer))

-- | Map a function to its Access map for a particular data constructor.
-- | Function stored as variable name
type FieldMap = M.Map Var DataConAccessMap

-- | Store the access edges for fields in a data con.
-- | Fields are represented as index positions in the DataCon.
type DataConAccessMap = M.Map DataCon [((Integer, Integer), Integer)]

generateAccessGraphs ::
  (FreeVars (e l d), Ord l, Ord d, Ord (e l d), Out d, Out l) =>
  CFGfunctionMap (PreExp e l d) ->
  FieldMap ->
  FunDef1 ->
  DataCon ->
  FieldMap
generateAccessGraphs
  cfgMap
  fieldMap
  funDef@FunDef
    { funName,
      funBody,
      funTy,
      funArgs
    }
  dcons =
    case (M.lookup funName cfgMap) of
      Just (graph, nodeFromVertex, vertexFromKey) ->
        let topologicallySortedVertices = topSort graph
            topologicallySortedNodes =
              P.map nodeFromVertex topologicallySortedVertices
            map = backtrackVariablesToDataConFields topologicallySortedNodes dcons
            (defUseChainsMap :: UseDefChainsFunctionMap Exp1) = getDefinitionsReachingLetExp funDef
            elem = M.lookup funName defUseChainsMap
            (g, f, f'') = fromJust elem
            vertices = P.map (\v -> f v) (topSort g)
            edges = S.toList $ S.fromList $ --dbgTraceIt ("DefUseChains:\n") dbgTraceIt ((M.elems defUseChainsMap)) dbgTraceIt ("\n")
                ( constructFieldGraph
                    Nothing
                    nodeFromVertex
                    vertexFromKey
                    topologicallySortedNodes
                    topologicallySortedNodes
                    map
                )
                dcons
            accessMapsList = {-dbgTraceIt ("STAGE1\n")-} zipWith (\x y -> (x, y)) [dcons] [edges]
            accessMaps = {-dbgTraceIt ("STAGE2\n")-} M.fromList accessMapsList
            fieldMap' = {-dbgTraceIt ("STAGE3\n")-} M.insert funName accessMaps fieldMap  --dbgTraceIt (sdoc topologicallySortedVertices) dbgTraceIt ("\n") dbgTraceIt (sdoc (topologicallySortedVertices, edges)) dbgTraceIt ("\n")
            s'' = {-dbgTraceIt ("STAGE4\n")-} generateSolverEdges funDef dcons fieldMap'
         in {-dbgTraceIt ("STAGE5:\n") dbgTraceIt (sdoc (funName, vertices, edges, findDataFlowDependencies funDef, s'')) dbgTraceIt ("\n")-} fieldMap'  
      Nothing -> error "generateAccessGraphs: no CFG for function found!"



getGreedyOrder :: [((Integer, Integer), Integer)] -> Int -> [Integer]
getGreedyOrder edges fieldLength = 
          if edges == []
            then P.map P.toInteger [0 .. (fieldLength - 1)] 
            else 
              let partial_order = greedyOrderOfVertices edges
                  completeOrder = P.foldl (\lst val -> if S.member val (S.fromList lst) then lst
                                                 else lst ++ [val]
                                    ) partial_order [0 .. (fieldLength - 1)]
                in P.map P.toInteger completeOrder --dbgTraceIt (sdoc (edges, completeOrder)) P.map P.toInteger completeOrder

greedyOrderOfVertices :: [((Integer, Integer), Integer)] -> [Int]
greedyOrderOfVertices ee = let     edges' = P.map (\((a, b), c) -> ((P.fromIntegral a, P.fromIntegral b), P.fromIntegral c)) ee
                                   bounds = (\e -> let v = P.foldr (\((i, j), _) s -> S.insert j (S.insert i s)) S.empty e
                                                       mini  = minimum v
                                                       maxi  = maximum v
                                                    in (mini, maxi)
                                            ) edges'
                                   edgesWithoutWeight = P.map fst edges'
                                   graph = buildG bounds edgesWithoutWeight
                                   weightMap = P.foldr (\(e, w) mm -> M.insert e w mm) M.empty edges'
                                   v'' = greedyOrderOfVerticesHelper graph (topSort graph) weightMap S.empty
                                in v'' -- dbgTraceIt (sdoc ((topSort graph), (M.elems weightMap))) dbgTraceIt (sdoc (v'', (M.elems weightMap)))


greedyOrderOfVerticesHelper :: Graph -> [Int] -> M.Map (Int, Int) Int -> S.Set Int -> [Int]
greedyOrderOfVerticesHelper graph vertices' weightMap visited = case vertices' of
  [] -> []
  x:xs -> if S.member x visited
          then greedyOrderOfVerticesHelper graph xs weightMap visited
          else let successors = succGraph x (G.edges graph) visited
                   removeCurr = S.toList $ S.delete x (S.fromList successors)
                   orderedSucc = orderedSuccsByWeight removeCurr x weightMap visited
                   visited' = P.foldr S.insert visited orderedSucc
                   v'' = greedyOrderOfVerticesHelper graph xs weightMap visited'
                in  [x] ++ orderedSucc ++ v'' 
                   -- dbgTraceIt (sdoc (x, successors, removeCurr, orderedSucc, v'', S.toList visited' , S.toList visited ))
                   --then dbgTraceIt (sdoc (x, successors, removeCurr, orderedSucc, v'', S.toList visited')) orderedSucc ++ v'' --dbgTraceIt (sdoc (v'', orderedSucc))
                   --else dbgTraceIt (sdoc (x, successors, removeCurr, orderedSucc, v'', S.toList visited')) [x] ++ orderedSucc ++ v''


succGraph :: Int -> [(Int, Int)] -> S.Set Int -> [Int]
succGraph node edges visited = case edges of 
  [] -> [] 
  (a, b):xs -> if S.member b visited || S.member a visited
               then succGraph node xs visited
               else 
                if node == a then [b] ++ succGraph node xs visited
                else succGraph node xs visited
               

orderedSuccsByWeight :: [Int] -> Int -> M.Map (Int, Int) Int -> S.Set Int -> [Int]
orderedSuccsByWeight s i weightMap visited = case s of
                                        [] -> []
                                        _  -> let vertexWithMaxWeight = P.foldr (\v (v', maxx) -> let w = M.lookup (i, v) weightMap
                                                                                                        in case w of
                                                                                                               Nothing -> (-1, -1)
                                                                                                               Just w' -> if w' > maxx
                                                                                                                          then (v, w')
                                                                                                                          else (v', maxx)
                                                                     ) (-1, -1) s
                                                in if fst vertexWithMaxWeight == -1
                                                   then []
                                                   else
                                                    let removeVertexWithMaxWeight = S.toList $ S.delete (fst vertexWithMaxWeight) (S.fromList s)
                                                     in if S.member (fst vertexWithMaxWeight) visited
                                                        then orderedSuccsByWeight removeVertexWithMaxWeight i weightMap visited 
                                                        else fst vertexWithMaxWeight : orderedSuccsByWeight removeVertexWithMaxWeight i weightMap visited --dbgTraceIt (sdoc (s, removeVertexWithMaxWeight, vertexWithMaxWeight))




backtrackVariablesToDataConFields ::
  (FreeVars (e l d), Ord l, Ord d, Ord (e l d), Out d, Out l) =>
  [(((PreExp e l d), Integer), Integer, [Integer])] ->
  DataCon ->
  VariableMap
backtrackVariablesToDataConFields graph dcon =
  case graph of
    [] -> M.empty
    x : xs ->
      let newMap = processVertex graph x M.empty dcon
          mlist = M.toList (newMap)
          m = backtrackVariablesToDataConFields xs dcon
          mlist' = M.toList m
          newMap' = M.fromList (mlist ++ mlist')
       in newMap'

processVertex ::
  (FreeVars (e l d), Ord l, Ord d, Ord (e l d), Out d, Out l) =>
  [(((PreExp e l d), Integer), Integer, [Integer])] ->
  (((PreExp e l d), Integer), Integer, [Integer]) ->
  VariableMap ->
  DataCon ->
  VariableMap
processVertex graph node map dataCon  =
  case node of
    ((expression, likelihood), id, succ) ->
      case expression of
        DataConE loc dcon args ->
          if dcon == dataCon
          then
            let freeVariables = L.concat (P.map (\x -> S.toList (gFreeVars x)) args)
                maybeIndexes = P.map (getDataConIndexFromVariable graph) freeVariables
                mapList = M.toList map
                newMapList = P.zipWith (\x y -> (x, y)) freeVariables maybeIndexes
             in M.fromList (mapList ++ newMapList)
          else map
        _ -> map

getDataConIndexFromVariable ::
  (FreeVars (e l d), Ord l, Ord d, Ord (e l d), Out d, Out l) =>
  [(((PreExp e l d), Integer), Integer, [Integer])] ->
  Var ->
  Maybe (DataCon, Integer)
getDataConIndexFromVariable graph variable =
  case graph of
    [] -> Nothing
    x : xs ->
      let status = compareVariableWithDataConFields x variable
       in case status of
            Nothing -> getDataConIndexFromVariable xs variable
            Just val -> Just val

compareVariableWithDataConFields ::
  (FreeVars (e l d), Ord l, Ord d, Ord (e l d), Out d, Out l) =>
  (((PreExp e l d), Integer), Integer, [Integer]) ->
  Var ->
  Maybe (DataCon, Integer)
compareVariableWithDataConFields node variable =
  case node of
    ((exp, likelihood), id, _) ->
      case exp of
        DataConE loc dcon args ->
          let variables = [var | VarE var <- args]
              results = P.map (variable ==) variables
              maybeIndex = L.elemIndex True results
           in case maybeIndex of
                Nothing -> Nothing
                Just val -> Just (dcon, P.toInteger val)
        _ -> Nothing

-- | Return the freeVariables bound by an expression in Order
freeVarsInOrder :: (PreExp e l d) -> [Var]
freeVarsInOrder exp =
  case exp of
    DataConE loc dcon args -> []
    VarE var -> [var]
    LitE val -> []
    CharE char -> []
    FloatE val -> []
    LitSymE var -> [var]
    AppE f locs args ->
      let var_list_list = P.map (freeVarsInOrder) args
          var_list = L.concat var_list_list
       in var_list
    PrimAppE f args ->
      let var_list_list = P.map (freeVarsInOrder) args
          var_list = L.concat var_list_list
       in var_list
    LetE (v, loc, ty, rhs) bod -> freeVarsInOrder rhs
    CaseE scrt mp ->
      (freeVarsInOrder scrt)
        ++ ( L.concat
               ( L.map
                   ( \(_, vlocs, expr) ->
                       let (vars, _) = P.unzip vlocs
                           freeVarsExp = freeVarsInOrder expr
                           newVars = freeVarsExp ++ vars
                        in newVars
                   )
                   mp
               )
           )
    IfE a b c ->
      (freeVarsInOrder a) ++ (freeVarsInOrder b) ++ (freeVarsInOrder c)
    MkProdE xs ->
      let var_list_list = P.map (freeVarsInOrder) xs
          var_list = L.concat var_list_list
       in var_list
    ProjE i e -> error "freeVarsInOrder: TODO ProjE"
    TimeIt e ty b -> freeVarsInOrder e
    WithArenaE v e -> error "freeVarsInOrder: TODO WithArenaE"
    SpawnE f locs args -> error "freeVarsInOrder: TODO SpawnE"
    SyncE -> error "freeVarsInOrder: TODO SyncE"
    Ext _ -> error "freeVarsInOrder: TODO Ext"
    MapE {} -> error "freeVarsInOrder: TODO MapE"
    FoldE {} -> error "freeVarsInOrder: TODO FoldE"

removeDuplicates :: (Eq a) => [a] -> [a]
removeDuplicates list =
  case list of
    [] -> []
    a : as -> a : removeDuplicates (P.filter (/= a) as)

-- | From a given graph generate the Field ordering subgraph.
-- | A subgraph that only contains Fields from the dataCons as Vertices.
-- | Edges amongst vertices amount to the READ ACCESS Patterns amongs the fields of the DataCon.
-- | For now, we only cares about read <-> read dependencies.

-- | RETURN: an edge list and corresponding weight of the the edges
-- | Edge: a tuple from vertex to vertex, left dominates right.

-- | TODO: any FIXMEs in the function.

-- | a.) Multiple datacon fields read in the same expression.
-- | Since this will be run after flatten, it is safe to assume that only possibly a maximum of two variables can be read in one let binding.
-- | Except function calls! where more than two fields can be passed as arguments.
evaluateExpressionFieldGraph :: (Out l, Out d, Out (e l d)) =>
  Maybe (DataCon, Integer) ->
  (G.Vertex -> (((PreExp e l d), Integer), Integer, [Integer])) ->
  (Integer -> Maybe G.Vertex) ->
  [(((PreExp e l d), Integer), Integer, [Integer])] ->
  [(((PreExp e l d), Integer), Integer, [Integer])] ->
  VariableMap ->
  DataCon ->
  [Var] ->
  [Integer] ->
  Integer ->
  [((Integer, Integer), Integer)]
evaluateExpressionFieldGraph currField nodeFromVertex vertexFromNode graph xs map datacon freeVars successors likelihood =
  case currField of
    Nothing ->
      let fromDataCon' =
            P.map
              (\v -> M.findWithDefault Nothing v map)
              (removeDuplicates freeVars)
          justDcons = [Just x | Just x <- fromDataCon']
          fromDataCon'' =
            if P.null justDcons
              then {-dbgTraceIt ("justDcons:") dbgTraceIt (sdoc justDcons)-} [Nothing]
              else {-dbgTraceIt ("justDcons:") dbgTraceIt (sdoc justDcons)-} justDcons
       in case fromDataCon'' of
            [a] ->
              case a of
                Nothing ->
                  []
                    ++ constructFieldGraph
                      Nothing
                      nodeFromVertex
                      vertexFromNode
                      graph
                      xs
                      map
                      datacon
                Just (dcon, id) ->
                  case (dcon == datacon) of
                    True ->
                      let succ' = Mb.catMaybes $ P.map vertexFromNode successors
                          succVertices = P.map nodeFromVertex succ'
                          succExp = P.map (\x -> (fst . fst3) x) succVertices
                          succprob = P.map (\x -> (snd . fst3) x) succVertices
                          {- list of list, where each list stores variables -}
                          succDataCon =
                            P.map
                              ( \x ->
                                  findFieldInDataConFromVariableInExpression
                                    x
                                    graph
                                    map
                                    datacon
                              )
                              succExp
                          {- list of tuples, where each tuple == ([(dcon, id), ... ], likelihood)    -}
                          succDataCon' = {-dbgTraceIt ("succDataCon:") dbgTraceIt (sdoc succDataCon)-}
                            P.zipWith (\x y -> (x, y)) succDataCon succprob
                          newEdges =
                            P.concat $
                              P.map
                                ( \x ->
                                    case x of
                                      (varsl, prob) ->
                                        P.map (\y -> ((id, snd y), prob)) varsl
                                )
                                succDataCon'
                       in case newEdges of
                            [] ->
                              case successors of
                                [] ->
                                  []
                                    ++ constructFieldGraph
                                      Nothing
                                      nodeFromVertex
                                      vertexFromNode
                                      graph
                                      xs
                                      map
                                      datacon
                                _ ->
                                  newEdges
                                    ++ constructFieldGraph
                                      (Just (dcon, id))
                                      nodeFromVertex
                                      vertexFromNode
                                      graph
                                      xs
                                      map
                                      datacon
                            _ ->
                              newEdges
                                ++ constructFieldGraph
                                  Nothing
                                  nodeFromVertex
                                  vertexFromNode
                                  graph
                                  xs
                                  map
                                  datacon
                    _ ->
                      []
                        ++ constructFieldGraph
                          currField
                          nodeFromVertex
                          vertexFromNode
                          graph
                          xs
                          map
                          datacon
            _ ->
              error
                "evaluateExpressionFieldGraph: More than one variable from DataCon in a let binding not modelled into Field dependence graph yet!"
    Just (dcon, pred) ->
      let fromDataCon' =
            P.map
              (\v -> M.findWithDefault Nothing v map)
              (removeDuplicates freeVars)
          justDcons = [Just x | Just x <- fromDataCon']
          fromDataCon'' =
            if P.null justDcons
              then {-dbgTraceIt ("justDcons:") dbgTraceIt (sdoc justDcons)-} [Nothing]
              else {-dbgTraceIt ("justDcons:") dbgTraceIt (sdoc justDcons)-} justDcons
       in case fromDataCon'' of
            [a] ->
              case a of
                Nothing ->
                  let succ' = Mb.catMaybes $ P.map vertexFromNode successors
                      succVertices = P.map nodeFromVertex succ'
                      succExp = P.map (\x -> (fst . fst3) x) succVertices
                      succprob = P.map (\x -> (snd . fst3) x) succVertices
                      {- list of list, where each list stores variables -}
                      succDataCon =
                        P.map
                          ( \x ->
                              findFieldInDataConFromVariableInExpression
                                x
                                graph
                                map
                                datacon
                          )
                          succExp
                      {- list of tuples, where each tuple == ([(dcon, id), ... ], likelihood)    -}
                      succDataCon' = {-dbgTraceIt ("succDataCon:") dbgTraceIt (sdoc succDataCon)-}
                        P.zipWith (\x y -> (x, y)) succDataCon succprob
                      -- FIXME: TODO: This might be needed for the other cases in this function as well. 
                      -- This is to make sure we recurse on all possible successors. 
                      newEdges' = constructFieldGraph (Just (dcon, pred)) nodeFromVertex vertexFromNode graph succVertices map datacon 
                      newEdges = newEdges' ++ ( 
                        P.concat $
                          P.map
                            ( \x ->
                                case x of
                                  (varsl, prob) ->
                                    P.map (\y -> ((pred, snd y), prob)) varsl
                            )
                            succDataCon' )
                   in case newEdges of
                        [] ->
                          case successors of
                            [] -> --dbgTraceIt (sdoc (currField, succVertices, newEdges, newEdges'))
                              []
                                ++ constructFieldGraph
                                  Nothing
                                  nodeFromVertex
                                  vertexFromNode
                                  graph
                                  xs
                                  map
                                  datacon
                            _ -> --dbgTraceIt (sdoc (currField, succVertices, newEdges, newEdges'))
                              newEdges
                                ++ constructFieldGraph
                                  (Just (dcon, pred))
                                  nodeFromVertex
                                  vertexFromNode
                                  graph
                                  xs
                                  map
                                  datacon
                        _ -> --dbgTraceIt (sdoc (currField, succVertices, newEdges, newEdges'))
                          newEdges
                            ++ constructFieldGraph
                              Nothing
                              nodeFromVertex
                              vertexFromNode
                              graph
                              xs
                              map
                              datacon
                Just (dcon', id') ->
                  case (dcon' == datacon) of
                    True ->
                      let edges = [((pred, id'), likelihood)]
                          succ' = Mb.catMaybes $ P.map vertexFromNode successors
                          succVertices = P.map nodeFromVertex succ'
                          succExp = P.map (\x -> (fst . fst3) x) succVertices
                          succprob = P.map (\x -> (snd . fst3) x) succVertices
                          succDataCon =
                            P.map
                              ( \x ->
                                  findFieldInDataConFromVariableInExpression
                                    x
                                    graph
                                    map
                                    datacon
                              )
                              succExp
                          succDataCon' = {-dbgTraceIt ("succDataCon:") dbgTraceIt (sdoc succDataCon)-}
                            P.zipWith (\x y -> (x, y)) succDataCon succprob
                          newEdges =
                            P.concat $
                              P.map
                                ( \x ->
                                    case x of
                                      (varsl, prob) ->
                                        P.map (\y -> ((pred, snd y), prob)) varsl
                                )
                                succDataCon'
                       in newEdges
                            ++ edges
                            ++ constructFieldGraph
                              Nothing
                              nodeFromVertex
                              vertexFromNode
                              graph
                              xs
                              map
                              datacon
                    _ ->
                      []
                        ++ constructFieldGraph
                          currField
                          nodeFromVertex
                          vertexFromNode
                          graph
                          xs
                          map
                          datacon
            _ ->
              error
                "evaluateExpressionFieldGraph: More than one variable from DataCon in a let binding not modelled into Field dependence graph yet!"

constructFieldGraph :: (Out l, Out d, Out (e l d)) =>
  Maybe (DataCon, Integer) ->
  (G.Vertex -> (((PreExp e l d), Integer), Integer, [Integer])) ->
  (Integer -> Maybe G.Vertex) ->
  [(((PreExp e l d), Integer), Integer, [Integer])] ->
  [(((PreExp e l d), Integer), Integer, [Integer])] ->
  VariableMap ->
  DataCon ->
  [((Integer, Integer), Integer)]
constructFieldGraph currField nodeFromVertex vertexFromNode graph progress map datacon =
  case progress of
    [] -> []
    x : xs ->
      let ((exp, likelihood), id'', successors) = x
       in case exp of
            LitE val ->
              case successors of
                [] ->
                  constructFieldGraph
                      Nothing
                      nodeFromVertex
                      vertexFromNode
                      graph
                      xs
                      map
                      datacon
                _ ->
                  constructFieldGraph
                      currField
                      nodeFromVertex
                      vertexFromNode
                      graph
                      xs
                      map
                      datacon
            CharE char ->
              case successors of
                [] ->
                  []
                    ++ constructFieldGraph
                      Nothing
                      nodeFromVertex
                      vertexFromNode
                      graph
                      xs
                      map
                      datacon
                _ ->
                  []
                    ++ constructFieldGraph
                      currField
                      nodeFromVertex
                      vertexFromNode
                      graph
                      xs
                      map
                      datacon
            FloatE val ->
              case successors of
                [] ->
                  []
                    ++ constructFieldGraph
                      Nothing
                      nodeFromVertex
                      vertexFromNode
                      graph
                      xs
                      map
                      datacon
                _ ->
                  []
                    ++ constructFieldGraph
                      currField
                      nodeFromVertex
                      vertexFromNode
                      graph
                      xs
                      map
                      datacon
            DataConE loc dcon args ->
              case successors of
                [] ->
                  []
                    ++ constructFieldGraph
                      Nothing
                      nodeFromVertex
                      vertexFromNode
                      graph
                      xs
                      map
                      datacon
                _ ->
                  constructFieldGraph
                      currField
                      nodeFromVertex
                      vertexFromNode
                      graph
                      xs
                      map
                      datacon
            VarE var ->
              evaluateExpressionFieldGraph
                currField
                nodeFromVertex
                vertexFromNode
                graph
                xs
                map
                datacon
                [var]
                successors
                likelihood
            LitSymE var ->
              evaluateExpressionFieldGraph
                currField
                nodeFromVertex
                vertexFromNode
                graph
                xs
                map
                datacon
                [var]
                successors
                likelihood
            LetE (v, loc, ty, rhs) bod ->
              evaluateExpressionFieldGraph
                currField
                nodeFromVertex
                vertexFromNode
                graph
                xs
                map
                datacon
                (freeVarsInOrder rhs)
                successors
                likelihood
            AppE f locs args ->
              evaluateExpressionFieldGraph
                currField
                nodeFromVertex
                vertexFromNode
                graph
                xs
                map
                datacon
                (freeVarsInOrder exp)
                successors
                likelihood
            PrimAppE f args ->
              evaluateExpressionFieldGraph
                currField
                nodeFromVertex
                vertexFromNode
                graph
                xs
                map
                datacon
                (freeVarsInOrder exp)
                successors
                likelihood
            MkProdE xss ->
              evaluateExpressionFieldGraph
                currField
                nodeFromVertex
                vertexFromNode
                graph
                xs
                map
                datacon
                (freeVarsInOrder exp)
                successors
                likelihood
            ProjE i e -> error "constructFieldGraph: TODO ProjE"
            TimeIt e ty b -> error "constructFieldGraph: TODO TimeIt"
            WithArenaE v e -> error "constructFieldGraph: TODO WithArenaE"
            SpawnE f locs args -> error "constructFieldGraph: TODO SpawnE"
            SyncE -> error "constructFieldGraph: TODO SyncE"
            Ext _ -> error "constructFieldGraph: TODO Ext"
            MapE {} -> error "constructFieldGraph: TODO MapE"
            FoldE {} -> error "constructFieldGraph: TODO FoldE"
            _ -> error "not expected"

-- | From an expression provided, Recursively find all the variables that come from a DataCon expression, that is, are fields in a DataConE.
findFieldInDataConFromVariableInExpression :: (Out l, Out d, Out (e l d)) =>
  (PreExp e l d) ->
  [(((PreExp e l d), Integer), Integer, [Integer])] ->
  VariableMap ->
  DataCon ->
  [(DataCon, Integer)]
findFieldInDataConFromVariableInExpression exp graph map datacon =
  case exp of
    VarE var ->
      let fromDataCon = M.findWithDefault Nothing var map
       in case fromDataCon of
            Nothing -> []
            Just (dcon, id') ->
              if dcon == datacon
                then [(dcon, id')]
                else []
    LitSymE var ->
      let fromDataCon = M.findWithDefault Nothing var map
       in case fromDataCon of
            Nothing -> []
            Just (dcon, id') ->
              if dcon == datacon
                then [(dcon, id')]
                else []
    LetE (v, loc, ty, rhs) bod ->
      let freeVars = freeVarsInOrder rhs
          fromDataCon = P.map (\v -> M.findWithDefault Nothing v map) freeVars
          removeMaybe = Mb.catMaybes fromDataCon
          newDatacons = --dbgTraceIt (sdoc (v, freeVars))
            [ if dcon == datacon
                then Just (dcon, id')
                else Nothing
              | (dcon, id') <- removeMaybe
            ]
          newDatacons' = Mb.catMaybes newDatacons
       in newDatacons'
    AppE f locs args ->
      let freeVars = freeVarsInOrder exp
          fromDataCon = P.map (\v -> M.findWithDefault Nothing v map) freeVars
          removeMaybe = Mb.catMaybes fromDataCon
          newDatacons =
            [ if dcon == datacon
                then Just (dcon, id')
                else Nothing
              | (dcon, id') <- removeMaybe
            ]
          newDatacons' = Mb.catMaybes newDatacons
       in newDatacons'
    PrimAppE f args ->
      let freeVars = freeVarsInOrder exp
          fromDataCon = P.map (\v -> M.findWithDefault Nothing v map) freeVars
          removeMaybe = Mb.catMaybes fromDataCon
          newDatacons =
            [ if dcon == datacon
                then Just (dcon, id')
                else Nothing
              | (dcon, id') <- removeMaybe
            ]
          newDatacons' = Mb.catMaybes newDatacons
       in newDatacons'
    LitE val -> []
    CharE char -> []
    FloatE val -> []
    DataConE loc dcon args -> []
    MkProdE xss ->
      let freeVars = freeVarsInOrder exp
          fromDataCon = P.map (\v -> M.findWithDefault Nothing v map) freeVars
          removeMaybe = Mb.catMaybes fromDataCon
          newDatacons =
            [ if dcon == datacon
                then Just (dcon, id')
                else Nothing
              | (dcon, id') <- removeMaybe
            ]
          newDatacons' = Mb.catMaybes newDatacons
       in newDatacons'
    ProjE i e -> error "findFieldInDataConFromVariableInExpression: TODO ProjE"
    TimeIt e ty b ->
      error "findFieldInDataConFromVariableInExpression: TODO TimeIt"
    WithArenaE v e ->
      error "findFieldInDataConFromVariableInExpression: TODO WithArenaE"
    SpawnE f locs args ->
      error "findFieldInDataConFromVariableInExpression: TODO SpawnE"
    SyncE -> error "findFieldInDataConFromVariableInExpression: TODO SyncE"
    Ext _ -> error "findFieldInDataConFromVariableInExpression: TODO Ext"
    MapE {} -> error "findFieldInDataConFromVariableInExpression: TODO MapE"
    FoldE {} -> error "findFieldInDataConFromVariableInExpression: TODO FoldE"

    


findIndexOfFields :: FunDef1 -> DataCon -> M.Map Int [Var]
findIndexOfFields f@FunDef{funName, funBody, funTy, funArgs} dcon = findIndexOfFieldsFunBody funBody dcon M.empty


findIndexOfFieldsFunBody :: Exp1 -> DataCon -> M.Map Int [Var] ->  M.Map Int [Var]
findIndexOfFieldsFunBody exp dcon m = case exp of
          -- Assumption that args will be flattened. 
          DataConE loc dcon args -> M.unions $ P.map (\exp -> findIndexOfFieldsFunBody exp dcon m) args --P.foldr (\exp m -> findIndexOfFieldsFunBody exp dcon) M.empty args
          -- DataConE loc dcon args -> P.foldr (\exp m -> case exp of 
          --                                                   VarE v -> let idx = elemIndex exp args 
          --                                                               in case idx of 
          --                                                                     Nothing -> error "Did not expect empty idx."
          --                                                                     Just idx' -> case M.lookup idx' m of 
          --                                                                                         Nothing -> M.insert idx' [v] m
          --                                                                                         Just lst -> M.insert idx' (lst ++ [v]) m
          --                                                   LitSymE v -> error "TODO: implememt for LitSymE."
          --                                   ) M.empty args 
          VarE {} -> m
          LitE {} -> m 
          CharE {} -> m 
          FloatE {} -> m
          LitSymE {} -> m 
          AppE f locs args -> M.unions $ P.map (\exp -> findIndexOfFieldsFunBody exp dcon m) args
          PrimAppE f args -> M.unions $ P.map (\exp -> findIndexOfFieldsFunBody exp dcon m) args
          LetE (v, loc, ty, rhs) bod -> let m'  = findIndexOfFieldsFunBody rhs dcon m 
                                            m'' = findIndexOfFieldsFunBody bod dcon m' 
                                         in m'' 
          -- mp == [(DataCon, [(Var, loc)], PreExp ext loc dec)]
          -- Change this to take from the Case expression instead. 
          CaseE scrt mp -> M.unions $ P.map (\(a, b, c) -> if (a == dcon)
                                                           then let ms' = M.unions $ P.map (\vv@(var, loc)-> let idx = elemIndex vv b
                                                                                                  in case idx of 
                                                                                                        Nothing -> error "Did not expect empty idx."
                                                                                                        Just idx' -> case M.lookup idx' m of 
                                                                                                                            Nothing -> M.insert idx' [var] m
                                                                                                                            Just lst -> M.insert idx' (lst ++ [var]) m
                                                                          ) b
                                                                    --m'' = findIndexOfFieldsFunBody c dcon ms' 
                                                                 in ms'
                                                           else m --let m' = findIndexOfFieldsFunBody c dcon m 
                                                                 --in m'                                   
                                            ) mp 
          -- CaseE scrt mp -> P.foldr (\(a, b, c) m -> let m' = findIndexOfFieldsFunBody c dcon 
          --                                            in M.union m m'                                   
          --                          ) M.empty mp 
          IfE a b c -> let mapA = findIndexOfFieldsFunBody a dcon m
                           mapB = findIndexOfFieldsFunBody b dcon mapA
                           mapC = findIndexOfFieldsFunBody c dcon mapB
                         in mapC -- M.unions [mapA, mapB, mapC]
          MkProdE xs ->  M.unions $ P.map (\exp -> findIndexOfFieldsFunBody exp dcon m) xs
          ProjE {} -> error "findIndexOfFieldsFunBody: TODO ProjE"
          TimeIt {} -> error "findIndexOfFieldsFunBody: TODO TimeIt"
          WithArenaE {} -> error "findIndexOfFieldsFunBody: TODO WithArenaE"
          SpawnE {} -> error "findIndexOfFieldsFunBody: TODO SpawnE"
          SyncE -> error "findIndexOfFieldsFunBody: TODO SyncE"
          Ext{} -> error "findIndexOfFieldsFunBody: TODO Ext"
          MapE {} -> error "findIndexOfFieldsFunBody: TODO MapE"
          FoldE {} -> error "findIndexOfFieldsFunBody: TODO FoldE"

findDataFlowDependencies :: FunDef1 -> M.Map Var [Var]
findDataFlowDependencies f@FunDef{funName, funBody, funTy, funArgs} = findDataFlowDependenciesFunBody funBody


-- Want to capture Read -> Read and Read -> Write dependencies. 
findDataFlowDependenciesFunBody :: Exp1 -> M.Map Var [Var]
findDataFlowDependenciesFunBody exp = case exp of
          DataConE loc dcon args -> M.unions $ P.map findDataFlowDependenciesFunBody args
          VarE {} -> M.empty
          LitE {} -> M.empty
          CharE {} -> M.empty
          FloatE {} -> M.empty
          LitSymE {} -> M.empty
          AppE f locs args ->  M.unions $ P.map findDataFlowDependenciesFunBody args
          PrimAppE f args ->  M.unions $ P.map findDataFlowDependenciesFunBody args
          -- RW dependence, rhs read, v is written to. 
          LetE (v, loc, ty, rhs) bod -> let vars_read = gFreeVars rhs 
                                            newMap = P.foldr (\v' m -> let elem = M.lookup v' m  
                                                                        in case elem of 
                                                                          Nothing -> M.insert v' [v] m
                                                                          Just lst -> M.insert v' (lst ++ [v]) m                                                           
                                                             ) M.empty vars_read
                                            m' = findDataFlowDependenciesFunBody rhs                  
                                            m'' = findDataFlowDependenciesFunBody bod 
                                         in M.unions [newMap, m', m''] 
          -- mp == [(DataCon, [(Var, loc)], PreExp ext loc dec)]
          CaseE scrt mp -> let vars_read = S.toList $ gFreeVars scrt
                               vars_dep  = P.foldr (\(a, b, c) st -> let vars = S.fromList $ P.map (\(vv, ll) -> vv) b
                                                                         vars' = gFreeVars c 
                                                                       in S.union vars vars'
                                                   ) S.empty mp
                               newMap = P.foldr (\v' m -> let elem = M.lookup v' m  
                                                                        in case elem of 
                                                                          Nothing -> M.insert v' (S.toList vars_dep) m 
                                                                          Just lst -> M.insert v' (lst ++ (S.toList vars_dep)) m                                                               
                                                ) M.empty vars_read
                              --  newMap' = P.foldr (\(a, b, c) mm -> let mm' = P.foldr (\(var, l) m'' -> let dep_vars = gFreeVars c 
                              --                                                                       in case M.lookup var m'' of 
                              --                                                                             Nothing -> M.insert var (S.toList dep_vars) m''
                              --                                                                             Just x -> M.insert var (x ++ S.toList dep_vars) m''
                              --                                                        ) M.empty b
                              --                                        in M.union mm mm'
                              --                    ) M.empty mp 
                               newMap'' = P.foldr (\(a, b, c) mm -> let mm' = findDataFlowDependenciesFunBody c 
                                                                      in M.union mm mm'
                                                  ) M.empty mp
                            in M.unions [newMap, newMap'']
          -- RW dependence, vars in a are read, b and c all could have Read or written to vars. 
          IfE a b c -> let vars_read = gFreeVars a 
                           vars_dep = {-dbgTraceIt ("Vars Read: ") dbgTraceIt (show vars_read) dbgTraceIt ("\n")-} S.union (gFreeVars b) (gFreeVars c)
                           newMap = P.foldr (\v' m -> let elem = M.lookup v' m  
                                                                        in case elem of 
                                                                          Nothing -> M.insert v' (S.toList vars_dep) m 
                                                                          Just lst -> M.insert v' (lst ++ (S.toList vars_dep)) m                                                               
                                            ) M.empty vars_read
                           mapA = findDataFlowDependenciesFunBody b
                           mapB = findDataFlowDependenciesFunBody c 
                         in M.unions [newMap, mapA, mapB]
          MkProdE xs -> M.unions $ P.map findDataFlowDependenciesFunBody xs
          ProjE _ e -> findDataFlowDependenciesFunBody e 
          TimeIt e _ _ -> findDataFlowDependenciesFunBody e 
          WithArenaE _ e -> findDataFlowDependenciesFunBody e
          SpawnE _ _ e -> M.unions $ P.map findDataFlowDependenciesFunBody e
          SyncE -> error "TODO: FindDataFlowDependenciesFunBody implement for SyncE"
          Ext{} -> error "TODO: FindDataFlowDependenciesFunBody implement for Ext{}"
          MapE {} -> error "TODO: FindDataFlowDependenciesFunBody implement for MapE{}"
          FoldE {} -> error "TODO: FindDataFlowDependenciesFunBody implement for FoldE{}"


-- TODO: need to generate the right type of edges. 

generateSolverEdges :: FunDef1 -> DataCon -> FieldMap -> [Constr]
generateSolverEdges fundef@FunDef{funName, funBody, funTy, funArgs, funMeta} dcon fmap = 
                                                                                let functionEdges = {-dbgTraceIt ("STARTED!")-} M.lookup funName fmap 
                                                                                  in case functionEdges of 
                                                                                          Nothing -> error "generateSolverEdges: functon does not exist.\n"
                                                                                          Just k -> case M.lookup dcon k of 
                                                                                                              Nothing -> error "generateSolverEdges: No associated edges exist for the function.\n"
                                                                                                              Just edges -> let indexToVariables = findIndexOfFields fundef dcon
                                                                                                                                dataFlowDependencies = {-dbgTraceIt ("ENDED") dbgTraceIt (sdoc indexToVariables) dbgTraceIt ("Print FunDef") dbgTraceIt (sdoc fundef)-} findDataFlowDependencies fundef
                                                                                                                                newEdges = {-dbgTraceIt ("FLOWDEPS") dbgTraceIt (sdoc dataFlowDependencies)-} (\FunMeta{dataConFieldTypeInfo} -> case dataConFieldTypeInfo of 
                                                                                                                                                                                      Nothing -> error "No associated field type record.\n"
                                                                                                                                                                                      Just x -> case M.lookup dcon x of 
                                                                                                                                                                                                      Nothing -> error "No field type for dcon.\n"
                                                                                                                                                                                                      Just y -> P.map (\((a, b), weight) -> ((a, fromJust (M.lookup (P.fromInteger a) y)), (b, fromJust (M.lookup (P.fromInteger b) y)), weight)) edges
                                                                                                                                           ) funMeta
                                                                                                                                newEdges' = P.map (\e@((a,a'),(b,b'), wt) -> let varA =  M.findWithDefault ( [(toVar "")]) (P.fromInteger a) indexToVariables
                                                                                                                                                                                 varB =  M.findWithDefault ( [(toVar "")]) (P.fromInteger b) indexToVariables 
                                                                                                                                                                                 lambda = (\var l s -> let b = S.member var s 
                                                                                                                                                                                                        in if b
                                                                                                                                                                                                        then l 
                                                                                                                                                                                                        else case M.lookup var dataFlowDependencies of
                                                                                                                                                                                                                   Nothing -> l
                                                                                                                                                                                                                   Just lst -> let s' = S.insert var s 
                                                                                                                                                                                                                                in P.foldr (\v l' -> lambda v l' s') (lst ++ l) lst 
                                                                                                                                                                                          )
                                                                                                                                                                                 varA' = if P.length varA /= 1 then error "TODO: multiple variables to optimize." else P.head varA 
                                                                                                                                                                                 varB' = if P.length varB /= 1 then error "TODO: multiple variables to optimize." else P.head varB
                                                                                                                                                                                 reachable = lambda varA' [] S.empty
                                                                                                                                                                               in case (elem varB' reachable) of 
                                                                                                                                                                                      False -> WeakConstr   (((a,a'),(b,b')), wt)
                                                                                                                                                                                      True  -> StrongConstr (((a,a'),(b,b')), wt)                                 
                                                
                                                                                                                
                                                                                                                                                  ) newEdges           
                                                                                                                                -- TODO: make the Weak vs Strong Constraints out of these edges. 
                                                                                                                              in {-dbgTraceIt ("PrintEdges with the types embedded:\n") dbgTraceIt (sdoc (newEdges', fundef))-} newEdges'
                                                                                                                                --fMeta{dataConFieldTypeInfo = fieldTypeInfo} = funMeta
                                                                                                                                --newEdges = P.map (((a, b), weight) -> let ) edges 