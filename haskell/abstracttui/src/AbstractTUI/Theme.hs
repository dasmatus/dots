-- | Theme tokens. Mirrors @abstracttui::theme::{tokens,registry}@. A
-- 'TokenSet' is one resolved palette (Rgba per named slot); the three apps
-- each build a custom 'TokenSet' at startup (Tokyonight for the dots, via
-- their @ui@ module) and pass it to widget builders that don't take a
-- 'Scope'.
module AbstractTUI.Theme
  ( TokenId (..)
  , TokenSet (..)
  , defaultTokens
  , abstractDark
  ) where

import AbstractTUI.Base.Color (Rgba, rgb)

-- | The named slots a widget can pull from. Matches the Rust @TokenId@ enum;
-- order is irrelevant (Haskell record selectors carry the names).
data TokenId
  = TidBg
  | TidSurface
  | TidSurfaceRaised
  | TidOverlay
  | TidBorder
  | TidBorderFocus
  | TidText
  | TidTextMuted
  | TidTextFaint
  | TidAccent
  | TidAccentAlt
  | TidOk
  | TidWarn
  | TidError
  | TidInfo
  | TidSelectionBg
  | TidSelectionFg
  | TidCursor
  | TidLink
  | TidShadow
  | TidShadowGround
  | TidChart0
  | TidChart1
  | TidChart2
  | TidChart3
  | TidChart4
  | TidChart5
  deriving (Show, Eq, Bounded, Enum)

-- | A resolved palette. Widgets read the slots they need (e.g. a 'Block'
-- fills with 'tokSurface' and borders with 'tokBorder'/'tokBorderFocus').
data TokenSet = TokenSet
  { tokBg :: !Rgba
  , tokSurface :: !Rgba
  , tokSurfaceRaised :: !Rgba
  , tokOverlay :: !Rgba
  , tokBorder :: !Rgba
  , tokBorderFocus :: !Rgba
  , tokText :: !Rgba
  , tokTextMuted :: !Rgba
  , tokTextFaint :: !Rgba
  , tokAccent :: !Rgba
  , tokAccentAlt :: !Rgba
  , tokOk :: !Rgba
  , tokWarn :: !Rgba
  , tokError :: !Rgba
  , tokInfo :: !Rgba
  , tokSelectionBg :: !Rgba
  , tokSelectionFg :: !Rgba
  , tokCursor :: !Rgba
  , tokLink :: !Rgba
  , tokShadow :: !Rgba
  , tokShadowGround :: !Rgba
  , tokChart0 :: !Rgba
  , tokChart1 :: !Rgba
  , tokChart2 :: !Rgba
  , tokChart3 :: !Rgba
  , tokChart4 :: !Rgba
  , tokChart5 :: !Rgba
  }
  deriving (Show, Eq)

-- | The abstract-dark house palette — the fallback when no theme context is
-- available (e.g. a widget built inside a @dyn_view@ with no 'Scope').
-- Values are a muted dark set; the real apps override everything with the
-- Tokyonight palette.
abstractDark :: TokenSet
abstractDark =
  TokenSet
    { tokBg = rgb 16 18 24
    , tokSurface = rgb 22 26 34
    , tokSurfaceRaised = rgb 30 34 44
    , tokOverlay = rgb 12 14 20
    , tokBorder = rgb 52 58 70
    , tokBorderFocus = rgb 122 162 247
    , tokText = rgb 218 224 236
    , tokTextMuted = rgb 144 152 168
    , tokTextFaint = rgb 92 100 116
    , tokAccent = rgb 122 162 247
    , tokAccentAlt = rgb 187 154 247
    , tokOk = rgb 134 211 134
    , tokWarn = rgb 235 203 139
    , tokError = rgb 247 118 118
    , tokInfo = rgb 122 162 247
    , tokSelectionBg = rgb 44 56 88
    , tokSelectionFg = rgb 240 244 252
    , tokCursor = rgb 122 162 247
    , tokLink = rgb 122 162 247
    , tokShadow = rgb 0 0 0
    , tokShadowGround = rgb 8 10 14
    , tokChart0 = rgb 122 162 247
    , tokChart1 = rgb 187 154 247
    , tokChart2 = rgb 134 211 134
    , tokChart3 = rgb 235 203 139
    , tokChart4 = rgb 247 118 118
    , tokChart5 = rgb 110 200 220
    }

-- | Alias for @TokenSet::default()@.
defaultTokens :: TokenSet
defaultTokens = abstractDark