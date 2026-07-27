//! Animation overlay for the installer TUI. All motion is opt-in and collapses
//! to a no-op when `DOTS_NO_ANIM` is set; the caller also gates on terminal
//! capabilities (`use_caps`) so raw `tty1` degrades to instant cuts.
//!
//! `ScreenFx` wraps abstracttui's `Transition` (retargetable eased motion) for
//! the panel slide and the progress fill, plus a damped-sine error shake. The
//! free helpers `ease_ratio` / `shake_at` expose the underlying math to unit
//! tests via a deterministic `Clock::fixed`.

use std::time::Duration;

use abstracttui::anim::{Clock, Easing, Transition, Tween};
use abstracttui::reactive::request_frame;

/// True unless `DOTS_NO_ANIM` is set.
#[must_use]
pub fn animations_enabled() -> bool {
    std::env::var("DOTS_NO_ANIM").is_err()
}

const SCREEN_DUR: Duration = Duration::from_millis(180);
const PROGRESS_DUR: Duration = Duration::from_millis(160);
const SHAKE_DUR: Duration = Duration::from_millis(120);
const SHAKE_AMP: f32 = 8.0;

/// Live, retargetable motion for the wizard panel + progress bar, plus a
/// one-shot error shake. Held in a `Signal<ScreenFx>` in the root scope.
pub struct ScreenFx {
    clock: Clock,
    screen_offset: Transition<f32>,
    progress: Transition<f32>,
    shake_start: Option<Duration>,
}

impl ScreenFx {
    /// New overlay on the given (real, in production) clock.
    #[must_use]
    pub fn new(clock: Clock) -> Self {
        Self {
            clock,
            screen_offset: Transition::new(0.0, SCREEN_DUR, Easing::EaseOut),
            progress: Transition::new(0.0, PROGRESS_DUR, Easing::EaseOut),
            shake_start: None,
        }
    }

    /// Retarget the panel slide x-offset (called on `Screen` change).
    pub fn retarget_screen(&mut self, to: f32) {
        if !animations_enabled() {
            return;
        }
        self.screen_offset.set_target(to, self.clock.now());
        request_frame();
    }

    /// Retarget the eased progress fill (called when the install step changes).
    pub fn retarget_progress(&mut self, ratio: f32) {
        if !animations_enabled() {
            return;
        }
        self.progress.set_target(ratio, self.clock.now());
        request_frame();
    }

    /// Fire a one-shot error shake (called when `app.error` becomes `Some`).
    pub fn shake(&mut self) {
        if !animations_enabled() {
            return;
        }
        self.shake_start = Some(self.clock.now());
        request_frame();
    }

    /// Current eased panel x-offset. Advances the transition to `now`.
    pub fn screen_offset(&mut self) -> f32 {
        self.screen_offset.tick(self.clock.now())
    }

    /// Current eased progress ratio (0.0..=1.0). Advances the transition to `now`.
    pub fn progress_ratio(&mut self) -> f32 {
        self.progress.tick(self.clock.now())
    }

    /// Current shake x-offset in cells; zero when no shake is in flight or it
    /// has settled. Clears the one-shot once `SHAKE_DUR` elapses.
    #[allow(clippy::cast_possible_truncation)]
    pub fn shake_offset(&mut self) -> i32 {
        let Some(start) = self.shake_start else {
            return 0;
        };
        let elapsed = self.clock.now().saturating_sub(start);
        if elapsed >= SHAKE_DUR {
            self.shake_start = None;
            return 0;
        }
        let t = elapsed.as_secs_f32() / SHAKE_DUR.as_secs_f32();
        ((std::f32::consts::PI * t).sin() * (1.0 - t) * SHAKE_AMP) as i32
    }
}

/// Deterministic probe over an eased `Tween`, sampled at arbitrary times (the
/// `Tween` is stateless, so call order does not matter). Used by tests.
pub struct EaseProbe {
    t: Tween<f32>,
}

impl EaseProbe {
    /// Eased value at `ms` milliseconds into the tween.
    #[must_use]
    pub fn now(&self, ms: u64) -> f32 {
        self.t.sample(Duration::from_millis(ms))
    }
}

/// Eased A→B over `dur_ms` with `EaseOut` (front-loads: mid value > 0.5).
#[must_use]
pub fn ease_ratio(_clock: Clock, from: f32, to: f32, dur_ms: u64) -> EaseProbe {
    EaseProbe {
        t: Tween::new(from, to, Duration::from_millis(dur_ms)).with_easing(Easing::EaseOut),
    }
}

/// Deterministic damped-sine shake probe: zero at the start, zero after the
/// duration, nonzero mid-flight. Used by tests.
pub struct ShakeProbe {
    dur_ms: u64,
}

impl ShakeProbe {
    /// Shake offset at `ms` milliseconds into the shake.
    #[must_use]
    #[allow(clippy::cast_precision_loss)]
    pub fn now(&self, ms: u64) -> f32 {
        let t = (ms as f32 / self.dur_ms as f32).clamp(0.0, 1.0);
        (std::f32::consts::PI * t).sin() * (1.0 - t) * SHAKE_AMP
    }
}

/// A one-shot shake of `dur_ms` (damped sine, amplitude `SHAKE_AMP`).
#[must_use]
pub fn shake_at(_clock: Clock, dur_ms: u64) -> ShakeProbe {
    ShakeProbe { dur_ms }
}
