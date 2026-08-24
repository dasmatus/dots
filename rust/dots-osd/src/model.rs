//! What a notification *is*, with no idea how it reaches a screen.
//!
//! Everything the rest of the crate decides, whether it's which reading changed,
//! which threshold was crossed, or what a keypress did, ends as one of these. Keeping
//! it plain data is what lets [`crate::watch`] be tested against two snapshots
//! and a list of expected notifications, on a machine with no session bus, no
//! notification daemon and no battery.

/// How loudly a notification asks to be read.
///
/// The numbers are the values the freedesktop `urgency` hint carries, and
/// dunst's `urgency_low`/`urgency_normal`/`urgency_critical` sections are keyed
/// on them. Critical is the one that never times out, so it is reserved for
/// readings a person would want to act on rather than merely know.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Urgency {
    Low = 0,
    Normal = 1,
    Critical = 2,
}

impl Urgency {
    /// The hint value.
    #[must_use]
    pub const fn hint(self) -> u8 {
        self as u8
    }
}

/// How long a notification should stay up.
///
/// A separate axis from [`Urgency`], because the two answer different
/// questions: urgency is how much it matters, this is how long you need to see
/// it. A volume bar is unimportant *and you are looking straight at it*; a lost
/// network is equally unimportant and you are not.
///
/// Sent as the freedesktop `expire_timeout` rather than left to the daemon's
/// per-urgency defaults. That is deliberate: dunst applies its rules and its
/// `[urgency_*]` sections in file order, and Home Manager renders those
/// sections alphabetically, so a rule of ours would land before
/// `[urgency_critical]` and lose to it. A timeout the notification carries
/// itself is not subject to any of that, and it keeps the decision next to the
/// code that knows which kind of notification this is.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum Linger {
    /// You caused this and are looking at the screen. Long enough to read a
    /// percentage, short enough that ten keypresses do not bury the desktop.
    Brief,
    /// You did not cause it and may look over in a moment.
    #[default]
    Normal,
    /// You should probably do something about it.
    Long,
}

impl Linger {
    /// The `expire_timeout` value, in milliseconds.
    #[must_use]
    pub const fn milliseconds(self) -> i32 {
        match self {
            Self::Brief => 2_000,
            Self::Normal => 8_000,
            Self::Long => 15_000,
        }
    }
}

/// One thing worth telling the user.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Notification {
    pub summary: String,
    pub body: String,
    /// A freedesktop icon name, resolved by the notification daemon against its
    /// icon theme. Never a path: which theme dresses these is the desktop's
    /// choice, not this crate's.
    ///
    /// Every name used by this crate was checked to exist in the Adwaita theme
    /// in this closure, so the names are right. Whether one *renders* is a
    /// separate question that currently answers no. Dunst here resolves no
    /// icon by name at all, for any theme, and the reason was not tracked down
    /// (see the note in `nix/home/dunst.nix`). That fault predates this crate
    /// and costs a notification its icon and nothing else, so the names stay:
    /// they are what any working daemon expects, and they cost nothing to send.
    pub icon: &'static str,
    pub urgency: Urgency,
    /// A percentage, when the reading is a proportion worth drawing as a bar.
    ///
    /// Becomes the `value` hint, which is what makes dunst render its progress
    /// bar. A volume boosted past 100% clamps here rather than overflowing the
    /// bar, because the number in the body still tells the truth.
    pub value: Option<u8>,
    /// Which slot on screen this notification owns.
    ///
    /// Sent as `x-dunst-stack-tag`, so holding the volume key down replaces one
    /// notification eleven times instead of stacking eleven of them. Metrics
    /// that should coexist, such as a VPN drop while the disk is filling, carry
    /// different tags.
    pub tag: &'static str,
    pub linger: Linger,
}

impl Notification {
    /// A notification at normal urgency with no bar.
    #[must_use]
    pub fn new(tag: &'static str, icon: &'static str, summary: impl Into<String>) -> Self {
        Self {
            summary: summary.into(),
            body: String::new(),
            icon,
            urgency: Urgency::Normal,
            value: None,
            tag,
            linger: Linger::Normal,
        }
    }

    /// Show it just long enough to read, because the reader is already looking.
    #[must_use]
    pub const fn brief(mut self) -> Self {
        self.linger = Linger::Brief;
        self
    }

    /// Leave it up long enough to be noticed by someone who was not watching.
    #[must_use]
    pub const fn long(mut self) -> Self {
        self.linger = Linger::Long;
        self
    }

    #[must_use]
    pub fn body(mut self, body: impl Into<String>) -> Self {
        self.body = body.into();
        self
    }

    #[must_use]
    pub const fn urgency(mut self, urgency: Urgency) -> Self {
        self.urgency = urgency;
        self
    }

    /// Draw a bar at `percent`, clamped to the range a bar can show.
    #[must_use]
    pub fn value(mut self, percent: u16) -> Self {
        self.value = Some(u8::try_from(percent.min(100)).unwrap_or(100));
        self
    }
}
