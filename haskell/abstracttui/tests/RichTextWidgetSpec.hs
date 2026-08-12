module Main (main) where

import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit (testCase, (@=?))

import AbstractTUI.Base.Color (rgb)
import AbstractTUI.Base.Geom (size)
import AbstractTUI.Driver (
    RunConfig (..),
    appMount,
    defaultRunConfig,
    newApp,
    newDriver,
    turn,
 )
import AbstractTUI.Render.Style (
    Span (..),
    fg,
    fromLines,
    fromSpans,
    plainText,
    style,
 )
import AbstractTUI.Testing.Capture (CaptureTerm, captureCell, newCaptureTerm)
import AbstractTUI.Widget.RichText (richTextView)

main :: IO ()
main =
    defaultMain $
        testGroup
            "richtext-widget"
            [ testCase "plain text lands at (0,0)" $ do
                app <- newApp (size 10 1)
                appMount app (\_ -> pure (richTextView (plainText "hi")))
                term <- newCaptureTerm 10 1
                dr <- newDriver app term defaultRunConfig{rcIdlePollMs = 0}
                _ <- turn dr
                cellEq 'h' term 0 0
                cellEq 'i' term 1 0
            , testCase "multi-span line renders in order" $ do
                let rt =
                        fromLines
                            [ fromSpans
                                [ Span "A" (fg (rgb 255 0 0) style) Nothing
                                , Span "B" style Nothing
                                ]
                            ]
                app <- newApp (size 10 1)
                appMount app (\_ -> pure (richTextView rt))
                term <- newCaptureTerm 10 1
                dr <- newDriver app term defaultRunConfig{rcIdlePollMs = 0}
                _ <- turn dr
                cellEq 'A' term 0 0
                cellEq 'B' term 1 0
            ]

{- | Assert the captured cell equals @expected@ (see "ElementSpec" for why
'captureCell' is monadic).
-}
cellEq :: Char -> CaptureTerm -> Int -> Int -> IO ()
cellEq expected term x y = do
    actual <- captureCell term x y
    expected @=? actual
