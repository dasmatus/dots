{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- | Integration tests for the 'Element' layout engine, 'onEvent' handler
wiring, 'dynView' image-producer regions, and — the load-bearing path the
interactive widgets ride on — signal mutation from a key handler
('sigUpdateIO') landing same-turn (the 'Driver.turn' fires the queued
trigger through the host's 'FireCommand' before render).
-}
module Main (main) where

import Data.Text (pack)
import Reflex (current)
import Reflex.Vty.Widget (displayWidth)
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit (testCase, (@=?))

import AbstractTUI.Base.Geom (size)
import AbstractTUI.Driver (
    RunConfig (..),
    appMount,
    defaultRunConfig,
    newApp,
    newDriver,
    turn,
 )
import AbstractTUI.Layout.Style (column, gap, h, row)
import AbstractTUI.Reactive (sigDyn, sigUpdateIO, signal)
import AbstractTUI.Render.Paint (renderRichTextImages)
import AbstractTUI.Render.Style (plainText)
import AbstractTUI.Testing.Capture (CaptureTerm, captureCell, feedInput, newCaptureTerm)
import AbstractTUI.View (
    Key (..),
    UiEvent (..),
    build,
    child,
    children,
    dynView,
    elementNew,
    onEvent,
    style,
    text,
 )

main :: IO ()
main =
    defaultMain $
        testGroup
            "element"
            [ testCase "column stacks h(1) children at rows 0/1/2" $ do
                let rowV t = build (style (h 1 row) (child (text t) elementNew))
                    root =
                        build
                            ( style
                                column
                                (children [rowV "a", rowV "b", rowV "c"] elementNew)
                            )
                app <- newApp (size 10 6)
                appMount app (\_ -> pure root)
                term <- newCaptureTerm 10 6
                dr <- newDriver app term defaultRunConfig{rcIdlePollMs = 0}
                _ <- turn dr
                cellEq 'a' term 0 0
                cellEq 'b' term 0 1
                cellEq 'c' term 0 2
            , testCase "gap 1 inserts a blank spacer row" $ do
                let rowV t = build (style (h 1 row) (child (text t) elementNew))
                    root =
                        build
                            ( style
                                (gap 1 column)
                                (children [rowV "a", rowV "b"] elementNew)
                            )
                app <- newApp (size 10 6)
                appMount app (\_ -> pure root)
                term <- newCaptureTerm 10 6
                dr <- newDriver app term defaultRunConfig{rcIdlePollMs = 0}
                _ <- turn dr
                cellEq 'a' term 0 0
                cellEq ' ' term 0 1
                cellEq 'b' term 0 2
            , testCase "onEvent signal mutation lands same-turn" $ do
                -- A dyn_view renders the current Int of a Signal; an on_event
                -- handler on the root mutates it via sigUpdateIO. Feeding '+'
                -- then a turn must show the incremented value (the Driver.turn
                -- fires the queued trigger through the host's FireCommand before
                -- render, so the new value lands same-turn).
                app <- newApp (size 10 1)
                appMount
                    app
                    ( \scope -> do
                        sig <- signal @Int 0 scope
                        let counter =
                                dynView
                                    (h 1 column)
                                    ( do
                                        dw <- displayWidth
                                        pure
                                            ( (\n w -> renderRichTextImages (plainText (pack (show n))) w)
                                                <$> current (sigDyn sig)
                                                <*> current dw
                                            )
                                    )
                            root =
                                build
                                    ( onEvent
                                        ( \case
                                            UiEventKey (KeyChar '+') -> sigUpdateIO sig (+ 1)
                                            _ -> pure ()
                                        )
                                        $ child counter elementNew
                                    )
                        pure root
                    )
                term <- newCaptureTerm 10 1
                dr <- newDriver app term defaultRunConfig{rcIdlePollMs = 0}
                _ <- turn dr
                cellEq '0' term 0 0
                feedInput term [43] -- '+'
                _ <- turn dr
                cellEq '1' term 0 0
                feedInput term [43]
                _ <- turn dr
                cellEq '2' term 0 0
            ]

{- | Assert the captured cell at @(x, y)@ equals @expected@. 'captureCell' is
monadic (it reads the mutable picture 'IORef'), so each assertion
sequences the read after the 'turn' that settled the picture — defeating
the full-laziness thunk-sharing that a pure 'unsafePerformIO' read would
hit across identical call sites.
-}
cellEq :: Char -> CaptureTerm -> Int -> Int -> IO ()
cellEq expected term x y = do
    actual <- captureCell term x y
    expected @=? actual
