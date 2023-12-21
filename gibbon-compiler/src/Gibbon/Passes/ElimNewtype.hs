module Gibbon.Passes.ElimNewtype where

import Gibbon.L1.Syntax
import Gibbon.Common

import Control.Arrow
import qualified Data.Map as M
import qualified Data.Set as S
import Data.Symbol (unintern)

passProgram :: Prog1 -> Prog1
passProgram prog = 
  Prog 
    { mainExp= (elimE connames tynames *** elimTy tynames) <$> mainExp prog
    , fundefs= fdefs
    , ddefs = tys
    }
  where
    (newtys, tys) = M.partition (\x -> case dataCons x of
        [(_, [_])] -> True
        _ -> False
      ) (ddefs prog)
    tynames = S.fromList $ (\(Var x) -> unintern x) <$> M.keys newtys
    connames = S.fromList $ fst . head . dataCons <$> M.elems newtys
    fdefs = M.map (\d -> d {funTy=elimTyArrow tynames (funTy d)}) (fundefs prog)

elimE :: S.Set String -> S.Set String -> Exp1 -> Exp1
elimE cns tns e0 = case e0 of
  DataConE _ty0 s [e]
    | S.member s cns -> f e
  DataConE _ty0 s es -> DataConE _ty0 s (f <$> es)
  VarE _ -> e0
  LitE _ -> e0
  CharE _ -> e0
  FloatE _ -> e0
  LitSymE _ -> e0
  AppE var ty es -> AppE var ty (f <$> es)
  PrimAppE p es -> PrimAppE (elimPrim tns p) (f <$> es)
  LetE (var, u, t, e1) e2 -> LetE (var, u, g t, f e1) (f e2)
  IfE e1 e2 e3 -> IfE (f e1) (f e2) (f e3)
  MkProdE es -> MkProdE (f <$> es)
  ProjE n e -> ProjE n (f e)
  -- replacing with a let  would be ideal, 
  -- but lets require types that are not kept
  -- CaseE e1 [(s, [(var, _)], e2)]
    -- | S.member s cns -> _
  -- CaseE e x -> CaseE (f e) _
  _ -> _
  where
    f = elimE cns tns
    g = elimTy tns

elimPrim :: S.Set String -> Prim Ty1 -> Prim Ty1
elimPrim tns p0 = case p0 of
  ErrorP s t -> ErrorP s (f t)
  DictInsertP t -> DictInsertP (f t)
  DictLookupP t -> DictLookupP (f t)
  DictEmptyP t -> DictEmptyP (f t)
  DictHasKeyP t -> DictHasKeyP (f t)
  PDictAllocP t1 t2 -> PDictAllocP (f t1) (f t2)
  PDictInsertP t1 t2 -> PDictInsertP (f t1) (f t2)
  PDictLookupP t1 t2 -> PDictLookupP (f t1) (f t2)
  PDictHasKeyP t1 t2 -> PDictHasKeyP (f t1) (f t2)
  PDictForkP t1 t2 -> PDictForkP (f t1) (f t2)
  PDictJoinP t1 t2 -> PDictJoinP (f t1) (f t2)
  LLAllocP t -> LLAllocP (f t)
  LLIsEmptyP t -> LLIsEmptyP (f t)
  LLConsP t -> LLConsP (f t)
  LLHeadP t -> LLHeadP (f t)
  LLTailP t -> LLTailP (f t)
  LLFreeP t -> LLFreeP (f t)
  LLCopyP t -> LLCopyP (f t)
  VAllocP t -> VAllocP (f t)
  VFreeP t -> VFreeP (f t)
  VFree2P t -> VFree2P (f t)
  VLengthP t -> VLengthP (f t)
  VNthP t -> VNthP (f t)
  VSliceP t -> VSliceP (f t)
  InplaceVUpdateP t -> InplaceVUpdateP (f t)
  VConcatP t -> VConcatP (f t)
  VSortP t -> VSortP (f t)
  InplaceVSortP t -> InplaceVSortP (f t)
  VMergeP t -> VMergeP (f t)
  ReadPackedFile ms s mVar t -> ReadPackedFile ms s mVar (f t)
  WritePackedFile s t -> WritePackedFile s (f t)
  ReadArrayFile m t -> ReadArrayFile m (f t)
  _ -> p0
  where
    f = elimTy tns

elimTyArrow :: S.Set String -> ([Ty1], Ty1) -> ([Ty1], Ty1)
elimTyArrow tns = fmap (elimTy tns) *** elimTy tns

elimTy :: S.Set String -> Ty1 -> Ty1
elimTy _tns _ = _
