--------------------------------------------------------------------
-- |
-- Module    :  Eval
-- Copyright :  (c) Zach Kimberg 2019
-- License   :  MIT
-- Maintainer:  zachary@kimberg.com
-- Stability :  experimental
-- Portability: non-portable
--
-- This module is used to run the interpreter (or compiler macro)
-- on a program. It can build, run, and compute the annotations
-- for the program.
--------------------------------------------------------------------
{-# LANGUAGE NamedFieldPuns #-}
{-# OPTIONS_GHC -Wno-deferred-type-errors #-}

module Eval where

import           CRes
import qualified Data.HashMap.Strict as H
import           Data.Zip
import           Prelude             hiding (unzip)
import           Syntax
import           Syntax.Prgm
import           Syntax.Types

import           Control.Monad
import           Data.Graph
import           Data.Maybe
import           Emit                (codegenExInit)
import           Eval.Common
import           Eval.Env
import           Eval.ExprBuilder
import           Eval.Runtime
import           Text.Printf
import           TreeBuild
import           Utils

data EvalMode
  = EvalRunWithContext -- ^ Run f{IO io} -> IO
  | EvalRun  -- ^ Run f -> Show
  | EvalBuildWithContext -- ^ Build f{IO io} -> CatlnResult
  | EvalBuild -- ^ Build f -> CatlnResult
  | NoEval -- ^ Can't run or build
  deriving Eq

evalRunnable :: EvalMode -> Bool
evalRunnable EvalRunWithContext = True
evalRunnable EvalRun            = True
evalRunnable _                  = False

evalBuildable :: EvalMode -> Bool
evalBuildable EvalRunWithContext   = True
evalBuildable EvalBuildWithContext = True
evalBuildable EvalBuild            = True
evalBuildable _                    = False

-- | Checks if a function is defined (not declared) and finds the 'EvalMode' of the function.
-- It will look through all of the objects to see if they match the function name or are Context(value=function name).
-- Then, those found functions can be checked for run/build based on whether the return type is a CatlnResult.
evalTargetMode :: String -> String -> EPrgmGraphData -> EvalMode
evalTargetMode function prgmName prgmGraphData = fromMaybe NoEval $ listToMaybe $ mapMaybe objArrowsContains objMap
  where
    (objMap, classMap, _) = prgmFromGraphData prgmName prgmGraphData
    objArrowsContains (_, arrows) | not (any arrowDefined arrows) = Nothing
    objArrowsContains (Object{objName, objArgs}, Arrow arrM _ _ _:_) = case objName of
      "Context" -> case H.lookup "value" objArgs of
        Just (_, Just Object{objName=valObjName}) -> if valObjName == function
          then Just $ if isBuildable (getMetaType arrM)
            then EvalBuildWithContext
            else EvalRunWithContext

          else Nothing
        _ -> Nothing
      _ | objName == function -> if isBuildable (getMetaType arrM)
          then Just EvalBuild
          else Just EvalRun
      _ -> Nothing
    objArrowsContains _ = Nothing
    isBuildable tp = not $ isBottomType $ intersectTypes classMap tp resultType
    arrowDefined (Arrow _ _ _ maybeExpr) = isJust maybeExpr

evalCompAnnot :: Env -> Val -> CRes Env
evalCompAnnot env (TupleVal "#assert" args) = case (H.lookup "test" args, H.lookup "msg" args) of
  (Just b, Just (StrVal _)) | b == true -> return env
  (Just b, Just (StrVal msg)) | b == false -> CErr [MkCNote $ AssertCErr msg]
  (Just b, Nothing) | b == true -> return env
  (Just b, Nothing) | b == false -> CErr [MkCNote $ AssertCErr "Failed assertion"]
  _ -> evalError env "Invalid assertion"
evalCompAnnot env (TupleVal name _) = evalError env $ printf "Unknown compiler annotation %s" name
evalCompAnnot env _ = evalError env "Eval: Invalid compiler annotation type"

eval :: Env -> ResArrowTree -> CRes (Val, Env)
eval env (ResEArrow input object arrow) = do
  (input', env2) <- evalPopVal <$> eval (evalPush env "resEArrow input") input
  let newArrArgs = buildArrArgs object input'
  (resArrowTree, compAnnots, oldArgs, env3) <- evalStartEArrow env2 (getValType input') object arrow newArrArgs
  env5s <- forM compAnnots $ \compAnnot -> do
            (compAnnot', env4) <- evalPopVal <$> eval (evalPush env3 $ printf "annot %s" (show compAnnot)) compAnnot
            evalCompAnnot env4 compAnnot'
  let env5 = case env5s of
        [] -> env3
        _  -> evalEnvJoinAll env5s
  (res, env6) <- evalPopVal <$> eval (evalPush env5 $ printf "ResEArrow %s" (show arrow)) resArrowTree
  return (res, evalEndEArrow env6 res oldArgs)
eval env (PrimArrow input _ (EPrim _ _ f)) = do
  (input', env2) <- evalPopVal <$> eval (evalPush env "PrimArrow input") input
  case input' of
    (TupleVal _ args) -> return (f args, env2)
    _                 -> error "Unexpected eval PrimArrow input"
eval env MacroArrow{} = evalError env $ printf "Can't evaluate a macro - it should be removed during TreeBuild"
eval env ExprArrow{} = evalError env $ printf "Can't evaluate an expr - it should be removed during TreeBuild"
eval env (ConstantArrow v) = return (v, env)
eval env@Env{evArgs} (ArgArrow _ name) = case H.lookup name evArgs of
  Just arg' -> return (arg', env)
  Nothing -> evalError env $ printf "Unknown arg %s found during evaluation \n\t\t with arg env %s" name (show evArgs)
eval env@Env{evClassMap} (ResArrowMatch m _ opts) = do
  (m', env2) <- evalPopVal <$> eval (evalPush env "match input") m
  case H.toList $ H.filterWithKey (\optType _ -> hasPartial evClassMap (getValType m') (singletonType optType)) opts of
    [(_, resArrowTree)] -> evalPopVal <$> eval (evalPush env2 $ "match with val " ++ show m') resArrowTree
    [] -> evalError env2 $ printf "Failed match in eval resArrowTree: \n\tVal: %s \n\tOptions: %s" (show m') (show opts)
    (_:_:_) -> evalError env $ printf "Multiple matches in eval resArrowTree: \n\tVal: %s \n\tOptions: %s " (show m') (show opts)
eval env (ResArrowCond _ [] elseTree) = evalPopVal <$> eval (evalPush env "else") elseTree
eval env@Env{evArgs} (ResArrowCond resType (((ifCondTree, ifCondInput, ifObj), ifThenTree):restIfTrees) elseTree) = do
  (ifCondInput', env2) <- evalPopVal <$> eval (evalPush env "condInput") ifCondInput
  let env3 = evalSetArgs env2 $ buildArrArgs ifObj ifCondInput'
  (cond', env4) <- evalPopVal <$> eval (evalPush env3 "cond") ifCondTree
  let env5 = evalSetArgs env4 evArgs
  case cond' of
    b | b == true -> evalPopVal <$> eval (evalPush env5 $ "then for " ++ show ifCondTree) ifThenTree
    b | b == false -> evalPopVal <$> eval (evalPush env5 $ "else for " ++ show ifCondTree) (ResArrowCond resType restIfTrees elseTree)
    _ -> error "Non-Bool eval resArrowCond"
eval env (ResArrowTuple name args) | H.null args = return (TupleVal name H.empty, env)
eval env (ResArrowTuple name args) = do
  args' <- traverse (eval (evalPush env "tuple")) args
  let (args'', env2s) = unzip args'
  let env2 = evalEnvJoinAll $ fmap evalPop env2s
  return (TupleVal name args'', env2)
eval env (ResArrowTupleApply base argName argRATree) = do
  (base', env2) <- evalPopVal <$> eval (evalPush env "tupleApplyBase") base
  case base' of
    TupleVal name baseArgs -> do
      (argVal, env3) <- eval (evalPush env2 $ printf "tupleApplyArg applying %s" argName) argRATree
      let args' = H.insert argName argVal baseArgs
      return (TupleVal name args', evalPop env3)
    _ -> evalError env "Invalid input to tuple application"

evalBaseEnv :: EPrgm -> Env
evalBaseEnv prgm@(objMap, classMap, _) = Env {
        evObjMap = objMap,
        evClassMap = classMap,
        evArgs = H.empty,
        evExEnv = H.empty,
        evTbEnv = buildTBEnv primEnv prgm,
        evCallStack = [],
        evCoverage = H.empty,
        evTreebugOpen = [],
        evTreebugClosed = []
                }

prgmFromGraphData :: String -> EPrgmGraphData -> EPrgm
prgmFromGraphData prgmName (prgmGraph, nodeFromVertex, vertexFromKey) = mergePrgms $ map (fst3 . nodeFromVertex) $ reachable prgmGraph $ fromJust $ vertexFromKey prgmName

evalBuildPrgm :: EExpr -> PartialType -> Type -> EPrgm -> CRes (ResArrowTree, Env)
evalBuildPrgm input srcType destType prgm = do
  let env@Env{evTbEnv} = evalBaseEnv prgm
  initTree <- buildRoot evTbEnv input srcType destType
  return (initTree, env)

evalAnnots :: String -> EPrgmGraphData -> CRes [(EExpr, Val)]
evalAnnots prgmName prgmGraphData = do
  let prgm@(_, _, annots) = prgmFromGraphData prgmName prgmGraphData
  let env@Env{evTbEnv} = evalBaseEnv prgm
  forM annots $ \annot -> do
    let exprType = getMetaType $ getExprMeta annot
    let inTree = ExprArrow annot exprType exprType
    let emptyType = PartialType (PTypeName "EmptyObj") H.empty H.empty H.empty PtArgExact
    let emptyObj = Object (Typed (singletonType emptyType) Nothing) FunctionObj "EmptyObj" H.empty H.empty Nothing
    tree <- resolveTree evTbEnv (emptyType, emptyObj) inTree
    val <- fst <$> eval env tree
    return (annot, val)

evalRun :: String -> String -> EPrgmGraphData -> CRes (IO (Integer, EvalResult))
evalRun function prgmName prgmGraphData = do
  let prgm = prgmFromGraphData prgmName prgmGraphData
  input <-  case evalTargetMode function prgmName prgmGraphData of
        EvalRunWithContext ->
          -- Case for eval Context(value=main, io=IO)
          return $ eApply (eApply (eVal "Context") "value" (eVal function)) "io" ioArg
        EvalRun ->
          -- Case for eval main
          return $ eVal function
        _ -> CErr [MkCNote $ GenCErr Nothing $ printf "Eval could not find a function %s to run" (show function)]
  let src = getExprPartialType input
  let dest = ioType
  (initTree, env) <- evalBuildPrgm input src dest prgm
  let env2 = evalSetArgs env (H.singleton "io" (IOVal 0 $ pure ()))
  (res, env') <- eval env2 initTree
  case res of
    (IOVal r io) -> return (io >> pure (r, evalResult env'))
    _ -> CErr [MkCNote $ GenCErr Nothing "Eval did not return an instance of IO"]

evalBuild :: String -> String -> EPrgmGraphData -> CRes (IO (Val, EvalResult))
evalBuild function prgmName prgmGraphData = do
  let prgm = prgmFromGraphData prgmName prgmGraphData
  input <-  case evalTargetMode function prgmName prgmGraphData of
        EvalRunWithContext ->
          -- Case for eval llvm(c=Context(value=main, io=IO))
          return $ eApply (eVal "llvm") "c" (eVal function)
        EvalBuildWithContext ->
          -- Case for buildable Context(value=main, io=IO)
          return $ eApply (eApply (eVal "Context") "value" (eVal function)) "io" ioArg
        EvalBuild ->
          -- Case for buildable main
          return $ eVal function
        _ -> CErr [MkCNote $ GenCErr Nothing $ printf "Eval could not find a function %s to build" (show function)]
  let src = getExprPartialType input
  let dest = resultType
  (initTree, env) <- evalBuildPrgm input src dest prgm
  (res, env') <- eval env initTree
  case res of
    val@(TupleVal "CatlnResult" args) -> case (H.lookup "name" args, H.lookup "contents" args) of
      (Just (StrVal _), Just (StrVal _)) -> return $ return (val, evalResult env')
      _ -> CErr [MkCNote $ GenCErr Nothing "Eval main returned a CatlnResult with bad args"]
    (LLVMVal toCodegen) -> return $ do
      llvmStr <- codegenExInit toCodegen
      return (TupleVal "CatlnResult" (H.fromList [("name", StrVal "out.ll"), ("contents", StrVal llvmStr)]), evalResult env')
    _ -> CErr [MkCNote $ GenCErr Nothing "Eval main did not return a CatlnResult"]
