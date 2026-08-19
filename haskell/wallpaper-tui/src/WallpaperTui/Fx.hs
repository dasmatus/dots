-- | Animation overlay for the wallpaper TUI: a re-triggerable preview
-- crossfade. Mirrors @rust/wallpaper-tui/src/fx.rs@. All motion is opt-in and
-- collapses to a no-op when @DOTS_NO_ANIM@ is set.
--
-- The crossfade is a one-shot 0→1 opacity ramp re-triggered on every
-- selection change. The view blends the new preview 'Bitmap' toward the pane
-- background by the cached opacity ('blendBitmap').
--
-- 'Fx' is PURE: it carries its own time field ('fxTime') rather than an
-- abstracttui 'Clock' (which is IO), so 'fxTick'\/'fxAdvance'\/'retarget' are
-- pure 'Fx -> Fx' functions — matching the Rust API and the
-- 'sigUpdate'\/'sigUpdateIO' pure-function contract. The production loop
-- seeds real time via 'fxTickAt' (passing @clockNow@ each frame); the tests
-- drive time directly via 'fxAdvance' on a zero-start 'fxNew' (matching
-- @Clock::fixed()@).
module WallpaperTui.Fx
  ( Fx (..)
  , fxNew
  , fxTick
  , fxTickAt
  , fxAdvance
  , retargetCrossfade
  , retargetCrossfadeForce
  , crossfadeOpacity
  , crossfadeDurMs
  , animationsEnabled
  , CrossfadeProbe (..)
  , crossfadeCurve
  , blendBitmap
  ) where

import Data.Word (Word8)
import System.Environment (lookupEnv)

import AbstractTUI.Base.Color (Rgba (..))
import AbstractTUI.Gfx.Bitmap (Bitmap (..), mapPixels)
import AbstractTUI.Anim (Tween, tween, tweenEasing, tweenSample, Easing (EaseOut))

import WallpaperTui.Accent (roundHalfAway)

-- | The crossfade duration in milliseconds (mirrors @CROSSFADE_DUR@).
crossfadeDurMs :: Int
crossfadeDurMs = 150

-- | The live overlay state. 'fxTime' is the clock's @now@ in ms (advanced by
-- the loop or the tests); 'fxStart' is the one-shot start time ('Nothing' at
-- rest); 'fxOpacity' is the cached eased opacity refreshed by 'fxTick'.
data Fx = Fx
  { fxTime :: !Int
  , fxStart :: !(Maybe Int)
  , fxOpacity :: !Float
  } deriving (Show, Eq)

-- | @Fx::new(Clock::fixed())@ — idle at time 0, opacity pinned at 1.0. The
-- production loop seeds the real wall time via 'fxTickAt' on the first frame.
fxNew :: Fx
fxNew = Fx{fxTime = 0, fxStart = Nothing, fxOpacity = 1.0}

-- | Advance the ramp to the clock's @now@ and cache the eased opacity. The
-- loop calls this once per frame (passing @clockNow@); tests use 'fxAdvance'
-- on a zero-start 'Fx'. Re-requests a frame while the fade is in flight (the
-- loop's idle pace already re-pumps, so this is a pure no-op marker here —
-- kept for API parity).
fxTickAt :: Int -> Fx -> Fx
fxTickAt now f =
  let (op, mStart) = opacityAt now f
  in f{fxTime = now, fxOpacity = op, fxStart = mStart}

-- | 'fxTickAt' at the current 'fxTime' (recompute opacity without moving
-- time). Mirrors @Fx::tick@ reading @clock.now()@.
fxTick :: Fx -> Fx
fxTick f = fxTickAt (fxTime f) f

-- | Advance the clock by @ms@ then 'fxTick'. The deterministic tests use this
-- with a zero-start 'Fx' (the real loop uses 'clockNow' + 'fxTickAt').
fxAdvance :: Int -> Fx -> Fx
fxAdvance ms f = fxTickAt (fxTime f + ms) f

-- | Re-trigger the crossfade (called on selection change). A no-op when
-- animations are disabled — BUT animations are an env-checked 'IO' concern,
-- so this is the UNGATED primitive; the on-event bridge checks
-- 'animationsEnabled' (IO) before calling it. Mirrors @retarget_crossfade@;
-- tests use 'retargetCrossfadeForce' directly to avoid the process-global
-- env race.
retargetCrossfade :: Fx -> Fx
retargetCrossfade = retargetCrossfadeForce

-- | Ungated crossfade re-trigger — set the one-shot start to the current
-- 'fxTime'. Mirrors @retarget_crossfade_force@.
retargetCrossfadeForce :: Fx -> Fx
retargetCrossfadeForce f = f{fxStart = Just (fxTime f)}

-- | Cached eased crossfade opacity (0.0..=1.0). Peek, no mutation.
crossfadeOpacity :: Fx -> Float
crossfadeOpacity = fxOpacity

-- | Eased opacity at @now@; clears the one-shot once 'crossfadeDurMs' elapses
-- (leaving opacity pinned at 1.0). Internal helper for 'fxTickAt'.
opacityAt :: Int -> Fx -> (Float, Maybe Int)
opacityAt now f = case fxStart f of
  Nothing -> (1.0, Nothing)
  Just start ->
    let elapsed = now - start
    in if elapsed >= crossfadeDurMs
         then (1.0, Nothing)
         else (clamp01 (tweenSample crossfadeTween elapsed), Just start)

-- | The 0→1 'EaseOut' 'Tween' over 'crossfadeDurMs'. Stateless, so sampled at
-- any @elapsed@ without per-instance state.
crossfadeTween :: Tween
crossfadeTween = tweenEasing EaseOut (tween 0.0 1.0 crossfadeDurMs)

-- | 'True' unless @DOTS_NO_ANIM@ is set. IO (reads the process env).
animationsEnabled :: IO Bool
animationsEnabled = do
  m <- lookupEnv "DOTS_NO_ANIM"
  pure (case m of Nothing -> True; Just _ -> False)

clamp01 :: Float -> Float
clamp01 x = max 0.0 (min 1.0 x)

-- * CrossfadeProbe

-- | Deterministic probe over the crossfade 'Tween', sampled at arbitrary
-- times (the 'Tween' is stateless, so call order does not matter). Used by
-- tests.
newtype CrossfadeProbe = CrossfadeProbe { probeNow :: Int -> Float }

-- | Eased 0→1 over @durMs@ with 'EaseOut'. The property tested: 0 at the
-- start, 1 at the duration, strictly between mid-fade. The 'Clock' argument
-- Rust takes is unused (@_clock@), so this port elides it.
crossfadeCurve :: Int -> CrossfadeProbe
crossfadeCurve durMs =
  CrossfadeProbe (clamp01 . tweenSample (tweenEasing EaseOut (tween 0.0 1.0 durMs)))

-- * blendBitmap

-- | Blend @bmp@ toward @bg@ by @opacity@ (0.0 → fully @bg@, 1.0 → fully
-- @bmp@), returning a fresh 'Bitmap'. Used by the view to render the
-- crossfade. NOTE: abstracttui's 'AbstractTUI.Gfx.Bitmap.blendBitmap' is
-- INVERTED (opacity 0→bmp, 1→bg), so this is a local definition with the
-- Rust orientation and half-away-from-zero channel rounding (matching Rust's
-- @f64::round@, NOT Haskell's 'round').
blendBitmap :: Bitmap -> Rgba -> Double -> Bitmap
blendBitmap bmp bg opacity =
  mapPixels (\p -> lerpAway (realToFrac opacity) bg p) bmp

-- | @lerp t a b = a + t*(b-a)@ with each channel rounded half away from zero
-- (Rust's @f64::round@) and clamped to 0..255. Alpha is lerped the same way
-- (the pane background is opaque, so it stays 255 in practice).
lerpAway :: Double -> Rgba -> Rgba -> Rgba
lerpAway t a b =
  Rgba
    { rgbaR = ch rgbaR
    , rgbaG = ch rgbaG
    , rgbaB = ch rgbaB
    , rgbaA = ch rgbaA
    }
  where
    t' = max 0.0 (min 1.0 t)
    ch f =
      let v = fromIntegral (f a) + t' * (fromIntegral (f b) - fromIntegral (f a)) :: Double
      in clampWord8 (roundHalfAway v)

-- | Clamp a rounded channel into the Word8 range.
clampWord8 :: Int -> Word8
clampWord8 n
  | n < 0 = 0
  | n > 255 = 255
  | otherwise = fromIntegral n