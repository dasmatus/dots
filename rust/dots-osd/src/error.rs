//! Every way this crate can fail, said out loud.
//!
//! A concrete enum rather than a boxed dynamic error, because the caller is a
//! keybind: there is no terminal reading the message, only the journal, and
//! "volume failed" in a journal is worthless. Each variant here carries the
//! part a person would need to fix it: which program, what it exited with,
//! what it printed, and a `help` line saying where to look.
//!
//! The shell-outs are the reason this file exists at all. A child process that
//! exits non-zero has already explained itself on stderr, and throwing that
//! away to report "command failed" turns a solved problem back into a mystery.

use std::process::ExitStatus;

use miette::Diagnostic;
use thiserror::Error;

/// A failure worth a diagnostic.
#[derive(Debug, Error, Diagnostic)]
pub enum Error {
    /// The program is not on `PATH`.
    ///
    /// Distinct from a program that ran and failed, because the fix is
    /// different in kind: one is a packaging mistake, the other is a runtime
    /// condition.
    #[error("`{program}` could not be run")]
    #[diagnostic(
        code(dots_osd::missing_program),
        help("`{program}` is not on this process's PATH. A systemd user unit does not inherit a login shell's PATH. Check that nix/home/dots-osd.nix puts it in home.packages.")
    )]
    MissingProgram {
        program: String,
        #[source]
        source: std::io::Error,
    },

    /// The program ran and refused.
    ///
    /// `ExitStatus` rather than a bare code, because its `Display` already
    /// spells out the signal case (`signal: 9 (SIGKILL)`) that a code alone
    /// cannot represent.
    #[error("`{program}` failed, {status}")]
    #[diagnostic(code(dots_osd::command_failed))]
    CommandFailed {
        program: String,
        status: ExitStatus,
        /// Whatever the child said on the way out, surfaced as the help line
        /// rather than dropped. `None` only when it said nothing at all on
        /// either stream.
        #[help]
        detail: Option<String>,
    },

    /// A reading that had to be there was not.
    #[error("could not read {what}")]
    #[diagnostic(
        code(dots_osd::unreadable),
        help("The command reported success but its output did not parse, which usually means the audio or backlight device went away between setting it and reading it back.")
    )]
    Unreadable { what: String },

    /// Hyprland reports no touchpad.
    #[error("no touchpad among Hyprland's input devices")]
    #[diagnostic(
        code(dots_osd::no_touchpad),
        help("Run `hyprctl devices -j` and look at the `mice` list. A touchpad is matched on its name containing `touchpad` or `trackpad`; a device named some other way will not be found.")
    )]
    NoTouchpad,

    /// The touchpad's remembered state could not be written.
    #[error("could not record the touchpad state at {path}")]
    #[diagnostic(
        code(dots_osd::runtime_state),
        help("Hyprland cannot be asked whether a device is enabled, so the answer is kept here. Without it, the next toggle cannot know which way to go.")
    )]
    RuntimeState {
        path: String,
        #[source]
        source: std::io::Error,
    },

    /// Nothing to send notifications to.
    #[error("could not reach the notification daemon")]
    #[diagnostic(
        code(dots_osd::no_notifier),
        help("Needs a session bus with something owning org.freedesktop.Notifications, which in this configuration is dunst. Check `systemctl --user status dunst`.")
    )]
    Notifier {
        #[source]
        source: zbus::Error,
    },
}

/// This crate's result type.
pub type Result<T> = std::result::Result<T, Error>;
