{-# LANGUAGE CPP            #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE LambdaCase     #-}

{- L0 Specializer (part 2):
~~~~~~~~~~~~~~~~~~~~~~~~~~~

Paulette worked on a specializer which lives in 'Gibbon.L0.Specialize'
and specializes functions on curried calls. Now we need a driver which
takes these different pieces, and puts them together in order to
transform a fully polymorphic L0 program, into a monomorphic L1 program.
This module is the first attempt to do that.

-}
module Gibbon.L0.Specialize2
  ( bindLambdas
  , monomorphize
  , specLambdas
  , desugarL0
  , toL1
  , floatOutCase
  ) where

import           Control.Monad
import           Control.Monad.State
import           Data.Foldable                  (foldlM, foldrM)
import qualified Data.Map                       as M
import qualified Data.Set                       as S
import           GHC.Stack                      (HasCallStack)
import           Text.PrettyPrint.GenericPretty

import           Data.Bifunctor
import           Gibbon.Common
import           Gibbon.L0.Syntax
import           Gibbon.L0.Typecheck
import qualified Gibbon.L1.Syntax               as L1
import           Gibbon.Pretty


--------------------------------------------------------------------------------
{-

Transforming L0 to L1
~~~~~~~~~~~~~~~~~~~~~

(A) Monomorphization
(B) Lambda lifting (via specialization)
(C) Convert to L1, which should be pretty straightforward at this point.



Monomorphization
~~~~~~~~~~~~~~~~

Things that can be polymorphic, and therefore should be monormorphized:
- top-level fn calls
- lamda functions
- datacons

Here's a rough plan:

(0) Walk over all datatypes and functions to collect obligations for
    polymorphic types which have been fully applied to monomorphic types in the
    source program. For example, in a function 'f :: Int -> Maybe Int', we must
    replace 'Maybe Int' with an appropriate monomorphic alternative.


(1) Start with main: walk over it, and collect all monomorphization obligations:

        { [((fn_name, [tyapp]), newname)] , [((lam_name, [tyapp]), newname)] , [((tycon, [tyapp]), newname)] }

    i.e fn_name should be monomorphized at [tyapp], and it should be named newname.

    While collecting these obligations, just replace all polymorphic things with their
    corresponding new names.

(1.2) 'main' can transitively call a polymorphic function via a monomorphic one.
      To collect those obligations, we walk over all the monomorphic functions in
      the program as well.

(2) Start monormorphizing toplevel functions, and collect any new obligations
    that may be generated. Repeat (2) until there are no more obls.

(3) Create monomorphic versions of all datatypes.

(4) After we have all the monomorphic datatypes, we need to fix TYPEs in (Packed TYPE ..) to
    have the correct suffix. Actually, this could be done in 'collectMonoObls', but we do
    it in a separate pass for now.

(5) Delete all polymorphic fns and datatypes, which should all just be dead code now.

(6) Typecheck monomorphic L0 once more.

TODOs:

(*) Curried functions are not supported atm (not even by the typechecker):
    they're a bit tricky to get right as Gibbon functions can only accept 1 argument.
(*) Support minimal 'import's in 'Gibbon.HaskellFronted'.
(*) Anonymous lambdas


Lambda lifting
~~~~~~~~~~~~~~

Assume that the input program is monomorphic.

(a) Traverse all expressions in the program (main and functions), and
    float out all lambda definitions to the top-level.

(b) Collect all function references passed in as arguments to other functions.
    E.g.

        foo :: (A -> B) -> A -> B
        main = ... (foo fn1 thing1) ... (foo fn2 thing2) ...

     => [ ((foo, [fn1]), foo_1), ((foo, [fn2]), foo_2), ... ]


(c) (foo fn1) and (foo fn2) would now be separate top-level first order functions:

        foo_1 :: A -> B
        foo_1 thing = ... fn1 thing ...

        foo_2 :: A -> B
        foo_2 thing = ... fn2 thing ...

    Create these functions, drop the lambdas from it's type, arguments etc.

-}

-- Just a mechanical transformation ..
toL1 :: Prog0 -> L1.Prog1
toL1 Prog {ddefs, fundefs, mainExp} =
  Prog (M.map toL1DDef ddefs) (M.map toL1FunDef fundefs) mainExp'
  where
    mainExp' =
      case mainExp of
        Nothing      -> Nothing
        Just (e, ty) -> Just (toL1Exp e, toL1Ty ty)
    toL1DDef :: DDef0 -> L1.DDef1
    toL1DDef ddf@DDef {dataCons} =
      ddf
        { dataCons =
            map
              (\(dcon, btys) -> (dcon, map (\(a, b) -> (a, toL1Ty b)) btys))
              dataCons
        }
    toL1FunDef :: FunDef0 -> L1.FunDef1
    toL1FunDef fn@FunDef {funTy, funBody} =
      fn {funTy = toL1TyS funTy, funBody = toL1Exp funBody}
    toL1Exp :: Exp0 -> L1.Exp1
    toL1Exp ex =
      case ex of
        VarE v -> L1.VarE v
        LitE n -> L1.LitE n
        CharE n -> L1.CharE n
        FloatE n -> L1.FloatE n
        LitSymE v -> L1.LitSymE v
        AppE f [] args -> AppE f [] (map toL1Exp args)
        AppE {} -> err1 (sdoc ex)
        PrimAppE pr args ->
          case pr
            -- This is always going to have a function reference which
            -- we cannot eliminate.
                of
            VSortP {} ->
              case args of
                [ls, Ext (FunRefE _ fp)] ->
                  PrimAppE (toL1Prim pr) [toL1Exp ls, VarE fp]
                [ls, Ext (L _ (Ext (FunRefE _ fp)))] ->
                  PrimAppE (toL1Prim pr) [toL1Exp ls, VarE fp]
                _ -> PrimAppE (toL1Prim pr) (map toL1Exp args)
            _ -> PrimAppE (toL1Prim pr) (map toL1Exp args)
        LetE (v, [], ty, rhs) bod ->
          LetE (v, [], toL1Ty ty, toL1Exp rhs) (toL1Exp bod)
        LetE {} -> err1 (sdoc ex)
        IfE a b c -> IfE (toL1Exp a) (toL1Exp b) (toL1Exp c)
        MkProdE ls -> MkProdE (map toL1Exp ls)
        ProjE i a -> ProjE i (toL1Exp a)
        CaseE scrt brs ->
          CaseE
            (toL1Exp scrt)
            (map (\(a, b, c) -> (a, map (\(x, _) -> (x, ())) b, toL1Exp c)) brs)
        DataConE (ProdTy []) dcon ls -> DataConE () dcon (map toL1Exp ls)
        DataConE {} -> err1 (sdoc ex)
        TimeIt e ty b -> TimeIt (toL1Exp e) (toL1Ty ty) b
        SpawnE f [] args -> SpawnE f [] (map toL1Exp args)
        SpawnE {} -> err1 (sdoc ex)
        SyncE -> SyncE
        WithArenaE v e -> WithArenaE v (toL1Exp e)
        MapE {} -> err1 (sdoc ex)
        FoldE {} -> err1 (sdoc ex)
        Ext ext ->
          case ext of
            LambdaE {} -> err2 (sdoc ex)
            PolyAppE {} -> err2 (sdoc ex)
            FunRefE {} -> err2 (sdoc ex)
            BenchE fn tyapps args b ->
              case tyapps of
                [] -> Ext $ L1.BenchE fn [] (map toL1Exp args) b
                _  -> error "toL1: Polymorphic 'bench' not supported yet."
            ParE0 {} -> error "toL1: ParE0"
            PrintPacked {} -> error "toL1: PrintPacked"
            CopyPacked {} -> error "toL1: CopyPacked"
            TravPacked {} -> error "toL1: TravPacked"
            LinearExt {} ->
              error $
              "toL1: a linear types extension wasn't desugared: " ++ sdoc ex
            -- Erase srclocs while going to L1
            L _ e -> toL1Exp e
    toL1Prim :: Prim Ty0 -> Prim L1.Ty1
    toL1Prim = fmap toL1Ty
    toL1Ty :: Ty0 -> L1.Ty1
    toL1Ty ty =
      case ty of
        CharTy -> L1.CharTy
        IntTy -> L1.IntTy
        FloatTy -> L1.FloatTy
        SymTy0 -> L1.SymTy
        BoolTy -> L1.BoolTy
        TyVar {} -> err1 (sdoc ty)
        MetaTv {} -> err1 (sdoc ty)
        ProdTy tys -> L1.ProdTy $ map toL1Ty tys
        SymDictTy (Just v) a -> L1.SymDictTy (Just v) $ toL1Ty a
        SymDictTy Nothing a -> L1.SymDictTy Nothing $ toL1Ty a
        PDictTy k v -> L1.PDictTy (toL1Ty k) (toL1Ty v)
        ArrowTy {} -> err2 (sdoc ty)
        PackedTy tycon tyapps
          | tyapps == [] -> L1.PackedTy tycon ()
          | otherwise -> err1 (sdoc ty)
        ArenaTy -> L1.ArenaTy
        SymSetTy -> L1.SymSetTy
        SymHashTy -> L1.SymHashTy
        IntHashTy -> L1.IntHashTy
        VectorTy a -> L1.VectorTy (toL1Ty a)
        ListTy a -> L1.ListTy (toL1Ty a)
    toL1TyS :: ArrowTy Ty0 -> ArrowTy L1.Ty1
    toL1TyS t@(ForAll tyvars (ArrowTy as b))
      | tyvars == [] = (map toL1Ty as, toL1Ty b)
      | otherwise    = err1 (sdoc t)
    toL1TyS (ForAll _ t) = error $ "toL1: Not a function type: " ++ sdoc t
    err1 msg =
      error $ "toL1: Program was not fully monomorphized. Encountered: " ++ msg
    err2 msg = error $ "toL1: Could not lift all lambdas. Encountered: " ++ msg


--------------------------------------------------------------------------------

-- The monomorphization monad.
type MonoM a = StateT MonoState PassM a

data MonoState = MonoState
  { mono_funs_worklist :: M.Map (Var, [Ty0]) Var
  , mono_funs_done :: M.Map (Var, [Ty0]) Var
  , mono_lams      :: M.Map (Var, [Ty0]) Var
  , mono_dcons     :: M.Map (TyCon, [Ty0]) Var -- suffix
  }
  deriving (Show, Read, Ord, Eq, Generic, Out)

emptyMonoState :: MonoState
emptyMonoState = MonoState
  { mono_funs_worklist = M.empty, mono_funs_done = M.empty
  , mono_lams = M.empty, mono_dcons = M.empty }

extendFuns :: (Var,[Ty0]) -> Var -> MonoState -> MonoState
extendFuns k v mono_st@MonoState{mono_funs_worklist} =
  mono_st { mono_funs_worklist = M.insert k v mono_funs_worklist }

extendLambdas :: (Var, [Ty0]) -> Var -> MonoState -> MonoState
extendLambdas k v mono_st@MonoState {mono_lams} =
  mono_st {mono_lams = M.insert k v mono_lams}

extendDatacons :: (TyCon, [Ty0]) -> Var -> MonoState -> MonoState
extendDatacons k v mono_st@MonoState {mono_dcons} =
  mono_st {mono_dcons = M.insert k v mono_dcons}


-- We need this wrapper because of the way these maps are defined.
--
-- getLambdaObls id { mono_lams = [ ((id,[IntTy]), id1), ((id,[BoolTy]), id2) ] }
--   = [ (id2, [IntTy]), (id2, [BoolTy]) ]
getLambdaObls :: Var -> MonoState -> (M.Map Var [Ty0])
getLambdaObls f MonoState {mono_lams} =
  M.fromList $ map (\((_, tys), w) -> (w, tys)) f_mono_st
  where
    f_mono_st = filter (\((v, _), _) -> v == f) (M.toList mono_lams)


--------------------------------------------------------------------------------
monomorphize :: Prog0 -> PassM Prog0
monomorphize p@Prog {ddefs, fundefs, mainExp} = do
  let env2 = Env2 M.empty (M.map funTy fundefs)
  let mono_m
        -- Step (0)
       = do
        (ddfs0 :: [DDef0]) <- mapM (monoOblsDDef ddefs) (M.elems ddefs)
        let ddefs' = M.fromList $ map (\a -> (tyName a, a)) ddfs0
        -- Step (1)
        mainExp' <-
          case mainExp of
            Nothing -> pure Nothing
            Just (e, ty) -> do
              mainExp' <- collectMonoObls ddefs' env2 toplevel e
              mainExp'' <- monoLambdas mainExp'
              mono_st <- get
              assertLambdasMonomorphized mono_st
              pure $ Just (mainExp'', ty)
        -- Step (1.2)
        let mono_funs = M.filter isMonoFun fundefs
        mono_funs' <-
          foldlM
            (\funs fn@FunDef {funArgs, funName, funBody, funTy} -> do
               let env2' =
                     extendsVEnv (M.fromList $ zip funArgs (inTys funTy)) env2
               let (ForAll tyvars (ArrowTy as b)) = funTy
               as' <- mapM (monoOblsTy ddefs) as
               b' <- monoOblsTy ddefs b
               funBody' <- collectMonoObls ddefs' env2' toplevel funBody
               funBody'' <- monoLambdas funBody'
               mono_st <- get
               assertLambdasMonomorphized mono_st
               let fn' =
                     fn
                       { funBody = funBody''
                       , funTy = ForAll tyvars (ArrowTy as' b')
                       }
               pure $ M.insert funName fn' funs)
            mono_funs
            (M.elems mono_funs)
        let fundefs' = mono_funs' `M.union` fundefs
        -- Step (2)
        fundefs'' <- monoFunDefs fundefs'
        -- N.B. Important to fetch the state before we run 'monoDDefs' which
        -- clears everything in 'mono_dcons'.
        mono_st <- get
        -- Step (3)
        ddefs'' <- monoDDefs ddefs'
        let p3 = p {ddefs = ddefs'', fundefs = fundefs'', mainExp = mainExp'}
        let p3' = updateTyCons mono_st p3
        -- Important; p3 is not type-checkable until updateTyCons runs.
        -- Step (4)
        lift $ tcProg p3'
  (p4, _) <- runStateT mono_m emptyMonoState
  let p5 = purgePolyDDefs p4
  let p5' = purgePolyFuns p5

-- Step (6)
  tcProg p5'
  where
    toplevel = M.keysSet fundefs
    monoFunDefs :: FunDefs0 -> MonoM FunDefs0
    monoFunDefs fundefs1 = do
      mono_st <- get
      if M.null (mono_funs_worklist mono_st)
      then pure fundefs1
      else do
        let (((fun_name, tyapps), new_fun_name):rst) = M.toList (mono_funs_worklist mono_st)
            fn@FunDef{funArgs, funName, funBody} = fundefs # fun_name
            tyvars = tyVarsFromScheme (funTy fn)
        assertSameLength ("While monormorphizing the function: " ++ sdoc funName) tyvars tyapps
        let mp = M.fromList $ zip tyvars tyapps
            funTy' = ForAll [] (substTyVar mp (tyFromScheme (funTy fn)))
            funBody' = substTyVarExp mp funBody
            -- Move this obligation from todo to done.
            mono_st' = mono_st { mono_funs_done = M.insert (fun_name, tyapps) new_fun_name (mono_funs_done mono_st)
                               , mono_funs_worklist = M.fromList rst }
        put mono_st'
        -- Collect any more obligations generated due to the monormorphization
        let argEnv = M.fromList $ zip funArgs (inTys funTy')
        let (argFenv, argVenv) = M.partition (\case ArrowTy {} -> True; _ -> False) argEnv
        let argFenv' = M.map (ForAll []) argFenv
        let env21 = Env2 argVenv (M.union argFenv' (M.map funTy fundefs1))
        funBody'' <- collectMonoObls ddefs env21 toplevel funBody'
        funBody''' <- monoLambdas funBody''
        let fn' = fn { funName = new_fun_name, funTy = funTy', funBody = funBody''' }
        monoFunDefs (M.insert new_fun_name fn' fundefs1)

    -- Create monomorphic versions of all polymorphic datatypes.
    monoDDefs :: DDefs0 -> MonoM DDefs0
    monoDDefs ddefs1 = do
      mono_st <- get
      if M.null (mono_dcons mono_st)
        then pure ddefs1
        else do
          let (((tycon, tyapps), suffix):rst) = M.toList (mono_dcons mono_st)
              ddf@DDef {tyName, tyArgs, dataCons} = lookupDDef ddefs tycon
          assertSameLength ("In the datacon: " ++ sdoc tyName) tyArgs tyapps
          let tyName' = varAppend tyName suffix
              dataCons' =
                map
                  (\(dcon, vtys) ->
                     let (vars, tys) = unzip vtys
                         sbst = M.fromList (zip tyArgs tyapps)
                         tys' = map (substTyVar sbst) tys
                         tys'' = map (updateTyConsTy ddefs1 mono_st) tys'
                         vtys' = zip vars tys''
                      in (dcon ++ fromVar suffix, vtys'))
                  dataCons
              ddefs1' =
                M.insert
                  tyName'
                  (ddf {tyName = tyName', tyArgs = [], dataCons = dataCons'})
                  ddefs1
              mono_st' = mono_st {mono_dcons = M.fromList rst}
          put mono_st'
          monoDDefs ddefs1'
    -- Foo. We must update Bar to use the correct Foo.
    monoOblsDDef :: DDefs0 -> DDef0 -> MonoM DDef0
    monoOblsDDef ddefs1 d@DDef {dataCons} = do
      dataCons' <-
        mapM
          (\(dcon, args) ->
             (dcon, ) <$> mapM (\(a, ty) -> (a, ) <$> monoOblsTy ddefs1 ty) args)
          dataCons
      pure $ d {dataCons = dataCons'}

-- Step (5)

-- Create monomorphic versions of all polymorphic functions.

-- Create monomorphic versions of all polymorphic datatypes.
-- See examples/T127. Bar is monomorphic, but uses a monomorphized-by-hand

-- After 'monoLambdas' runs, (mono_lams MonoState) must be empty
assertLambdasMonomorphized :: (Monad m, HasCallStack) => MonoState -> m ()
assertLambdasMonomorphized MonoState {mono_lams} =
  if M.null mono_lams
    then pure ()
    else error $
         "Expected 0 lambda monormorphization obligations. Got " ++
         sdoc mono_lams

assertSameLength ::
     (Out a, Out b, Monad m, HasCallStack) => String -> [a] -> [b] -> m ()
assertSameLength msg as bs =
  if length as /= length bs
    then error $
         "assertSameLength: Type applications " ++
         sdoc bs ++
         " incompatible with the type variables: " ++ sdoc as ++ ".\n " ++ msg
    else pure ()

monoOblsTy :: DDefs0 -> Ty0 -> MonoM Ty0
monoOblsTy ddefs1 t = do
  case t of
    CharTy -> pure t
    IntTy -> pure t
    FloatTy -> pure t
    SymTy0 -> pure t
    BoolTy -> pure t
    TyVar {} -> pure t
    MetaTv {} -> pure t
    ProdTy ls -> ProdTy <$> mapM (monoOblsTy ddefs1) ls
    SymDictTy {} -> pure t
    PDictTy {} -> pure t
    ArrowTy as b -> do
      as' <- mapM (monoOblsTy ddefs1) as
      b' <- monoOblsTy ddefs1 b
      pure $ ArrowTy as' b'
    PackedTy tycon tyapps ->
      case tyapps of
        [] -> pure t
        -- We're only looking for fully monomorphized datatypes here
        _ ->
          case tyVarsInTys tyapps of
            [] -> do
              tyapps' <- mapM (monoOblsTy ddefs1) tyapps
              mono_st <- get
              case M.lookup (tycon, tyapps') (mono_dcons mono_st) of
                Nothing -> do
                  let DDef {tyArgs} = lookupDDef ddefs1 tycon
                  assertSameLength ("In the type: " ++ sdoc t) tyArgs tyapps'
                  suffix <- lift $ gensym "_v"
                  let mono_st' = extendDatacons (tycon, tyapps') suffix mono_st
                      tycon' = tycon ++ (fromVar suffix)
                  put mono_st'
                  pure $ PackedTy tycon' []
                Just suffix -> pure $ PackedTy (tycon ++ (fromVar suffix)) []
            _ -> pure t
    VectorTy {} -> pure t
    ListTy {} -> pure t
    ArenaTy -> pure t
    SymSetTy -> pure t
    SymHashTy -> pure t
    IntHashTy -> pure t


-- | Collect monomorphization obligations.
collectMonoObls :: DDefs0 -> Env2 Ty0 -> S.Set Var -> Exp0 -> MonoM Exp0
collectMonoObls ddefs env2 toplevel ex =
  case ex of
    AppE f [] args -> do
      args' <- mapM (collectMonoObls ddefs env2 toplevel) args
      pure $ AppE f [] args'
    AppE f tyapps args -> do
      args' <- mapM (collectMonoObls ddefs env2 toplevel) args
      tyapps' <- mapM (monoOblsTy ddefs) tyapps
      f' <- addFnObl f tyapps'
      pure $ AppE f' [] args'
    LetE (v, [], ty@ArrowTy {}, rhs) bod -> do
      let env2' = (extendVEnv v ty env2)
      case rhs of
        Ext (LambdaE {}) -> do
          rhs' <- go rhs
          bod' <- collectMonoObls ddefs env2' toplevel bod
          pure $ LetE (v, [], ty, rhs') bod'
        _
          -- Special case for lambda bindings passed in as function arguments:
          --
          -- 'v' is an ArrowTy, but not a lambda defn -- this let binding must
          -- be in a function body, and 'v' must be a lambda that's
          -- passed in as an argument. We don't want to monormorphize it here.
          -- It'll be handled when the the outer fn is processed.
          -- To ensure that (AppE v ...) stays the same, we add 'v' into
          -- mono_st s.t. it's new name would be same as it's old name.
         -> do
          state (\st -> ((), extendLambdas (v, []) v st))
          rhs' <- go rhs
          bod' <- collectMonoObls ddefs env2' toplevel bod
          pure $ LetE (v, [], ty, rhs') bod'
    LetE (v, [], ty, rhs) bod -> do
      let env2' = (extendVEnv v ty env2)
      rhs' <- go rhs
      bod' <- collectMonoObls ddefs env2' toplevel bod
      pure $ LetE (v, [], ty, rhs') bod'
    LetE (_, (_:_), _, _) _ ->
      error $ "collectMonoObls: Let not monomorphized: " ++ sdoc ex
    CaseE scrt brs -> do
      case recoverType ddefs env2 scrt of
        PackedTy tycon tyapps -> do
          mono_st <- get
          (suffix, mono_st'') <-
            case tyapps
              -- It's a monomorphic datatype.
                  of
              [] -> pure ("", mono_st)
              _ -> do
                tyapps' <- mapM (monoOblsTy ddefs) tyapps
                case M.lookup (tycon, tyapps') (mono_dcons mono_st) of
                  Nothing -> do
                    let DDef {tyArgs} = lookupDDef ddefs tycon
                    assertSameLength
                      ("In the expression: " ++ sdoc ex)
                      tyArgs
                      tyapps'
                    suffix <- lift $ gensym "_v"
                    let mono_st' =
                          extendDatacons (tycon, tyapps') suffix mono_st
                    pure (suffix, mono_st')
                  Just suffix -> pure (suffix, mono_st)
          put mono_st''
          scrt' <- go scrt
          brs' <-
            foldlM
              (\acc (dcon, vtys, bod) -> do
                 let env2' = extendsVEnv (M.fromList vtys) env2
                 bod' <- collectMonoObls ddefs env2' toplevel bod
                 pure $ acc ++ [(dcon ++ fromVar suffix, vtys, bod')])
              []
              brs
          pure $ CaseE scrt' brs'
        ty ->
          error $
          "collectMonoObls: Unexpected type for the scrutinee, " ++
          sdoc ty ++ ". In the expression: " ++ sdoc ex
    DataConE (ProdTy tyapps) dcon args -> do
      args' <- mapM (collectMonoObls ddefs env2 toplevel) args
      case tyapps
        -- It's a monomorphic datatype.
            of
        [] -> pure $ DataConE (ProdTy []) dcon args'
        _ -> do
          mono_st <- get
          -- Collect datacon instances here.
          let tycon = getTyOfDataCon ddefs dcon
          tyapps' <- mapM (monoOblsTy ddefs) tyapps
          case M.lookup (tycon, tyapps') (mono_dcons mono_st) of
            Nothing -> do
              let DDef {tyArgs} = lookupDDef ddefs tycon
              assertSameLength ("In the expression: " ++ sdoc ex) tyArgs tyapps'
              suffix <- lift $ gensym "_v"
              let mono_st' = extendDatacons (tycon, tyapps) suffix mono_st
                  dcon' = dcon ++ (fromVar suffix)
              put mono_st'
              pure $ DataConE (ProdTy []) dcon' args'
            Just suffix -> do
              let dcon' = dcon ++ (fromVar suffix)
              pure $ DataConE (ProdTy []) dcon' args'
    DataConE {} ->
      error $
      "collectMonoObls: DataConE expected ProdTy tyapps, got " ++ sdoc ex
    PrimAppE pr args -> do
      args' <- mapM (collectMonoObls ddefs env2 toplevel) args
      pure $ PrimAppE pr args'
    VarE {} -> pure ex
    LitE {} -> pure ex
    CharE {} -> pure ex
    FloatE {} -> pure ex
    LitSymE {} -> pure ex
    IfE a b c -> do
      a' <- go a
      b' <- go b
      c' <- go c
      pure $ IfE a' b' c'
    MkProdE args -> do
      args' <- mapM (collectMonoObls ddefs env2 toplevel) args
      pure $ MkProdE args'
    ProjE i e -> do
      e' <- go e
      pure $ ProjE i e'
    TimeIt e ty b -> do
      e' <- go e
      pure $ TimeIt e' ty b
    WithArenaE v e -> do
      e' <- go e
      pure $ WithArenaE v e'
    Ext ext ->
      case ext of
        LambdaE args bod -> do
          bod' <-
            collectMonoObls
              ddefs
              (extendsVEnv (M.fromList args) env2)
              toplevel
              bod
          pure $ Ext $ LambdaE args bod'
        PolyAppE {} -> error ("collectMonoObls: TODO, " ++ sdoc ext)
        FunRefE tyapps f ->
          case tyapps of
            [] -> pure $ Ext $ FunRefE [] f
            _ -> do
              tyapps' <- mapM (monoOblsTy ddefs) tyapps
              f' <- addFnObl f tyapps'
              pure $ Ext $ FunRefE [] f'
        BenchE _fn tyapps _args _b ->
          case tyapps of
            [] -> pure ex
            _ ->
              error $
              "collectMonoObls: Polymorphic bench not supported yet. In: " ++
              sdoc ex
        ParE0 ls -> do
          ls' <- mapM (collectMonoObls ddefs env2 toplevel) ls
          pure $ Ext $ ParE0 ls'
        PrintPacked ty arg -> do
          arg' <- collectMonoObls ddefs env2 toplevel arg
          pure $ Ext $ PrintPacked ty arg'
        CopyPacked ty arg -> do
          arg' <- collectMonoObls ddefs env2 toplevel arg
          pure $ Ext $ CopyPacked ty arg'
        TravPacked ty arg -> do
          arg' <- collectMonoObls ddefs env2 toplevel arg
          pure $ Ext $ TravPacked ty arg'
        L p e -> do
          e' <- go e
          pure $ Ext $ L p e'
        LinearExt {} ->
          error $
          "collectMonoObls: a linear types extension wasn't desugared: " ++
          sdoc ex
    SpawnE f [] args -> do
      args' <- mapM (collectMonoObls ddefs env2 toplevel) args
      pure $ SpawnE f [] args'
    SpawnE f tyapps args -> do
      args' <- mapM (collectMonoObls ddefs env2 toplevel) args
      tyapps' <- mapM (monoOblsTy ddefs) tyapps
      f' <- addFnObl f tyapps'
      pure $ SpawnE f' [] args'
    SyncE -> pure SyncE
    MapE {} -> error $ "collectMonoObls: TODO: " ++ sdoc ex
    FoldE {} -> error $ "collectMonoObls: TODO: " ++ sdoc ex
  where
    go = collectMonoObls ddefs env2 toplevel
    addFnObl :: Var -> [Ty0] -> MonoM Var
    addFnObl f tyapps = do
      mono_st <- get
      if f `S.member` toplevel
      then case (M.lookup (f,tyapps) (mono_funs_done mono_st), M.lookup (f,tyapps) (mono_funs_worklist mono_st)) of
             (Nothing, Nothing) -> do
               new_name <- lift $ gensym f
               state (\st -> ((), extendFuns (f,tyapps) new_name st))
               pure new_name
             (Just fn_name, _) -> pure fn_name
             (_, Just fn_name) -> pure fn_name

      -- Why (f,[])? See "Special case for lambda bindings passed in as function arguments".
      else case (M.lookup (f,[]) (mono_lams mono_st), M.lookup (f,tyapps) (mono_lams mono_st)) of
             (Nothing, Nothing) -> do
               new_name <- lift $ gensym f
               state (\st -> ((),extendLambdas (f,tyapps) new_name st))
               pure new_name
             (_,Just lam_name) -> pure lam_name
             (Just lam_name,_) -> pure lam_name


-- | Create monomorphic versions of lambdas bound in this expression.
-- This does not float out the lambda definitions.
monoLambdas :: Exp0 -> MonoM Exp0
-- Assummption: lambdas only appear as RHS in a let.
monoLambdas ex =
  case ex of
    LetE (v, [], vty, rhs@(Ext (LambdaE args lam_bod))) bod -> do
      mono_st <- get
      let lam_mono_st = getLambdaObls v mono_st
      if M.null lam_mono_st
      -- This lambda is not polymorphic, don't monomorphize.
        then do
          bod' <- go bod
          lam_bod' <- monoLambdas lam_bod
          pure $ LetE (v, [], vty, (Ext (LambdaE args lam_bod'))) bod'
        else do
          let new_lam_mono_st =
                (mono_lams mono_st) `M.difference`
                (M.fromList $
                 map (\(w, wtyapps) -> ((v, wtyapps), w)) (M.toList lam_mono_st))
              mono_st' = mono_st {mono_lams = new_lam_mono_st}
          put mono_st'
          bod' <- monoLambdas bod
          monomorphized <- monoLamBinds (M.toList lam_mono_st) (vty, rhs)
          pure $ foldl (\acc bind -> LetE bind acc) bod' monomorphized
    LetE (_, (_:_), _, _) _ ->
      error $ "monoLambdas: Let not monomorphized: " ++ sdoc ex
    -- Straightforward recursion
    VarE {} -> pure ex
    LitE {} -> pure ex
    CharE {} -> pure ex
    FloatE {} -> pure ex
    LitSymE {} -> pure ex
    AppE f tyapps args ->
      case tyapps of
        [] -> do
          args' <- mapM monoLambdas args
          pure $ AppE f [] args'
        _ ->
          error $
          "monoLambdas: Expression probably not processed by collectMonoObls: " ++
          sdoc ex
    PrimAppE pr args -> do
      args' <- mapM monoLambdas args
      pure $ PrimAppE pr args'
    LetE (v, [], ty, rhs) bod -> do
      rhs' <- go rhs
      bod' <- monoLambdas bod
      pure $ LetE (v, [], ty, rhs') bod'
    IfE a b c -> IfE <$> go a <*> go b <*> go c
    MkProdE ls -> MkProdE <$> mapM monoLambdas ls
    ProjE i a -> (ProjE i) <$> go a
    CaseE scrt brs -> do
      scrt' <- go scrt
      brs' <- mapM (\(a, b, c) -> (a, b, ) <$> go c) brs
      pure $ CaseE scrt' brs'
    DataConE tyapp dcon args -> (DataConE tyapp dcon) <$> mapM monoLambdas args
    TimeIt e ty b -> (\e' -> TimeIt e' ty b) <$> go e
    WithArenaE v e -> (\e' -> WithArenaE v e') <$> go e
    Ext (LambdaE {}) ->
      error $
      "monoLambdas: Encountered a LambdaE outside a let binding. In\n" ++
      sdoc ex
    Ext (PolyAppE {}) -> error $ "monoLambdas: TODO: " ++ sdoc ex
    Ext (FunRefE {}) -> pure ex
    Ext (BenchE {}) -> pure ex
    Ext (ParE0 ls) -> Ext <$> ParE0 <$> mapM monoLambdas ls
    Ext (PrintPacked ty arg) -> Ext <$> (PrintPacked ty) <$> monoLambdas arg
    Ext (CopyPacked ty arg) -> Ext <$> (CopyPacked ty) <$> monoLambdas arg
    Ext (TravPacked ty arg) -> Ext <$> (TravPacked ty) <$> monoLambdas arg
    Ext (L p e) -> Ext <$> (L p) <$> monoLambdas e
    Ext (LinearExt {}) ->
      error $
      "monoLambdas: a linear types extension wasn't desugared: " ++ sdoc ex
    SpawnE f tyapps args ->
      case tyapps of
        [] -> do
          args' <- mapM monoLambdas args
          pure $ SpawnE f [] args'
        _ ->
          error $
          "monoLambdas: Expression probably not processed by collectMonoObls: " ++
          sdoc ex
    SyncE -> pure SyncE
    MapE {} -> error $ "monoLambdas: TODO: " ++ sdoc ex
    FoldE {} -> error $ "monoLambdas: TODO: " ++ sdoc ex
  where
    go = monoLambdas
    monoLamBinds ::
         [(Var, [Ty0])] -> (Ty0, Exp0) -> MonoM [(Var, [Ty0], Ty0, Exp0)]
    monoLamBinds [] _ = pure []
    monoLamBinds ((w, tyapps):rst) (ty, ex1) = do
      let tyvars = tyVarsInTy ty
      assertSameLength ("In the expression: " ++ sdoc ex1) tyvars tyapps
      let mp = M.fromList $ zip tyvars tyapps
          ty' = substTyVar mp ty
          ex' = substTyVarExp mp ex1
      (++ [(w, [], ty', ex')]) <$> monoLamBinds rst (ty, ex1)


-- | Remove all polymorphic functions and datatypes from a program. 'monoLambdas'
-- already gets rid of polymorphic mono_lams.
purgePolyFuns :: Prog0 -> Prog0
purgePolyFuns p@Prog {fundefs} = p {fundefs = M.filter isMonoFun fundefs}

isMonoFun :: FunDef0 -> Bool
isMonoFun FunDef {funTy} = (tyVarsFromScheme funTy) == []

purgePolyDDefs :: Prog0 -> Prog0
purgePolyDDefs p@Prog {ddefs} = p {ddefs = M.filter isMonoDDef ddefs}
  where
    isMonoDDef DDef {tyArgs} = tyArgs == []


-- See Step (4) in the big note. Lot of code duplication :(
updateTyCons :: MonoState -> Prog0 -> Prog0
updateTyCons mono_st p@Prog {ddefs, fundefs, mainExp} =
  let fundefs' = M.map fixFunDef fundefs
      mainExp' =
        case mainExp of
          Nothing -> Nothing
          Just (e, ty) ->
            Just
              (updateTyConsExp ddefs mono_st e, updateTyConsTy ddefs mono_st ty)
   in p {fundefs = fundefs', mainExp = mainExp'}
  where
    fixFunDef :: FunDef0 -> FunDef0
    fixFunDef fn@FunDef {funTy, funBody} =
      let funTy' =
            ForAll
              (tyVarsFromScheme funTy)
              (updateTyConsTy ddefs mono_st (tyFromScheme funTy))
          funBody' = updateTyConsExp ddefs mono_st funBody
       in fn {funTy = funTy', funBody = funBody'}


-- |
updateTyConsExp :: DDefs0 -> MonoState -> Exp0 -> Exp0
updateTyConsExp ddefs mono_st ex =
  case ex of
    VarE {} -> ex
    LitE {} -> ex
    CharE {} -> ex
    FloatE {} -> ex
    LitSymE {} -> ex
    AppE f tyapps args -> AppE f tyapps (map go args)
    PrimAppE pr args -> PrimAppE pr (map go args)
    LetE (v, tyapps, ty, rhs) bod ->
      LetE (v, tyapps, updateTyConsTy ddefs mono_st ty, go rhs) (go bod)
    IfE a b c -> IfE (go a) (go b) (go c)
    MkProdE ls -> MkProdE (map go ls)
    ProjE i e -> ProjE i (go e)
    CaseE scrt brs ->
      CaseE
        (go scrt)
        (map
           (\(dcon, vtys, rhs) ->
              let (vars, tys) = unzip vtys
                  vtys' = zip vars $ map (updateTyConsTy ddefs mono_st) tys
               in (dcon, vtys', go rhs))
           brs)
    DataConE (ProdTy tyapps) dcon args ->
      let tyapps' = map (updateTyConsTy ddefs mono_st) tyapps
          tycon = getTyOfDataCon ddefs dcon
          dcon' =
            case M.lookup (tycon, tyapps') (mono_dcons mono_st) of
              Nothing     -> dcon
              Just suffix -> dcon ++ fromVar suffix
       in DataConE (ProdTy tyapps) dcon' (map go args)
    DataConE {} ->
      error $
      "updateTyConsExp: DataConE expected ProdTy tyapps, got: " ++ sdoc ex
    TimeIt e ty b -> TimeIt (go e) (updateTyConsTy ddefs mono_st ty) b
    WithArenaE v e -> WithArenaE v (go e)
    SpawnE fn tyapps args -> SpawnE fn tyapps (map go args)
    SyncE -> SyncE
    MapE {} -> error $ "updateTyConsExp: TODO: " ++ sdoc ex
    FoldE {} -> error $ "updateTyConsExp: TODO: " ++ sdoc ex
    Ext (LambdaE args bod) ->
      Ext
        (LambdaE
           (map (\(v, ty) -> (v, updateTyConsTy ddefs mono_st ty)) args)
           (go bod))
    Ext (PolyAppE a b) -> Ext (PolyAppE (go a) (go b))
    Ext (FunRefE {}) -> ex
    Ext (BenchE {}) -> ex
    Ext (ParE0 ls) -> Ext $ ParE0 $ map go ls
    Ext (PrintPacked ty arg) ->
      Ext $ PrintPacked (updateTyConsTy ddefs mono_st ty) (go arg)
    Ext (CopyPacked ty arg) ->
      Ext $ CopyPacked (updateTyConsTy ddefs mono_st ty) (go arg)
    Ext (TravPacked ty arg) ->
      Ext $ TravPacked (updateTyConsTy ddefs mono_st ty) (go arg)
    Ext (L p e) -> Ext $ L p (go e)
    Ext (LinearExt {}) ->
      error $
      "updateTyConsExp: a linear types extension wasn't desugared: " ++ sdoc ex
  where
    go = updateTyConsExp ddefs mono_st


-- | Update TyCons if an appropriate monomorphization obligation exists.
updateTyConsTy :: DDefs0 -> MonoState -> Ty0 -> Ty0
updateTyConsTy ddefs mono_st ty =
  case ty of
    CharTy -> ty
    IntTy -> ty
    FloatTy -> ty
    SymTy0 -> ty
    BoolTy -> ty
    TyVar {} -> ty
    MetaTv {} -> ty
    ProdTy tys -> ProdTy (map go tys)
    SymDictTy v t -> SymDictTy v (go t)
    PDictTy k v -> PDictTy (go k) (go v)
    ArrowTy as b -> ArrowTy (map go as) (go b)
    PackedTy t tys ->
      let tys' = map go tys
       in case M.lookup (t, tys') (mono_dcons mono_st) of
            Nothing     -> PackedTy t tys'
           -- Why [] ? The type arguments aren't required as the DDef is monomorphic.
            Just suffix -> PackedTy (t ++ fromVar suffix) []
    VectorTy t -> VectorTy (go t)
    ListTy t -> ListTy (go t)
    ArenaTy -> ty
    SymSetTy -> ty
    SymHashTy -> ty
    IntHashTy -> ty
  where
    go = updateTyConsTy ddefs mono_st

---------------------------------------------------------------------------
-- The specialization monad.
type SpecM a = StateT SpecState PassM a

type FunRef = Var

data SpecState = SpecState
  { sp_funs_worklist :: M.Map (Var, [FunRef]) Var
  , sp_funs_done :: M.Map (Var, [FunRef]) Var
  , sp_extra_args :: M.Map Var [(Var, Ty0)]
  , sp_fundefs   :: FunDefs0 }
  deriving (Show, Eq, Generic, Out)

{-|

Specialization, only lambdas for now. E.g.

    foo :: (a -> b) -> a -> b
    foo f1 a = f1 a

    ... foo top1 x ...

becomes

    foo f1 a = ...

    foo2 :: a -> b
    foo2 a = top1 a

    ... foo2 x ...

-}
specLambdas :: Prog0 -> PassM Prog0
specLambdas prg@Prog {ddefs, fundefs, mainExp} = do
  let spec_m = do
        let env2 = progToEnv prg
        mainExp' <-
          case mainExp of
            Nothing -> pure Nothing
            Just (e, ty) -> do
              e' <- specLambdasExp ddefs env2 e
              pure $ Just (e', ty)
        -- Same reason as Step (1.2) in monomorphization.
        let fo_funs = M.filter isFOFun fundefs
        mapM_
          (\fn@FunDef {funName, funArgs, funTy, funBody} -> do
             let venv = M.fromList (fragileZip funArgs (inTys funTy))
                 env2' = extendsVEnv venv env2
             funBody' <- specLambdasExp ddefs env2' funBody
             sp_state <- get
             let funs = sp_fundefs sp_state
                 fn' = fn {funBody = funBody'}
                 funs' = M.insert funName fn' funs
                 sp_state' = sp_state {sp_fundefs = funs'}
             put sp_state'
             pure ())
          (M.elems fo_funs)
        fixpoint
        pure mainExp'
  (mainExp', sp_state'') <- runStateT spec_m emptySpecState
  let fundefs' = purgeHO (sp_fundefs sp_state'')
      prg' = prg {mainExp = mainExp', fundefs = fundefs'}

-- Typecheck again.
  tcProg prg'
  where
    emptySpecState :: SpecState
    emptySpecState = SpecState M.empty M.empty M.empty fundefs
    -- Lower functions
    fixpoint :: SpecM ()
    fixpoint = do
      sp_state <- get
      if M.null (sp_funs_worklist sp_state)
      then pure ()
      else do
        let fns = sp_fundefs sp_state
            fn = fns # fn_name
            ((fn_name, refs), new_fn_name) = M.elemAt 0 (sp_funs_worklist sp_state)
        specLambdasFun ddefs new_fn_name refs fn
        state (\st -> ((), st { sp_funs_worklist = M.delete (fn_name, refs) (sp_funs_worklist st)
                              , sp_funs_done = M.insert (fn_name, refs) new_fn_name (sp_funs_done st) }))
        fixpoint

    purgeHO :: FunDefs0 -> FunDefs0
    purgeHO fns = M.filter isFOFun fns
    isFOFun :: FunDef0 -> Bool
    isFOFun FunDef {funTy} =
      let ForAll _ (ArrowTy arg_tys ret_ty) = funTy
       in all (null . arrowTysInTy) arg_tys && arrowTysInTy ret_ty == []

-- Get rid of all higher order functions.

-- Eliminate all functions passed in as arguments to this function.
specLambdasFun :: DDefs0 -> Var -> [FunRef] -> FunDef0 -> SpecM ()
specLambdasFun ddefs new_fn_name refs fn@FunDef {funArgs, funTy} = do
  sp_state <- get
  let funArgs' = map fst $ filter (isFunTy . snd) $ zip funArgs (inTys funTy)
      specs = fragileZip funArgs' refs
      funArgs'' =
        map fst $ filter (not . isFunTy . snd) $ zip funArgs (inTys funTy)
      fn' = fn {funName = new_fn_name, funBody = do_spec specs (funBody fn)}
  let venv = M.fromList (fragileZip funArgs'' (inTys funTy'))
      env2 = Env2 venv (initFunEnv (sp_fundefs sp_state))
  funBody' <- specLambdasExp ddefs env2 (funBody fn')
  sp_state' <- get
  let (funArgs''', funTy'') =
        case M.lookup new_fn_name (sp_extra_args sp_state') of
          Nothing -> (funArgs'', funTy')
          Just extra_args ->
            let ForAll tyvars1 (ArrowTy arg_tys1 ret_ty1) = funTy'
                (extra_vars, extra_tys) = unzip extra_args
             in ( funArgs'' ++ extra_vars
                , ForAll tyvars1 (ArrowTy (arg_tys1 ++ extra_tys) ret_ty1))
  let fn'' =
        fn'
          { funBody = funBody'
          , funArgs = funArgs'''

-- N.B. Only update the type after 'specExp' runs.
          , funTy = funTy''
          }
  state
    (\st -> ((), st {sp_fundefs = M.insert new_fn_name fn'' (sp_fundefs st)}))
  where
    ForAll tyvars (ArrowTy arg_tys ret_ty) = funTy

-- TODO: What if the function returns another function ? Not handled yet.
    -- First order type
    funTy' = ForAll tyvars (ArrowTy (filter (not . isFunTy) arg_tys) ret_ty)
    do_spec :: [(Var, Var)] -> Exp0 -> Exp0
    do_spec lams e = foldr (uncurry subst') e lams
    subst' old new ex = gRename (M.singleton old new) ex

-- lamda args
-- non-lambda args
specLambdasExp :: DDefs0 -> Env2 Ty0 -> Exp0 -> SpecM Exp0
specLambdasExp ddefs env2 ex =
  case ex of
    AppE f [] args -> do
      args' <- mapM go args
      let args'' = dropFunRefs f env2 args'
          refs = foldr collectFunRefs [] args'
      sp_state <- get
      case refs of
        [] ->
          case M.lookup f (sp_extra_args sp_state) of
            Nothing -> pure $ AppE f [] args''
            Just extra_args -> do
              let (vars, _) = unzip extra_args
                  args''' = args'' ++ map VarE vars
              pure $ AppE f [] args'''
        _ -> do
          let extra_args =
                foldr
                  (\fnref acc ->
                     case M.lookup fnref (sp_extra_args sp_state) of
                       Nothing    -> acc
                       Just extra -> extra ++ acc)
                  []
                  refs
          let (vars, _) = unzip extra_args
              args''' = args'' ++ (map VarE vars)
          case (M.lookup (f,refs) (sp_funs_done sp_state), M.lookup (f,refs) (sp_funs_worklist sp_state)) of
            (Nothing, Nothing) -> do
              f' <- lift $ gensym f
              let (ForAll _ (ArrowTy as _)) = lookupFEnv f env2
                  arrow_tys = concatMap arrowTysInTy as

-- Check that the # of refs we collected actually matches the #
              -- of functions 'f' expects.
              assertSameLength
                ("While lowering the expression " ++ sdoc ex)
                refs
                arrow_tys
              -- We have a new lowering obligation.
              let sp_extra_args' = case extra_args of
                                     [] -> sp_extra_args sp_state
                                     _  -> M.insert f' extra_args (sp_extra_args sp_state)
              let sp_state' = sp_state { sp_funs_worklist = M.insert (f,refs) f' (sp_funs_worklist sp_state)
                                       , sp_extra_args = sp_extra_args'
                                       }
              put sp_state'
              pure $ AppE f' [] args'''
            (Just f', _) -> pure $ AppE f' [] args'''
            (_, Just f') -> pure $ AppE f' [] args'''
    AppE _ (_:_) _ ->
      error $ "specLambdasExp: Call-site not monomorphized: " ++ sdoc ex
    -- Float out a lambda fun to the top-level.
    LetE (v, [], ty, (Ext (LambdaE args lam_bod))) bod -> do
      v' <- lift $ gensym v
      let bod' = gRename (M.singleton v v') bod
      sp_state <- get
      let arg_vars = map fst args
          captured_vars =
            gFreeVars lam_bod `S.difference` (S.fromList arg_vars) `S.difference`
            (M.keysSet (sp_fundefs sp_state))
      lam_bod' <-
        specLambdasExp ddefs (L1.extendsVEnv (M.fromList args) env2) lam_bod
      if not (S.null captured_vars)
      -- Pass captured values as extra arguments
        then do
          let ls = S.toList captured_vars
              tys =
                map
                  (\w ->
                     case M.lookup w (vEnv env2) of
                       Nothing  -> error $ "Unbound variable: " ++ pprender w
                       Just ty1 -> ty1)
                  ls
              fns = collectAllFuns lam_bod []
              extra_args =
                foldr
                  (\fnref acc ->
                     case M.lookup fnref (sp_extra_args sp_state) of
                       Nothing    -> acc
                       Just extra -> extra ++ acc)
                  []
                  fns
              extra_args1 = (zip ls tys) ++ extra_args
              (vars1, tys1) = unzip extra_args1
              ty' = addArgsToTy tys1 (ForAll [] ty)
              fn =
                FunDef
                  { funName = v'
                  , funArgs = arg_vars ++ vars1
                  , funTy = ty'
                  , funBody = lam_bod'
                  , funMeta =
                      FunMeta
                        { funRec = NotRec
                        , funInline = Inline
                        , funCanTriggerGC = False
                        , funOptLayout = NoLayoutOpt
                        , userConstraintsDataCon = Nothing
                        , dataConFieldTypeInfo = Nothing
                        }
                  }
              env2' = extendFEnv v' ty' env2
          state
            (\st ->
               ( ()
               , st
                   { sp_fundefs = M.insert v' fn (sp_fundefs st)
                   , sp_extra_args = M.insert v' extra_args1 (sp_extra_args st)
                   }))
          specLambdasExp ddefs env2' bod'
        else do
          let fns = collectAllFuns lam_bod []
          let extra_args =
                foldr
                  (\fnref acc ->
                     case M.lookup fnref (sp_extra_args sp_state) of
                       Nothing    -> acc
                       Just extra -> extra ++ acc)
                  []
                  fns
          let (vars, tys) = unzip extra_args
              ty' = addArgsToTy tys (ForAll [] ty)
          let fn =
                FunDef
                  { funName = v'
                  , funArgs = arg_vars ++ vars
                  , funTy = ty'
                  , funBody = lam_bod'
                  , funMeta =
                      FunMeta
                        { funRec = NotRec
                        , funInline = Inline
                        , funCanTriggerGC = False
                        , funOptLayout = NoLayoutOpt
                        , userConstraintsDataCon = Nothing
                        , dataConFieldTypeInfo = Nothing
                        }
                  }
              env2' = extendFEnv v' (ForAll [] ty) env2
          state
            (\st ->
               ( ()
               , st
                   { sp_fundefs = M.insert v' fn (sp_fundefs st)
                   , sp_extra_args = M.insert v' extra_args (sp_extra_args st)
                   }))
          specLambdasExp ddefs env2' bod'
    LetE (v, [], ty, rhs) bod -> do
      let _fn_refs = collectFunRefs rhs []
          env2' = (extendVEnv v ty env2)
      rhs' <- go rhs
      bod' <- specLambdasExp ddefs env2' bod
      pure $ LetE (v, [], ty, rhs') bod'
    LetE (_, (_:_), _, _) _ ->
      error $ "specExp: Binding not monomorphized: " ++ sdoc ex
    VarE {} -> pure ex
    LitE {} -> pure ex
    CharE {} -> pure ex
    FloatE {} -> pure ex
    LitSymE {} -> pure ex
    PrimAppE pr args -> do
      args' <- mapM go args
      pure $ PrimAppE pr args'
    IfE a b c -> IfE <$> go a <*> go b <*> go c
    MkProdE ls -> MkProdE <$> mapM go ls
    ProjE i a -> (ProjE i) <$> go a
    CaseE scrt brs -> do
      scrt' <- go scrt
      brs' <-
        mapM
          (\(dcon, vtys, rhs) -> do
             let env2' = extendsVEnv (M.fromList vtys) env2
             (dcon, vtys, ) <$> specLambdasExp ddefs env2' rhs)
          brs
      pure $ CaseE scrt' brs'
    DataConE tyapp dcon args -> (DataConE tyapp dcon) <$> mapM go args
    TimeIt e ty b -> do
      e' <- go e
      pure $ TimeIt e' ty b
    WithArenaE v e -> do
      e' <- specLambdasExp ddefs (extendVEnv v ArenaTy env2) e
      pure $ WithArenaE v e'
    SpawnE fn tyapps args -> do
      e' <- specLambdasExp ddefs env2 (AppE fn tyapps args)
      case e' of
        AppE fn' tyapps' args' -> pure $ SpawnE fn' tyapps' args'
        _                      -> error "specLambdasExp: SpawnE"
    SyncE -> pure SyncE
    MapE {} -> error $ "specLambdasExp: TODO: " ++ sdoc ex
    FoldE {} -> error $ "specLambdasExp: TODO: " ++ sdoc ex
    Ext ext ->
      case ext of
        LambdaE {} ->
          error $
          "specLambdasExp: Should reach a LambdaE. It should be floated out by the Let case." ++
          sdoc ex
        PolyAppE {} -> error $ "specLambdasExp: TODO: " ++ sdoc ex
        FunRefE {} -> pure ex
        BenchE {} -> pure ex
        ParE0 ls -> do
          let mk_fn ::
                   Exp0
                -> SpecM ( Maybe FunDef0
                         , [(Var, [Ty0], Ty0, (PreExp E0Ext Ty0 Ty0))]
                         , Exp0)
              mk_fn e0 = do
                let vars = S.toList $ gFreeVars e0
                args <- mapM (\v -> lift $ gensym v) vars
                let e0' =
                      foldr
                        (\(old, new) acc -> gSubst old (VarE new) acc)
                        e0
                        (zip vars args)
                -- let bind args = vars before call_a
                fnname <- lift $ gensym "fn"
                let binds =
                      map
                        (\(v, w, ty) -> (v, [], ty, VarE w))
                        (zip3 args vars argtys)
                    retty = recoverType ddefs env2 e0
                    argtys = map (\v -> lookupVEnv v env2) vars
                    fn =
                      FunDef
                        { funName = fnname
                        , funArgs = args
                        , funTy = ForAll [] (ArrowTy argtys retty)
                        , funBody = e0'
                        , funMeta =
                            FunMeta
                              { funRec = NotRec
                              , funInline = NoInline
                              , funCanTriggerGC = False
                              , funOptLayout = NoLayoutOpt
                              , userConstraintsDataCon = Nothing
                              , dataConFieldTypeInfo = Nothing
                              }
                        }
                pure (Just fn, binds, AppE fnname [] (map VarE args))
          let mb_insert mb_fn mp =
                case mb_fn of
                  Just fn -> M.insert (funName fn) fn mp
                  Nothing -> mp
          (mb_fns, binds, calls) <-
            unzip3 <$>
            mapM
              (\a ->
                 case a of
                   AppE {} -> pure (Nothing, [], a)
                   _       -> mk_fn a)
              ls
          state
            (\st ->
               ((), st {sp_fundefs = foldr mb_insert (sp_fundefs st) mb_fns}))
          pure $ mkLets (concat binds) (Ext $ ParE0 calls)
        PrintPacked ty arg -> Ext <$> (PrintPacked ty) <$> go arg
        CopyPacked ty arg -> Ext <$> (CopyPacked ty) <$> go arg
        TravPacked ty arg -> Ext <$> (TravPacked ty) <$> go arg
        LinearExt {} ->
          error $
          "specLambdasExp: a linear types extension wasn't desugared: " ++
          sdoc ex
        L p e -> Ext <$> (L p) <$> go e
  where
    go = specLambdasExp ddefs env2
    _isFunRef e =
      case e of
        VarE v -> M.member v (fEnv env2)
        _      -> False
    dropFunRefs :: Var -> Env2 Ty0 -> [Exp0] -> [Exp0]
    dropFunRefs fn_name env21 args =
      foldr
        (\(a, t) acc ->
           if isFunTy t
             then acc
             else a : acc)
        []
        (zip args arg_tys)
      where
        ForAll _ (ArrowTy arg_tys _) = lookupFEnv fn_name env21
    collectFunRefs :: Exp0 -> [FunRef] -> [FunRef]
    collectFunRefs e acc =
      case e of
        VarE {} -> acc
        LitE {} -> acc
        CharE {} -> acc
        FloatE {} -> acc
        LitSymE {} -> acc
        AppE _ _ args -> foldr collectFunRefs acc args
        PrimAppE _ args -> foldr collectFunRefs acc args
        LetE (_, _, _, rhs) bod -> foldr collectFunRefs acc [bod, rhs]
        IfE a b c -> foldr collectFunRefs acc [c, b, a]
        MkProdE ls -> foldr collectFunRefs acc ls
        ProjE _ a -> collectFunRefs a acc
        DataConE _ _ ls -> foldr collectFunRefs acc ls
        TimeIt a _ _ -> collectFunRefs a acc
        WithArenaE _ e1 -> collectFunRefs e1 acc
        CaseE scrt brs ->
          foldr
            (\(_, _, b) acc2 -> collectFunRefs b acc2)
            (collectFunRefs scrt acc)
            brs
        SpawnE _ _ args -> foldr collectFunRefs acc args
        SyncE -> acc
        MapE {} -> error $ "collectFunRefs: TODO: " ++ sdoc e
        FoldE {} -> error $ "collectFunRefs: TODO: " ++ sdoc e
        Ext ext ->
          case ext of
            LambdaE _ bod -> collectFunRefs bod acc
            PolyAppE rator rand ->
              collectFunRefs rand (collectFunRefs rator acc)
            FunRefE _ f -> f : acc
            BenchE {} -> acc
            ParE0 ls -> foldr collectFunRefs acc ls
            PrintPacked _ty arg -> collectFunRefs arg acc
            CopyPacked _ty arg -> collectFunRefs arg acc
            TravPacked _ty arg -> collectFunRefs arg acc
            L _ e1 -> collectFunRefs e1 acc
            LinearExt {} ->
              error $
              "collectFunRefs: a linear types extension wasn't desugared: " ++
              sdoc ex

-- Returns all functions used in an expression, both in AppE's and FunRefE's.
    collectAllFuns :: Exp0 -> [FunRef] -> [FunRef]
    collectAllFuns e acc =
      case e of
        VarE {} -> acc
        LitE {} -> acc
        CharE {} -> acc
        FloatE {} -> acc
        LitSymE {} -> acc
        AppE f _ args -> f : foldr collectAllFuns acc args
        PrimAppE _ args -> foldr collectAllFuns acc args
        LetE (_, _, _, rhs) bod -> foldr collectAllFuns acc [bod, rhs]
        IfE a b c -> foldr collectAllFuns acc [c, b, a]
        MkProdE ls -> foldr collectAllFuns acc ls
        ProjE _ a -> collectAllFuns a acc
        DataConE _ _ ls -> foldr collectAllFuns acc ls
        TimeIt a _ _ -> collectAllFuns a acc
        WithArenaE _ e1 -> collectAllFuns e1 acc
        CaseE scrt brs ->
          foldr
            (\(_, _, b) acc2 -> collectAllFuns b acc2)
            (collectAllFuns scrt acc)
            brs
        SpawnE _ _ args -> foldr collectAllFuns acc args
        SyncE -> acc
        MapE {} -> error $ "collectAllFuns: TODO: " ++ sdoc e
        FoldE {} -> error $ "collectAllFuns: TODO: " ++ sdoc e
        Ext ext ->
          case ext of
            LambdaE _ bod -> collectAllFuns bod acc
            PolyAppE rator rand ->
              collectAllFuns rand (collectAllFuns rator acc)
            FunRefE _ f -> f : acc
            BenchE {} -> acc
            ParE0 ls -> foldr collectAllFuns acc ls
            PrintPacked _ty arg -> collectAllFuns arg acc
            CopyPacked _ty arg -> collectAllFuns arg acc
            TravPacked _ty arg -> collectAllFuns arg acc
            L _ e1 -> collectAllFuns e1 acc
            LinearExt {} ->
              error $
              "collectAllFuns: a linear types extension wasn't desugared: " ++
              sdoc ex

-- TODO, docs.

-- Straightforward recursion
-- fn_0 (fn_1, thing, fn_2) => fn_0 (thing)
addArgsToTy :: [Ty0] -> TyScheme -> TyScheme
addArgsToTy ls (ForAll tyvars (ArrowTy in_tys ret_ty)) =
  let in_tys' = in_tys ++ ls
   in ForAll tyvars (ArrowTy in_tys' ret_ty)
addArgsToTy _ oth = error $ "addArgsToTy: " ++ sdoc oth ++ " is not ArrowTy."

{-|

Let bind all anonymous lambdas.

    map (\x -> x + 1) [1,2,3]

becomes

   let lam_1 = (\x -> x + 1)
   in map lam_1 [1,2,3]

This is an intermediate step before the specializer turns the let bound
lambdas into top-level functions.

-}
bindLambdas :: Prog0 -> PassM Prog0
bindLambdas prg@Prog {fundefs, mainExp} = do
  mainExp' <-
    case mainExp of
      Nothing      -> pure Nothing
      Just (a, ty) -> Just <$> (, ty) <$> goExp a
  fundefs' <-
    mapM
      (\fn@FunDef {funBody} -> goExp funBody >>= \b' -> pure $ fn {funBody = b'})
      fundefs
  pure $ prg {fundefs = fundefs', mainExp = mainExp'}
  where
    goExp :: Exp0 -> PassM Exp0
    goExp ex0 = gocap ex0
      where
        gocap ex = do
          (lets, ex') <- go ex
          pure $ mkLets lets ex'
        go :: Exp0 -> PassM ([(Var, [Ty0], Ty0, Exp0)], Exp0)
        go e0 =
          case e0 of
            (Ext (LambdaE {})) -> do
              v <- gensym "lam"
              ty <- newMetaTy
              pure ([(v, [], ty, e0)], VarE v)
            (LetE (v, tyapps, t, rhs@(Ext LambdaE {})) bod) -> do
              (lts2, bod') <- go bod
              pure (lts2, LetE (v, tyapps, t, rhs) bod')
            (Ext (ParE0 ls)) -> do
              ls' <- mapM gocap ls
              pure ([], Ext $ ParE0 ls')
            (Ext PolyAppE {}) -> pure ([], e0)
            (Ext FunRefE {}) -> pure ([], e0)
            (Ext BenchE {}) -> pure ([], e0)
            (Ext (PrintPacked ty arg)) -> do
              (lts, arg') <- go arg
              pure (lts, Ext (PrintPacked ty arg'))
            (Ext (CopyPacked ty arg)) -> do
              (lts, arg') <- go arg
              pure (lts, Ext (CopyPacked ty arg'))
            (Ext (TravPacked ty arg)) -> do
              (lts, arg') <- go arg
              pure (lts, Ext (TravPacked ty arg'))
            (Ext (L p e1)) -> do
              (ls, e1') <- go e1
              pure (ls, Ext $ L p e1')
            (Ext (LinearExt {})) ->
              error $
              "bindLambdas: a linear types extension wasn't desugared: " ++
              sdoc e0
            (LitE _) -> pure ([], e0)
            (CharE _) -> pure ([], e0)
            (FloatE {}) -> pure ([], e0)
            (LitSymE _) -> pure ([], e0)
            (VarE _) -> pure ([], e0)
            (PrimAppE {}) -> pure ([], e0)
            (AppE f tyapps args) -> do
              (ltss, args') <- unzip <$> mapM go args
              pure (concat ltss, AppE f tyapps args')
            (MapE _ _) -> error "bindLambdas: FINISHME MapE"
            (FoldE _ _ _) -> error "bindLambdas: FINISHME FoldE"
            (LetE (v, tyapps, t, rhs) bod) -> do
              (lts1, rhs') <- go rhs
              bod' <- gocap bod
              pure (lts1, LetE (v, tyapps, t, rhs') bod')
            (IfE e1 e2 e3) -> do
              (lts1, e1') <- go e1
              e2' <- gocap e2
              e3' <- gocap e3
              pure (lts1, IfE e1' e2' e3')
            (ProjE i e) -> do
              (lts, e') <- go e
              pure (lts, ProjE i e')
            (MkProdE es) -> do
              (ltss, es') <- unzip <$> mapM go es
              pure (concat ltss, MkProdE es')
            (CaseE scrt ls) -> do
              (lts, scrt') <- go scrt
              ls' <- mapM (\(a, b, c) -> (a, b, ) <$> gocap c) ls
              pure (lts, CaseE scrt' ls')
            (DataConE c loc es) -> do
              (ltss, es') <- unzip <$> mapM go es
              pure (concat ltss, DataConE c loc es')
            (SpawnE f tyapps args) -> do
              (ltss, args') <- unzip <$> mapM go args
              pure (concat ltss, SpawnE f tyapps args')
            (SyncE) -> pure ([], SyncE)
            (WithArenaE v e) -> do
              e' <- (gocap e)
              pure ([], WithArenaE v e')
            (TimeIt e t b) -> do
              (lts, e') <- go e
              pure (lts, TimeIt e' t b)


-- boilerplate
---
-----------------------------------------------------------------------------
-- | Desugar parallel tuples to spawn's and sync's, and printPacked into function calls.
desugarL0 :: Prog0 -> PassM Prog0
desugarL0 (Prog ddefs fundefs' mainExp') = do
  let ddefs'' = M.map desugar_tuples ddefs
  fundefs'' <-
    mapM
      (\fn@FunDef {funBody} -> go funBody >>= \b -> pure $ fn {funBody = b})
      fundefs'
  mainExp'' <-
    case mainExp' of
      Nothing      -> pure Nothing
      Just (e, ty) -> Just <$> (, ty) <$> go e
  addRepairFns $ Prog ddefs'' fundefs'' mainExp''
  where
    err1 msg = error $ "desugarL0: " ++ msg
    desugar_tuples :: DDef0 -> DDef0
    desugar_tuples d@DDef {dataCons} =
      let dataCons' = map (second (concatMap goty)) dataCons
       in d {dataCons = dataCons'}
      where
        goty :: (t, Ty0) -> [(t, Ty0)]
        goty (isBoxed, ty) =
          case ty of
            ProdTy ls -> concatMap (goty . (isBoxed, )) ls
            _         -> [(isBoxed, ty)]
    go :: Exp0 -> PassM Exp0
    go ex =
      case ex of
        VarE {} -> pure ex
        LitE {} -> pure ex
        CharE {} -> pure ex
        FloatE {} -> pure ex
        LitSymE {} -> pure ex
        AppE f tyapps args -> AppE f tyapps <$> mapM go args
        PrimAppE pr args

-- This is always going to have a function reference which
          -- we cannot eliminate.
         -> do
          let args' =
                case pr of
                  VSortP {} ->
                    case args of
                      [ls, Ext (FunRefE _ fp)] -> [ls, VarE fp]
                      [ls, Ext (L _ (Ext (FunRefE _ fp)))] -> [ls, VarE fp]
                      _ -> error $ "desugarL0: vsort" ++ sdoc ex
                  InplaceVSortP {} ->
                    case args of
                      [ls, Ext (FunRefE _ fp)] -> [ls, VarE fp]
                      [ls, Ext (L _ (Ext (FunRefE _ fp)))] -> [ls, VarE fp]
                      _ -> error $ "desugarL0: vsort" ++ sdoc ex
                  _ -> args
          args'' <- mapM go args'
          pure $ PrimAppE pr args''
        LetE (v, _tyapps, (ProdTy tys), (Ext (ParE0 ls))) bod -> do
          vs <- mapM (\_ -> gensym "par_") ls
          let xs = (zip3 vs tys ls)
              spawns = init xs
              (a, b, c) = last xs
              ls' =
                foldr
                  (\(w, ty1, (AppE fn tyapps1 args)) acc ->
                     (w, [], ty1, (SpawnE fn tyapps1 args)) : acc)
                  []
                  spawns
              ls'' = ls' ++ [(a, [], b, c)]
          ls''' <- mapM (\(w, x, y, z) -> (w, x, y, ) <$> go z) ls''
          let binds = ls''' ++ [("_", [], ProdTy [], SyncE)]
              bod' =
                foldr
                  (\((x, _, _, _), i) acc ->
                     gSubstE (ProjE i (VarE v)) (VarE x) acc)
                  bod
                  (zip ls''' [0 ..])
          bod'' <- go bod'
          pure $ mkLets binds bod''
        LetE (v, tyapps, ty, rhs) bod ->
          LetE <$> (v, tyapps, ty, ) <$> go rhs <*> go bod
        IfE a b c -> IfE <$> go a <*> go b <*> go c
        MkProdE ls -> MkProdE <$> mapM go ls
        ProjE i a -> (ProjE i) <$> go a
        CaseE scrt brs -> do
          scrt' <- go scrt
          brs' <-
            mapM
              (\(dcon, vtys, bod) -> do
                 let (xs, _tyapps) = unzip vtys
                 bod' <- go bod
                 let dcon_tys = lookupDataCon ddefs dcon
                     flattenTupleArgs ::
                          (Var, Ty0) -> ([Var], Exp0) -> PassM ([Var], Exp0)
                     flattenTupleArgs (v, vty) (vs0, bod0) =
                       case vty of
                         ProdTy ls
                                    -- create projection variables: v = (y1, y2, ...)
                          -> do
                           ys <- mapM (\_ -> gensym "y") ls
                                    -- substitute projections in body with new variable: yi = ProjE i v
                           let bod1 =
                                 foldr
                                   (\(i, y) bod1' ->
                                      gSubstE (ProjE i (VarE v)) (VarE y) bod1')
                                   bod0
                                   (zip [0 ..] ys)
                                    -- substitute whole variable v with product: v = MkProdE (y1, y2, ...)
                           let bod2 =
                                 gSubstE (VarE v) (MkProdE (map VarE ys)) bod1
                                    -- flatten each of yis
                           (ys', bod3) <-
                             foldrM flattenTupleArgs (vs0, bod2) (zip ys ls)
                           pure (ys', bod3)
                         _ -> pure (v : vs0, bod0)
                 (xs', bod'') <-
                   foldrM flattenTupleArgs ([], bod') (zip xs dcon_tys)
                 let vtys' = zip xs' (repeat (ProdTy []))
                 pure (dcon, vtys', bod''))
              brs
          pure $ CaseE scrt' brs'
        DataConE a dcon ls -> do
          ls' <- mapM go ls
          let tys = lookupDataCon ddefs dcon
              flattenTupleArgs :: Exp0 -> Ty0 -> PassM ([(Var, [loc], Ty0, Exp0)] ,[Exp0])
              flattenTupleArgs arg ty = case ty of
                ProdTy tys' ->
                  case arg of
                    MkProdE args -> do
                      (bnds', args') <- unzip <$> zipWithM flattenTupleArgs args tys'
                      pure (concat bnds',concat args')
                    _ -> do
                        -- generating alias so that repeated expression is
                        -- eliminated and we are taking projection of trivial varEs
                        argalias <- gensym "alias"
                        ys <- mapM (\_ -> gensym "proj") tys'
                        let vs = map VarE ys
                        (bnds', args') <-
                          unzip <$> zipWithM flattenTupleArgs vs tys'
                        let bnds'' =
                              (argalias, [], ty, arg) :
                              [ (y, [], ty', ProjE i (VarE argalias))
                              | (y, ty', i) <- zip3 ys tys' [0 ..]
                              ]
                        pure (bnds'' ++ concat bnds', concat args')
                _ -> do
                  pure ([], [arg])
          (binds, args) <- unzip <$> zipWithM flattenTupleArgs ls' tys
          pure $ mkLets (concat binds) $ DataConE a dcon (concat args)
        TimeIt e ty b -> (\a -> TimeIt a ty b) <$> go e
        WithArenaE v e -> (WithArenaE v) <$> go e
        SpawnE fn tyapps args -> (SpawnE fn tyapps) <$> mapM go args
        SyncE -> pure SyncE
        MapE {} -> err1 (sdoc ex)
        FoldE {} -> err1 (sdoc ex)
        Ext ext ->
          case ext of
            LambdaE {} -> err1 (sdoc ex)
            PolyAppE {} -> err1 (sdoc ex)
            FunRefE {} -> err1 (sdoc ex)
            BenchE fn _tyapps args b ->
              (\a -> Ext $ BenchE fn [] a b) <$> mapM go args
            ParE0 ls -> err1 ("unbound ParE0" ++ sdoc ls)
            PrintPacked ty arg
              | (PackedTy tycon _) <- ty -> do
                let f = mkPrinterName tycon
                pure $ AppE f [] [arg]
              | otherwise ->
                err1 $ "printPacked without a packed type. Got " ++ sdoc ty
            CopyPacked ty arg
              | (PackedTy tycon _) <- ty -> do
                let f = mkCopyFunName tycon
                pure $ AppE f [] [arg]
              | otherwise ->
                err1 $ "printPacked without a packed type. Got " ++ sdoc ty
            TravPacked ty arg
              | (PackedTy tycon _) <- ty -> do
                let f = mkTravFunName tycon
                pure $ AppE f [] [arg]
              | otherwise ->
                err1 $ "printPacked without a packed type. Got " ++ sdoc ty
            L p e -> Ext <$> (L p) <$> (go e)
            LinearExt {} -> err1 (sdoc ex)

-- (Prog ddefs' fundefs' mainExp') <- addRepairFns prg

--
------------------------------------------------------------------------------
-- | Add copy & traversal functions for each data type in a prog
addRepairFns :: Prog0 -> PassM Prog0
addRepairFns (Prog dfs fds me) = do
  newFns <-
    concat <$>
    mapM
      (\d -> do
         copy_fn <- genCopyFn d
         copy2_fn <- genCopySansPtrsFn d
         trav_fn <- genTravFn d
         print_fn <- genPrintFn d
         return [copy_fn, copy2_fn, trav_fn, print_fn])
      (filter (not . isVoidDDef) (M.elems dfs))
  let fds' = fds `M.union` (M.fromList $ map (\f -> (funName f, f)) newFns)
  pure $ Prog dfs fds' me


-- | Generate a copy function for a particular data definition.

-- Note: there will be redundant let bindings in the function body which may need to be inlined.
genCopyFn :: DDef0 -> PassM FunDef0
genCopyFn DDef {tyName, dataCons} = do
  arg <- gensym $ "arg"
  casebod <-
    forM dataCons $ \(dcon, dtys) -> do
      let tys = map snd dtys
      xs <- mapM (\_ -> gensym "x") tys
      ys <- mapM (\_ -> gensym "y") tys
                -- let packed_vars = map fst $ filter (\(x,ty) -> isPackedTy ty) (zip ys tys)
      let bod =
            foldr
              (\(ty, x, y) acc ->
                 case ty of
                   PackedTy tycon _ ->
                     LetE
                       (y, [], ty, AppE (mkCopyFunName tycon) [] [VarE x])
                       acc
                   _ -> LetE (y, [], ty, VarE x) acc)
              (DataConE (ProdTy []) dcon $ map VarE ys)
              (zip3 tys xs ys)
      return (dcon, map (\x -> (x, (ProdTy []))) xs, bod)
  return $
    FunDef
      { funName = mkCopyFunName (fromVar tyName)
      , funArgs = [arg]
      , funTy =
          (ForAll
             []
             (ArrowTy
                [PackedTy (fromVar tyName) []]
                (PackedTy (fromVar tyName) [])))
      , funBody = CaseE (VarE arg) casebod
      , funMeta =
          FunMeta
            { funRec = Rec
            , funInline = NoInline
            , funCanTriggerGC = False
            , funOptLayout = NoLayoutOpt
            , userConstraintsDataCon = Nothing
            , dataConFieldTypeInfo = Nothing
            }
      }

genCopySansPtrsFn :: DDef0 -> PassM FunDef0
genCopySansPtrsFn DDef {tyName, dataCons} = do
  arg <- gensym $ "arg"
  casebod <-
    forM dataCons $ \(dcon, dtys) -> do
      let tys = map snd dtys
      xs <- mapM (\_ -> gensym "x") tys
      ys <- mapM (\_ -> gensym "y") tys
                -- let packed_vars = map fst $ filter (\(x,ty) -> isPackedTy ty) (zip ys tys)
      let bod =
            foldr
              (\(ty, x, y) acc ->
                 case ty of
                   PackedTy tycon _ ->
                     LetE
                       ( y
                       , []
                       , ty
                       , AppE (mkCopySansPtrsFunName tycon) [] [VarE x])
                       acc
                   _ -> LetE (y, [], ty, VarE x) acc)
              (DataConE (ProdTy []) dcon $ map VarE ys)
              (zip3 tys xs ys)
      return (dcon, map (\x -> (x, (ProdTy []))) xs, bod)
  return $
    FunDef
      { funName = mkCopySansPtrsFunName (fromVar tyName)
      , funArgs = [arg]
      , funTy =
          (ForAll
             []
             (ArrowTy
                [PackedTy (fromVar tyName) []]
                (PackedTy (fromVar tyName) [])))
      , funBody = CaseE (VarE arg) casebod
      , funMeta =
          FunMeta
            { funRec = Rec
            , funInline = NoInline
            , funCanTriggerGC = False
            , funOptLayout = NoLayoutOpt
            , userConstraintsDataCon = Nothing
            , dataConFieldTypeInfo = Nothing
            }
      }


-- | Traverses a packed data type.
genTravFn :: DDef0 -> PassM FunDef0
genTravFn DDef {tyName, dataCons} = do
  arg <- gensym $ "arg"
  casebod <-
    forM dataCons $ \(dcon, tys) -> do
      xs <- mapM (\_ -> gensym "x") tys
      ys <- mapM (\_ -> gensym "y") tys
      let bod =
            foldr
              (\(ty, x, y) acc ->
                 case ty of
                   PackedTy tycon _ ->
                     LetE
                       ( y
                       , []
                       , ProdTy []
                       , AppE (mkTravFunName tycon) [] [VarE x])
                       acc
                   _ -> acc)
              (MkProdE [])
              (zip3 (map snd tys) xs ys)
      return (dcon, map (\x -> (x, ProdTy [])) xs, bod)
  return $
    FunDef
      { funName = mkTravFunName (fromVar tyName)
      , funArgs = [arg]
      , funTy = (ForAll [] (ArrowTy [PackedTy (fromVar tyName) []] (ProdTy [])))
      , funBody = CaseE (VarE arg) casebod
      , funMeta =
          FunMeta
            { funRec = Rec
            , funInline = NoInline
            , funCanTriggerGC = False
            , funOptLayout = NoLayoutOpt
            , userConstraintsDataCon = Nothing
            , dataConFieldTypeInfo = Nothing
            }
      }


-- | Print a packed datatype.
genPrintFn :: DDef0 -> PassM FunDef0
genPrintFn DDef {tyName, dataCons} = do
  arg <- gensym "arg"
  casebod <-
    forM dataCons $ \(dcon, tys) -> do
      xs <- mapM (\_ -> gensym "x") tys
      ys <- mapM (\_ -> gensym "y") tys
      let bnds =
            foldr
              (\(ty, x, y) acc ->
                 case ty of
                   IntTy -> (y, [], ProdTy [], PrimAppE PrintInt [VarE x]) : acc
                   FloatTy ->
                     (y, [], ProdTy [], PrimAppE PrintFloat [VarE x]) : acc
                   SymTy0 ->
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
              (zip3 (map snd tys) xs ys)
      w1 <- gensym "wildcard"
      w2 <- gensym "wildcard"
      let add_spaces ::
               [(Var, [Ty0], Ty0, PreExp E0Ext Ty0 Ty0)]
            -> PassM [(Var, [Ty0], Ty0, PreExp E0Ext Ty0 Ty0)]
          add_spaces [] = pure []
          add_spaces [z] = pure [z]
          add_spaces (z:zs) = do
            zs' <- add_spaces zs
            wi <- gensym "wildcard"
            pure $
              z :
              (wi, [], ProdTy [], PrimAppE PrintSym [(LitSymE (toVar " "))]) :
              zs'
      bnds'' <-
        add_spaces $
        [ ( w1
          , []
          , ProdTy []
          , PrimAppE PrintSym [(LitSymE (toVar ("(" ++ dcon)))])
        ] ++
        bnds
      let bnds' =
            bnds'' ++
            [(w2, [], ProdTy [], PrimAppE PrintSym [(LitSymE (toVar ")"))])]
          bod = mkLets bnds' (MkProdE [])
      return (dcon, map (\x -> (x, ProdTy [])) xs, bod)
  return $
    FunDef
      { funName = mkPrinterName (fromVar tyName)
      , funArgs = [arg]
      , funTy = (ForAll [] (ArrowTy [PackedTy (fromVar tyName) []] (ProdTy [])))
      , funBody = CaseE (VarE arg) casebod
      , funMeta =
          FunMeta
            { funRec = Rec
            , funInline = NoInline
            , funCanTriggerGC = False
            , funOptLayout = NoLayoutOpt
            , userConstraintsDataCon = Nothing
            , dataConFieldTypeInfo = Nothing
            }
      }

-------------------------------------------------------------------------------

type FloatState = FunDefs0

type FloatM a = StateT FloatState PassM a

floatOutCase :: Prog0 -> PassM Prog0
floatOutCase (Prog ddefs fundefs mainExp) = do
  let float_m = do
        mapM_
          (\fn@FunDef {funName, funArgs, funTy, funBody} -> do
             fstate <- get
             let venv = M.fromList (fragileZip funArgs (inTys funTy))
             let env2 = Env2 venv (initFunEnv fstate)
             funBody' <- go False env2 funBody
             let fn' = fn {funBody = funBody'}
             state (\s -> ((), M.insert funName fn' s)))
          (M.elems fundefs)
        float_main <-
          do fstate <- get
             let env2 = Env2 M.empty (initFunEnv fstate)
             case mainExp of
               Nothing      -> pure Nothing
               Just (e, ty) -> Just <$> (, ty) <$> go True env2 e
        pure float_main
  (mainExp', state') <- runStateT float_m fundefs
  pure $ (Prog ddefs state' mainExp')
  where
    err1 msg = error $ "floatOutCase: " ++ msg
    float_fn :: Env2 Ty0 -> Exp0 -> FloatM Exp0
    float_fn env2 ex = do
      fundefs' <- get
      let fenv' = M.map funTy fundefs'
          env2' = env2 {fEnv = fenv'}
          free = S.toList $ gFreeVars ex `S.difference` (M.keysSet fundefs')
          in_tys = map (\x -> lookupVEnv x env2') free
          ret_ty = recoverType ddefs env2' ex
          fn_ty = ForAll [] (ArrowTy in_tys ret_ty)
      fn_name <- lift $ gensym "caseFn"
      args <- mapM (\x -> lift $ gensym x) free
      let ex' =
            foldr
              (\(from, to) acc -> gSubst from (VarE to) acc)
              ex
              (zip free args)
      let fn =
            FunDef
              fn_name
              args
              fn_ty
              ex'
              (FunMeta NotRec NoInline False NoLayoutOpt Nothing Nothing)
      state (\s -> ((AppE fn_name [] (map VarE free)), M.insert fn_name fn s))
    go :: Bool -> Env2 Ty0 -> Exp0 -> FloatM Exp0
    go float env2 ex =
      case ex of
        VarE {} -> pure ex
        LitE {} -> pure ex
        CharE {} -> pure ex
        FloatE {} -> pure ex
        LitSymE {} -> pure ex
        AppE f tyapps args -> AppE f tyapps <$> mapM recur args
        PrimAppE pr args -> do
          args' <- mapM recur args
          pure $ PrimAppE pr args'
        LetE (v, tyapps, ty, rhs) bod -> do
          rhs' <- go True env2 rhs
          let env2' = extendVEnv v ty env2
          bod' <- go True env2' bod
          pure $ LetE (v, tyapps, ty, rhs') bod'
        IfE a b c ->
          IfE <$> go True env2 a <*> go True env2 b <*> go True env2 c
        MkProdE ls -> MkProdE <$> mapM recur ls
        ProjE i a -> (ProjE i) <$> recur a
        CaseE scrt brs -> do
          scrt' <- go float env2 scrt
          brs' <-
            mapM
              (\(dcon, vtys, rhs) -> do
                 let vars = map fst vtys
                 let tys = lookupDataCon ddefs dcon
                 let env2' = extendsVEnv (M.fromList (zip vars tys)) env2
                 rhs' <- go True env2' rhs
                 pure (dcon, vtys, rhs'))
              brs
          if float
            then float_fn env2 (CaseE scrt' brs')
            else pure $ CaseE scrt' brs'
        DataConE a dcon ls -> DataConE a dcon <$> mapM recur ls
        TimeIt e ty b -> (\a -> TimeIt a ty b) <$> recur e
        WithArenaE v e -> (WithArenaE v) <$> recur e
        SpawnE fn tyapps args -> (SpawnE fn tyapps) <$> mapM recur args
        SyncE -> pure SyncE
        Ext {} -> pure ex
        MapE {} -> err1 (sdoc ex)
        FoldE {} -> err1 (sdoc ex)
      where
        recur = go float env2
