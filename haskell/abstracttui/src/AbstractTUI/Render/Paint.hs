-- | Pure ink → 'V.Image' rendering. Bridges the abstracttui ink model
-- ("AbstractTUI.Render.Style": 'Style'/'Span'/'RichLine'/'RichText') to vty
-- 'V.Attr'/'V.Image' so the 'RichTextView' widget (and any pure-render path)
-- can turn a 'RichText' block into a 'V.Image' with 'tellImages'.
--
-- This is the module "AbstractTUI.Layout.Style" references as the paint
-- layer. It is deliberately pure (no Reflex/vty-widget imports): a widget
-- calls 'renderRichText' inside a 'Behavior' and 'tellImages' the result, so
-- re-render is automatic when the underlying signal 'Dynamic' fires.
module AbstractTUI.Render.Paint
  ( rgbaColor
  , rgbaAttr
  , styleAttr
  , renderRichText
  , renderRichTextImages
  , renderLine
  ) where

import qualified Data.Text as T
import qualified Graphics.Vty as V

import AbstractTUI.Base.Color (Rgba (..))
import AbstractTUI.Render.Style
  ( RichLine (..)
  , RichText (..)
  , Span (..)
  , Style (..)
  , wrap
  )

-- | True-colour 'V.Color' from an 'Rgba'. The alpha channel is dropped —
-- terminal ink is always opaque; alpha is only meaningful for the mosaic
-- 'Image' widget's bitmap blend.
rgbaColor :: Rgba -> V.Color
rgbaColor c = V.rgbColor (rgbaR c) (rgbaG c) (rgbaB c)

-- | A foreground-only 'V.Attr' from an 'Rgba'.
rgbaAttr :: Rgba -> V.Attr
rgbaAttr c = V.withForeColor V.defAttr (rgbaColor c)

-- | The full 'V.Attr' for an ink 'Style': fg/bg true colours plus the
-- bold/dim/italic/underline/invert attribute bits. Unset fg/bg defer to the
-- terminal default ('V.defAttr'), matching abstracttui's "absent ink = inherit
-- the cell's current ink" behaviour.
styleAttr :: Style -> V.Attr
styleAttr s =
  applyFg (stFg s) . applyBg (stBg s) $ applyFlags
  where
    applyFg (Just c) a = V.withForeColor a (rgbaColor c)
    applyFg Nothing  a = a
    applyBg (Just c) a = V.withBackColor a (rgbaColor c)
    applyBg Nothing  a = a
    applyFlags =
      foldr ($) V.defAttr
        [ flagIf stBold V.bold
        , flagIf stDim V.dim
        , flagIf stItalic V.italic
        , flagIf stUnderline V.underline
        , flagIf stInvert V.reverseVideo
        ]
    flagIf sel bit a = if sel s then V.withStyle a bit else a

-- | Render a 'RichText' block as a single 'V.Image', hard-wrapped to
-- @maxWidth@ columns. Each line is the horizontal concatenation of its spans
-- (each span painted with its own ink via 'styleAttr'); lines are vertically
-- concatenated. An empty block yields 'V.emptyImage' (the caller controls
-- content and sizes its container separately).
renderRichText :: RichText -> Int -> V.Image
renderRichText rt maxWidth =
  V.vertCat (map renderLine (rtLines (wrap rt maxWidth)))

-- | 'renderRichText' as a layer list (one image), the shape 'tellImages'
-- expects.
renderRichTextImages :: RichText -> Int -> [V.Image]
renderRichTextImages rt maxWidth = [renderRichText rt maxWidth]

-- | Render one 'RichLine' as a 'V.Image': the horizontal concatenation of its
-- spans. An empty line is a zero-width 'V.text'' so a stack of blank lines
-- still has the right row count.
renderLine :: RichLine -> V.Image
renderLine (RichLine ss)
  | null ss = V.text' V.defAttr T.empty
  | otherwise = V.horizCat (map renderSpan ss)

renderSpan :: Span -> V.Image
renderSpan (Span t ink _) = V.text' (styleAttr ink) t