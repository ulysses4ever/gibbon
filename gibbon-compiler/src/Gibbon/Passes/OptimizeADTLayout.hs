{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use lambda-case" #-}
{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}
{-# HLINT ignore "Redundant lambda" #-}
{-# HLINT ignore "Use tuple-section" #-}
module Gibbon.Passes.OptimizeADTLayout
  ( 
    globallyOptimizeDataConLayout,
    locallyOptimizeDataConLayout
  )
where

-- Gibbon imports

import Control.Exception (evaluate)
import Data.List as L

import           Data.Graph                     as G
import           Control.Monad

import Data.Set as S
-- Haskell imports
import Data.Map as M
import Data.Maybe as Maybe
import Data.Time.Clock
  ( diffUTCTime,
    getCurrentTime,
  )
import Gibbon.Common
import Gibbon.Language
import Gibbon.Language.Syntax
import Gibbon.L1.Syntax as L1
import Gibbon.Passes.AccessPatternsAnalysis
  ( DataConAccessMap,
    FieldMap,
    generateAccessGraphs,
    getGreedyOrder, 
    generateSolverEdges
  )
import Gibbon.Passes.CallGraph
  ( ProducersMap (..),
    generateProducerGraph,
  )
import Gibbon.Passes.ControlFlowGraph (getFunctionCFG)
import Gibbon.Passes.DefinitionUseChains
  ( DefUseChainsFunctionMap (..),
    generateDefUseChainsFunction,
    progToVEnv,
    getDefinitionsReachingLetExp,
    UseDefChainsFunctionMap (..)
  )
import Gibbon.Passes.SolveLayoutConstrs (solveConstrs)
import Gibbon.Pretty
import System.CPUTime
import System.IO.Unsafe as U
import System.TimeIt
import Text.PrettyPrint.GenericPretty
import Prelude as P
import Data.Either
import Data.Data (Data)
import qualified Gibbon.L2.Syntax as L1
import qualified Data.Foldable as P
import qualified Data.Tree as L1
import qualified Gibbon.Passes.Flatten as L1
import Gibbon.Passes.Flatten (flattenL1)

-- | Data structure to store output from ILP solver.
-- | Maps DataCon to bijection of new indices -> fields of datacon
type FieldOrder = M.Map DataCon [Integer]

-- TODO: Make FieldOrder an argument passed to shuffleDataCon function.
--optimizeADTLayout ::
--  Prog1 ->
--  PassM Prog1
--optimizeADTLayout prg@Prog{ddefs, fundefs, mainExp} =
  --do
    -- let list_pair_func_dcon =
    --       concatMap ( \fn@(FunDef {funName, funMeta = FunMeta {funOptLayout = layout}}) ->
    --               case layout of
    --                 Single dcon -> [(fromVar funName, dcon)]
    --                 -- only handles optimizing a single dcon for a function right now.
    --                 -- its okay for the current examples
    --                 -- but should be extended
    --                 _ -> []
    --           ) (M.elems fundefs)
    -- -- If a total ordering is defined for a function (by the user), then we should just use that instead.
    -- -- The total ordering defined by the user should just override
    -- -- get the function for which the total ordering is defined and get the corresponding total ordering.
    -- -- Tuple (funcName, map) map : map from data constructor to the user defined ordering.
    -- let userConstraints =
    --       concatMap ( \fn@( FunDef
    --                     { funName,
    --                       funMeta = FunMeta {userConstraintsDataCon = totalOrdering}
    --                     }
    --                   ) ->
    --                 case totalOrdering of
    --                   Nothing -> []
    --                   Just m -> [(fromVar funName, m)]
    --           ) (M.elems fundefs)
    -- -- pure prg
    -- case userConstraints of
    --   [] ->
    --     case list_pair_func_dcon of
    --       [] -> pure prg
    --       --TODO: handle for more than one function
    --       (funcName, dcon) : xs -> do
    --         let [fundef] =
    --               P.concatMap
    --                 ( \fn@(FunDef {funName}) ->
    --                     ([fn | fromVar funName == funcName])
    --                 )
    --                 (M.elems fundefs)
    --         let (ddefs', fundef', fieldorder) =
    --               optimizeFunctionWRTDataCon ddefs fundef dcon
    --         let fundefs' = M.delete (toVar funcName) fundefs
    --         let fundefs'' = M.insert (toVar funcName) fundef' fundefs'
    --         let venv = progToVEnv prg
    --         let pmap = generateProducerGraph prg
    --         let p = prg {ddefs = ddefs', fundefs = fundefs'', mainExp = mainExp}
    --         let prg' =
    --               genNewProducersAndRewriteProgram
    --                 (toVar funcName)
    --                 (dcon ++ "Optimized")
    --                 fieldorder
    --                 venv
    --                 pmap
    --                 p
    --         pure prg'
      --prg' <- runUntilFixPoint prg
      --globallyOptimizeDataConLayout prg
      --pure prg'
            --generateCopyFunctionsForFunctionsThatUseOptimizedVariable (toVar funcName) (dcon ++ "Optimized") fieldorder prg'
      --_ -> error "OptimizeFieldOrder: handle user constraints"


locallyOptimizeDataConLayout :: Bool -> Prog1 -> PassM Prog1 
locallyOptimizeDataConLayout useGreedy prg1 = do 
  runUntilFixPoint useGreedy prg1 



runUntilFixPoint :: Bool -> Prog1 -> PassM Prog1
runUntilFixPoint useGreedy prog1 = do
  prog1' <- producerConsumerLayoutOptimization prog1 useGreedy
  prog1'' <- flattenL1 prog1'
  if prog1 == prog1''
  then return prog1
  else runUntilFixPoint useGreedy prog1'' 


dataConsInFunBody :: Exp1 -> S.Set DataCon
dataConsInFunBody funBody = case funBody of
            DataConE _ dcon args -> let dcons = S.unions $ P.map dataConsInFunBody args
                                      in S.union (S.singleton dcon) dcons
            VarE {} -> S.empty
            LitE {} -> S.empty
            CharE {} -> S.empty
            FloatE {} -> S.empty
            LitSymE {} -> S.empty
            AppE f locs args -> S.unions $ P.map dataConsInFunBody args
            PrimAppE f args -> S.unions $ P.map dataConsInFunBody args
            LetE (v, loc, ty, rhs) bod -> S.union (dataConsInFunBody rhs) (dataConsInFunBody bod)
            -- a == DataCon
            -- b == [(Var, loc)]
            -- c == Case Body
            CaseE scrt mp -> S.unions $ P.map (\(a, b, c) -> S.union (S.singleton a) (dataConsInFunBody c)) mp
            IfE a b c -> S.unions $ [dataConsInFunBody a] ++ [dataConsInFunBody b] ++ [dataConsInFunBody c]
            MkProdE xs -> S.unions $ P.map dataConsInFunBody xs
            ProjE i e -> error "getGeneratedVariable: TODO ProjE"
            TimeIt e ty b -> dataConsInFunBody e
            WithArenaE v e -> error "getGeneratedVariable: TODO WithArenaE"
            SpawnE f locs args -> error "getGeneratedVariable: TODO SpawnE"
            SyncE -> error "getGeneratedVariable: TODO SyncE"
            Ext _ -> error "getGeneratedVariable: TODO Ext"
            MapE {} -> error "getGeneratedVariable: TODO MapE"
            FoldE {} -> error "getGeneratedVariable: TODO FoldE"

producerConsumerLayoutOptimization :: Prog1 -> Bool -> PassM Prog1
producerConsumerLayoutOptimization prg@Prog{ddefs, fundefs, mainExp} useGreedy = do
  -- TODO: make a custom function name printer that guarantees that functions starting with _ are auto-generated. 
  let funsToOptimize = P.concatMap (\FunDef{funName} -> ([funName | not $ isInfixOf "_" (fromVar funName)])
                                   ) $ M.elems fundefs
  let pairDataConFuns = P.concatMap (\name -> case M.lookup name fundefs
                                                       of Just f@FunDef{funName, funBody} -> [(f, dataConsInFunBody funBody)]
                                                          Nothing -> []
                                    ) funsToOptimize
  let linearizeDcons = P.concatMap (\(f, dcons) -> let l = S.toList dcons
                                               in P.map (\d -> (f, d)) l
                             ) pairDataConFuns
  let lambda = (\(f@FunDef{funName=fname}, dcon) pr@Prog{ddefs=dd, fundefs=fds, mainExp=mexp} -> do
                                   --let newDcon = dcon ++ "Optimized"
                                   newSymDcon  <- gensym (toVar dcon)
                                   -- dbgTraceIt (sdoc mexp) 
                                   let maybeFd = M.lookup fname fds
                                   let fd = case maybeFd of
                                                  Just x -> x
                                                  Nothing -> error "producerConsumerLayoutOptimization: expected a function definition!!"
                                   let fieldOrder = getAccessGraph f dcon
                                   let result = {-dbgTraceIt ("CHECKPOINTA\n")-} optimizeFunctionWRTDataCon dd fd dcon (fromVar newSymDcon) fieldOrder useGreedy
                                   case result of
                                     Nothing ->  pure pr --dbgTraceIt (sdoc (result, fname, fieldOrder)) 
                                     Just (ddefs', fundef', fieldorder) -> let fundefs' = M.delete fname fds
                                                                               fundefs'' = M.insert fname fundef' fundefs'
                                                                               p = Prog{ddefs = ddefs', fundefs = fundefs'', mainExp = mexp}
                                                                               venv = progToVEnv p
                                                                               pmap = generateProducerGraph p
                                                                               prg' = genNewProducersAndRewriteProgram fname (fromVar newSymDcon) fieldorder venv pmap p
                                                                             in dbgTraceIt ("Producer Graph:\n") dbgTraceIt (sdoc pmap) dbgTraceIt ("End\n")  pure prg' --dbgTraceIt (sdoc (result, fname, fundef', fieldOrder))
                )
  P.foldrM lambda prg linearizeDcons --dbgTraceIt (sdoc linearizeDcons)


globallyOptimizeDataConLayout :: Bool -> Prog1 -> PassM Prog1
globallyOptimizeDataConLayout useGreedy prg@Prog{ddefs, fundefs, mainExp} = do
  -- TODO: make a custom function name printer that guarantees that functions starting with _ are auto-generated. 
  -- let f' = P.map (deduceFieldSolverTypes ddefs) (M.elems fundefs)
  let funsToOptimize = P.concatMap (\FunDef{funName} -> ([funName | not (isInfixOf "_" (fromVar funName))])
                                   ) $ M.elems fundefs --f'
  let pairDataConFuns = P.concatMap (\name -> case M.lookup name fundefs
                                                       of Just f@FunDef{funName, funBody} -> [(f, dataConsInFunBody funBody)]
                                                          Nothing -> []
                                    ) funsToOptimize
  let linearizeDcons = P.concatMap (\(f, dcons) -> let l = S.toList dcons
                                               in P.map (\d -> (f, d)) l
                                   ) pairDataConFuns
  let clubSameDcons = P.foldr (\(f, dcon) map -> case M.lookup dcon map of
                                                            Nothing -> M.insert dcon [f] map
                                                            Just funList -> M.insert dcon (funList ++ [f]) map
                              ) M.empty linearizeDcons

  let lstElements = M.toList clubSameDcons

  let dconToFieldOrder = P.map (\(dcon, funList) -> let allEdges = P.concatMap (\f@FunDef{funName} -> let dconmap  = getAccessGraph f dcon
                                                                                                          maybeElem = M.lookup funName dconmap
                                                                                                              in case maybeElem of
                                                                                                                Nothing -> []
                                                                                                                Just edgeLst -> fromMaybe [] (M.lookup dcon edgeLst)
                                                                               ) funList
                                                     in (dcon, allEdges)
                               ) lstElements
  -- Does not account for function weight as of the moment. 
  let mergedEdges = P.foldr (\(dcon, edgeList) m'' -> let m' = P.foldr (\(a, b) m -> case M.lookup a m of
                                                                             Nothing -> M.insert a b m
                                                                             Just weight -> M.insert a (weight + b) m 
                                                                                 
                                                                 ) M.empty edgeList
                                                                 
                                                          e' = M.toList m'
                                                        in M.insert dcon e' m''
                          ) M.empty dconToFieldOrder

  let funsToOptimizeTripleGreedy = P.concatMap 
                            (\(dcon, funList) -> let edges' = M.lookup dcon mergedEdges 
                                                   in case edges' of 
                                                           Nothing -> []
                                                           Just x -> [(funList, dcon, x)] 
                            ) lstElements
                          
  let funsToOptimizeTriple = P.concatMap (\(dcon, funList) -> let edges' = M.lookup dcon mergedEdges 
                                                   in case edges' of 
                                                           Nothing -> []
                                                           Just x -> let m = M.insert dcon x M.empty
                                                                        in [(funList, dcon, m)] 
                             ) lstElements
  
  let funsToOptimizeTriple' = P.map (\(funList, dcon, m) -> (P.map (\f -> deduceFieldSolverTypes ddefs f) funList, dcon, m)) funsToOptimizeTriple

  let funsToOptimizeTripleSolver = dbgTraceIt (sdoc funsToOptimizeTriple') P.map 
                        (\(funList, dcon, m) -> let constraints = S.toList $ S.fromList $ P.concatMap (\f@FunDef{funName=fname} -> let fieldOrder = M.insert fname m M.empty
                                                                                                                                       constrs = generateSolverEdges f dcon fieldOrder
                                                                                                                                     in constrs
                                                                                                      ) funList
                                                    mergedConstraints = dbgTraceIt (sdoc constraints) mergeConstraints $ constraints
                                                  in (funList, dcon, mergedConstraints)
                        ) funsToOptimizeTriple'

  let solverOptimization =
              (\(f@FunDef{funName=fname}, (dcon, newSymDcon), constrs) pr@Prog{ddefs=dd, fundefs=fds, mainExp=mexp} -> do 
                      let maybeFd = M.lookup fname fds
                      let fd = case maybeFd of
                                                  Just x -> x
                                                  Nothing -> error "globallyOptimizeDataConLayout: expected a function definition!!" 
                      let result = optimizeFunctionWRTDataConGlobal dd fd dcon (fromVar newSymDcon) (Left constrs) useGreedy
                      case result of
                                     Nothing -> pure pr 
                                     Just (ddefs', fundef', fieldorder) -> let fundefs' = M.delete fname fds
                                                                               fundefs'' = M.insert fname fundef' fundefs'
                                                                               p = Prog{ddefs = ddefs', fundefs = fundefs'', mainExp = mexp}
                                                                               prg' = globallyChangeDataConstructorLayout dcon (fromVar newSymDcon) fieldorder p
                                                                             in pure prg'
                ) 

  let solverMain = 
              (\(fList, dcon, constrs) pr@Prog{ddefs=dd, fundefs=fds, mainExp=mexp} -> do
                                   newSymDcon  <- gensym (toVar dcon)
                                   let vals = P.map (\f -> (f, (dcon, newSymDcon), constrs)) fList 
                                   P.foldrM solverOptimization pr vals
              )

  let greedyOptimization = 
                  (\(f@FunDef{funName=fname}, (dcon, newSymDcon), edges) pr@Prog{ddefs=dd, fundefs=fds, mainExp=mexp} -> do 
                          let maybeFd = M.lookup fname fds 
                          let fd = case maybeFd of 
                                          Just x -> x 
                                          Nothing -> error "globallyOptimizeDataConLayout: greedy: expected a function definition!!"
                          let result = optimizeFunctionWRTDataConGlobal dd fd dcon (fromVar newSymDcon) (Right edges) useGreedy
                          case result of
                                     Nothing -> pure pr 
                                     Just (ddefs', fundef', fieldorder) -> let fundefs' = M.delete fname fds
                                                                               fundefs'' = M.insert fname fundef' fundefs'
                                                                               p = Prog{ddefs = ddefs', fundefs = fundefs'', mainExp = mexp}
                                                                               prg' = globallyChangeDataConstructorLayout dcon (fromVar newSymDcon) fieldorder p
                                                                             in pure prg'
                  )

  let greedyMain = 
            (\(fList, dcon, edges) pr@Prog{ddefs=dd, fundefs=fds, mainExp=mexp} -> do 
                              newSymDcon <- gensym (toVar dcon)
                              let vals = P.map (\f -> (f, (dcon, newSymDcon), edges)) fList 
                              P.foldrM greedyOptimization pr vals
            )
  if useGreedy then P.foldrM greedyMain prg funsToOptimizeTripleGreedy else P.foldrM solverMain prg funsToOptimizeTripleSolver


isStrongConstr :: Constr -> Bool 
isStrongConstr constr = case constr of 
                              StrongConstr _ -> True 
                              _ -> False

-- Fold over all constraints to make sure we are not using duplicate constraints across different functions with possibly 
-- different field meta data. Union all the meta data about a field globally by merding constraints.
mergeConstraints :: [Constr] -> [Constr]
mergeConstraints lst = case lst of 
  [] -> [] 
  [x] -> [x]
  x@(WeakConstr e@(((a, ma), (b, mb)), _)):y -> let (x', y') = P.foldr (\constr (newConstr, tail) -> case constr of 
                                                                                          WeakConstr e'@(((a', ma'), (b', mb')), wt) -> if (a, b) == (a', b') 
                                                                                                                                        then
                                                                                                                                          if isStrongConstr constr 
                                                                                                                                          then (StrongConstr (((a', removeDuplicates $ ma' ++ ma), (b', removeDuplicates $ mb' ++ mb)), wt), tail) 
                                                                                                                                          else (WeakConstr (((a', removeDuplicates $ ma' ++ ma), (b', removeDuplicates $ mb' ++ mb)), wt), tail) 
                                                                                                                                        else (newConstr, tail ++ [constr])
                                                                                          StrongConstr e'@(((a', ma'), (b', mb')), wt) -> if (a, b) == (a', b') 
                                                                                                                                          then (StrongConstr (((a', removeDuplicates $ ma' ++ ma), (b', removeDuplicates $ mb' ++ mb)), wt), tail) 
                                                                                                                                          else (newConstr, tail ++ [constr])


                                                                        ) (x, []) y 
                                                  in [x'] ++ (mergeConstraints y')
                                 
  x@(StrongConstr e@(((a, ma), (b, mb)), _)):y -> let (x', y') = P.foldr (\constr (newConstr, tail) -> case constr of 
                                                                                          WeakConstr e'@(((a', ma'), (b', mb')), wt) -> if (a, b) == (a', b') 
                                                                                                                                          then (StrongConstr (((a', removeDuplicates $ ma' ++ ma), (b', removeDuplicates $ mb' ++ mb)), wt), tail) 
                                                                                                                                          else (newConstr, tail ++ [constr])
                                                                                          StrongConstr e'@(((a', ma'), (b', mb')), wt) -> if (a, b) == (a', b') 
                                                                                                                                          then (StrongConstr (((a', removeDuplicates $ ma' ++ ma), (b', removeDuplicates $ mb' ++ mb)), wt), tail) 
                                                                                                                                          else (newConstr, tail ++ [constr])


                                                                        ) (x, []) y 
                                                    in [x'] ++ (mergeConstraints y')


generateCopyFunctionsForFunctionsThatUseOptimizedVariable :: Var -> DataCon -> FieldOrder -> Prog1 -> PassM Prog1
generateCopyFunctionsForFunctionsThatUseOptimizedVariable funcName newDconName fieldOrder prg@Prog{ddefs, fundefs, mainExp} = case mainExp of
                                                                                                                                      Nothing -> error "no main exp in generateCopyFunctionsForFunctionsThatUseOptimizedVariable."
                                                                                                                                      Just (expr, ty) -> let generatedVars = S.toList $ S.fromList $ getGeneratedVariable expr
                                                                                                                                                          in case generatedVars of
                                                                                                                                                                    [v] -> do  let funcsUsingVar = findFunctionsUsingVar v expr
                                                                                                                                                                               fundefs' <- makeFunctionCopies funcsUsingVar ddefs fundefs
                                                                                                                                                                               --(toVar (fromVar func ++ "_new"))
                                                                                                                                                                               let exp' = P.foldr (\func ex -> replaceFunctionName func func ex ) expr funcsUsingVar
                                                                                                                                                                               pure prg {ddefs = ddefs, fundefs = fundefs', mainExp = Just (exp', ty)}
                                                                                                                                                                    [] -> error "generateCopyFunctionsForFunctionsThatUseOptimizedVariable: no variables found"
                                                                                                                                                                    _ -> error "generateCopyFunctionsForFunctionsThatUseOptimizedVariable: handle multiple produced variables"
  where
    getGeneratedVariable exp = case exp of
          DataConE loc dcon args -> P.concatMap getGeneratedVariable args
          VarE {} -> []
          LitE {} -> []
          CharE {} -> []
          FloatE {} -> []
          LitSymE {} -> []
          AppE f locs args -> P.concatMap getGeneratedVariable args
          PrimAppE f args -> P.concatMap getGeneratedVariable args
          LetE (v, loc, ty, rhs) bod -> case rhs of
                                              AppE f' _ _ -> if f' == funcName then [v] ++ getGeneratedVariable rhs ++ getGeneratedVariable bod
                                                             else getGeneratedVariable rhs ++ getGeneratedVariable bod
                                              _ -> getGeneratedVariable rhs ++ getGeneratedVariable bod
          CaseE scrt mp -> P.concatMap (\(_, _, c) -> getGeneratedVariable c ) mp
          IfE a b c -> getGeneratedVariable a ++ getGeneratedVariable b ++ getGeneratedVariable c
          MkProdE xs -> P.concatMap getGeneratedVariable xs
          ProjE i e -> error "getGeneratedVariable: TODO ProjE"
          TimeIt e ty b -> error "getGeneratedVariable: TODO TimeIt"
          WithArenaE v e -> error "getGeneratedVariable: TODO WithArenaE"
          SpawnE f locs args -> error "getGeneratedVariable: TODO SpawnE"
          SyncE -> error "getGeneratedVariable: TODO SyncE"
          Ext _ -> error "getGeneratedVariable: TODO Ext"
          MapE {} -> error "getGeneratedVariable: TODO MapE"
          FoldE {} -> error "getGeneratedVariable: TODO FoldE"

    replaceFunctionName oldName newName expr = case expr of
          DataConE loc dcon args -> DataConE loc dcon $ P.map (replaceFunctionName oldName newName) args
          VarE {} -> expr
          LitE {} -> expr
          CharE {} -> expr
          FloatE {} -> expr
          LitSymE {} -> expr
          AppE f locs args -> if f == oldName then AppE newName locs $ P.map (replaceFunctionName oldName newName) args
                              else AppE f locs $ P.map (replaceFunctionName oldName newName) args
          PrimAppE f args -> PrimAppE f $ P.map (replaceFunctionName oldName newName) args
          LetE (v, loc, ty, rhs) bod -> LetE (v, loc, ty, replaceFunctionName oldName newName rhs) (replaceFunctionName oldName newName bod)
          CaseE scrt mp -> let mp' = P.map (\(a, b, c) -> (a, b, replaceFunctionName oldName newName c)) mp
                             in CaseE scrt mp'
          IfE a b c -> IfE (replaceFunctionName oldName newName a) (replaceFunctionName oldName newName b) (replaceFunctionName oldName newName c)
          MkProdE xs -> MkProdE $ P.map (replaceFunctionName oldName newName) xs
          ProjE i e -> error "replaceFunctionName: TODO ProjE"
          TimeIt e ty b -> error "replaceFunctionName: TODO TimeIt"
          WithArenaE v e -> error "replaceFunctionName: TODO WithArenaE"
          SpawnE f locs args -> error "replaceFunctionName: TODO SpawnE"
          SyncE -> error "replaceFunctionName: TODO SyncE"
          Ext _ -> error "replaceFunctionName: TODO Ext"
          MapE {} -> error "replaceFunctionName: TODO MapE"
          FoldE {} -> error "replaceFunctionName: TODO FoldE"

    findFunctionsUsingVar var expr = case expr of
          DataConE loc dcon args -> P.concatMap (findFunctionsUsingVar var) args
          VarE {} -> []
          LitE {} -> []
          CharE {} -> []
          FloatE {} -> []
          LitSymE {} -> []
          AppE f locs args -> let freeVars = S.unions $ P.map gFreeVars args
                               in if S.member var freeVars
                                  then f : P.concatMap (findFunctionsUsingVar var) args
                                  else P.concatMap (findFunctionsUsingVar var) args
          PrimAppE f args -> P.concatMap (findFunctionsUsingVar var) args
          LetE (v, loc, ty, rhs) bod -> findFunctionsUsingVar var rhs ++ findFunctionsUsingVar var bod
          CaseE scrt mp -> P.concatMap (\(_, _, c) -> findFunctionsUsingVar var c) mp
          IfE a b c -> findFunctionsUsingVar var a ++  findFunctionsUsingVar var b ++ findFunctionsUsingVar var c
          MkProdE xs -> P.concatMap (findFunctionsUsingVar var) xs
          ProjE i e -> error "findFunctionsUsingVar: TODO ProjE"
          TimeIt e ty b -> error "findFunctionsUsingVar: TODO TimeIt"
          WithArenaE v e -> error "findFunctionsUsingVar: TODO WithArenaE"
          SpawnE f locs args -> error "findFunctionsUsingVar: TODO SpawnE"
          SyncE -> error "findFunctionsUsingVar: TODO SyncE"
          Ext _ -> error "findFunctionsUsingVar: TODO Ext"
          MapE {} -> error "findFunctionsUsingVar: TODO MapE"
          FoldE {} -> error "findFunctionsUsingVar: TODO FoldE"

    makeFunctionCopies funcList ddefs' fdefs = case funcList of
                                                  [] -> pure fdefs
                                                  x:xs -> if not $ isInfixOf "_print" (fromVar x)
                                                          then
                                                            let newFunctionName = x -- toVar (fromVar x ++ "_new")
                                                                oldFunctionBody = M.lookup x fdefs
                                                              in case oldFunctionBody of
                                                                        Just body -> let newFunctionBody = shuffleDataConFunBody True fieldOrder body newDconName
                                                                                         newFunctionBody' = changeCallNameInRecFunction newFunctionName newFunctionBody
                                                                                         funRemoveAllLets = (\FunDef{funName=fName, funBody=fBody, funTy=fTy, funArgs=fArgs, funMeta=fMeta} -> let removeLets = delAllLetBindings fBody
                                                                                                                                    in FunDef{funName=fName, funBody=removeLets, funTy=fTy, funArgs=fArgs, funMeta=fMeta}
                                                                                                            ) newFunctionBody'
                                                                                         var_order = S.toList $ (\FunDef{funBody=fb} -> gFreeVars fb) funRemoveAllLets
                                                                                         var_order' = P.map Just var_order
                                                                                         (m :: UseDefChainsFunctionMap Exp1) = getDefinitionsReachingLetExp newFunctionBody'
                                                                                         depLets = P.map (\vv -> getDependentLetBindings vv newFunctionName m) var_order
                                                                                         var_order'' = P.zip var_order' depLets
                                                                                         newFunctionBody''@FunDef{funName} = P.foldl (\fundef (insertPosition, dl) -> reOrderLetExp insertPosition dl fundef) funRemoveAllLets var_order''
                                                                                         --newFunctionBody''' = L1.flattenL1 newFunctionBody''
                                                                                         --fundefs' = M.delete funName fdefs 
                                                                                         fdefs' = M.insert funName newFunctionBody'' fdefs
                                                                                       in makeFunctionCopies xs ddefs' fdefs'
                                                                        Nothing -> error ""
                                                          else
                                                            do
                                                              let flds = snd $ lkp ddefs' newDconName
                                                              newPrintCase <- genPrintFnCase flds
                                                              let fn = M.lookup x fdefs
                                                              case fn of
                                                                  Just ff@FunDef{funName, funBody, funTy, funArgs, funMeta} -> let exp' = addCaseForNewDataConInPrintFn [newPrintCase] funBody
                                                                                                                                   fn'  = FunDef{funName=funName, funBody=exp', funTy=funTy, funArgs=funArgs, funMeta=funMeta}
                                                                                                                                   newFunctionName = x --toVar (fromVar x ++ "_new")
                                                                                                                                   newFunctionBody' = changeCallNameInRecFunction newFunctionName fn'
                                                                                                                                   fdefs' = M.insert newFunctionName newFunctionBody' fdefs
                                                                                                                                  in makeFunctionCopies xs ddefs' fdefs'


                                                                  Nothing -> error ""



    addCaseForNewDataConInPrintFn newCase expr = case expr of
          DataConE loc dcon args -> DataConE loc dcon $ P.map (addCaseForNewDataConInPrintFn newCase) args
          VarE {} -> expr
          LitE {} -> expr
          CharE {} -> expr
          FloatE {} -> expr
          LitSymE {} -> expr
          AppE f locs args -> AppE f locs $ P.map (addCaseForNewDataConInPrintFn newCase) args
          PrimAppE f args -> PrimAppE f $ P.map (addCaseForNewDataConInPrintFn newCase) args
          LetE (v, loc, ty, rhs) bod -> let rhs' = addCaseForNewDataConInPrintFn newCase rhs
                                            bod' = addCaseForNewDataConInPrintFn newCase bod
                                          in LetE (v, loc, ty, rhs') bod'
          CaseE scrt mp -> let mp' = mp ++ newCase
                            in CaseE scrt mp'
          IfE a b c -> IfE (addCaseForNewDataConInPrintFn newCase a) (addCaseForNewDataConInPrintFn newCase b) (addCaseForNewDataConInPrintFn newCase c)
          MkProdE xs -> MkProdE $ P.map (addCaseForNewDataConInPrintFn newCase) xs
          ProjE i e -> error "findFunctionsUsingVar: TODO ProjE"
          TimeIt e ty b -> error "findFunctionsUsingVar: TODO TimeIt"
          WithArenaE v e -> error "findFunctionsUsingVar: TODO WithArenaE"
          SpawnE f locs args -> error "findFunctionsUsingVar: TODO SpawnE"
          SyncE -> error "findFunctionsUsingVar: TODO SyncE"
          Ext _ -> error "findFunctionsUsingVar: TODO Ext"
          MapE {} -> error "findFunctionsUsingVar: TODO MapE"
          FoldE {} -> error "findFunctionsUsingVar: TODO FoldE"

getAccessGraph ::
  FunDef1 ->
  DataCon ->
  FieldMap
getAccessGraph
  fundef
  datacon =
    let cfg = getFunctionCFG fundef
      in generateAccessGraphs cfg M.empty fundef datacon


-- optimizeFunctionWRTDataConGlobal ::
--   DDefs1 ->
--   FunDef1 ->
--   DataCon ->
--   DataCon ->
--   FieldMap ->
--   Maybe (DDefs1, FunDef1, FieldOrder)
-- optimizeFunctionWRTDataConGlobal
--   ddefs
--   fundef@FunDef
--     { funName,
--       funBody,
--       funTy,
--       funArgs
--     }
--   datacon
--   newDcon
--   fieldMap =
--     let field_len = P.length $ snd . snd $ lkp' ddefs datacon
--         fieldorder =
--           optimizeDataConOrderFunc
--             fieldMap
--             M.empty
--             fundef
--             [(datacon, field_len)]
--             M.empty
--         -- make a function to generate a new data con as a value instead of changing the order of fields in the original one.
--         --[(dcon, order)] = M.toList fieldorder
--         --(newDDefs, newDcon) = optimizeDataCon (dcon, order) ddefs
--         --fundef' = shuffleDataConFunBody True fieldorder fundef newDcon
--         --(newDDefs, fundef', fieldorder)
--       in case M.toList fieldorder of
--                   [] ->  Nothing --dbgTraceIt (sdoc fieldorder)
--                   [(dcon, order)] -> let orignal_order = [0..(P.length order - 1)]
--                                        in if orignal_order == P.map P.fromInteger order
--                                           then Nothing
--                                           else let newDDefs = optimizeDataCon (dcon, order) ddefs newDcon
--                                                    fundef' = shuffleDataConFunBody True fieldorder fundef newDcon
--                                                  in Just (newDDefs, fundef', fieldorder) --dbgTraceIt (sdoc order) -- dbgTraceIt (sdoc fieldorder)
--                   _ -> error "more than one"




-- getGreedyFieldOrder :: Int -> DataCon -> FieldMap 

optimizeFunctionWRTDataCon ::
  DDefs1 ->
  FunDef1 ->
  DataCon ->
  DataCon ->
  FieldMap ->
  Bool ->
  Maybe (DDefs1, FunDef1, FieldOrder)
optimizeFunctionWRTDataCon
  ddefs
  fundef@FunDef
    { funName,
      funBody,
      funTy,
      funArgs
    }
  datacon
  newDcon
  fieldMap
  useGreedy = case useGreedy of 
   False -> 
    let field_len = P.length $ snd . snd $ lkp' ddefs datacon
        fieldorder = dbgTraceIt (sdoc funName) dbgTraceIt ("End1\n")
          optimizeDataConOrderFunc
            fieldMap
            M.empty
            (deduceFieldSolverTypes ddefs fundef) --deduceFieldSolverTypes ddefs f)
            [(datacon, field_len)]
            M.empty
        -- make a function to generate a new data con as a value instead of changing the order of fields in the original one.
        --[(dcon, order)] = M.toList fieldorder
        --(newDDefs, newDcon) = optimizeDataCon (dcon, order) ddefs
        --fundef' = shuffleDataConFunBody True fieldorder fundef newDcon
        --(newDDefs, fundef', fieldorder)
      in case M.toList fieldorder of
                  [] -> dbgTraceIt (sdoc funName) dbgTraceIt ("End2\n") Nothing --dbgTraceIt (sdoc fieldorder)
                  [(dcon, order)] -> let orignal_order = [0..(P.length order - 1)]
                                       in if orignal_order == P.map P.fromInteger order
                                          then dbgTraceIt (sdoc funName) dbgTraceIt ("End2\n") Nothing
                                          else let newDDefs = optimizeDataCon (dcon, order) ddefs newDcon
                                                   fundef' = shuffleDataConFunBody True fieldorder fundef newDcon
                                                 in {-dbgTraceIt ("CHECKPOINT2\n")-} Just (newDDefs, fundef', fieldorder) --dbgTraceIt (sdoc order) -- dbgTraceIt (sdoc fieldorder)
                  _ -> error "more than one"
   True ->
    let field_len = P.length $ snd . snd $ lkp' ddefs datacon
        edges' = case (M.lookup funName fieldMap) of 
                       Just d  -> case (M.lookup datacon d) of 
                                      Nothing -> error ""
                                      Just e -> e 
                       Nothing -> error ""
        greedy_order = getGreedyOrder edges' field_len
        fieldorder = M.insert datacon greedy_order M.empty 
      in case M.toList fieldorder of
                  [] -> Nothing --dbgTraceIt (sdoc fieldorder) dbgTraceIt (sdoc greedy_order) 
                  [(dcon, order)] -> let orignal_order = [0..(P.length order - 1)]
                                       in if orignal_order == P.map P.fromInteger order
                                          then Nothing
                                          else let newDDefs = optimizeDataCon (dcon, order) ddefs newDcon
                                                   fundef' = shuffleDataConFunBody True fieldorder fundef newDcon
                                                 in Just (newDDefs, fundef', fieldorder) --dbgTraceIt (sdoc order) -- dbgTraceIt (sdoc fieldorder) dbgTraceIt (sdoc greedy_order) 
                  _ -> error "more than one"



getLeft :: Either [Constr] [(L1.Edge, ConstrEdgeWeightTy)] -> [Constr]
getLeft (Left x) = x

getRight :: Either [Constr] [(L1.Edge, ConstrEdgeWeightTy)] -> [(L1.Edge, ConstrEdgeWeightTy)]
getRight (Right x) = x

optimizeFunctionWRTDataConGlobal ::
  DDefs1 ->
  FunDef1 ->
  DataCon ->
  DataCon ->
  Either [Constr] [(L1.Edge, ConstrEdgeWeightTy)] ->
  Bool ->
  Maybe (DDefs1, FunDef1, FieldOrder)
optimizeFunctionWRTDataConGlobal
  ddefs
  fundef@FunDef
    { funName,
      funBody,
      funTy,
      funArgs
    }
  datacon
  newDcon
  constrsOrEdges
  useGreedy = case useGreedy of 
   False -> 
    let newFieldOrder = optimizeDataConOrderGlobal (getLeft constrsOrEdges) ddefs datacon
      in case M.toList newFieldOrder of
                  [] -> Nothing
                  [(dcon, order)] -> let orignal_order = [0..(P.length order - 1)]
                                       in if orignal_order == P.map P.fromInteger order
                                          then Nothing
                                          else let newDDefs = optimizeDataCon (dcon, order) ddefs newDcon
                                                   fundef' = shuffleDataConFunBody True newFieldOrder fundef newDcon
                                                 in Just (newDDefs, fundef', newFieldOrder)
                  _ -> error "Error: function did not expect more than one dcon to optimize."
   True ->
    let field_len = P.length $ snd . snd $ lkp' ddefs datacon
        greedy_order = getGreedyOrder (getRight constrsOrEdges) field_len
        fieldorder = M.insert datacon greedy_order M.empty 
      in case M.toList fieldorder of
                  [] -> Nothing 
                  [(dcon, order)] -> let orignal_order = [0..(P.length order - 1)]
                                       in if orignal_order == P.map P.fromInteger order
                                          then Nothing
                                          else let newDDefs = optimizeDataCon (dcon, order) ddefs newDcon
                                                   fundef' = shuffleDataConFunBody True fieldorder fundef newDcon
                                                 in Just (newDDefs, fundef', fieldorder)
                  _ -> error "Error: function did not expect more than one dcon to optimize."

changeCallNameInRecFunction ::
  Var -> FunDef1 -> FunDef1
changeCallNameInRecFunction
  newFunName
  f@FunDef
    { funName,
      funArgs,
      funTy,
      funBody,
      funMeta
    } =
    case funMeta of
      FunMeta {funRec} ->
        case funRec of
          Rec ->
            f
              { funName = newFunName,
                funArgs = funArgs,
                funTy = funTy,
                funBody = fixExp funBody,
                funMeta
              }
          _ ->
            f
              { funName = newFunName,
                funArgs = funArgs,
                funTy = funTy,
                funBody = funBody,
                funMeta
              }
    where
      fixExp funBody =
        case funBody of
          DataConE loc dcon args -> DataConE loc dcon (P.map fixExp args)
          VarE {} -> funBody
          LitE {} -> funBody
          CharE {} -> funBody
          FloatE {} -> funBody
          LitSymE {} -> funBody
          AppE f locs args ->
            if f == funName
              then AppE newFunName locs (P.map fixExp args)
              else AppE f locs (P.map fixExp args)
          PrimAppE f args -> PrimAppE f (P.map fixExp args)
          LetE (v, loc, ty, rhs) bod ->
            let rhs' = fixExp rhs
                bod' = fixExp bod
             in LetE (v, loc, ty, rhs') bod'
          CaseE scrt mp ->
            let mp' = P.map (\(a, b, c) -> (a, b, fixExp c)) mp
             in CaseE scrt mp'
          IfE a b c -> IfE (fixExp a) (fixExp b) (fixExp c)
          MkProdE xs -> MkProdE (P.map fixExp xs)
          ProjE i e -> error "getExpTyEnv: TODO ProjE"
          TimeIt e ty b -> TimeIt (fixExp e) ty b
          WithArenaE v e -> error "getExpTyEnv: TODO WithArenaE"
          SpawnE f locs args -> error "getExpTyEnv: TODO SpawnE"
          SyncE -> error "getExpTyEnv: TODO SyncE"
          Ext _ -> error "getExpTyEnv: TODO Ext"
          MapE {} -> error "getExpTyEnv: TODO MapE"
          FoldE {} -> error "getExpTyEnv: TODO FoldE"


-- Rather than backtracking all the producers, which seems like a lot trickier of a prospect. 
-- For a new data constructor, why not just change all the occurences of this data constructor to the new one? This is much simpler. 
-- However for the producer / consumer boundary optimization. The backtracking needs to be done. 

genNewProducersAndRewriteProgram ::
  Var ->
  DataCon ->
  FieldOrder ->
  Env2 Ty1 ->
  ProducersMap Exp1 ->
  Prog Exp1 ->
  Prog Exp1
genNewProducersAndRewriteProgram
  funName
  newDataConName
  newdataConOrder
  venv
  pmap
  prg@Prog
    { ddefs,
      fundefs,
      mainExp
    } =
    case mainExp of
      Nothing ->
        error "genNewProducersAndRewriteProgram : Program has no main expression."
      Just (mexp, ty) ->
        let 
          --variablesAndProducers' = dbgTraceIt ("Variables and Producers") dbgTraceIt (sdoc (funName, newDataConName)) P.concatMap (\f@FunDef{funName=fnName, funBody=fnb} -> if fnName /= funName then getVariableAndProducer funName pmap venv ddefs newDataConName fnb else []) (M.elems fundefs)  
          variablesAndProducers  = dbgTraceIt ("End\n") removeDuplicates $ (getVariableAndProducer funName pmap venv ddefs newDataConName mexp) -- ++ variablesAndProducers'
         in case variablesAndProducers of
              [] -> prg-- error "no variable and producers found to modify" -- Error here, has no producers to modify, figure out a way to find all producers correctly.
              [(var, producer)] -> 
                let newProducerName = producer -- toVar (fromVar producer ++ "_new")
                    oldProducerBody = M.lookup producer fundefs
                 in case oldProducerBody of
                      Just body ->
                        let newProducerBody@FunDef
                              { funName,
                                funBody,
                                funTy,
                                funArgs
                              } =
                                shuffleDataConFunBody
                                  False
                                  newdataConOrder
                                  body
                                  newDataConName
                            newProducerBody' =
                              changeCallNameInRecFunction
                                newProducerName
                                newProducerBody
                            funRemoveAllLets = (\FunDef{funName=fName, funBody=fBody, funTy=fTy, funArgs=fArgs, funMeta=fMeta} -> let removeLets = delAllLetBindings fBody
                                                                                                                                    in FunDef{funName=fName, funBody=removeLets, funTy=fTy, funArgs=fArgs, funMeta=fMeta}
                                               ) newProducerBody'
                            var_order = S.toList $ (\FunDef{funBody=fb} -> gFreeVars fb) funRemoveAllLets
                            var_order' = P.map Just var_order
                            (m :: UseDefChainsFunctionMap Exp1) = getDefinitionsReachingLetExp newProducerBody'
                            depLets = P.map (\vv -> getDependentLetBindings vv newProducerName m) var_order
                            var_order'' = P.zip var_order' depLets
                            newProducerBody'' = P.foldl (\fundef (insertPosition, dl) -> reOrderLetExp insertPosition dl fundef
                                                        ) funRemoveAllLets var_order''

                            fundefs' = M.delete newProducerName fundefs --dbgTraceIt (sdoc (newProducerName, newProducerBody''))
                            fundefs'' =
                              M.insert newProducerName newProducerBody'' fundefs'
                            newMainExp =
                              callNewProducerForVarInMain
                                var
                                False
                                producer
                                newProducerName
                                mexp
                         in prg
                              { ddefs = ddefs,
                                fundefs = fundefs'',
                                mainExp = Just (newMainExp, ty)
                              }
                      _ -> error ""
              x : xs -> error ("more than one variable and producer not handled yet." ++ show variablesAndProducers)


globallyChangeDataConstructorLayout :: DataCon -> DataCon -> FieldOrder -> Prog Exp1 -> Prog Exp1 
globallyChangeDataConstructorLayout oldDcon newDcon fieldOrder prg@Prog{ddefs, fundefs, mainExp} = 
  let fundefs' = P.foldr (\f@FunDef{funName, funBody} funMap -> 
                              let dconsInFunBody = dataConsInFunBody funBody
                               in if S.member oldDcon dconsInFunBody
                                  then 
                                    let f' = shuffleDataConFunBody False fieldOrder f newDcon
                                        f'' = shuffleDataConFunBody True fieldOrder f' newDcon
                                        (m :: UseDefChainsFunctionMap Exp1) = getDefinitionsReachingLetExp f''
                                        funRemoveAllLets = 
                                          (\FunDef{funName=fName, funBody=fBody, funTy=fTy, funArgs=fArgs, funMeta=fMeta} ->
                                                let removeLets = delAllLetBindings fBody
                                                  in FunDef{funName=fName, funBody=removeLets, funTy=fTy, funArgs=fArgs, funMeta=fMeta}
                                          ) f''
                                        var_order = S.toList $ (\FunDef{funBody=fb} -> gFreeVars fb) funRemoveAllLets
                                        depLets = P.map (\vv -> getDependentLetBindings vv funName m) var_order
                                        var_order' = P.map Just var_order
                                        var_order'' = P.zip var_order' depLets
                                        newFuncDef = P.foldl (\fundef (insertPosition, dl) -> reOrderLetExp insertPosition dl fundef
                                                             ) funRemoveAllLets var_order''
                                        m' = M.insert funName newFuncDef funMap 
                                      in m'
                                  else M.insert funName f funMap
                         ) M.empty (M.elems fundefs)
    in Prog{ddefs=ddefs, fundefs=fundefs', mainExp=mainExp} 
   


-- Function to find the the variable/s that have the type that's being optimized for the given function f
-- Also return the producer of) those variable/s
-- Arguments
-- Var -> Name of the function being optimized
-- pmap -> variable to producer map
-- (PreExp e l d) -> expression to search over
-- Return
-- [(Var, Producer)]
getVariableAndProducer ::
  Var ->
  ProducersMap Exp1 ->
  Env2 Ty1 ->
  DDefs1 ->
  DataCon ->
  Exp1 ->
  [(Var, Var)]
getVariableAndProducer funName pMap venv@Env2{vEnv, fEnv} ddefs dconName exp =
  case exp of
    DataConE loc dcon args ->
      P.concatMap (getVariableAndProducer funName pMap venv ddefs dconName) args
    VarE {} -> []
    LitE {} -> []
    CharE {} -> []
    FloatE {} -> []
    LitSymE {} -> []
    AppE f locs args ->
      P.concatMap (getVariableAndProducer funName pMap venv ddefs dconName) args
    PrimAppE f args ->
      P.concatMap (getVariableAndProducer funName pMap venv ddefs dconName) args
    LetE (v, loc, ty, rhs) bod ->
      let varOf =
            case rhs of
              AppE f locs args ->
                if f == funName
                  then
                    let potentialVarsOfTy =
                          P.map
                            ( \exp ->
                                case exp of
                                  VarE v ->
                                    case lookupVEnv' v venv of
                                      Just e -> let tyCon = getTyOfDataCon ddefs dconName
                                                    urtyTyCon = PackedTy tyCon ()
                                                  in if e == urtyTyCon then Just v
                                                     else Nothing
                                      Nothing -> Nothing
                                  _ -> Nothing
                            )
                            args
                        justVariables = Maybe.catMaybes potentialVarsOfTy
                     in if P.null justVariables
                          -- dbgTraceIt (sdoc (funName, dconName, args, venv))
                          then Nothing-- dbgTraceIt (sdoc (funName, dconName, args, venv)) error "getVariableAndProducer: no variables of Ty to optimize found!"
                          else
                            if P.length justVariables > 1
                              then error "getVariableAndProducer: More than one variable of the type being optimized is passed to function call. Not implemented yet!"
                              else Just (P.head justVariables)
                  else Nothing
              TimeIt e _ _ -> case e of 
                                AppE f locs args -> if f == funName
                                                    then
                                                      let potentialVarsOfTy =
                                                            P.map
                                                              ( \exp ->
                                                                        case exp of
                                                                              VarE v -> case lookupVEnv' v venv of
                                                                                            Just e -> let tyCon = getTyOfDataCon ddefs dconName
                                                                                                          urtyTyCon = PackedTy tyCon ()
                                                                                                        in if e == urtyTyCon then Just v
                                                                                                           else Nothing
                                                                                            Nothing -> Nothing
                                                                              _ -> Nothing
                                                              ) args
                                                          justVariables = Maybe.catMaybes potentialVarsOfTy
                                                       in if P.null justVariables
                                                        -- dbgTraceIt (sdoc (funName, dconName, args, venv))
                                                        then error "getVariableAndProducer: no variables of Ty to optimize found!"
                                                        else
                                                          if P.length justVariables > 1
                                                          then error "getVariableAndProducer: More than one variable of the type being optimized is passed to function call. Not implemented yet!"
                                                          else Just (P.head justVariables)
                                                    else Nothing
                                _ -> Nothing  
              _ -> Nothing
          producers =
            getVariableAndProducer funName pMap venv ddefs dconName rhs
              ++ getVariableAndProducer funName pMap venv ddefs dconName bod
       in case varOf of
            Just var ->
              let varType = lookupVEnv' var venv
               in case varType of
                    Just ty ->
                      let producerExp = M.lookup (var, ty) pMap
                       in case producerExp of
                            Just (AppE f locs args) -> (var, f) : producers
                            Just (TimeIt e _ _) -> case e of
                                AppE f locs args -> (var, f) : producers
                                _ -> dbgTraceIt (sdoc e) error "getVariableAndProducer1: producer other than a function call not expected." 

                            _ -> dbgTraceIt (sdoc (varOf, producerExp))
                              error
                                "getVariableAndProducer2: producer other than a function call not expected."
                    Nothing -> []
            Nothing -> producers
    -- a == DataCon
    -- b == [(Var, loc)]
    -- c == Case Body
    CaseE scrt mp ->
      P.concatMap (\(a, b, c) -> getVariableAndProducer funName pMap venv ddefs dconName c) mp
    IfE a b c ->
      let producersA = getVariableAndProducer funName pMap venv ddefs dconName a
          producersB = getVariableAndProducer funName pMap venv ddefs dconName b
          producersC = getVariableAndProducer funName pMap venv ddefs dconName c
       in producersA ++ producersB ++ producersC
    MkProdE xs -> P.concatMap (getVariableAndProducer funName pMap venv ddefs dconName) xs
    ProjE i e -> error "getExpTyEnv: TODO ProjE"
    TimeIt e ty b -> getVariableAndProducer funName pMap venv ddefs dconName e
    WithArenaE v e -> error "getExpTyEnv: TODO WithArenaE"
    SpawnE f locs args -> error "getExpTyEnv: TODO SpawnE"
    SyncE -> error "getExpTyEnv: TODO SyncE"
    Ext _ -> error "getExpTyEnv: TODO Ext"
    MapE {} -> error "getExpTyEnv: TODO MapE"
    FoldE {} -> error "getExpTyEnv: TODO FoldE"

-- For a variable that's produced change the old producer to the new producer.
-- Args
-- Var  -> Variable whose producer needs to be changed
-- Bool -> a switch for modifying the call or not.
-- Var  -> Name of the old producer
-- Var  -> Name of the new producer
-- (PreExp e l d) -> Main Expression
-- Return value
-- (PreExp e l d) -> New Main Expression
callNewProducerForVarInMain ::
  Var -> Bool -> Var -> Var -> Exp1 -> Exp1
callNewProducerForVarInMain var boolModify oldProducer newProducer mainExp =
  case mainExp of
    DataConE loc dcon args ->
      let args' =
            P.map
              ( callNewProducerForVarInMain
                  var
                  boolModify
                  oldProducer
                  newProducer
              )
              args
       in DataConE loc dcon args'
    VarE {} -> mainExp
    LitE {} -> mainExp
    CharE {} -> mainExp
    FloatE {} -> mainExp
    LitSymE {} -> mainExp
    AppE f locs args ->
      let args' =
            P.map
              ( callNewProducerForVarInMain
                  var
                  boolModify
                  oldProducer
                  newProducer
              )
              args
       in if f == oldProducer && boolModify
            then AppE newProducer locs args'
            else AppE f locs args'
    PrimAppE f args ->
      let args' =
            P.map
              ( callNewProducerForVarInMain
                  var
                  boolModify
                  oldProducer
                  newProducer
              )
              args
       in PrimAppE f args'
    LetE (v, loc, ty, rhs) bod ->
      let rhs' =
            if v == var
              then
                callNewProducerForVarInMain
                  var
                  True
                  oldProducer
                  newProducer
                  rhs
              else
                callNewProducerForVarInMain
                  var
                  False
                  oldProducer
                  newProducer
                  rhs
          bod' =
            callNewProducerForVarInMain
              var
              boolModify
              oldProducer
              newProducer
              bod
       in LetE (v, loc, ty, rhs') bod'
    -- a == DataCon
    -- b == [(Var, loc)]
    -- c == Case Body
    CaseE scrt mp ->
      let mp' =
            P.map
              ( \(a, b, c) ->
                  let c' =
                        callNewProducerForVarInMain
                          var
                          boolModify
                          oldProducer
                          newProducer
                          c
                   in (a, b, c')
              )
              mp
       in CaseE scrt mp'
    IfE a b c ->
      let a' =
            callNewProducerForVarInMain var boolModify oldProducer newProducer a
          b' =
            callNewProducerForVarInMain var boolModify oldProducer newProducer b
          c' =
            callNewProducerForVarInMain var boolModify oldProducer newProducer c
       in IfE a' b' c'
    MkProdE xs ->
      let xs' =
            P.map
              ( callNewProducerForVarInMain
                  var
                  boolModify
                  oldProducer
                  newProducer
              )
              xs
       in MkProdE xs'
    ProjE i e -> error "getExpTyEnv: TODO ProjE"
    TimeIt e ty b -> TimeIt (callNewProducerForVarInMain var boolModify oldProducer newProducer e) ty b 
    WithArenaE v e -> error "getExpTyEnv: TODO WithArenaE"
    SpawnE f locs args -> error "getExpTyEnv: TODO SpawnE"
    SyncE -> error "getExpTyEnv: TODO SyncE"
    Ext _ -> error "getExpTyEnv: TODO Ext"
    MapE {} -> error "getExpTyEnv: TODO MapE"
    FoldE {} -> error "getExpTyEnv: TODO FoldE"

genEdgesFromTotalOrdering ::
  [(String, DataConMap)] -> [FunDef1] -> FieldMap -> FieldMap
genEdgesFromTotalOrdering lstTotalOrdering fundefs mapIn =
  case lstTotalOrdering of
    [] -> mapIn
    x : xs ->
      let (funcName, map) = x
          [fundef@(FunDef {funName})] =
            concatMap ( \fn@(FunDef {funName}) ->
                    ([fn | fromVar funName == funcName])
                ) fundefs
          dconOrderings = M.toList map
          dconOrderings' =
            P.map
              ( \(dcon, strongOrderings) ->
                  let edges =
                        P.map
                          ( \(Strong a b) -> ((a, b), P.toInteger (100 :: Integer))
                          )
                          strongOrderings
                   in (dcon, edges)
              )
              dconOrderings
          orderMap = M.fromList dconOrderings'
          newMap = M.insert funName orderMap mapIn
          newMap' = genEdgesFromTotalOrdering xs fundefs newMap
       in newMap'

existsTuple :: [(String, a)] -> String -> Bool
existsTuple lst name =
  case lst of
    [] -> False
    (x, y) : xs ->
      x == name || existsTuple xs name

-- This just goes through the function we are locally optimizing
-- Since this problem is to locally optimize for a particular function right now we are not concerned with finding the best
-- optimal layout for the complete program.
locallyOptimizeFieldOrdering ::
  FieldMap ->
  [DataCon] ->
  [FunDef1] ->
  String ->
  Int ->
  FieldOrder ->
  Int ->
  FieldOrder
locallyOptimizeFieldOrdering fieldMap dcons fundefs funcName field_len orderIn mode =
  case fundefs of
    [] -> orderIn
    x : xs ->
      let map' =
            generateLocallyOptimalOrderings
              fieldMap
              dcons
              x
              funcName
              field_len
              orderIn
              mode
          map'' =
            locallyOptimizeFieldOrdering
              fieldMap
              dcons
              xs
              funcName
              field_len
              map'
              mode
       in map''


genUserConstrs :: [UserOrdering] -> [Constr]
genUserConstrs userOrdering =
  case userOrdering of
    (Strong a b) : xs -> Absolute (a, b) : genUserConstrs xs
    (Immediate a b) : xs -> Imm (a, b) : genUserConstrs xs
    [] -> []

-- Takes in Field access map
-- Takes in user constraints for data con for that function
-- takes in the function def for the function
-- Takes in [(DataCon, Int)], ie, data con name, and number of fields for data constructors that need to be optimized
-- Returns optimal order of fields of a data constructor.

-- Timing for filtering the blogs based on a keyword
timeSolver ::
  (IO [(Int, Int)] -> [(Int, Int)]) ->
  IO [(Int, Int)] ->
  IO ([(Int, Int)], Double)
timeSolver f f' = do
  t1 <- getCurrentTime
  a <- evaluate (f f')
  t2 <- getCurrentTime
  let delt = fromRational (toRational (diffUTCTime t2 t1))
  --putStrLn ("iter time: " ++ show delt)
  return (a, delt)

optimizeDataConOrderFunc ::
  FieldMap ->
  DataConMap ->
  FunDef1 ->
  [(DataCon, Int)] ->
  FieldOrder ->
  FieldOrder
optimizeDataConOrderFunc
  dconAccessMap
  dconUserConstr
  fundef@FunDef
    { funName,
      funBody,
      funTy,
      funArgs
    }
  datacons
  orderIn =
    let lstDconEdges = M.findWithDefault M.empty funName dconAccessMap
     in case datacons of
          [] -> orderIn
          [(x, field_len)] ->
            let accessEdges = M.findWithDefault [] x lstDconEdges
                solverConstraints = generateSolverEdges fundef x dconAccessMap
                --softConstrs = P.map Soft softEdges
                --userOrdering = dbgTraceIt ("Constraints: ") dbgTraceIt (sdoc (lstDconEdges)) M.findWithDefault [] x dconUserConstr
                --userConstrs = genUserConstrs userOrdering
                allConstrs = solverConstraints --userConstrs --softConstrs ++
             in -- field_len    = P.length $ snd . snd $ lkp ddefs x
                case allConstrs of
                  [] -> orderIn
                  _  ->
                    let (layout, t) = --([], 0.0) --dbgTraceIt ("Constraints: ") dbgTraceIt (sdoc (allConstrs))
                           U.unsafePerformIO $
                           timeSolver U.unsafePerformIO (solveConstrs allConstrs)
                        -- In case we don't get orderings for some of the fields in the data con
                        -- to be safe we should complete the layout orderings of the missing fields.
                        fix_missing =
                          if P.length layout < field_len
                            then
                              let indices = [0 .. (field_len - 1)]
                                  minuslist = makeneg field_len
                                  partial = fillList minuslist layout
                                  avail = P.map fst layout
                                  navail = deleteMany avail indices
                                  new = fillminus1 partial navail
                               in new
                            else
                              let layout' = L.sort layout
                               in P.map snd layout'
                        fieldorder = dbgTraceIt ("NewOrder.") dbgTraceIt (sdoc fix_missing) dbgTraceIt ("End.\n") M.insert x (integerList fix_missing) orderIn
                     in fieldorder
          _ ->
            error
              "OptimizeFieldOrder: optimizeDataConOrderFunc more that one data constructor per function not implemented yet."


optimizeDataConOrderGlobal :: [Constr] -> DDefs1 -> DataCon -> FieldOrder
optimizeDataConOrderGlobal constrs ddefs dcon =
  let field_len = P.length $ snd . snd $ lkp ddefs dcon
   in case constrs of
          [] -> M.empty
          _  -> let (layout, t) = U.unsafePerformIO $ timeSolver U.unsafePerformIO (solveConstrs constrs)
                                 -- In case we don't get orderings for some of the fields in the data con
                                 -- to be safe we should complete the layout orderings of the missing fields.
                    fix_missing = if P.length layout < field_len
                                  then
                                    let indices = [0 .. (field_len - 1)]
                                        minuslist = makeneg field_len
                                        partial = fillList minuslist layout
                                        avail = P.map fst layout
                                        navail = deleteMany avail indices
                                        new = fillminus1 partial navail
                                      in new
                                  else
                                    let layout' = L.sort layout
                                      in P.map snd layout'
                    fieldorder = dbgTraceIt ("NewOrder.") dbgTraceIt (sdoc fix_missing) dbgTraceIt ("End.\n") M.insert dcon (integerList fix_missing) M.empty
                  in fieldorder
          _ -> error "OptimizeFieldOrder: optimizeDataConOrderFunc more that one data constructor per function not implemented yet."

-- for the function for which we are locally optimizing for, find the optimal layout of the data constructors that we care about.
-- "Locally optimizing for the function"
generateLocallyOptimalOrderings ::
  FieldMap ->
  [DataCon] ->
  FunDef1 ->
  String ->
  Int ->
  FieldOrder ->
  Int ->
  FieldOrder
generateLocallyOptimalOrderings
  fieldMap
  datacons
  fundef@FunDef
    { funName,
      funBody,
      funTy,
      funArgs
    }
  funcName
  field_len
  orderIn
  mode =
    if fromVar funName == funcName
      then
        let lstDconEdges = M.findWithDefault M.empty funName fieldMap
         in case datacons of
              [] -> orderIn
              x : xs ->
                let dconEdges = M.findWithDefault [] x lstDconEdges
                    dconEdges' = [] --P.map Soft dconEdges
                 in case dconEdges' of
                      [] -> orderIn
                      _ ->
                        let layout = []
                            --  U.unsafePerformIO (solveConstrs dconEdges')
                            -- In case we don't get orderings for some of the fields in the data con
                            -- to be safe we should complete the layout orderings of the missing fields.
                            fix_missing =
                              if P.length layout < field_len
                                then
                                  let indices = [0 .. (field_len - 1)]
                                      minuslist = makeneg field_len
                                      partial = fillList minuslist layout
                                      avail = P.map fst layout
                                      navail = deleteMany avail indices
                                      new = fillminus1 partial navail
                                   in new
                                else
                                  let layout' = [] --L.sort layout
                                   in P.map snd layout'
                            fieldorder =
                              M.insert x (integerList fix_missing) orderIn
                            fieldorder' =
                              generateLocallyOptimalOrderings
                                fieldMap
                                xs
                                fundef
                                funcName
                                field_len
                                fieldorder
                                mode
                         in fieldorder'
      else orderIn

makeneg :: Int -> [Int]
makeneg len =
  if len <= 0
    then []
    else makeneg (len - 1) ++ [-1]

integerList :: [Int] -> [Integer]
integerList lst =
  case lst of
    [] -> []
    x : xs -> P.toInteger x : integerList xs

fillList :: [Int] -> [(Int, Int)] -> [Int]
fillList old vals =
  case vals of
    [] -> old
    x : xs ->
      let (a, b) = x
          edited = L.take b old ++ [a] ++ L.drop (b + 1) old
       in fillList edited xs

-- https://www.reddit.com/r/haskell/comments/u841av/trying_to_remove_all_the_elements_that_occur_in/
deleteOne :: (Eq a) => a -> [a] -> [a]
deleteOne _ [] = [] -- Nothing to delete
deleteOne x (y : ys)
  | x == y = ys -- Drop exactly one matching item
deleteOne x (y : ys) = y : deleteOne x ys -- Drop one, but not this one (doesn't match).

deleteMany :: (Eq a) => [a] -> [a] -> [a]
deleteMany [] = id -- Nothing to delete
deleteMany (x : xs) = deleteMany xs . deleteOne x -- Delete one, then the rest.

removeDuplicates :: Eq a => [a] -> [a]
removeDuplicates list = case list of 
                                []   -> []
                                a:as -> a:removeDuplicates (P.filter (/=a) as)

fillminus1 :: [Int] -> [Int] -> [Int]
fillminus1 lst indices =
  case lst of
    [] -> []
    x : xs ->
      case indices of
        [] -> lst
        y : ys ->
          if x == -1
            then y : fillminus1 xs ys
            else x : fillminus1 xs indices

shuffleDataConFunBody ::
  Bool -> FieldOrder -> FunDef1 -> DataCon -> FunDef1
shuffleDataConFunBody phase fieldorder f@FunDef {funBody} newDataCon =
  let funBody' = shuffleDataConExp phase fieldorder newDataCon funBody
   in f {funBody = funBody'}

shuffleDataConExp :: Bool -> FieldOrder -> DataCon -> Exp1 -> Exp1
shuffleDataConExp phase fieldorder newDataCon ex =
  case ex of
    DataConE loc dcon args -> if phase then DataConE loc dcon $ P.map (shuffleDataConExp phase fieldorder newDataCon) args
                                       else
                                        let args' = shuffleDataConArgs fieldorder dcon args
                                            newCon = if M.member dcon fieldorder
                                                     then newDataCon
                                                     else dcon
                                          in DataConE loc newCon args'
    VarE {} -> ex
    LitE {} -> ex
    CharE {} -> ex
    FloatE {} -> ex
    LitSymE {} -> ex
    AppE f locs args ->
      AppE f locs (P.map (shuffleDataConExp phase fieldorder newDataCon) args)
    PrimAppE f args ->
      PrimAppE f (P.map (shuffleDataConExp phase fieldorder newDataCon) args)
    LetE (v, loc, ty, rhs) bod ->
      let rhs' = shuffleDataConExp phase fieldorder newDataCon rhs
          bod' = shuffleDataConExp phase fieldorder newDataCon bod
       in LetE (v, loc, ty, rhs') bod'
    IfE a b c ->
      let a' = shuffleDataConExp phase fieldorder newDataCon a
          b' = shuffleDataConExp phase fieldorder newDataCon b
          c' = shuffleDataConExp phase fieldorder newDataCon c
       in IfE a' b' c'
    MkProdE xs -> MkProdE (P.map (shuffleDataConExp phase fieldorder newDataCon) xs)
    ProjE i e -> ProjE i (shuffleDataConExp phase fieldorder newDataCon e)
    -- a == DataCon
    -- b == [(Var, loc)]
    -- c == Case Body
    CaseE scrt mp ->
      let mp' =
            P.map
              ( \(a, b, c) ->
                  let b' = if phase then shuffleDataConCase fieldorder a b else b
                      c' = shuffleDataConExp phase fieldorder newDataCon c
                      a' =
                        if M.member a fieldorder && phase
                          then newDataCon
                          else a
                   in (a', b', c')
              )
              mp
       in CaseE scrt mp'
    TimeIt e ty b ->
      let e' = shuffleDataConExp phase fieldorder newDataCon e
       in TimeIt e' ty b
    WithArenaE v e ->
      let e' = shuffleDataConExp phase fieldorder newDataCon e
       in WithArenaE v e'
    SpawnE f locs args ->
      SpawnE f locs (P.map (shuffleDataConExp phase fieldorder newDataCon) args)
    SyncE -> SyncE
    Ext _ -> ex
    MapE {} -> error "shuffleFieldOrdering: TODO MapE"
    FoldE {} -> error "shuffleFieldOrdering: TODO FoldE"

shuffleDataConArgs ::
  FieldOrder -> DataCon -> [Exp1] -> [Exp1]
shuffleDataConArgs fieldorder dcon exps =
  if M.member dcon fieldorder
    then permute (findWithDefault [] dcon fieldorder) exps
    else exps

shuffleDataConCase :: FieldOrder -> DataCon -> [(Var, loc)] -> [(Var, loc)]
shuffleDataConCase fieldorder dcon vs =
  if M.member dcon fieldorder
    then permute (findWithDefault [] dcon fieldorder) vs
    else vs


optimizeDataCon ::
  (DataCon, [Integer]) ->
  DDefs1 -> DataCon ->
  DDefs1
optimizeDataCon (dcon, newindices) ddefs newDcon =
  case lkp'' ddefs newDcon of 
    Nothing -> 
      let (tycon, (_, fields)) = lkp' ddefs dcon
          newFields = permute newindices fields
          --newDcon = dcon ++ "Optimized" -- TODO: Change this to use gensym
          DDef {tyName, tyArgs, dataCons} = lookupDDef' ddefs (fromVar tycon)
          newDDef =
            DDef
              { tyName = tyName,
                tyArgs = tyArgs,
                dataCons = dataCons ++ [(newDcon, newFields)]
              }
          ddefs' = M.delete tycon ddefs
          ddefs'' = insertDD newDDef ddefs'
        in ddefs''
    Just _ -> ddefs 

-- | Lookup a Datacon.  Return (TyCon, (DataCon, [flds]))
lkp' ::
  DDefs1 ->
  DataCon ->
  (Var, (DataCon, [(IsBoxed, UrTy())]))
lkp' dds con =
  -- Here we try to lookup in ALL datatypes, assuming unique datacons:
  case [ (tycon, variant)
         | (tycon, DDef {dataCons}) <- M.toList dds,
           variant <- L.filter ((== con) . fst) dataCons
       ] of
    [] ->
      error "OptimizeFieldOrder -> lookupDataCon: could not find constructor!"
    [hit] -> hit
    _ ->
      error "OptimizeFieldOrder -> lookupDataCon: found multiple occurences of constructor!"


-- | Lookup a Datacon.  Return (TyCon, (DataCon, [flds]))
lkp'' ::
  DDefs1 ->
  DataCon ->
  Maybe (Var, (DataCon, [(IsBoxed, UrTy())]))
lkp'' dds con =
  -- Here we try to lookup in ALL datatypes, assuming unique datacons:
  case [ (tycon, variant)
         | (tycon, DDef {dataCons}) <- M.toList dds,
           variant <- L.filter ((== con) . fst) dataCons
       ] of
    [] -> Nothing
    [hit] -> Just hit
    _ ->
      error "OptimizeFieldOrder -> lookupDataCon: found multiple occurences of constructor!"
  

-- | Lookup a ddef in its entirety
lookupDDef' ::
  DDefs1 -> TyCon -> DDef1
lookupDDef' mp tycon =
  case M.lookup (toVar tycon) mp of
    Just x -> x
    Nothing -> error "OptimizeFieldOrder: lookupDDef' failed!"

permute :: [Integer] -> [a] -> [a]
permute indices list =
  case indices of
    [] -> []
    x : xs -> (list !! P.fromInteger x) : permute xs list



-- getVarsBoundByDconInOrder' :: DataCon -> FunDef1 -> [Var]
-- getVarsBoundByDconInOrder' datacon f@FunDef{funName, funBody, funTy, funArgs, funMeta} = getVarsBoundByDconInOrder datacon funBody

-- -- Only works assuming you have just one data constructor in the function body.  
-- getVarsBoundByDconInOrder :: DataCon -> Exp1 -> [Var]
-- getVarsBoundByDconInOrder datacon expr = case expr of
--           DataConE _ dcon args -> if dcon == datacon then
--                                                        P.concatMap (\expr' -> case expr' of
--                                                                                 VarE v -> [v]
--                                                                                 LitSymE v -> [v]
--                                                                                 _ -> []
--                                                                    ) args
--                                     else []
--           VarE {} -> []
--           LitE {} -> []
--           CharE {} -> []
--           FloatE {} -> []
--           LitSymE {} -> []
--           AppE _ _ args -> P.concatMap (getVarsBoundByDconInOrder datacon) args
--           PrimAppE _ args -> P.concatMap (getVarsBoundByDconInOrder datacon) args
--           LetE (v, loc, ty, rhs) bod -> let vars  = getVarsBoundByDconInOrder datacon rhs
--                                             vars' = getVarsBoundByDconInOrder datacon bod
--                                           in vars ++ vars'
--           CaseE scrt mp -> P.concatMap (\(a, b, c) -> getVarsBoundByDconInOrder datacon c) mp
--           IfE a b c -> let varsa = getVarsBoundByDconInOrder datacon a
--                            varsb = getVarsBoundByDconInOrder datacon b
--                            varsc = getVarsBoundByDconInOrder datacon c
--                          in varsa ++ varsb ++ varsc
--           MkProdE xs -> P.concatMap (getVarsBoundByDconInOrder datacon) xs
--           ProjE i e -> error "getExpTyEnv: TODO ProjE"
--           TimeIt e ty b -> error "getExpTyEnv: TODO TimeIt"
--           WithArenaE v e -> error "getExpTyEnv: TODO WithArenaE"
--           SpawnE f locs args -> error "getExpTyEnv: TODO SpawnE"
--           SyncE -> error "getExpTyEnv: TODO SyncE"
--           Ext _ -> error "getExpTyEnv: TODO Ext"
--           MapE {} -> error "getExpTyEnv: TODO MapE"
--           FoldE {} -> error "getExpTyEnv: TODO FoldE"



getDependentLetBindings :: Var -> Var -> UseDefChainsFunctionMap Exp1 -> [Exp1]
getDependentLetBindings curr funName m = case M.lookup funName m of
                                        Just (_, getNode, getVertex) -> let lambda = (\var -> let vertex = getVertex var
                                                                                                    in case vertex of
                                                                                                           Just v -> let ((_, ex, _), _, successors::[Var]) = getNode v
                                                                                                                      in (successors, Just ex)
                                                                                                           Nothing -> ([], Nothing)                                                                                                                                       )
                                                                            lambda' = (\varList -> case varList of
                                                                                                             [] -> []
                                                                                                             x:xs -> let (successors, ex) = lambda x
                                                                                                                         recurseSucc = lambda' successors
                                                                                                                         recurseRst  = lambda' xs
                                                                                                                      in case ex of
                                                                                                                            Just ex' -> recurseSucc ++ recurseRst ++ [ex']
                                                                                                                            Nothing  -> recurseSucc ++ recurseRst
                                                                                          )
                                                                              in lambda' [curr]
                                        Nothing -> error "reOrderLetExp: could not find data flow relation for let expressions."

reOrderLetExp :: Maybe Var -> [Exp1] -> FunDef1 -> FunDef1
reOrderLetExp after letExpOrder FunDef{funName, funBody, funTy, funArgs, funMeta} = let funBody'' = reOrderLetExpHelper after letExpOrder funBody
                                                                                    in FunDef{funName=funName, funBody=funBody'', funTy=funTy, funArgs=funArgs, funMeta=funMeta}



reOrderLetExpHelper :: Maybe Var -> [Exp1] -> Exp1 -> Exp1
reOrderLetExpHelper Nothing letExpOrder expr = case letExpOrder of
  [] -> expr
  x:xs -> case x of
            LetE (v, loc, ty, rhs) _ -> let exp' = LetE (v, loc, ty, rhs) $ reOrderLetExpHelper Nothing xs expr
                                          in exp'
            _ -> error "reOrderLetExpHelper: did not expect expressions other than LetE."


reOrderLetExpHelper (Just var) letExpOrder expr = fst $ run letExpOrder expr
  where
  lambdaHandleExpList expList letExpOrder' = case expList of
                                        [] -> ([], False)
                                        x:xs -> let (exp', releasedBinds) = run letExpOrder' x
                                                  in if releasedBinds
                                                     then (exp' : xs, releasedBinds)
                                                     else
                                                       let (exp'', val) = lambdaHandleExpList xs letExpOrder'
                                                         in (exp' : exp'', releasedBinds || val)

  lambdaAppendLets = \l ex -> case l of
                                LetE (v', loc', ty', rhs') _ -> LetE (v', loc', ty', rhs') ex
                                _ -> error "reOrderLetExpHelper(run): did not expect expressions other than LetE."

  run letExpOrder' expr' = case expr' of
          DataConE loc dcon args -> let (newArgs :: [PreExp E1Ext () Ty1], releasedBinds) = lambdaHandleExpList args letExpOrder'
                                      in (DataConE loc dcon newArgs, releasedBinds)
          VarE vv -> if vv == var
                     then
                        let exp' = P.foldr lambdaAppendLets expr' letExpOrder'
                          in (exp', True)
                     else
                      (expr', False)
          LitE {} -> (expr', False)
          CharE {} -> (expr', False)
          FloatE {} -> (expr', False)
          LitSymE {} -> (expr', False)
          AppE f locs args -> let (newArgs, releasedBinds) = lambdaHandleExpList args letExpOrder'
                               in (AppE f locs newArgs, releasedBinds)
          PrimAppE f args -> let (newArgs, releasedBinds) = lambdaHandleExpList args letExpOrder'
                               in (PrimAppE f newArgs, releasedBinds)
          LetE (v, loc, ty, rhs) bod -> let (rhs', relRhs) = run letExpOrder' rhs
                                            (bod', relBod) = if relRhs then (bod, relRhs) else run letExpOrder' bod
                                          in
                                            (LetE (v, loc, ty, rhs') bod' , relRhs || relBod)
          --TODO: if it exits in more than one case then lift releasing bindings on top of case.                                  
          CaseE scrt mp -> let lambdaCase = (\(a, b, c) -> let (c' , released') = run letExpOrder' c
                                                             in ((a, b, c'), released')
                                            )
                               newExps = P.map lambdaCase mp
                               mp' = P.map fst newExps
                               released = any snd newExps
                             in (CaseE scrt mp', released)
          IfE a b c -> let freeVarsA = gFreeVars a
                           freeVarsB = gFreeVars b
                           freeVarsC = gFreeVars c
                          in if S.member var freeVarsA || S.member var freeVarsC && S.member var freeVarsB
                             then (P.foldr lambdaAppendLets expr' letExpOrder', True)
                             else if S.member var freeVarsB && S.notMember var freeVarsC
                             then let b' = fst $ run letExpOrder' b
                                   in (IfE a b' c, True)
                             else if S.member var freeVarsC && S.notMember var freeVarsB
                             then let c' = fst $ run letExpOrder' c
                                    in (IfE a b c', True)
                             else
                                (expr', False)
          MkProdE xs -> let (xs', releasedBinds) = lambdaHandleExpList xs letExpOrder'
                          in (MkProdE xs', releasedBinds)
          ProjE {} -> error "reOrderLetExpHelper: TODO ProjE"
          TimeIt e ty b -> let (e', releasedBinds) = run letExpOrder' e  
                         in (TimeIt e' ty b, releasedBinds)
          WithArenaE {} -> error "reOrderLetExpHelper: TODO WithArenaE"
          SpawnE {} -> error "reOrderLetExpHelper: TODO SpawnE"
          SyncE -> error "reOrderLetExpHelper: TODO SyncE"
          Ext {} -> error "reOrderLetExpHelper: TODO Ext"
          MapE {} -> error "reOrderLetExpHelper: TODO MapE"
          FoldE {} -> error "reOrderLetExpHelper: TODO FoldE"

delLetBinding :: Exp1 -> Exp1 -> Exp1
delLetBinding letBind expr = case expr of
          DataConE loc dcon args -> DataConE loc dcon $ P.map (delLetBinding letBind) args
          VarE {} -> expr
          LitE {} -> expr
          CharE {} -> expr
          FloatE {} -> expr
          LitSymE {} -> expr
          AppE f locs args -> AppE f locs $ P.map (delLetBinding letBind) args
          PrimAppE f args -> PrimAppE f $ P.map (delLetBinding letBind) args
          LetE (v, loc, ty, rhs) bod -> case letBind of
                                              LetE (v', _, _, _) _ -> if v == v' then bod
                                                                              else LetE (v, loc, ty, delLetBinding letBind rhs) $ delLetBinding letBind bod
                                              _ -> error "delLetBinding: did not expect an expression other than let."
          CaseE scrt mp -> CaseE scrt $ P.map (\(a, b, c) -> (a, b, delLetBinding letBind c)) mp
          IfE a b c -> IfE (delLetBinding letBind a) (delLetBinding letBind b) (delLetBinding letBind c)
          MkProdE xs -> MkProdE $ P.map (delLetBinding letBind) xs
          ProjE {} -> error "delLetBinding: TODO ProjE"
          TimeIt {} -> error "delLetBinding: TODO TimeIt"
          WithArenaE {} -> error "delLetBinding: TODO WithArenaE"
          SpawnE {} -> error "delLetBinding: TODO SpawnE"
          SyncE -> error "delLetBinding: TODO SyncE"
          Ext{} -> error "delLetBinding: TODO Ext"
          MapE {} -> error "delLetBinding: TODO MapE"
          FoldE {} -> error "delLetBinding: TODO FoldE"


delAllLetBindings :: Exp1 -> Exp1
delAllLetBindings expr = case expr of
          DataConE loc dcon args -> DataConE loc dcon $ P.map delAllLetBindings args
          VarE {} -> expr
          LitE {} -> expr
          CharE {} -> expr
          FloatE {} -> expr
          LitSymE {} -> expr
          AppE f locs args -> AppE f locs $ P.map delAllLetBindings args
          PrimAppE f args -> PrimAppE f $ P.map delAllLetBindings args
          LetE _ bod -> delAllLetBindings bod
          CaseE scrt mp -> CaseE scrt $ P.map (\(a, b, c) -> (a, b, delAllLetBindings c)) mp
          IfE a b c -> IfE (delAllLetBindings a) (delAllLetBindings b) (delAllLetBindings c)
          MkProdE xs -> MkProdE $ P.map delAllLetBindings xs
          ProjE {} -> error "delLetBinding: TODO ProjE"
          TimeIt {} -> error "delLetBinding: TODO TimeIt"
          WithArenaE {} -> error "delLetBinding: TODO WithArenaE"
          SpawnE {} -> error "delLetBinding: TODO SpawnE"
          SyncE -> error "delLetBinding: TODO SyncE"
          Ext{} -> error "delLetBinding: TODO Ext"
          MapE {} -> error "delLetBinding: TODO MapE"
          FoldE {} -> error "delLetBinding: TODO FoldE"



genPrintFnCase ::  (DataCon, [(IsBoxed, Ty1)]) -> PassM (DataCon, [(Var, ())], PreExp E1Ext () Ty1)
genPrintFnCase (dcon, tys) = do
      xs <- mapM (\_ -> gensym "x") tys
      ys <- mapM (\_ -> gensym "y") tys
      let bnds =
            P.foldr
              (\(ty, x, y) acc ->
                 case ty of
                   IntTy -> (y, [], ProdTy [], PrimAppE PrintInt [VarE x]) : acc
                   FloatTy ->
                     (y, [], ProdTy [], PrimAppE PrintFloat [VarE x]) : acc
                   SymTy ->
                     (y, [], ProdTy [], PrimAppE PrintSym [VarE x]) : acc
                   BoolTy ->
                     (y, [], ProdTy [], PrimAppE PrintBool [VarE x]) : acc
                   PackedTy tycon _ ->
                     (y, [], ProdTy [], AppE (mkPrinterName tycon) [] [VarE x]) :
                     acc
                   SymDictTy {} ->
                     ( y
                     , []
                     , ProdTy []
                     , PrimAppE PrintSym [LitSymE (toVar "SymDict")]) :
                     acc
                   VectorTy {} ->
                     ( y
                     , []
                     , ProdTy []
                     , PrimAppE PrintSym [LitSymE (toVar "Vector")]) :
                     acc
                   PDictTy {} ->
                     ( y
                     , []
                     , ProdTy []
                     , PrimAppE PrintSym [LitSymE (toVar "PDict")]) :
                     acc
                   ListTy {} ->
                     ( y
                     , []
                     , ProdTy []
                     , PrimAppE PrintSym [LitSymE (toVar "List")]) :
                     acc
                   ArenaTy {} ->
                     ( y
                     , []
                     , ProdTy []
                     , PrimAppE PrintSym [LitSymE (toVar "Arena")]) :
                     acc
                   SymSetTy {} ->
                     ( y
                     , []
                     , ProdTy []
                     , PrimAppE PrintSym [LitSymE (toVar "SymSet")]) :
                     acc
                   SymHashTy {} ->
                     ( y
                     , []
                     , ProdTy []
                     , PrimAppE PrintSym [LitSymE (toVar "SymHash")]) :
                     acc
                   IntHashTy {} ->
                     ( y
                     , []
                     , ProdTy []
                     , PrimAppE PrintSym [LitSymE (toVar "IntHash")]) :
                     acc
                   _ -> acc)
              []
              (zip3 (P.map snd tys) xs ys)
      w1 <- gensym "wildcard"
      w2 <- gensym "wildcard"
      let add_spaces ::
               [(Var, [()], Ty1, PreExp E1Ext () Ty1)]
            -> PassM [(Var, [()], Ty1, PreExp E1Ext () Ty1)]
          add_spaces [] = pure []
          add_spaces [z] = pure [z]
          add_spaces (z:zs) = do
            zs' <- add_spaces zs
            wi <- gensym "wildcard"
            pure $
              z :
              (wi, [], ProdTy [], PrimAppE PrintSym [LitSymE (toVar " ")]) :
              zs'
      bnds'' <-
        add_spaces $
        ( w1
          , []
          , ProdTy []
          , PrimAppE PrintSym [LitSymE (toVar ("(" ++ dcon))]) : bnds
      let bnds' =
            bnds'' ++
            [(w2, [], ProdTy [], PrimAppE PrintSym [LitSymE (toVar ")")])]
          bod = mkLets' bnds' (MkProdE [])
      return (dcon, P.map (\x -> (x, ())) xs, bod)

mkLets' ::
     [(Var, [()], Ty1, PreExp E1Ext () Ty1)]
  -> Exp1
  -> Exp1
mkLets' bs bod = P.foldr LetE bod bs



-- For a given Function, deduce the types of each field of a dataconstructor relavant for the solver 
deduceFieldSolverTypes :: DDefs1 -> FunDef1 -> FunDef1
deduceFieldSolverTypes dataDefinitions f@FunDef {funName, funBody, funTy, funArgs, funMeta} = 
  let dconsUsedInFunction = dataConsInFunBody funBody 
      dataConFieldTypeInfo = P.foldr (\dcon map -> let flds = lookupDataCon dataDefinitions dcon
                                                       (_, meta) = {-dbgTraceIt (sdoc flds)-} P.foldr (\fld (index::Int, map) -> 
                                                                                   let isInline = maybeInlineable fld funTy dataDefinitions funName funBody
                                                                                       (isRec, m) = {-([], M.empty)-} isRecursive fld dataDefinitions M.empty
                                                                                       isSc = {-[]-} isScalar fld dataDefinitions dcon M.empty
                                                                                       isSR = isSelfRecursive fld dataDefinitions dcon
                                                                                       ind' = index-1
                                                                                     in (ind', M.insert index (isInline ++ isRec ++ isSc ++ isSR) map)
                                                                                     --index = elemIndex fld flds 
                                                                                     --in case index of 
                                                                                     --       Nothing -> map
                                                                                     --       Just val -> M.insert index (isInline ++ isRec ++ isSc ++ isSR) map
                                                                      ) ((P.length flds) - 1, M.empty) flds 
                                                     in M.insert dcon meta map
                                     ) M.empty (S.toList dconsUsedInFunction)
    in {-dbgTraceIt (sdoc (funName, dataConFieldTypeInfo, snd funTy, funArgs))-} FunDef{funName=funName, funBody=funBody, funTy=funTy, funArgs=funArgs, funMeta=funMeta{dataConFieldTypeInfo=Just dataConFieldTypeInfo}}
       

maybeInlineable :: Ty1 -> ArrowTy Ty1 -> DDefs1 -> Var -> Exp1 -> [DataConFieldType]
maybeInlineable fld funty dataDefinitions funname exp = if (elem fld (fst funty) && (fst (isRecursive fld dataDefinitions M.empty) == [Recursive])) then [IsInlineable] else [] 

-- only for packed mode
-- TODO: update check for pointer mode. 
isSelfRecursive :: Ty1 -> DDefs1 -> DataCon -> [DataConFieldType]
isSelfRecursive fld ddefs dcon = let tycon = getTyOfDataCon ddefs dcon
                                     urty  = PackedTy tycon ()
                                   in if urty == fld then [SelfRecursive] else []

-- isScalar :: Ty1 -> DDefs1 -> DataCon -> [DataConFieldType]
-- isScalar fld ddefs dcon = case fld of 
--                                 PackedTy tycon () -> let d@DDef{tyName=tn, tyArgs=targ, dataCons=dcons} = lookupDDef ddefs tycon
--                                                          len = P.length dcons 
--                                                        in if len == 1 then 
--                                                                         let scl = checkScalar (fst (P.head dcons)) ddefs
--                                                                           in if scl then [Scalar]
--                                                                                     else []
--                                                                       else []
                                                              
--                                 -- TODO: check for other types is not implemented yet. 
--                                 _ -> []

isScalar :: Ty1 -> DDefs1 -> DataCon -> M.Map Ty1 DataConFieldType -> [DataConFieldType]
isScalar fld ddefs dcon map  = case (isRecursive fld ddefs map) of 
                                      ([Recursive], _ ) -> []
                                      _ -> [Scalar]

-- checkScalar :: DataCon -> DDefs1 -> Bool 
-- checkScalar dcon ddefs = let flds = lookupDataCon ddefs dcon
--                            in case flds of 
--                                   [a] -> case a of 
--                                             IntTy   -> True
--                                             CharTy  -> True
--                                             FloatTy -> True
--                                             BoolTy  -> True
--                                             _  -> False
--                                   _  -> False



isRecursive :: Ty1 -> DDefs1 -> M.Map Ty1 DataConFieldType -> ([DataConFieldType], M.Map Ty1 DataConFieldType)
isRecursive fld ddefs map = case M.lookup fld map of 
                                    Nothing -> case fld of --[(DataCon, [(IsBoxed, a)])] 
                                              PackedTy tycon () -> let d@DDef{tyName=tn, tyArgs=targ, dataCons=dcons} = lookupDDef ddefs tycon
                                                                       fld' = P.concatMap (\(a, b) -> P.concatMap (\(d, c) -> [c]) b) dcons
                                                                       (check, map') = P.foldr (\ty (accum, m)  -> 
                                                                                            if not (M.member ty m)
                                                                                            then   
                                                                                              let (r', m') = if (ty == fld) then (accum || True, M.insert ty Recursive m) else (accum || False, m) --isRecursive ty ddefs m''
                                                                                               in case r' of 
                                                                                                  True -> (accum || True, M.insert ty Recursive m')
                                                                                                  False -> let (r'', m'') = isRecursive ty ddefs m'
                                                                                                             in case r'' of 
                                                                                                                   [Recursive] -> (accum || True, M.insert ty Recursive m'')
                                                                                                                   [] -> (accum || False, M.insert ty Recursive m'')
                                                                                            else 
                                                                                              case M.lookup ty m of 
                                                                                                    Just k  -> (accum || True, m) 
                                                                                                    Nothing -> (accum || False, m)
                                                                                   ) (False, map) fld'
                                                                    in if check 
                                                                       then ([Recursive], M.insert fld Recursive map')
                                                                       else ([], map')
                                              _ -> ([], map)
                                    Just val -> ([val], map)
                                                            