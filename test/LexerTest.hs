module LexerTest (tests) where

import Lexer (Token (..), lexer)
import Ourlude
import Test.Tasty
import Test.Tasty.HUnit

shouldLex :: String -> [Token] -> Assertion
shouldLex str as = Right as @=? lexer str

tests :: TestTree
tests =
  testGroup
    "Lexer Tests"
    [ testCase "lexing keywords" (shouldLex "in data type if then else case" [OpenBrace, In, Data, Type, If, Then, Else, Case, CloseBrace]),
      testCase "lexing operators" (shouldLex "() ; :: -> | \\ / + ++ - * = . > >= < <= == /= && || $" operators),
      testCase "lexing names" (shouldLex "foo32' A34'" [OpenBrace, LowerName "foo32'", UpperName "A34'", CloseBrace]),
      testCase "lexing integer literals" (shouldLex "-42 32" [OpenBrace, Dash, IntLit 42, IntLit 32, CloseBrace]),
      testCase "lexing string literals" (shouldLex "\"foo bar\"" [OpenBrace, StringLit "foo bar", CloseBrace]),
      testCase "lexing bool literals" (shouldLex "True False" [OpenBrace, BoolLit True, BoolLit False, CloseBrace]),
      testCase "lexing comments" (shouldLex "if -- comment\n if" [OpenBrace, If, If, CloseBrace]),
      layoutTests
    ]
  where
    operators =
      [ OpenBrace,
        OpenParens,
        CloseParens,
        Semicolon,
        DoubleColon,
        ThinArrow,
        VBar,
        BSlash,
        FSlash,
        Plus,
        PlusPlus,
        Dash,
        Asterisk,
        Equal,
        Dot,
        RightAngle,
        RightAngleEqual,
        LeftAngle,
        LeftAngleEqual,
        EqualEqual,
        FSlashEqual,
        AmpersandAmpersand,
        VBarVBar,
        Dollar,
        CloseBrace
      ]

layoutTests :: TestTree
layoutTests =
  testGroup
    "Layout Tests"
    [ testCase "basic layouts" (shouldLex prog1 [OpenBrace, If, Equal, Let, OpenBrace, If, Semicolon, If, CloseBrace, In, CloseBrace]),
      testCase "nested layouts" (shouldLex prog2 [OpenBrace, If, Equal, Let, OpenBrace, If, Equal, Let, OpenBrace, If, CloseBrace, In, Semicolon, If, CloseBrace, In, CloseBrace])
    ]
  where
    prog1 =
      "if =\n\
      \  let\n\
      \    if\n\
      \    if\n\
      \  in"
    prog2 =
      "if =\n\
      \  let\n\
      \    if = -- comment\n\
      \      let\n\
      \        if\n\
      \      in\n\
      \    if\n\
      \  in"
