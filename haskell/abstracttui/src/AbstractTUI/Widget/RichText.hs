-- | The 'RichTextView' widget — renders a 'RichText' block (styled spans) into
-- the current display region. Mirrors @abstracttui::widgets::RichTextView@.
--
-- 'RichText' spans carry their own ink ('AbstractTUI.Render.Style.Style' with
-- explicit 'Rgba' fg/bg), so — unlike 'AbstractTUI.Widget.Block' — this widget
-- takes no 'TokenSet': the @.element(tokens)@ form in the Rust API exists only
-- for parity and is unused. This is the engine's
-- "no color arithmetic in widgets" rule: colours are resolved at construction
-- time, not render time.
--
-- The widget is pure-render: it 'tellImages' a 'Behavior' built from
-- 'current' 'displayWidth', so it re-renders automatically on resize (and on
-- any signal 'Dynamic' change when used inside 'dyn_view'). No 'dyn'/
-- 'switchHold' is needed.
module AbstractTUI.Widget.RichText
  ( richTextView
  , richTextView'
  ) where

import Reflex (current, never)
import Reflex.Vty.Widget (displayWidth, tellImages)

import AbstractTUI.Render.Paint (renderRichTextImages)
import AbstractTUI.Render.Style (RichText)
import AbstractTUI.View (View (..))

-- | Render a 'RichText' block, wrapped to the current display width. The
-- @.view(cx)@ path: theme comes from the spans' own ink, so no 'Scope' is
-- needed.
richTextView :: RichText -> View t
richTextView rt = richTextView' rt

-- | 'richTextView' with an explicit (unused) 'TokenSet' slot — the
-- @.element(&tokens)@ door. Kept so ports read faithfully; the tokens are
-- ignored because the spans carry their own ink.
richTextView' :: RichText -> View t
richTextView' rt =
  ViewRaw $ do
    dw <- displayWidth
    tellImages ((\w -> renderRichTextImages rt w) <$> current dw)
    pure never