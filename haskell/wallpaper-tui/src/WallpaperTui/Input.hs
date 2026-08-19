-- | Engine-agnostic key-event types for the wallpaper picker state machine.
--
-- 'WallpaperTui.App.handleKey' is a pure transition function deliberately kept
-- free of any TUI engine dependency, so the state machine stays testable
-- without a terminal. The 'WallpaperTui.Ui' on-event bridge converts
-- abstracttui's key events into these at the bridge; tests construct them
-- directly. The variant set covers every key the picker reacts to:
-- @q@\/@Esc@, @j@\/@Down@, @k@\/@Up@, @Enter@, @m@, @c@, @o@, @p@, @r@ — all
-- reachable via 'Char' + the named variants. Mirrors @rust/wallpaper-tui/
-- src/input.rs@.
module WallpaperTui.Input
  ( KeyCode (..)
  , KeyEvent (..)
  ) where

-- | The subset of keys the picker reacts to.
data KeyCode
  = -- | A printable key (@q@, @j@, @k@, @m@, @c@, @o@, @p@, @r@, …).
    Char !Char
  | -- | ↵.
    Enter
  | -- | @Esc@.
    Esc
  | -- | ⌫.
    Backspace
  | -- | ↑.
    Up
  | -- | ↓.
    Down
  deriving (Show, Eq, Ord)

-- | An engine-agnostic key event — a 'KeyCode' with no modifier state (the
-- picker binds single keys only).
data KeyEvent = KeyEvent
  { -- | Which key.
    keyCode :: !KeyCode
  }
  deriving (Show, Eq, Ord)