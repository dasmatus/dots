module Main (main) where

import AbstractTUI.Render.Style (Span (..), push, richLine, rlSpans, style)
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit ((@=?), testCase)

main :: IO ()
main =
  defaultMain $
    testGroup
      "style"
      [ testCase "push coalesces equal-ink spans" $
          1 @=? length (rlSpans (pushTwice richLine))
      ]
  where
    pushTwice l = push (push l (Span "cd" style Nothing)) (Span "ab" style Nothing)