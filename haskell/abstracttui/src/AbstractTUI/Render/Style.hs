-- | Ink style + rich-text runs. Mirrors @abstracttui::render::{style,rich}@.
--
-- 'Style' here is the *ink* (foreground/background/attributes) — distinct from
-- "AbstractTUI.Layout.Style" (the layout style). The two are kept separate to
-- match the Rust crate's naming and to avoid an import cycle (layout doesn't
-- need ink; ink doesn't need geometry).
module AbstractTUI.Render.Style
  ( Style (..)
  , style
  , fg
  , bg
  , bold
  , dim
  , italic
  , underline
  , invert
  , noInk
  , Span (..)
  , RichLine (..)
  , richLine
  , fromSpans
  , push
  , RichText (..)
  , richText
  , fromLines
  , plain
  , plainText
  , rtHeight
  , rtWidth
  , wrap
  ) where

import Data.Text (Text)
import qualified Data.Text as T

import AbstractTUI.Base.Color (Rgba)

-- | The ink applied to a span of text. Attributes are boolean flags so a
-- 'Monoid'-like builder (fg . bg . bold) composes naturally.
data Style = Style
  { stFg :: !(Maybe Rgba)
  , stBg :: !(Maybe Rgba)
  , stBold :: !Bool
  , stDim :: !Bool
  , stItalic :: !Bool
  , stUnderline :: !Bool
  , stInvert :: !Bool
  }
  deriving (Show, Eq)

-- | The blank ink (no fg/bg, no attributes).
style :: Style
style = Style Nothing Nothing False False False False False

noInk :: Style
noInk = style

fg :: Rgba -> Style -> Style
fg c s = s { stFg = Just c }

bg :: Rgba -> Style -> Style
bg c s = s { stBg = Just c }

bold :: Style -> Style
bold s = s { stBold = True }

dim :: Style -> Style
dim s = s { stDim = True }

italic :: Style -> Style
italic s = s { stItalic = True }

underline :: Style -> Style
underline s = s { stUnderline = True }

invert :: Style -> Style
invert s = s { stInvert = True }

-- | One styled run. The optional link target is carried for the rare
-- hyperlink-emitting path (not rendered as a protocol sequence — the
-- presenter drops it, matching abstracttui's mosaic-first stance).
data Span = Span
  { spanText :: !Text
  , spanStyle :: !Style
  , spanLink :: !(Maybe Text)
  }
  deriving (Show, Eq)

-- | One line of styled runs. Adjacent runs with equal ink coalesce on push.
data RichLine = RichLine
  { rlSpans :: ![Span]
  }
  deriving (Show, Eq)

-- | Empty line.
richLine :: RichLine
richLine = RichLine []

fromSpans :: [Span] -> RichLine
fromSpans = RichLine

-- | Append a span, coalescing with the trailing span when the ink matches
-- (matches Rust's @RichLine::push@ coalescing).
push :: RichLine -> Span -> RichLine
push (RichLine ss) sp = RichLine (coalesce ss)
  where
    coalesce [] = [sp]
    coalesce (prev : rest)
      | sameInk prev sp = prev { spanText = spanText prev <> spanText sp } : rest
      | otherwise = prev : coalesce rest
    sameInk a b = spanStyle a == spanStyle b && spanLink a == spanLink b

-- | A block of styled lines. Width/height are computed (not stored) to keep
-- construction pure; the layout engine queries them.
data RichText = RichText
  { rtLines :: ![RichLine]
  }
  deriving (Show, Eq)

richText :: RichText
richText = RichText []

fromLines :: [RichLine] -> RichText
fromLines = RichText

-- | A single-style run of (possibly multi-line) text. Newlines split into
-- separate lines.
plain :: Text -> Style -> RichText
plain t s = RichText (map (\ln -> richLine { rlSpans = [Span ln s Nothing] }) (T.lines t))

-- | Convenience: unstyled text.
plainText :: Text -> RichText
plainText t = plain t style

-- | Number of lines (the block's cell height).
rtHeight :: RichText -> Int
rtHeight (RichText ls) = max 1 (length ls)

-- | Widest line in display columns. Tabs are not expanded (the apps don't
-- emit them); double-width characters are counted as 1 (good enough for the
-- layout heuristics here).
rtWidth :: RichText -> Int
rtWidth (RichText ls) = foldr max 0 (map lineW ls)
  where
    lineW (RichLine ss) = T.length (T.concat (map spanText ss))

-- | Hard-wrap a line to @max_width@ columns by character. Rust's @wrap@ is
-- word-aware; the apps only wrap single words (filenames, log lines) so a
-- char-level wrap matches behaviour closely enough. Returns a new block.
wrap :: RichText -> Int -> RichText
wrap (RichText ls) maxW
  | maxW <= 0 = RichText ls
  | otherwise = RichText (concatMap (wrapLine maxW) ls)

wrapLine :: Int -> RichLine -> [RichLine]
wrapLine maxW (RichLine ss) =
  -- Flatten to the line's text + the first span's style, wrap, rebuild.
  let txt = T.concat (map spanText ss)
      ink = maybe style spanStyle (maybeHead ss)
   in if T.null txt
        then [richLine]
        else map (\ln -> richLine { rlSpans = [Span ln ink Nothing] }) (chunksOf maxW txt)
  where
    maybeHead [] = Nothing
    maybeHead (x : _) = Just x

chunksOf :: Int -> Text -> [Text]
chunksOf n t
  | T.null t = []
  | otherwise =
      let (a, b) = T.splitAt n t
       in a : chunksOf n b