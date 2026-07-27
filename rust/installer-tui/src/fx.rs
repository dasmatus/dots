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
///
/// The transitions are advanced once per frame by `tick` (called from the
/// app loop) and the eased results cached in `screen_x` / `progress_r` /
/// `shake_x`. The view reads those caches via the `&self` peek methods — it
/// never mutates the signal during render, which keeps the reactive damage
/// contract clean (no write-during-read re-render storms).
#[derive(Clone)]
pub struct ScreenFx {
    clock: Clock,
    screen_offset: Transition<f32>,
    progress: Transition<f32>,
    shake_start: Option<Duration>,
    /// Cached eased panel x-offset, refreshed by `tick`.
    screen_x: f32,
    /// Cached eased progress ratio, refreshed by `tick`.
    progress_r: f32,
    /// Cached shake x-offset in cells, refreshed by `tick`.
    shake_x: i32,
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
            screen_x: 0.0,
            progress_r: 0.0,
            shake_x: 0,
        }
    }

    /// Retarget the panel slide x-offset (called on `Screen` change).
    pub fn retarget_screen(&mut self, to: f32) {
        if !animations_enabled() {
            return;
        }
        self.retarget_screen_force(to);
    }

    /// Retarget the eased progress fill (called when the install step changes).
    pub fn retarget_progress(&mut self, ratio: f32) {
        if !animations_enabled() {
            return;
        }
        self.retarget_progress_force(ratio);
    }

    /// Fire a one-shot error shake (called when `app.error` becomes `Some`).
    pub fn shake(&mut self) {
        if !animations_enabled() {
            return;
        }
        self.shake_force();
    }

    /// Ungated panel retarget — the primitive `retarget_screen` delegates to.
    /// Tests use this directly so they don't race with the env-mutating
    /// `animations_enabled` test (tests run in parallel threads sharing one
    /// process env).
    pub fn retarget_screen_force(&mut self, to: f32) {
        self.screen_offset.set_target(to, self.clock.now());
        request_frame();
    }

    /// Ungated progress retarget — see `retarget_screen_force`.
    pub fn retarget_progress_force(&mut self, ratio: f32) {
        self.progress.set_target(ratio, self.clock.now());
        request_frame();
    }

    /// Ungated shake fire — see `retarget_screen_force`.
    pub fn shake_force(&mut self) {
        self.shake_start = Some(self.clock.now());
        request_frame();
    }

    /// Advance every transition to the clock's `now` and cache the eased
    /// values. The app loop calls this once per frame; tests drive it via
    /// `advance` on a `Clock::fixed`. Re-requests a frame while anything is
    /// still in flight so the loop keeps pumping until motion settles.
    #[allow(clippy::float_cmp)]
    pub fn tick(&mut self) {
        let now = self.clock.now();
        self.screen_x = self.screen_offset.tick(now);
        self.progress_r = self.progress.tick(now);
        self.shake_x = self.shake_offset_at(now);
        let flying = self.screen_offset.value() != self.screen_offset.target()
            || self.progress.value() != self.progress.target();
        if self.shake_start.is_some() || flying {
            request_frame();
        }
    }

    /// Advance the clock by `dur` then `tick`. The deterministic door tests
    /// use with `Clock::fixed` (the real loop uses `Clock::real` + `tick`).
    pub fn advance(&mut self, dur: Duration) {
        self.clock.advance(dur);
        self.tick();
    }

    /// Cached eased panel x-offset (cells). Peek, no mutation.
    #[must_use]
    pub fn screen_x(&self) -> f32 {
        self.screen_x
    }

    /// Cached eased progress ratio (0.0..=1.0). Peek, no mutation.
    #[must_use]
    pub fn progress_r(&self) -> f32 {
        self.progress_r
    }

    /// Cached shake x-offset (cells). Peek, no mutation.
    #[must_use]
    pub fn shake_x(&self) -> i32 {
        self.shake_x
    }

    /// Current shake x-offset at `now`; clears the one-shot once `SHAKE_DUR`
    /// elapses. Internal helper for `tick`.
    #[allow(clippy::cast_possible_truncation)]
    fn shake_offset_at(&mut self, now: Duration) -> i32 {
        let Some(start) = self.shake_start else {
            return 0;
        };
        let elapsed = now.saturating_sub(start);
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
