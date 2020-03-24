--------------------------------------------------------------------
-- |
-- Module    :  TypeCheck.Show
-- Copyright :  (c) Zach Kimberg 2019
-- License   :  MIT
-- Maintainer:  zachary@kimberg.com
-- Stability :  experimental
-- Portability: non-portable
--
--------------------------------------------------------------------

module TypeCheck.Show where

import           Control.Monad.ST
import           Data.UnionFind.ST
import qualified Data.HashMap.Strict as H

import           Syntax
import           TypeCheck.Common

showM :: VarMeta s -> ST s ShowMeta
showM = descriptor

showExpr :: VExpr s -> ST s SExpr
showExpr (CExpr m c) = do
  m' <- showM m
  return (CExpr m' c)
showExpr (Value m name) = do
  m' <- showM m
  return (Value m' name)
showExpr (TupleApply m (bm, base) args) = do
  m' <- showM m
  bm' <- showM bm
  base' <- showExpr base
  args' <- mapM showExpr args
  return (TupleApply m' (bm', base') args')

showCompAnnot :: VCompAnnot s -> ST s SCompAnnot
showCompAnnot (CompAnnot name args) = do
  args' <- mapM showExpr args
  return $ CompAnnot name args'

showArrow :: VArrow s -> ST s SArrow
showArrow (Arrow m annots maybeExpr) = do
  m' <- showM m
  annots' <- mapM showCompAnnot annots
  case maybeExpr of
    Just expr -> do
      expr' <- showExpr expr
      return (Arrow m' annots' (Just expr'))
    Nothing -> return (Arrow m' annots' Nothing)

showObj :: (VObject s, [VArrow s]) -> ST s (SObject, [SArrow])
showObj (Object m name args, arrows) = do
  m' <- showM m
  args' <- mapM showM args
  arrows' <- mapM showArrow arrows
  return (Object m' name args', arrows')

showConHelper :: (Scheme -> Scheme -> SConstraint) -> Pnt s -> Pnt s -> ST s SConstraint
showConHelper f p1 p2 = do
  s1 <- descriptor p1
  s2 <- descriptor p2
  return $ f s1 s2

showCon :: Constraint s -> ST s SConstraint
showCon (EqualsKnown p t) = do
  scheme <- descriptor p
  return $ SEqualsKnown scheme t
showCon (EqPoints p1 p2) = showConHelper SEqPoints p1 p2
showCon (BoundedBy p1 p2) = showConHelper SBoundedBy p1 p2
showCon (ArrowTo p1 p2) = showConHelper SArrowTo p1 p2
showCon (PropEq (p1, name) p2) = showConHelper (\s1 s2 -> SPropEq (s1, name) s2) p1 p2
showCon (AddArgs (p1, argNames) p2) = showConHelper (\s1 s2 -> SAddArgs (s1, argNames) s2) p1 p2

showPrgm :: VPrgm s -> ST s SPrgm
showPrgm (objMap, classMap) = do
  objs' <- mapM showObj objMap
  return (H.fromList objs', classMap)

showConstraints :: [Constraint s] -> ST s [SConstraint]
showConstraints = mapM showCon
