//! Engine-agnostic key-event types for the wallpaper picker state machine.
//!
//! [`crate::app::App::handle_key`] is a pure transition function deliberately
//! kept free of any TUI engine dependency, so the state machine stays testable
//! without a terminal. `main.rs` converts abstracttui's key events into these
//! at the bridge; tests construct them directly. The variant set covers every
//! key the picker reacts to: `q`/`Esc`, `j`/`Down`, `k`/`Up`, `Enter`, `m`, `c`,
//! `o`, `p`, `r` — all reachable via `Char` + the named variants.

/// The subset of keys the picker reacts to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyCode {
    /// A printable key (`q`, `j`, `k`, `m`, `c`, `o`, `p`, `r`, …).
    Char(char),
    /// ↵.
    Enter,
    /// `Esc`.
    Esc,
    /// ⌫.
    Backspace,
    /// ↑.
    Up,
    /// ↓.
    Down,
}

/// An engine-agnostic key event — a [`KeyCode`] with no modifier state (the
/// picker binds single keys only).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeyEvent {
    /// Which key.
    pub code: KeyCode,
}

impl From<KeyCode> for KeyEvent {
    fn from(code: KeyCode) -> Self {
        Self { code }
    }
}
