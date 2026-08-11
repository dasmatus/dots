module Main (main) where

import AbstractTUI.Theme (defaultTokens, TokenSet (tokAccent))
import AbstractTUI.Base.Color (Rgba (rgbaA))
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit ((@=?), testCase)

main :: IO ()
main =
  defaultMain $
    testGroup
      "theme"
      [ testCase "accent token is opaque" $
          255 @=? rgbaA (tokAccent defaultTokens)
      ]