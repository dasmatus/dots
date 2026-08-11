module Main (main) where

import AbstractTUI.Layout.Style (Dimension (..), Edges (..), allEdges)
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit ((@=?), testCase)

main :: IO ()
main = defaultMain $ testGroup "layout"
  [ testCase "all edges" $ Edges 2 2 2 2 @=? allEdges 2
  , testCase "percent is fraction" $ 0.5 @=? fractionOf (Percent 0.5)
  ]

fractionOf :: Dimension -> Float
fractionOf (Percent f) = f
fractionOf _ = -1