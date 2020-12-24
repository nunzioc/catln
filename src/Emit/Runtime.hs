--------------------------------------------------------------------
-- |
-- Module    :  Emit.Runtime
-- Copyright :  (c) Zach Kimberg 2020
-- License   :  MIT
-- Maintainer:  zachary@kimberg.com
-- Stability :  experimental
-- Portability: non-portable
--
--------------------------------------------------------------------

module Emit.Runtime where

import qualified Data.HashMap.Strict as H
import           Syntax.Types
import           Syntax.Prgm
import           Syntax

import Eval.Common
import Emit.Codegen
import qualified LLVM.AST as AST
import LLVM.AST.Operand (Operand)
import qualified LLVM.AST.IntegerPredicate as IP
import qualified LLVM.AST.Constant as C
import qualified LLVM.AST.Type as ATP

type Op = (TypeName, [(PartialType, Guard (Expr Typed), ResBuildEnvFunction EPrim)])

true, false :: Val
true = TupleVal "True" H.empty
false = TupleVal "False" H.empty

bool :: Bool -> Val
bool True = true
bool False = false

liftBinOp :: Type -> Type -> Type -> TypeName -> (Operand -> Operand -> AST.Instruction) -> Op
liftBinOp lType rType resType name f = (name', [(srcType, NoGuard, \input -> PrimArrow input resType prim)])
  where
    name' = "operator" ++ name
    srcType = PartialType (PTypeName name') H.empty H.empty (H.fromList [("l", lType), ("r", rType)]) PtArgAny
    prim = EPrim srcType NoGuard (\args -> case (H.lookup "l" args, H.lookup "r" args) of
                           (Just (LLVMOperand _ l), Just (LLVMOperand _ r)) -> LLVMOperand resType $ do
                             l' <- l
                             r' <- r
                             instr (f l' r')
                           _ -> LLVMIO (pure ()) -- TODO: Delete, should be an error
                           -- _ -> error "Invalid binary op signature"
                           )

liftIntOp :: TypeName -> (Operand -> Operand -> AST.Instruction) -> Op
liftIntOp = liftBinOp intType intType intType

liftCmpOp :: TypeName -> IP.IntegerPredicate -> Op
liftCmpOp name predicate = liftBinOp intType intType boolType name (\l r -> AST.ICmp predicate l r [])

rneg :: TypeName -> Op
rneg name = (name', [(srcType, NoGuard, \input -> PrimArrow input resType prim)])
  where
    name' = "operator" ++ name
    srcType = PartialType (PTypeName name') H.empty H.empty (H.singleton "a" intType) PtArgAny
    resType = intType
    prim = EPrim srcType NoGuard (\args -> case H.lookup "a" args of
                           Just (LLVMOperand _ a') -> LLVMOperand intType $ do
                             a'' <- a'
                             instr (AST.Mul False False a'' (cons $ C.Int 32 (-1)) [])
                           _ -> error "Invalid strEq signature"
                           )

-- Floating point operations for reference
-- Arithmetic and Constants
-- arith :: (Operand -> Operand -> Instruction) -> [(S.Typed, Operand)] -> Maybe (Codegen Operand)
-- arith _ [(S.Typed at, _), (S.Typed bt, _)] | at /= bt = Nothing
-- arith f [(at, ao), (_, bo)] | S.typedIs at S.floatType = Just $ instr $ f ao bo
-- arith f [(at, ao), (_, bo)] | S.typedIs at S.intType = Just $ instr $ f ao bo
-- arith _ _ = Nothing

-- fadd, fsub, fmul, fdiv, fand, for :: [(S.Typed, Operand)] -> Maybe (Codegen Operand)
-- fadd = arith (\a b -> FAdd noFastMathFlags a b [])
-- fsub = arith (\a b -> FSub noFastMathFlags a b [])
-- fmul = arith (\a b -> FMul noFastMathFlags a b [])
-- fdiv = arith (\a b -> FDiv noFastMathFlags a b [])
-- fand = arith (\a b -> And a b [])
-- for = arith (\a b -> Or a b [])

-- cmp :: FP.FloatingPointPredicate -> IP.IntegerPredicate -> [(S.Typed, Operand)] -> Maybe (Codegen Operand)
-- cmp _ _ [(S.Typed at, _), (S.Typed bt, _)] | at /= bt = Nothing
-- cmp cond _ [(at, ao), (_, bo)] | S.typedIs at S.floatType = Just $ instr $ FCmp cond ao bo []
-- cmp _ cond [(at, ao), (_, bo)] | S.typedIs at S.intType = Just $ instr $ ICmp cond ao bo []
-- cmp _ _ _ = Nothing

-- lt, gt, gte, lte, eq, neq :: [(S.Typed, Operand)] -> Maybe (Codegen Operand)
-- gt = cmp FP.UGT IP.UGT
-- lt = cmp FP.ULT IP.ULT
-- gte = cmp FP.UGE IP.UGE
-- lte = cmp FP.ULE IP.ULE
-- eq = cmp FP.UEQ IP.EQ
-- neq = cmp FP.UNE IP.NE

strEq :: Op
strEq = (name', [(srcType, NoGuard, \input -> PrimArrow input resType prim)])
  where
    name' = "operator=="
    srcType = PartialType (PTypeName name') H.empty H.empty (H.fromList [("l", strType), ("r", strType)]) PtArgAny
    resType = boolType
    prim = EPrim srcType NoGuard (\args -> case (H.lookup "l" args, H.lookup "r" args) of
                           (Just (LLVMOperand _ l), Just (LLVMOperand _ r)) -> LLVMOperand boolType $ do
                             l' <- l
                             r' <- r
                             callf ATP.i1 "strcmp" [l', r'] -- TODO: really returns int type as result of comparison
                           _ -> error "Invalid strEq signature"
                           )

intToString :: Op
intToString = (name', [(srcType, NoGuard, \input -> PrimArrow input resType prim)])
  where
    name' = "toString"
    srcType = PartialType (PTypeName name') H.empty H.empty (H.singleton "this" intType) PtArgAny
    resType = strType
    prim = EPrim srcType NoGuard (\args -> case H.lookup "this" args of
                           Just (LLVMOperand _ _) -> LLVMOperand strType (pure $ cons $ C.Int 64 0) --TODO: Should do actual conversion
                           _ -> error "Invalid strEq signature"
                           )

ioExit :: Op
ioExit = (name', [(srcType, NoGuard, \input -> PrimArrow input resType prim)])
  where
    name' = "exit"
    srcType = PartialType (PTypeName name') H.empty H.empty (H.fromList [("this", ioType), ("val", intType)]) PtArgAny
    resType = ioType
    prim = EPrim srcType NoGuard (\args -> case (H.lookup "this" args, H.lookup "val" args) of
                           (Just (LLVMIO _), Just (LLVMOperand _ r)) -> LLVMIO $ do
                             r' <- r
                             _ <- callf ATP.VoidType "exit" [r']
                             return ()
                           _ -> LLVMIO (pure ())-- TODO: Delete, should be an error
                           -- _ -> error "Invalid ioExit signature"
                           )

println :: Op
println = (name', [(srcType, NoGuard, \input -> PrimArrow input resType prim)])
  where
    name' = "println"
    srcType = PartialType (PTypeName name') H.empty H.empty (H.fromList [("this", ioType), ("msg", strType)]) PtArgAny
    resType = ioType
    prim = EPrim srcType NoGuard (\args -> case (H.lookup "this" args, H.lookup "msg" args) of
                           (Just (LLVMIO _), Just (LLVMOperand _ s)) -> LLVMIO $ do
                             s' <- s
                             _ <- callf ATP.i32 "puts" [s']
                             return ()
                           _ -> error "Invalid strEq signature"
                           )


primEnv :: ResBuildEnv EPrim
primEnv = H.fromListWith (++) [liftIntOp "+" (\l r -> AST.Add False False l r [])
                              , liftIntOp "-" (\l r -> AST.Sub False False l r [])
                              , liftIntOp "*" (\l r -> AST.Mul False False l r [])
                              , liftCmpOp ">" IP.SGT
                              , liftCmpOp "<" IP.SLT
                              , liftCmpOp ">=" IP.SGE
                              , liftCmpOp "<=" IP.SLE
                              , liftCmpOp "==" IP.EQ
                              , liftCmpOp "!=" IP.NE
                              , rneg "-"
                              , strEq
                              , intToString
                              , ioExit
                              , println
                              ]
