//! Engine-agnostic key-event types for the wizard state machine.
//!
//! `App::handle_key` is a pure transition function deliberately kept free of
//! any TUI engine dependency, so the state machine stays unit-testable without
//! a terminal. `main.rs` converts abstracttui's key events into these at the
//! bridge; tests construct them directly.

/// The subset of keys the wizard reacts to. Variant names mirror the
/// `crossterm` names the tests already use, so existing call sites are
/// unchanged.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeyCode {
    Char(char),
    Enter,
    Esc,
    Backspace,
    Up,
    Down,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KeyEvent {
    pub code: KeyCode,
}

impl From<KeyCode> for KeyEvent {
    fn from(code: KeyCode) -> Self {
        Self { code }
    }
}
