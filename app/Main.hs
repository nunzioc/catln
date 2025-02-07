
{-# OPTIONS_GHC -Wno-type-defaults #-}
module Main where

import           CRes
import           Desugarf            (desFiles)
import           Eval
import           Options.Applicative
import           Parser
import           TypeCheck           (typecheckPrgm)

import qualified Data.HashMap.Strict as H
import           Data.Maybe
import           Data.Semigroup      ((<>))
import           Eval.Common         (Val (StrVal, TupleVal))
import           System.Directory
import           Text.Printf
import           WebDocs             (docServe)
-- import Repl (repl)

xRun :: String -> String -> IO ()
xRun prgmName function = do
  maybeRawPrgm <- readFiles True [prgmName]
  case aux maybeRawPrgm of
    CErr err   -> print err
    CRes _ resIO -> do
      returnValue <- resIO
      case returnValue of
        (0, _) -> return ()
        (i, _) -> print $ "error code " ++ show i
  where
    aux maybeRawPrgm = do
      rawPrgm <- maybeRawPrgm
      desPrgm <- desFiles rawPrgm
      tprgm <- typecheckPrgm desPrgm
      evalRun function prgmName tprgm

xBuild :: String -> String -> IO ()
xBuild prgmName function = do
  maybeRawPrgm <- readFiles True [prgmName]
  case aux maybeRawPrgm of
    CErr err   -> print err
    CRes _ resIO -> do
      returnValue <- resIO
      case returnValue of
        (TupleVal _ args, _) -> do
          let buildDir = "build"
          removePathForcibly buildDir
          createDirectoryIfMissing True buildDir
          let (StrVal outFileName) = fromJust $ H.lookup "name" args
          let (StrVal outContents) = fromJust $ H.lookup "contents" args
          writeFile (buildDir ++ "/" ++ outFileName) outContents
          printf "Successfully built %s" (show prgmName)
        _ -> error "Failed to build"
  where
    aux maybeRawPrgm = do
      rawPrgm <- maybeRawPrgm
      desPrgm <- desFiles rawPrgm
      tprgm <- typecheckPrgm desPrgm
      evalBuild function prgmName tprgm

xDoc :: String -> Bool -> IO ()
xDoc prgmName cached = docServe cached True prgmName

exec :: Command -> IO ()
exec (RunFile file function)   = xRun file function
exec (BuildFile file function) = xBuild file function
exec (Doc fname cached)        = xDoc fname cached

data Command
  = BuildFile String String
  | RunFile String String
  | Doc String Bool

cRun :: Parser Command
cRun = RunFile
  <$> argument str (metavar "FILE" <> help "The file to run")
  <*> argument str (metavar "FUN" <> value "main" <> help "The function in the file to run")

cBuild :: Parser Command
cBuild = BuildFile
  <$> argument str (metavar "FILE" <> help "The file to build")
  <*> argument str (metavar "FUN" <> value "main" <> help "The function in the file to build")

cDoc :: Parser Command
cDoc = Doc
  <$> argument str (metavar "FILE" <> help "The file to run")
  <*> switch (long "cached" <> help "Cache results instead of reloading live (useful for serving rather than development)")

main :: IO ()
main = exec =<< execParser opts
  where
    opts = info (mainCommands <**> helper)
      ( fullDesc
     <> progDesc "Executes Catln options"
     <> header "Catln Compiler" )
    mainCommands = subparser (
         command "run" (info cRun (progDesc "Runs a program"))
      <> command "build" (info cBuild (progDesc "Builds a program"))
      <> command "doc" (info cDoc (progDesc "Runs webdocs for a program"))
                             )
