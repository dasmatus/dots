-- | Animation overlay: the crossfade curve (0→1 EaseOut), the env gate, the
-- re-triggerable one-shot opacity ramp on 'Fx', and the 'blendBitmap' pixel
-- math. Faithful Haskell port of @rust/wallpaper-tui/tests/fx.rs@.
module FxSpec (tests) where

import Control.Exception (bracket)
import Data.Maybe (fromJust)
import qualified Data.Vector as V
import System.Environment (lookupEnv, setEnv, unsetEnv)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

import AbstractTUI.Base.Color (Rgba (..), rgb)
import AbstractTUI.Gfx.Bitmap (bitmap, bmpHeight, bmpWidth, fromPixels, pixels)

import WallpaperTui.Fx
  ( CrossfadeProbe (..)
  , Fx (..)
  , animationsEnabled
  , blendBitmap
  , crossfadeCurve
  , crossfadeOpacity
  , fxAdvance
  , fxNew
  , fxTick
  , retargetCrossfadeForce
  )

-- | Run an action with @name@ set to @val@ (or unset), restoring the
-- previous value afterwards. Hermetic so the env-gate test does not bleed
-- into the rest of the suite.
withEnv :: String -> Maybe String -> IO a -> IO a
withEnv name val action =
  bracket
    ( do
        old <- lookupEnv name
        case val of
          Just v -> setEnv name v
          Nothing -> unsetEnv name
        pure old
    )
    (\old -> maybe (unsetEnv name) (setEnv name) old)
    (const action)

tests :: TestTree
tests =
  testGroup
    "Fx"
    [ testCase "crossfade_curve rises to one then settles" $ do
        let probe = crossfadeCurve 150
            now = probeNow probe
        assertBool "starts invisible" (abs (now 0) < 1e-6)
        assertBool "fully visible at duration" (abs (now 150 - 1.0) < 1e-6)
        let mid = now 75
        assertBool ("mid-fade between 0 and 1, got " <> show mid)
          (mid > 0.0 && mid < 1.0)
        assertBool ("EaseOut past halfway at midpoint, got " <> show mid)
          (mid > 0.5)
    , testCase "animations_enabled respects env" $ do
        withEnv "DOTS_NO_ANIM" (Just "1") $ do
          off <- animationsEnabled
          assertBool "disabled when set" (not off)
        withEnv "DOTS_NO_ANIM" Nothing $ do
          on <- animationsEnabled
          assertBool "enabled when unset" on
    , testCase "crossfade_retrigger fires and settles to one" $ do
        -- Idle: opacity pinned at 1.0.
        let idle = fxTick fxNew
        assertBool "idle opacity 1.0"
          (abs (crossfadeOpacity idle - 1.0) < 1e-6)
        -- Fire at t=0, advance to the midpoint — opacity in (0, 1).
        let fired = retargetCrossfadeForce idle
            mid = fxAdvance 75 fired
            midOp = crossfadeOpacity mid
        assertBool ("mid-fade in (0,1), got " <> show midOp)
          (midOp > 0.0 && midOp < 1.0)
        -- After the full duration, one-shot clears, opacity pins at 1.0.
        let settled = fxAdvance 75 mid
        assertBool "settled to 1.0"
          (abs (crossfadeOpacity settled - 1.0) < 1e-6)
        -- Re-trigger after settle restarts from near-zero.
        let refired = retargetCrossfadeForce settled
            bumped = fxAdvance 1 refired
        assertBool "re-trigger restarts from near-zero"
          (crossfadeOpacity bumped < midOp)
    , testCase "blend_bitmap lerps from bg to image by opacity" $ do
        let px = V.generate 4 (const (rgb 255 0 0))
            bmp = fromJust (fromPixels 2 2 px)
            bg = rgb 0 0 0
        -- opacity 0 → fully bg (black).
        let faded = blendBitmap bmp bg 0.0
            p0 = V.head (pixels faded)
        assertEqual "opacity 0 → bg" bg p0
        -- opacity 1 → fully the source (red).
        let full = blendBitmap bmp bg 1.0
            p1 = V.head (pixels full)
        assertEqual "opacity 1 → src" (rgb 255 0 0) p1
        -- opacity 0.5 → midpoint (≈127, 0, 0).
        let half = blendBitmap bmp bg 0.5
            pMid = V.head (pixels half)
        assertBool ("red midpoint ~127, got " <> show (rgbaR pMid))
          (abs (fromIntegral (rgbaR pMid) - 127) <= 1)
    ]