-- | Animation-math tests using abstracttui's fixed clock for determinism.
-- Faithful Haskell port of @rust/installer-tui/tests/fx.rs@.
module FxSpec (tests) where

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

import AbstractTUI.Anim (clockFixed)

import Dots.Installer.Fx
  ( EaseProbe (..)
  , ScreenFx (..)
  , advanceFx
  , animationsEnabled
  , easeNow
  , easeRatio
  , progressR
  , retargetProgressForce
  , retargetScreenForce
  , screenFxNew
  , screenX
  , shakeAt
  , shakeForce
  , shakeNow
  , shakeX
  )

import Common (withEnv)

tests :: TestTree
tests =
  testGroup
    "Fx"
    [ testCase "ease_ratio eases out and clamps" $ do
        clock <- clockFixed
        let r = easeRatio clock 0.0 1.0 200
        assertBool "starts 0" (abs (easeNow r 0) < 1e-6)
        assertBool "lands 1" (abs (easeNow r 200 - 1.0) < 1e-6)
        assertBool "mid > 0.5" (easeNow r 100 > 0.5)
    , testCase "shake settles to zero after duration" $ do
        clock <- clockFixed
        let s = shakeAt clock 120
        assertBool "starts 0" (abs (shakeNow s 0) < 1e-6)
        assertBool "after dur 0" (abs (shakeNow s 121) < 1e-6)
        assertBool "mid nonzero" (abs (shakeNow s 60) > 0.0)
    , testCase "animations_enabled respects env" $ do
        withEnv "DOTS_NO_ANIM" (Just "1") $ do
          off <- animationsEnabled
          assertBool "disabled when set" (not off)
        withEnv "DOTS_NO_ANIM" Nothing $ do
          on <- animationsEnabled
          assertBool "enabled when unset" on
    , testCase "progress retarget eases toward target" $ do
        clock <- clockFixed
        fx0 <- screenFxNew clock
        fx1 <- retargetProgressForce fx0 1.0
        fx2 <- advanceFx fx1 0
        assertBool ("starts at 0: " <> show (progressR fx2))
                   (abs (progressR fx2) < 1e-6)
        fx3 <- advanceFx fx2 80
        assertBool ("midpoint > 0.5: " <> show (progressR fx3))
                   (progressR fx3 > 0.5)
        fx4 <- advanceFx fx3 160
        assertBool ("lands at 1: " <> show (progressR fx4))
                   (abs (progressR fx4 - 1.0) < 1e-6)
    , testCase "shake_force fires and settles" $ do
        clock <- clockFixed
        fx0 <- screenFxNew clock
        fx1 <- shakeForce fx0
        fx2 <- advanceFx fx1 60
        assertBool ("shaking mid-flight: " <> show (shakeX fx2))
                   (shakeX fx2 /= 0)
        fx3 <- advanceFx fx2 80
        assertEqual "settled" 0 (shakeX fx3)
    , testCase "screen retarget eases to target" $ do
        clock <- clockFixed
        fx0 <- screenFxNew clock
        fx1 <- retargetScreenForce fx0 1.0
        fx2 <- advanceFx fx1 0
        assertBool ("starts at 0: " <> show (screenX fx2))
                   (abs (screenX fx2) < 1e-6)
        fx3 <- advanceFx fx2 180
        assertBool ("lands at 1: " <> show (screenX fx3))
                   (abs (screenX fx3 - 1.0) < 1e-6)
    ]