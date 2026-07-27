//! Animation overlay for the wallpaper TUI: a re-triggerable preview
//! crossfade. All motion is opt-in and collapses to a no-op when
//! `DOTS_NO_ANIM` is set; the caller also gates on terminal capabilities
//! (`use_caps`) so raw VTs degrade to instant cuts.
//!
//! The crossfade is a one-shot 0→1 opacity ramp re-triggered on every
//! selection change. The view blends the new preview `Bitmap` toward the pane
//! background by the cached opacity (see [`blend_bitmap`]) — the `Image` widget
//! itself paints opaque mosaic cells, so the fade happens at the pixel level
//! before the mosaic renderer. The free helpers [`crossfade_curve`] /
//! [`blend_bitmap`] expose the math to unit tests via a deterministic
//! `Clock::fixed`.

use std::time::Duration;

use abstracttui::anim::{Clock, Easing, Tween};
use abstracttui::base::Rgba;
use abstracttui::gfx::Bitmap;
use abstracttui::reactive::request_frame;

/// True unless `DOTS_NO_ANIM` is set.
#[must_use]
pub fn animations_enabled() -> bool {
    std::env::var("DOTS_NO_ANIM").is_err()
}

const CROSSFADE_DUR: Duration = Duration::from_millis(150);

/// Live, re-triggerable preview crossfade. Held in a `Signal<Fx>` in the root
/// scope.
///
/// The opacity ramp is advanced once per frame by [`Fx::tick`] (called from the
/// app loop) and the eased result cached in `opacity`. The view reads that
/// cache via [`Fx::crossfade_opacity`] — it never mutates the signal during
/// render, which keeps the reactive damage contract clean (no write-during-read
/// re-render storms).
#[derive(Clone)]
pub struct Fx {
    clock: Clock,
    crossfade_start: Option<Duration>,
    /// Cached eased crossfade opacity (0.0..=1.0), refreshed by `tick`.
    opacity: f32,
}

impl Fx {
    /// New overlay on the given (real, in production) clock.
    #[must_use]
    pub fn new(clock: Clock) -> Self {
        Self {
            clock,
            crossfade_start: None,
            opacity: 1.0,
        }
    }

    /// Re-trigger the preview crossfade (called on selection change). A no-op
    /// when animations are disabled.
    pub fn retarget_crossfade(&mut self) {
        if !animations_enabled() {
            return;
        }
        self.retarget_crossfade_force();
    }

    /// Ungated crossfade re-trigger — the primitive `retarget_crossfade`
    /// delegates to. Tests use this directly so they don't race with the
    /// env-mutating `animations_enabled` test (tests run in parallel threads
    /// sharing one process env).
    pub fn retarget_crossfade_force(&mut self) {
        self.crossfade_start = Some(self.clock.now());
        request_frame();
    }

    /// Advance the ramp to the clock's `now` and cache the eased opacity. The
    /// app loop calls this once per frame; tests drive it via [`Fx::advance`] on
    /// a `Clock::fixed`. Re-requests a frame while the fade is in flight so the
    /// loop keeps pumping until it settles.
    pub fn tick(&mut self) {
        let now = self.clock.now();
        self.opacity = self.opacity_at(now);
        if self.crossfade_start.is_some() {
            request_frame();
        }
    }

    /// Advance the clock by `dur` then `tick`. The deterministic tests use this
    /// with `Clock::fixed` (the real loop uses `Clock::real` + `tick`).
    pub fn advance(&mut self, dur: Duration) {
        self.clock.advance(dur);
        self.tick();
    }

    /// Cached eased crossfade opacity (0.0..=1.0). Peek, no mutation.
    #[must_use]
    pub fn crossfade_opacity(&self) -> f32 {
        self.opacity
    }

    /// Eased opacity at `now`; clears the one-shot once `CROSSFADE_DUR` elapses
    /// (leaving opacity pinned at 1.0). Internal helper for `tick`.
    fn opacity_at(&mut self, now: Duration) -> f32 {
        let Some(start) = self.crossfade_start else {
            return 1.0;
        };
        let elapsed = now.saturating_sub(start);
        if elapsed >= CROSSFADE_DUR {
            self.crossfade_start = None;
            return 1.0;
        }
        // EaseOut: front-loads the fade so the new preview reads fast, then
        // settles gently — matches the installer's progress easing.
        Tween::new(0.0_f32, 1.0, CROSSFADE_DUR)
            .with_easing(Easing::EaseOut)
            .sample(elapsed)
            .clamp(0.0, 1.0)
    }
}

/// Blend `bmp` toward `bg` by `opacity` (0.0 → fully `bg`, 1.0 → fully `bmp`),
/// returning a fresh `Bitmap`. Used by the view to render the crossfade: feed
/// the blended bitmap to `Image::from_bitmap` while [`Fx::crossfade_opacity`]
/// is in flight. Cheap for a thumbnail (a few thousand px) over a ~150 ms fade.
#[must_use]
pub fn blend_bitmap(bmp: &Bitmap, bg: Rgba, opacity: f32) -> Bitmap {
    let t = opacity.clamp(0.0, 1.0);
    let mut out = Bitmap::new(bmp.width(), bmp.height(), bg);
    for (dst, src) in out.pixels_mut().iter_mut().zip(bmp.pixels()) {
        *dst = bg.lerp(*src, t);
    }
    out
}

/// Deterministic probe over the crossfade `Tween`, sampled at arbitrary times
/// (the `Tween` is stateless, so call order does not matter). Used by tests.
pub struct CrossfadeProbe {
    t: Tween<f32>,
}

impl CrossfadeProbe {
    /// Eased opacity at `ms` milliseconds into the fade.
    #[must_use]
    pub fn now(&self, ms: u64) -> f32 {
        self.t.sample(Duration::from_millis(ms))
    }
}

/// Eased 0→1 over `dur_ms` with `EaseOut`. The property tested: 0 at the start,
/// 1 at the duration, strictly between mid-fade.
#[must_use]
pub fn crossfade_curve(_clock: Clock, dur_ms: u64) -> CrossfadeProbe {
    CrossfadeProbe {
        t: Tween::new(0.0_f32, 1.0, Duration::from_millis(dur_ms)).with_easing(Easing::EaseOut),
    }
}
