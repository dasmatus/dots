-- | Engine-agnostic key-event types for the wizard state machine.
--
-- 'handleKey' is a pure transition function deliberately kept free of any TUI
-- engine dependency, so the state machine stays unit-testable without a
-- terminal. "Dots.Installer.Ui" converts abstracttui's key events into these at
-- the bridge; tests construct them directly. Mirrors @rust/installer-tui/src/input.rs@.
module Dots.Installer.Input
  ( KeyCode (..)
  , KeyEvent (..)
  ) where

-- | The subset of keys the wizard reacts to. Variant names mirror the
-- crossterm names the Rust tests already use, so existing call sites are
-- unchanged.
data KeyCode
  = KeyChar Char
  | KeyEnter
  | KeyEsc
  | KeyBackspace
  | KeyUp
  | KeyDown
  deriving (Show, Eq, Ord)

-- | A single key event, carrying only the 'KeyCode'.
newtype KeyEvent = KeyEvent { keCode :: KeyCode }
  deriving (Show, Eq)