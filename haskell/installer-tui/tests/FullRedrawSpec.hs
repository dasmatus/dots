{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}

-- | Full-redraw contract for the installer TUI's custom 'Driver' loop.
-- Faithful Haskell port of @rust/installer-tui/tests/full_redraw.rs@.
--
-- Pins the mechanism the loop relies on: an unchanged frame is normally
-- suppressed to zero bytes by the diff, but the same unchanged state preceded
-- by 'requestFullRedraw' emits a full non-empty frame again.
module FullRedrawSpec (tests) where

import Control.Monad.IO.Class (liftIO)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.ByteString as BS (length, null)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

import AbstractTUI.Anim (clockReal)
import AbstractTUI.Base.Geom (size)
import AbstractTUI.Driver
  ( RunConfig (..)
  , appMount
  , defaultRunConfig
  , newApp
  , newDriver
  , requestFullRedraw
  , turn
  , turnEmitted
  )
import AbstractTUI.Reactive (signal)
import AbstractTUI.Testing.Capture (captureCell, drainOutput, newCaptureTerm)

import Dots.Installer.App (App (..), appNew)
import Dots.Installer.Fx (ScreenFx, screenFxNew)
import Dots.Installer.Ui (rootView)

-- | Existential wrapper so the mount closure (polymorphic in @t@) can publish
-- the 'Signal' 'ScreenFx' to the test body.
data SomeFxSig = forall t. SomeFxSig (Signal t ScreenFx)

import AbstractTUI.Reactive (Signal)

tests :: TestTree
tests =
  testGroup
    "FullRedraw"
    [ testCase "request_full_redraw re-emits an unchanged frame" $ do
        let app0 = appNew [] (Just "/dev/nvme0n1")
            cols = 80
            rows = 24
        fxRef <- newIORef (Nothing :: Maybe SomeFxSig)
        eng <- newApp (size cols rows)
        appMount eng $ \scope -> do
          a <- signal app0 scope
          clock <- liftIO clockReal
          fx0 <- liftIO (screenFxNew clock)
          f <- signal fx0 scope
          liftIO (writeIORef fxRef (Just (SomeFxSig f)))
          pure (rootView a f)
        term <- newCaptureTerm cols rows
        dr <- newDriver eng term defaultRunConfig{rcProbe = False}
        -- Discard the enter bytes (alt-screen / cursor / mode arm) so only
        -- frame emissions are measured below.
        _enter <- drainOutput term
        -- Turn 1: the initial frame paints a full screen of cells.
        t1 <- turn dr
        assertBool ("initial frame emits bytes: " <> show t1) (turnEmitted t1)
        frame1 <- drainOutput term
        assertBool "initial frame non-empty" (not (BS.null frame1))
        screenAfterInitial <- screenText term cols rows
        -- Idle turn, no change, no full-redraw: the diff suppresses
        -- byte-identical cells, so the unchanged frame emits nothing.
        _idle <- turn dr
        idleBytes <- drainOutput term
        assertBool ("idle unchanged frame emits zero bytes") (BS.null idleBytes)
        -- Same unchanged state, but request_full_redraw is set first — exactly
        -- what Run.loop does every draw. The presenter re-anchors and the diff
        -- re-emits every cell this frame.
        requestFullRedraw dr
        t3 <- turn dr
        assertBool ("forced-redraw turn emits bytes: " <> show t3) (turnEmitted t3)
        frame3 <- drainOutput term
        assertBool "forced full redraw non-empty" (not (BS.null frame3))
        -- The full rewrite reproduces the same screen.
        screenAfterRedraw <- screenText term cols rows
        assertEqual "full redraw reproduces screen" screenAfterInitial screenAfterRedraw
    ]

-- | Concatenate the modeled screen's cell text, one row per line.
screenText :: term -> Int -> Int -> IO String
screenText term cols rows = do
  rows' <- mapM row [0 .. rows - 1]
  pure (unlines rows')
  where
    row y = concat <$> mapM (\x -> (: []) <$> captureCell term x y) [0 .. cols - 1]