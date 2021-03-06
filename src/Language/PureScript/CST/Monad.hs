module Language.PureScript.CST.Monad where

import Prelude

import Data.Text (Text)
import Data.Char (isSpace)
import Language.PureScript.CST.Layout
import Language.PureScript.CST.Positions
import Language.PureScript.CST.Print
import Language.PureScript.CST.Types
import qualified Text.Megaparsec as P

data ParserErrorType
  = ErrExpr
  | ErrDecl
  | ErrExprInLabel
  | ErrExprInBinder
  | ErrExprInDeclOrBinder
  | ErrExprInDecl
  | ErrBinderInDecl
  | ErrRecordUpdateInCtr
  | ErrRecordPunInUpdate
  | ErrRecordCtrInUpdate
  | ErrElseInDecl
  | ErrImportInDecl
  | ErrGuardInLetBinder
  | ErrKeywordVar
  | ErrKeywordSymbol
  | ErrLetBinding
  | ErrToken
  | ErrLexeme (Maybe String) [String]
  | ErrEof
  deriving (Show, Eq, Ord)

data ParserError = ParserError
  { errRange :: SourceRange
  , errToks :: [SourceToken]
  , errStack :: LayoutStack
  , errType :: ParserErrorType
  } deriving (Show, Eq)

data ParserState = ParserState
  { parserNext :: P.State Text
  , parserBuff :: [SourceToken]
  , parserPos :: SourcePos
  , parserLeading :: [Comment LineFeed]
  , parserStack :: LayoutStack
  , parserErrors :: [ParserError]
  }

newtype Parser a =
  Parser (forall r. ParserState -> (ParserState -> ParserError -> r) -> (ParserState -> a -> r) -> r)

instance Functor Parser where
  fmap f (Parser k) =
    Parser $ \st kerr ksucc ->
      k st kerr (\st' a -> ksucc st' (f a))

instance Applicative Parser where
  pure a = Parser $ \st _ k -> k st a
  Parser k1 <*> Parser k2 =
    Parser $ \st kerr ksucc ->
      k1 st kerr $ \st' f ->
        k2 st' kerr $ \st'' a ->
          ksucc st'' (f a)

instance Monad Parser where
  return = pure
  Parser k1 >>= k2 =
    Parser $ \st kerr ksucc ->
      k1 st kerr $ \st' a -> do
        let Parser k3 = k2 a
        k3 st' kerr ksucc

runParser :: ParserState -> Parser a -> Either [ParserError] a
runParser st (Parser k) = k st left right
  where
  left (ParserState {..}) err =
    Left $ reverse $ err : parserErrors

  right (ParserState {..}) res
    | null parserErrors = Right res
    | otherwise = Left $ reverse parserErrors

parseError :: SourceToken -> Parser a
parseError tok = Parser $ \st kerr _ ->
  kerr st $ ParserError
    { errRange = tokRange . fst $ tok
    , errToks = [tok]
    , errStack = parserStack st
    , errType = ErrToken
    }

mkParserError :: LayoutStack -> [SourceToken] -> ParserErrorType -> ParserError
mkParserError stack toks ty =
  ParserError
    { errRange =  range
    , errToks = toks
    , errStack = stack
    , errType = ty
    }
  where
  range = case toks of
    [] -> SourceRange (SourcePos 0 0) (SourcePos 0 0)
    _  -> widen (tokRange . fst $ head toks) (tokRange . fst $ last toks)

addFailure :: [SourceToken] -> ParserErrorType -> Parser ()
addFailure toks ty = Parser $ \st _ ksucc ->
  ksucc (st { parserErrors = mkParserError (parserStack st) toks ty : parserErrors st }) ()

parseFail' :: [SourceToken] -> ParserErrorType -> Parser a
parseFail' toks msg = Parser $ \st kerr _ -> kerr st (mkParserError (parserStack st) toks msg)

parseFail :: SourceToken -> ParserErrorType -> Parser a
parseFail = parseFail' . pure

getLeadingComments :: Parser [Comment LineFeed]
getLeadingComments = Parser $ \st _ ksucc -> ksucc st (parserLeading st)

getLayoutStack :: Parser LayoutStack
getLayoutStack = Parser $ \st _ ksucc -> ksucc st (parserStack st)

pushBack :: SourceToken -> Parser ()
pushBack tok = Parser $ \st _ ksucc -> ksucc (st { parserBuff = tok : parserBuff st }) ()

prettyPrintError :: ParserError -> String
prettyPrintError (ParserError {..}) =
  errMsg <> " at " <> errPos
  where
  errMsg = case errType of
    ErrExprInLabel ->
      "Expected labeled expression or pun, saw expression"
    ErrExprInBinder ->
      "Expected pattern, saw expression"
    ErrExprInDeclOrBinder ->
      "Expected declaration or pattern, saw expression"
    ErrExprInDecl ->
      "Expected declaration, saw expression"
    ErrBinderInDecl ->
      "Expected declaration, saw pattern"
    ErrRecordUpdateInCtr ->
      "Expected ':', saw '='"
    ErrRecordPunInUpdate ->
      "Expected record update, saw pun"
    ErrRecordCtrInUpdate ->
      "Expected '=', saw ':'"
    ErrElseInDecl ->
      "Expected declaration, saw 'else'"
    ErrImportInDecl ->
      "Expected declaration, saw 'import'"
    ErrGuardInLetBinder ->
      "Unexpected guard in let pattern"
    ErrKeywordVar ->
      "Expected variable, saw keyword"
    ErrKeywordSymbol ->
      "Expected symbol, saw reserved symbol"
    ErrEof ->
      "Unexpected end of input"
    ErrLexeme (Just (hd:_)) _ | isSpace hd ->
      "Illegal whitespace character " <> show hd
    ErrLexeme (Just a) _ ->
      "Unexpected input " <> show a
    ErrLexeme _ _ ->
      basicError
    ErrLetBinding ->
      basicError
    ErrToken ->
      basicError
    ErrExpr ->
      basicError
    ErrDecl ->
      basicError

  errPos = case errRange of
    SourceRange (SourcePos line col) _ ->
      "line " <> show line <> ", column " <> show col

  basicError = case errToks of
    tok : _ -> basicTokError (snd tok)
    [] -> "Unexpected input"

  basicTokError = \case
    TokLayoutStart -> "Unexpected or mismatched indentation"
    TokLayoutSep   -> "Unexpected or mismatched indentation"
    TokLayoutEnd   -> "Unexpected or mismatched indentation"
    TokEof         -> "Unexpected end of input"
    tok            -> "Unexpected token " <> show (printToken tok)
