-- | Animation overlay for the installer TUI. Faithful Haskell port of
-- @rust/installer-tui/src/fx.rs@.
--
-- All motion is opt-in and collapses to a no-op when @DOTS_NO_ANIM@ is set.
-- 'ScreenFx' wraps abstracttui's 'Transition' (retargetable eased motion) for
-- the panel slide and the progress fill, plus a damped-sine error shake. The
-- free helpers 'easeRatio' / 'shakeAt' expose the underlying math to unit
-- tests via a deterministic 'Clock.clockFixed'.
--
-- 'ScreenFx' is a PURE value (no mutable cached fields): the loop writes a new
-- one back into the 'Signal' each frame via 'sigSetIO', and the 'dynView'
-- re-renders from 'current (sigDyn fx)' on each fire. This matches the Rust
-- @Signal<ScreenFx>@ which fires on every @update(tick)@.
module Dots.Installer.Fx
  ( animationsEnabled
  , ScreenFx (..)
  , screenFxNew
  , retargetScreen
  , retargetProgress
  , shake
  , retargetScreenForce
  , retargetProgressForce
  , shakeForce
  , tickFx
  , advanceFx
  , screenX
  , progressR
  , shakeX
  , EaseProbe (..)
  , easeRatio
  , easeNow
  , ShakeProbe (..)
  , shakeAt
  , shakeNow
  , screenDur
  , progressDur
  , shakeDur
  , shakeAmp
  ) where

import System.Environment (lookupEnv)

import AbstractTUI.Anim
  ( Clock
  , Easing (..)
  , Transition
  , Tween
  , clockAdvance
  , clockNow
  , transition
  , transitionSetTarget
  , transitionTick
  , transitionValue
  , tween
  , tweenEasing
  , tweenSample
  )

-- | True unless @DOTS_NO_ANIM@ is set. Mirrors @animations_enabled@.
animationsEnabled :: IO Bool
animationsEnabled = do
  m <- lookupEnv "DOTS_NO_ANIM"
  pure (m == Nothing)

-- | Panel slide duration (ms). Mirrors @SCREEN_DUR@.
screenDur :: Int
screenDur = 180

-- | Progress fill duration (ms). Mirrors @PROGRESS_DUR@.
progressDur :: Int
progressDur = 160

-- | Error shake duration (ms). Mirrors @SHAKE_DUR@.
shakeDur :: Int
shakeDur = 120

-- | Error shake amplitude (cells). Mirrors @SHAKE_AMP@.
shakeAmp :: Float
shakeAmp = 8.0

-- | Live, retargetable motion for the wizard panel + progress bar, plus a
-- one-shot error shake. Stored in a 'Signal' and written back each frame via
-- 'tickFx' + 'sigSetIO'. The cached eased values ('sfScreenX' etc.) are read
-- by the view via the pure peek functions.
data ScreenFx = ScreenFx
  { sfClock :: !Clock
  , sfScreenOffset :: !Transition
  , sfProgress :: !Transition
  , sfShakeStart :: !(Maybe Int)
  -- | Cached eased panel x-offset, refreshed by 'tickFx'.
  , sfScreenX :: !Float
  -- | Cached eased progress ratio, refreshed by 'tickFx'.
  , sfProgressR :: !Float
  -- | Cached shake x-offset in cells, refreshed by 'tickFx'.
  , sfShakeX :: !Int
  }

-- | New overlay on the given clock (real in production). Mirrors
-- @ScreenFx::new@.
screenFxNew :: Clock -> IO ScreenFx
screenFxNew clock = pure ScreenFx
  { sfClock = clock
  , sfScreenOffset = transition 0.0 screenDur EaseOut
  , sfProgress = transition 0.0 progressDur EaseOut
  , sfShakeStart = Nothing
  , sfScreenX = 0.0
  , sfProgressR = 0.0
  , sfShakeX = 0
  }

-- | Retarget the panel slide x-offset (called on 'Screen' change). No-op when
-- @DOTS_NO_ANIM@ is set. Mirrors @retarget_screen@.
retargetScreen :: ScreenFx -> Float -> IO ScreenFx
retargetScreen fx to = do
  on <- animationsEnabled
  if on then retargetScreenForce fx to else pure fx

-- | Retarget the eased progress fill (called when the install step changes).
-- No-op when @DOTS_NO_ANIM@ is set. Mirrors @retarget_progress@.
retargetProgress :: ScreenFx -> Float -> IO ScreenFx
retargetProgress fx ratio = do
  on <- animationsEnabled
  if on then retargetProgressForce fx ratio else pure fx

-- | Fire a one-shot error shake (called when 'appError' becomes 'Just'). No-op
-- when @DOTS_NO_ANIM@ is set. Mirrors @shake@.
shake :: ScreenFx -> IO ScreenFx
shake fx = do
  on <- animationsEnabled
  if on then shakeForce fx else pure fx

-- | Ungated panel retarget — the primitive 'retargetScreen' delegates to.
-- Tests use this directly so they don't race with the env-mutating
-- 'animationsEnabled' test (tests run in parallel threads sharing one process
-- env). Mirrors @retarget_screen_force@.
retargetScreenForce :: ScreenFx -> Float -> IO ScreenFx
retargetScreenForce fx to = do
  now <- clockNow (sfClock fx)
  pure fx { sfScreenOffset = transitionSetTarget to now (sfScreenOffset fx) }

-- | Ungated progress retarget — see 'retargetScreenForce'.
retargetProgressForce :: ScreenFx -> Float -> IO ScreenFx
retargetProgressForce fx ratio = do
  now <- clockNow (sfClock fx)
  pure fx { sfProgress = transitionSetTarget ratio now (sfProgress fx) }

-- | Ungated shake fire — see 'retargetScreenForce'.
shakeForce :: ScreenFx -> IO ScreenFx
shakeForce fx = do
  now <- clockNow (sfClock fx)
  pure fx { sfShakeStart = Just now }

-- | Advance every transition to the clock's 'now' and cache the eased values.
-- The app loop calls this once per frame and writes the result back via
-- 'sigSetIO'; tests drive it via 'advanceFx' on a 'clockFixed'. Mirrors @tick@.
tickFx :: ScreenFx -> IO ScreenFx
tickFx fx = do
  now <- clockNow (sfClock fx)
  let so' = transitionTick now (sfScreenOffset fx)
      pr' = transitionTick now (sfProgress fx)
      (shx, mStart') = shakeOffsetAt now (sfShakeStart fx)
  pure fx
    { sfScreenOffset = so'
    , sfScreenX = transitionValue so'
    , sfProgress = pr'
    , sfProgressR = transitionValue pr'
    , sfShakeX = shx
    , sfShakeStart = mStart'
    }

-- | Advance the clock by @ms@ then 'tickFx'. The deterministic door tests use
-- this with 'clockFixed' (the real loop uses 'clockReal' + 'tickFx').
-- Mirrors @advance@.
advanceFx :: ScreenFx -> Int -> IO ScreenFx
advanceFx fx ms = do
  clockAdvance (sfClock fx) ms
  tickFx fx

-- | Cached eased panel x-offset (cells). Pure peek.
screenX :: ScreenFx -> Float
screenX = sfScreenX

-- | Cached eased progress ratio (0.0..=1.0). Pure peek.
progressR :: ScreenFx -> Float
progressR = sfProgressR

-- | Cached shake x-offset (cells). Pure peek.
shakeX :: ScreenFx -> Int
shakeX = sfShakeX

-- | Current shake x-offset at @now@; clears the one-shot once 'shakeDur'
-- elapses. Returns (offset, newShakeStart). Pure helper for 'tickFx'.
-- Mirrors @shake_offset_at@.
shakeOffsetAt :: Int -> Maybe Int -> (Int, Maybe Int)
shakeOffsetAt now mStart = case mStart of
  Nothing -> (0, Nothing)
  Just start ->
    let elapsed = max 0 (now - start)
    in if elapsed >= shakeDur
      then (0, Nothing)
      else
        let t = fromIntegral elapsed / fromIntegral shakeDur :: Float
        in (floor (sin (pi * t) * (1.0 - t) * shakeAmp), Just start)

-- * Deterministic test probes

-- | Deterministic probe over an eased 'Tween', sampled at arbitrary times (the
-- 'Tween' is stateless, so call order does not matter). Used by tests.
-- Mirrors @EaseProbe@.
data EaseProbe = EaseProbe
  { epTween :: !Tween
  }

-- | Eased value at @ms@ milliseconds into the tween. Mirrors @EaseProbe::now@.
easeNow :: EaseProbe -> Int -> Float
easeNow (EaseProbe t) ms = tweenSample t ms

-- | Eased A→B over @durMs@ with 'EaseOut' (front-loads: mid value > 0.5).
-- Mirrors @ease_ratio@.
easeRatio :: Clock -> Float -> Float -> Int -> EaseProbe
easeRatio _clock from to durMs =
  EaseProbe (tweenEasing EaseOut (tween from to durMs))

-- | Deterministic damped-sine shake probe: zero at the start, zero after the
-- duration, nonzero mid-flight. Used by tests. Mirrors @ShakeProbe@.
data ShakeProbe = ShakeProbe
  { spDurMs :: !Int
  }

-- | Shake offset at @ms@ milliseconds into the shake. Mirrors
-- @ShakeProbe::now@.
shakeNow :: ShakeProbe -> Int -> Float
shakeNow (ShakeProbe durMs) ms =
  let t = max 0.0 (min 1.0 (fromIntegral ms / fromIntegral durMs)) :: Float
  in sin (pi * t) * (1.0 - t) * shakeAmp

-- | A one-shot shake of @durMs@ (damped sine, amplitude 'shakeAmp'). Mirrors
-- @shake_at@.
shakeAt :: Clock -> Int -> ShakeProbe
shakeAt _clock durMs = ShakeProbe durMs