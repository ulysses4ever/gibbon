{-# OPTIONS_GHC -fno-warn-name-shadowing #-}

-- | A pass to route end-witnesses as additional function returns.

module Packed.FirstOrder.Passes.RouteEnds 
    ( routeEnds ) where

import           Packed.FirstOrder.Common hiding (FunDef)
import qualified Packed.FirstOrder.L1_Source as L1
import qualified Packed.FirstOrder.LTraverse as L2

-- We use some pieces from this other attempt:
import           Packed.FirstOrder.LTraverse as L2
import           Packed.FirstOrder.Passes.Cursorize2 (cursorizeTy)
import           Packed.FirstOrder.Passes.InferEffects (zipLT, zipTL, instantiateApp)
import Data.List as L hiding (tail)
import Data.Map as M
import Data.Set as S
import Text.PrettyPrint.GenericPretty
import Control.Monad
import Control.Exception
    

-- | Chatter level for this module:
lvl :: Int
lvl = 5


-- =============================================================================

    
-- | The goal of this pass is to take effect signatures and translate
-- them into extra arguments and returns.  This pass does not worry
-- about where the witnesses come from to synthesize these extra
-- returns, it just inserts references to them that create demand.
-- 
-- 
routeEnds :: L2.Prog -> SyM L2.Prog
routeEnds L2.Prog{ddefs,fundefs,mainExp} = -- ddefs, fundefs
    dbgTrace lvl ("Starting routeEnds on "++show(doc fundefs)) $ do
    -- Prog emptyDD <$> mapM fd fundefs <*> pure Nothing

    fds' <- mapM fd $ M.elems fundefs

    -- let gloc = "global"
    mn <- case mainExp of
            Nothing -> return Nothing
            Just (x,t)  -> do (_,x',_) <- exp [] M.empty x
                              return $ Just (x',t) 
                -- do let initWenv = WE (M.singleton gloc (L1.VarE "gcurs")) M.empty
                --    tl' <- tail [] (M.empty,initWenv) x
                --    return $ Just $ L1.LetE ("gcurs", CursorTy, NewBuffer) tl'
    return L2.Prog{ fundefs = M.fromList $ L.map (\f -> (L2.funname f,f)) fds'
                  , ddefs = ddefs
                  , mainExp = mn
                  }
 where
   
  fd :: L2.FunDef -> SyM L2.FunDef
  fd (f@L2.FunDef{funname,funty,funarg,funbod}) =
      let ArrowTy oldInT effs _ = funty
          -- FIXME: split cursorizeTy into two stages.
          (tmpTy@(ArrowTy inT _ newOutT),newIn,newOut) = cursorizeTy funty 
          newTy = ArrowTy oldInT effs newOutT
      in
      dbgTrace lvl ("Processing fundef: "++show(doc f)++
                    "\n  new type: "++sdoc newTy++"\n  newIn/newOut: " ++ show (newIn,newOut)) $
   do
      fresh <- gensym "tupin"
      -- First off, we need to use the lexical variable name to name
      -- the input's fixed abstract location (from the lambda body's prspective).      
      let 

-- This pass doesn't deal with injected arguments, only returns:
          -- (newArg, bod) =
          --     if newIn == [] -- No injected cursor params..
          --     then (funarg, funbod)
          --     else ( fresh
          --          , LetE (funarg, fmap (const ()) inT,
          --                  (L1.projNonFirst (length newIn) (L1.VarE fresh)))
          --                 funbod
          --          )

          -- argLoc  = argtyToLoc (L2.mangle newArg) inT
          -- Arg location NOT COUNTING, new/inserted arguments:
          argLoc  = argtyToLoc (L2.mangle funarg) oldInT

--          localizedEffects  = substEffs (zipLT argLoc inT) effs
--          localizedEffects2 = substEffs (zipTL inT argLoc) effs

      (_efs, TupLoc retlocs) <- instantiateApp newTy argLoc 
      let augments = L.init retlocs
                       
      let env0 = 
           dbgTrace lvl (" !!! argLoc "++show argLoc++", inTy "++show inT++", instantiate: "++show retlocs) $ 
--           dbgTrace lvl (" !!! localEffs1 "++show localizedEffects++" locEffs2 "++show localizedEffects2) $ 
           M.singleton newArg argLoc
          newArg = funarg
          bod = funbod
          demand = L.map ((\(Just x) -> x) . getLocVar) augments -- newOut
      (_,exp',_) <- exp demand env0 bod
      return $ L2.FunDef funname newTy newArg exp'


  funType f = funty $ fundefs # f
             
  -- Arguments:
  --
  --  (1) the demanded traversal witnesses (end-of-input cursors)
  --  (2) an environment mapping lexical variables to abstract locations
  --  (3) expression to process
  -- 
  -- Return values:
  --
  --  (1) A list corresponding to the cursor values ADDED to the
  --      return type, containing their locations.
  --  (2) The updated expression, possibly with a tupled return type
  --      thereby including the new cursor returns.
  --  (3) The location of the processed expression, NOT including the
  --      added returns.
  exp :: [LocVar] -> LocEnv -> L1.Exp -> SyM ([Loc],L1.Exp, Loc)
  exp demanded env ex =
    dbgTrace lvl ("\n [routeEnds] exp, demanding "++show demanded++": "++show ex++"\n  with env: "++show env) $
    case ex of

     -- ASSUMPTION we are ONLY given demands that we can FULFILL:
     VarE v  ->
         let ex' = MkProdE $ (L.map VarE demanded) ++ [VarE v] in
         return (L.map Fixed demanded, ex', env # v)

     -- Literals cannot produce end-witnesses:
     LitE n -> case demanded of [] -> pure$ ([], LitE n, Bottom)


     -- PrimApps do not currently produce end-witnesses:
     PrimAppE _ ls -> case demanded of
                        [] -> L1.assertTrivs ls $ pure ([],ex,Bottom)
                
     -- Allocating new data doesn't witness the end of any data being read.
     LetE (v,ty, MkPackedE k ls) bod -> L1.assertTrivs ls $ 
       do env' <- extendLocEnv [(v,ty)] env
          (aug,bod',loc) <- exp demanded env' bod
          return (aug, LetE (v,ty,MkPackedE k ls) bod', loc)
                
    -- A let is a fork in the road, a compound expression where we
    -- need to decide which branch can fulfill a given demand.
     LetE (v,_t,rhs) bod -> 
      do
         ((fulfilled,demanded'), rhs', rloc) <- maybeFulfill demanded env rhs          
         -- (reff,rhs', rloc) <- exp [] env rhs
         error $ "got effects back from rhs: "++show (fulfilled,demanded)
         -- let env' = M.insert v rloc env 
         -- (beff,bloc) <- exp env' bod         
         -- return (S.union beff reff, bloc)
         __finishLetE

     --  We're allowing these as tail calls:
     AppE rat rand -> -- L1.assertTriv rnd $
       case rand of
        L1.VarE vr -> 
          do let loc   = env # vr
             -- This looks up the type before this pass, not with end cursors:
             let arrTy@(ArrowTy _ _ ouT) = funType rat
             (effs,loc) <- instantiateApp arrTy loc
             if L.null effs
              then dbgTrace lvl (" [routeEnds] processing app with ZERO extra end-witness returns:\n  "++sdoc ex) $
                   assert (demanded == []) $ 
                   return ([], AppE rat rand, loc) -- Nothing to see here.
              else do
                -- FIXME: THESE COULD BE IN THE WRONG ORDER:  (But it doesn't matter below.)
                let outs = L.map (\(Traverse v) -> toEndVar v) (S.toList effs)
                -- FIXME: assert that the demands match what we got back...
                -- might need to shuffle the order 
                assert (length demanded == length outs) $! return ()
                let ouT' = L1.ProdTy $ (L.map mkCursorTy outs) ++ [ouT]
                tmp <- gensym "hoistapp"
                let newExp = LetE (tmp, fmap (const ()) ouT', AppE rat rand) $
                               letBindProjections (L.map (\v -> (v,mkCursorTy ())) outs) (VarE tmp) $
                                 -- FIXME/TODO: unpack the witnesses we know about, returns 1-(N-1):
                                 (ProjE (length effs) (VarE tmp))
                dbgTrace lvl (" [routeEnds] processing app with these extra returns: "++
                                 show effs++", new expr:\n "++sdoc newExp) $! 
                  return (_,newExp,loc)

        _ -> error$ "routeEnds: FINISHME: handle this AppE operand: "++show rand
      
          
     -- Here we must fulfill the demand on ALL branches uniformly.
     CaseE e1 ls -> L1.assertTriv e1 $
      let scrutloc = let VarE sv = e1 in env # sv

          docase (dcon,patVs,rhs) = do
            let tys    = lookupDataCon ddefs dcon
                zipped = fragileZip patVs tys
--                freeRHS = L1.freeVars rhs
            env' <- extendLocEnv zipped env
            (extra,rhs',loc) <- exp demanded env' rhs
            
            -- Since this pass is the one concerned with End propogation,
            -- it's the one that reifies the fact "last field's end is constructors end":
            let rhs'' = let Fixed v = scrutloc
                        in LetE (toEndVar v, mkCursorTy (), VarE (toEndVar (L.last patVs)))$
                            rhs'                                
            return (extra,(dcon,patVs,rhs''),loc)
         
      in do 
            (extras,ls',locs) <- unzip3 <$> mapM docase ls   
            unless (1 == (length $ nub $ L.map L.length extras)) $
              error $ "Got inconsintent-length augmented-return types from branches of case:\n  "
                      ++show extras++"\nExpr:\n  "++sdoc ex
            let (locFin,cnstrts) = joins locs
                (augments,_) = unzip$ L.map joins $ L.transpose extras

            when (not (L.null cnstrts)) $
             dbgTrace 1 ("Warning: routeEnds/FINISHME: process these constraints: "++show cnstrts) (return ())

            return (augments, CaseE e1 ls', locFin)

     _ -> error$ "[routeEnds] Unfinished.  Needs to handle:\n  "++sdoc ex
{-
      AppE v e -> AppE v <$> go e

      ProjE i e      -> ProjE i <$> go e
      MkProdE ls     -> MkProdE <$> mapM go ls
      MkPackedE k ls -> MkPackedE k <$> mapM go ls
      TimeIt e t     -> TimeIt <$> go e <*> pure t
      IfE a b c      -> IfE <$> go a <*> go b <*> go c
      -- MapE (v,t,rhs) bod -> MapE <$> ((v,t,) <$> go rhs) <*> go bod
      -- FoldE (v1,t1,r1) (v2,t2,r2) bod ->
      --     FoldE <$> ((v1,t1,) <$> go r1)
      --           <*> ((v2,t2,) <$> go r2)
      --           <*> go bod
-}

  -- | Process an expression multiple times, first to see what it can
  -- offer, and then again if it can offer something we want.
  -- Returns hits followed by misses.
  maybeFulfill :: [LocVar] -> LocEnv -> L1.Exp -> SyM (([Loc],[LocVar]),L1.Exp, Loc)
  maybeFulfill demand env ex = do
    ([], ex', loc) <- exp [] env ex
    let offered = locToEndVars loc
        matches = S.intersection (S.fromList demand) (S.fromList offered)

    if dbgTrace 1 ("[routeEnds] maybeFulfill, offered"++show offered
                   ++", demanded "++show demand++", from: "++show ex) $
       S.null matches
     then return (([],demand),ex',loc)
     else do 
      let (hits,misses) = L.partition (`S.member` matches) demand
      (hits',ex',loc) <- exp [] env ex
      return ((hits',misses), ex', loc)
           
           

locToEndVars :: Loc -> [Var]
locToEndVars l =
 case l of
   (Fixed x) | isEndVar x -> [x]
             | otherwise -> []
   (Fresh _) -> []
   (TupLoc ls) -> concatMap locToEndVars ls 
   Top    -> []
   Bottom -> []
     

letBindProjections :: [(Var, L1.Ty)] -> Exp -> Exp -> Exp
letBindProjections ls tupname bod = go 0 ls
  where
    go _ [] = bod
    go ix ((vr,ty):rst) = LetE (vr, ty, ProjE ix tupname) $ go (ix+1) rst
                   
     
-- | Let bind IFF there are extra cursor results.
maybeLetTup :: [Loc] -> (L1.Ty, L1.Exp) -> WitnessEnv
            -> (L1.Exp -> WitnessEnv -> SyM L1.Exp) -> SyM L1.Exp
maybeLetTup locs (ty,ex) env fn = __refactor
{-maybeLetTup locs (ty,ex) env fn =
  case locs of
   -- []  -> error$ "maybeLetTup: didn't expect zero locs:\n  " ++sdoc (ty,ex)
   -- Zero extra cursor return values
   [] -> fn ex env
   -- Otherwise the layout of the tuple is (cursor0,..cursorn, origValue):
   _   -> do
     -- The name doesn't matter, just that it's in the environment:
     tmp <- gensym "mlt"
     -- Let-bind all the new things that come back with the exp
     -- to bring them into the environment.
     let env' = witnessBinding tmp (TupLoc locs) `unionWEnv` env
         n = length locs
     bod <- fn (mkProj (n - 1) n (L1.VarE tmp)) env'
     return $ L1.LetE (tmp, ty, ex) bod
-}

-- | A variable binding may be able to 
varToWitnesses :: Var -> Loc -> M.Map LocVar Exp
varToWitnesses = __                  
{- varToWitnesses vr loc = WE (M.fromList $ go loc (L1.VarE vr)) M.empty
  where
   go (TupLoc ls) ex =
       concat [ go x (mkProj ix (length ls) ex)
              | (ix,x) <- zip [0..] ls ]
   go (Fresh v) e = [ (v,e) ]
   go (Fixed v) e = [ (v,e) ]
   go Top       _ = []
   go Bottom    _ = [] -}

data WitnessEnv -- WIP: REMOVE ME