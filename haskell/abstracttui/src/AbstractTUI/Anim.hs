-- | Animation primitives. Mirrors @abstracttui::anim::{Clock,Tween,Transition,Easing}@.
-- The installer and wallpaper apps drive their screen-shake + crossfade from
-- these: a 'Transition' eases a value (the shake offset, the crossfade
-- opacity) toward a target, and a 'Tween' is a one-shot from→to curve (the
-- progress-bar ease). A 'Clock' abstracts "what time is it" so tests run
-- deterministically with 'clockFixed' + 'clockAdvance' and the live app uses
-- 'clockReal'.
module AbstractTUI.Anim
  ( Easing (..)
  , ease
  , Clock
  , ClockMode (..)
  , clockFixed
  , clockReal
  , clockNow
  , clockAdvance
  , Tween
  , tween
  , tweenEasing
  , tweenSample
  , Transition
  , transition
  , transitionSetTarget
  , transitionTick
  , transitionValue
  , transitionTarget
  ) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Time.Clock.POSIX (getPOSIXTime)

-- | The easing curve. Only 'EaseOut' is exercised by the apps; 'Linear' is
-- included for completeness and the spike.
data Easing = Linear | EaseOut
  deriving (Show, Eq)

-- | Apply an easing curve to a normalized progress @p ∈ [0,1]@.
ease :: Easing -> Float -> Float
ease Linear p = p
ease EaseOut p = 1 - (1 - p) * (1 - p)

-- * Clock

-- | The time source. 'Fixed' clocks read only the accumulated 'clockAdvance'
-- (deterministic); 'Real' clocks read wall time since creation plus the
-- advance offset (the apps add nothing in production, so this is just wall
-- time). Time is in milliseconds throughout.
data ClockMode = Fixed | Real
  deriving (Show, Eq)

data Clock = Clock
  { ckMode :: !ClockMode
  , ckStart :: !Int
  , ckOffset :: !(IORef Int)
  }

-- | A deterministic clock pinned at 0; only 'clockAdvance' moves it. Tests use
-- this so a frame's easing curve is reproducible.
clockFixed :: IO Clock
clockFixed = do
  o <- newIORef 0
  pure Clock { ckMode = Fixed, ckStart = 0, ckOffset = o }

-- | A wall clock starting "now". 'clockNow' returns ms since creation.
clockReal :: IO Clock
clockReal = do
  o <- newIORef 0
  start <- systemMs
  pure Clock { ckMode = Real, ckStart = start, ckOffset = o }

-- | Current time in ms. For a 'Fixed' clock this is the accumulated advance;
-- for a 'Real' clock, wall ms since creation plus the advance offset.
clockNow :: Clock -> IO Int
clockNow ck = case ckMode ck of
  Fixed -> readIORef (ckOffset ck)
  Real -> do
    now <- systemMs
    extra <- readIORef (ckOffset ck)
    pure (now - ckStart ck + extra)

-- | Advance the clock by @ms@. For a 'Fixed' clock this is the only way time
-- moves; for a 'Real' clock it's an additive offset on top of wall time
-- (unused in production, harmless).
clockAdvance :: Clock -> Int -> IO ()
clockAdvance ck ms = modifyIORef' (ckOffset ck) (+ ms)

-- | Wall time in ms since the epoch (only 'clockReal' uses it).
systemMs :: IO Int
systemMs = do
  t <- getPOSIXTime
  pure (round (t * 1000))

-- * Tween

-- | A one-shot from→to curve over a duration. Sampled with 'tweenSample'
-- (clamped to [0, dur] then eased).
data Tween = Tween
  { twFrom :: !Float
  , twTo :: !Float
  , twDur :: !Int
  , twEasing :: !Easing
  }
  deriving (Show, Eq)

-- | @Tween::new(from, to, dur)@ — defaults to 'EaseOut' (the only easing the
-- apps use).
tween :: Float -> Float -> Int -> Tween
tween from to dur = Tween { twFrom = from, twTo = to, twDur = dur, twEasing = EaseOut }

tweenEasing :: Easing -> Tween -> Tween
tweenEasing e t = t { twEasing = e }

-- | Sample the tween at @now@ ms. Clamps to the duration so overshoot returns
-- the target. @EaseOut@ gives the apps' snappy "land early" feel.
tweenSample :: Tween -> Int -> Float
tweenSample t now =
  let dur = max 1 (twDur t)
      clamped = max 0 (min now dur)
      raw = fromIntegral clamped / fromIntegral dur
      p = ease (twEasing t) raw
   in twFrom t + (twTo t - twFrom t) * p

-- * Transition

-- | A value that eases toward a moving target. The apps hold a 'Transition'
-- in a signal and retarget it on screen change (the shake) or image change
-- (the crossfade opacity); each frame 'transitionTick' advances the eased
-- value and 'transitionValue' reads it for the view.
data Transition = Transition
  { trValue :: !Float
  , trTarget :: !Float
  , trFrom :: !Float
  , trStart :: !Int
  , trDur :: !Int
  , trEasing :: !Easing
  }
  deriving (Show, Eq)

-- | @Transition::new(initial, dur, easing)@ — starts at @initial@ with itself
-- as the target (so it's at rest until 'transitionSetTarget' moves it).
transition :: Float -> Int -> Easing -> Transition
transition initial dur e =
  Transition
    { trValue = initial
    , trTarget = initial
    , trFrom = initial
    , trStart = 0
    , trDur = dur
    , trEasing = e
    }

-- | Retarget: ease from the CURRENT value to @val@ starting at @now@. The
-- apps call this when the screen changes (a new shake) or the image swaps.
transitionSetTarget :: Float -> Int -> Transition -> Transition
transitionSetTarget val now tr = tr { trTarget = val, trFrom = trValue tr, trStart = now }

-- | Advance one tick to @now@ ms. Pure — returns the new 'Transition'; the
-- apps write it back into the fx signal. At rest once the duration elapses.
transitionTick :: Int -> Transition -> Transition
transitionTick now tr =
  let dur = max 1 (trDur tr)
      elapsed = max 0 (now - trStart tr)
      raw = min 1 (fromIntegral elapsed / fromIntegral dur)
      p = ease (trEasing tr) raw
      v = trFrom tr + (trTarget tr - trFrom tr) * p
   in tr { trValue = v }

-- | The eased value the view reads.
transitionValue :: Transition -> Float
transitionValue = trValue

-- | The value being eased toward (for the apps' "are we there yet" checks).
transitionTarget :: Transition -> Float
transitionTarget = trTarget