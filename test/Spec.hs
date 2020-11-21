module Main where

import System.Directory
import           Data.List
import           Test.Tasty
import           Test.Tasty.HUnit
import           Text.Printf

import CRes
import           Desugarf         (desFiles)
import           Emit             (codegen, initModule)
import           Eval
import           TypeCheck
import qualified Data.Text.Lazy as T
import Text.Pretty.Simple
import WebDocs (docServe)

testDir :: String
testDir = "test/code/"

buildDir :: String
buildDir = "test/build/"

runTest :: Bool -> String -> TestTree
runTest includeStd fileName = testCaseSteps fileName $ \step -> do
  step $ printf "Read file %s..." fileName
  maybePrgm <- desFiles $ (fileName : ["std/std.ct" | includeStd])
  case maybePrgm of
    CErr notes -> assertFailure $ "Could not parse and desguar:\n \t" ++ concat (map show notes)
    CRes _ prgm -> do
      -- step $ T.unpack $ pShow prgm
      step "Typecheck..."
      -- step $ T.unpack $ pShow $ traceTestPrgm prgm
      case typecheckPrgm prgm of
        CErr err -> do
          assertFailure $ "Could not typecheck:\n\n\n\t" ++ intercalate "\n\n\n\t\t" (map (T.unpack . pShow) err)
        CRes _ tprgm -> do
          -- step $ T.unpack $ pShow $ tprgm
          step "Eval tests..."
          -- step $ T.unpack $ pShow $ evalBuildMain tprgm
          case evalMain tprgm of
            CErr notes -> do
              assertFailure $ "Could not eval:\n\t " ++ intercalate "\n\t" (map show notes)
            CRes notes io -> do
              returnValue <- io
              case (notes, returnValue) of
                ([], 0) -> return () -- success
                _ -> assertFailure $ "Bad result for:\n \t " ++ show returnValue ++ "\n \tNotes\t" ++ concat (map show notes)
          step "Codegen"
          _ <- codegen initModule tprgm
          -- step $ T.unpack $ pShow $ cgPrgm
          step "Done"

runTests :: Bool -> [String] -> TestTree
runTests includeStd testFiles = testGroup "Tests" testTrees
  where testTrees = map (runTest includeStd) testFiles

runBuild :: String -> TestTree
runBuild fileName = testCaseSteps fileName $ \step -> do
  step $ printf "Read file %s..." fileName
  maybePrgm <- desFiles $ (fileName : ["std/std.ct"])
  case maybePrgm of
    CErr notes -> assertFailure $ "Could not parse and desguar:\n \t" ++ concat (map show notes)
    CRes _ prgm -> do
      -- step $ T.unpack $ pShow prgm
      step "Typecheck..."
      -- step $ T.unpack $ pShow $ traceTestPrgm prgm
      case typecheckPrgm prgm of
        CErr err -> do
          assertFailure $ "Could not typecheck:\n\n\n\t" ++ intercalate "\n\n\n\t\t" (map (T.unpack . pShow) err)
        CRes _ tprgm -> do
          -- step $ T.unpack $ pShow $ tprgm
          step "Eval tests..."
          -- step $ T.unpack $ pShow $ evalBuildMain tprgm
          case evalMainb tprgm of
            CErr notes -> do
              assertFailure $ "Could not eval:\n\t " ++ intercalate "\n\t" (map show notes)
            CRes _ _ -> return () -- success

runBuilds :: [String] -> TestTree
runBuilds testFiles = testGroup "Builds" testTrees
  where testTrees = map runBuild testFiles

test :: IO ()
test = defaultMain $ runTests False ["test/test.ct"]

testd :: IO ()
testd = docServe False "test/test.ct"

standardTests :: IO ([String])
standardTests = do
  fileNames <- listDirectory testDir
  return $ map (testDir ++) fileNames

buildTests :: IO ([String])
buildTests = do
  fileNames <- listDirectory buildDir
  return $ map (buildDir ++) fileNames

mt :: String -> IO ()
mt k = do
  let fileName = testDir ++ k ++ ".ct"
  tests <- standardTests
  if elem fileName tests
     then defaultMain $ runTests True [fileName]
     else error $ printf "invalid test name %s in %s" fileName (show tests)

mtd :: String -> IO ()
mtd k = do
  let fileName = testDir ++ k ++ ".ct"
  tests <- standardTests
  if elem fileName tests
     then docServe True fileName
     else error $ printf "invalid test name %s in %s" fileName (show tests)

mb :: String -> IO ()
mb k = do
  let fileName = buildDir ++ k ++ ".ct"
  tests <- buildTests
  if elem fileName tests
     then defaultMain $ runBuilds [fileName]
     else error $ printf "invalid build test name %s in %s" fileName (show tests)

mtt :: IO ()
mtt = mt "match"

main :: IO ()
main = do
  tests <- standardTests
  let tests' = runTests True tests
  builds <- buildTests
  let builds' = runBuilds builds
  let full = testGroup "full" [tests', builds']
  defaultMain full
