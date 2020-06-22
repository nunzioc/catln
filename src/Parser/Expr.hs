--------------------------------------------------------------------
-- |
-- Module    :  Parser.Expr
-- Copyright :  (c) Zach Kimberg 2020
-- License   :  MIT
-- Maintainer:  zachary@kimberg.com
-- Stability :  experimental
-- Portability: non-portable
--
--------------------------------------------------------------------

{-# LANGUAGE OverloadedStrings #-}

module Parser.Expr where

import           Control.Applicative            hiding (many, some)
import           Control.Monad.Combinators.Expr
import qualified Data.HashMap.Strict as H
import           Data.Maybe
import           Text.Megaparsec
import           Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer     as L

import           Lexer
import           Syntax.Types
import           Syntax.Prgm
import           Syntax
import Parser.Syntax

mkOp1 :: String -> PExpr -> PExpr
mkOp1 opChars x = RawTupleApply emptyMeta (emptyMeta, RawValue emptyMeta op) (H.singleton "a" x)
  where op = "operator" ++ opChars

mkOp2 :: String -> PExpr -> PExpr -> PExpr
mkOp2 opChars x y = RawTupleApply emptyMeta (emptyMeta, RawValue emptyMeta op) (H.fromList [("l", x), ("r", y)])
  where op = "operator" ++ opChars

ops :: [[Operator Parser PExpr]]
ops = [
    [ Prefix (mkOp1 "-"  <$ symbol "-")
    , Prefix (mkOp1 "~" <$ symbol "~")
    ],
    [ InfixL (mkOp2 "*" <$ symbol "*")
    , InfixL (mkOp2 "/" <$ symbol "/")
    ],
    [ InfixL (mkOp2 "+" <$ symbol "+")
    , InfixL (mkOp2 "-" <$ symbol "-")
    ],
    [ InfixL (mkOp2 "<=" <$ symbol "<=")
    , InfixL (mkOp2 ">=" <$ symbol ">=")
    , InfixL (mkOp2 "<" <$ symbol "<")
    , InfixL (mkOp2 ">" <$ symbol ">")
    , InfixL (mkOp2 "==" <$ symbol "==")
    , InfixL (mkOp2 "!=" <$ symbol "!=")
    ],
    [ InfixL (mkOp2 "&" <$ symbol "&")
    , InfixL (mkOp2 "|" <$ symbol "|")
    , InfixL (mkOp2 "^" <$ symbol "^")
    ]
  ]

pCallArg :: Parser (String, PExpr)
pCallArg = do
  argName <- identifier
  _ <- symbol "="
  expr <- pExpr
  return (argName, expr)

pCall :: Parser PExpr
pCall = do
  funName <- identifier <|> tidentifier
  maybeArgVals <- optional $ parens $ sepBy1 pCallArg (symbol ",")
  let baseValue = RawValue emptyMeta funName
  return $ case maybeArgVals of
    Just argVals -> RawTupleApply emptyMeta (emptyMeta, baseValue) (H.fromList argVals)
    Nothing -> baseValue

pStringLiteral :: Parser PExpr
pStringLiteral = RawCExpr emptyMeta . CStr <$> (char '\"' *> manyTill L.charLiteral (char '\"'))

pIfThenElse :: Parser PExpr
pIfThenElse = do
  _ <- symbol "if"
  condExpr <- pExpr
  _ <- symbol "then"
  thenExpr <- pExpr
  _ <- symbol "else"
  RawIfThenElse emptyMeta condExpr thenExpr <$> pExpr

pMatchCaseHelper :: String -> Parser (PExpr, [(PPattern, PExpr)])
pMatchCaseHelper keyword = L.indentBlock scn p
  where
    pack expr matchItems = return (expr, matchItems)
    pItem = do
      patt <- pPattern PatternObj
      _ <- symbol "=>"
      expr <- pExpr
      return (patt, expr)
    p = do
      _ <- symbol keyword
      expr <- pExpr
      _ <- symbol "of"
      return $ L.IndentSome Nothing (pack expr) pItem

pCase :: Parser PExpr
pCase = do
  (expr, matchItems) <- pMatchCaseHelper "case"
  return $ RawCase emptyMeta expr matchItems

pMatch :: Parser PExpr
pMatch = do
  (expr, matchItems) <- pMatchCaseHelper "match"
  return $ RawMatch emptyMeta expr (H.fromList matchItems)

term :: Parser PExpr
term = try (parens pExpr)
       <|> pIfThenElse
       <|> pMatch
       <|> pCase
       <|> pStringLiteral
       <|> RawCExpr emptyMeta . CInt <$> integer
       <|> try pCall
       <|> (RawValue emptyMeta <$> tidentifier)

pExpr :: Parser PExpr
pExpr = makeExprParser term ops

-- Pattern

pIfGuard :: Parser PGuard
pIfGuard = do
  _ <- symbol "if"
  IfGuard <$> pExpr

pElseGuard :: Parser PGuard
pElseGuard = do
  _ <- symbol "else"
  return ElseGuard

pPatternGuard :: Parser PGuard
pPatternGuard = fromMaybe NoGuard <$> optional (try pIfGuard
                                              <|> pElseGuard
                                            )

pObjTreeVar :: Parser (TypeVarName, ParseMeta)
pObjTreeVar = do
  var <- tvar
  return (var, emptyMeta)

pObjTreeArgPattern :: Parser (ArgName, PObjArg)
pObjTreeArgPattern = do
  val <- identifier
  _ <- symbol "="
  subTree <- pObjTree PatternObj
  return (val, (emptyMeta, Just subTree))

pObjTreeArgName :: Parser (ArgName, PObjArg)
pObjTreeArgName = do
  tp <- try $ optional pType
  val <- identifier
  let tp' = maybe emptyMeta PreTyped tp
  return (val, (tp', Nothing))

pObjTreeArgs :: Parser [(ArgName, PObjArg)]
pObjTreeArgs = sepBy1 (try pObjTreeArgPattern <|> pObjTreeArgName) (symbol ",")

pObjTree :: ObjectBasis -> Parser PObject
pObjTree basis = do
  name <- opIdentifier <|> identifier <|> tidentifier
  vars <- try $ optional $ angleBraces $ sepBy1 pObjTreeVar (symbol ",")
  args <- optional $ parens pObjTreeArgs
  let vars' = maybe H.empty H.fromList vars
  let args' = H.fromList $ fromMaybe [] args
  return $ Object emptyMeta basis name vars' args'

pPattern :: ObjectBasis -> Parser PPattern
pPattern basis = do
  objTree <- pObjTree basis
  Pattern objTree <$> pPatternGuard

-- Pattern Types


pLeafVar :: Parser (TypeVarName, Type)
pLeafVar = do
  var <- tvar
  return (var, TopType)

pTypeArg :: Parser (String, Type)
pTypeArg = do
  argName <- identifier
  _ <- symbol "="
  tp <- tidentifier
  return (argName, SumType $ joinPartialLeafs [(tp, H.empty, H.empty)])

pTypeVar :: Parser Type
pTypeVar = TypeVar <$> tvar

pLeafType :: Parser PartialType
pLeafType = do
  name <- tidentifier
  maybeVars <- try $ optional $ angleBraces $ sepBy1 pLeafVar (symbol ",")
  maybeArgs <- optional $ parens (sepBy1 pTypeArg (symbol ","))
  let vars = maybe H.empty H.fromList maybeVars
  let args = maybe H.empty H.fromList maybeArgs
  return (name, vars, args)

pSingleType :: Parser Type
pSingleType = pTypeVar
              <|> SumType . joinPartialLeafs . pure <$> pLeafType

pType :: Parser Type
pType = pTypeVar
        <|> SumType . joinPartialLeafs <$> sepBy1 pLeafType (symbol "|")