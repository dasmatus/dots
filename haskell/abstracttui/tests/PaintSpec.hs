module Main (main) where

import qualified Graphics.Vty as V
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit (testCase, (@=?), (@?=))

import AbstractTUI.Base.Color (rgb)
import AbstractTUI.Render.Style
  ( Span (..)
  , fg
  , fromLines
  , fromSpans
  , plainText
  , style
  )
import AbstractTUI.Render.Paint (renderRichText, styleAttr)

main :: IO ()
main =
  defaultMain $
    testGroup
      "paint"
      [ testCase "plain text width/height" $ do
          let img = renderRichText (plainText "hi") 10
          2 @=? V.imageWidth img
          1 @=? V.imageHeight img
      , testCase "multiline block height" $ do
          let rt =
                fromLines
                  [ fromSpans [Span "ab" style Nothing]
                  , fromSpans [Span "cd" style Nothing]
                  ]
          2 @=? V.imageHeight (renderRichText rt 10)
      , testCase "wrap splits to maxWidth" $ do
          let img = renderRichText (plainText "abcdef") 3
          3 @=? V.imageWidth img
          2 @=? V.imageHeight img
      , testCase "styleAttr fg diverges from defAttr" $
          let a = styleAttr (fg (rgb 255 0 0) style)
           in (V.defAttr /= a) @?= True
      ]