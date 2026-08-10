-- | Colour primitives shared by the renderer, the theme, and the mosaic
-- image widget. Mirrors @abstracttui::base::color@.
module AbstractTUI.Base.Color
  ( Rgba (..)
  , rgb
  , transparent
  , black
  , white
  , withAlpha
  , fromHex
  , lerp
  , blendOver
  , clampByte
  ) where

import Data.Word (Word8)

-- | A true-colour pixel / ink. The alpha channel is carried for the mosaic
-- image crossfade (bitmaps blend against an opaque pane background); the
-- terminal ink itself is always opaque — alpha is dropped when the SGR
-- escape is emitted.
data Rgba = Rgba
  { rgbaR :: !Word8
  , rgbaG :: !Word8
  , rgbaB :: !Word8
  , rgbaA :: !Word8
  }
  deriving (Show, Eq, Ord)

-- | Opaque RGB shortcut — the common case for theme tokens and ink.
rgb :: Word8 -> Word8 -> Word8 -> Rgba
rgb r g b = Rgba r g b 255

transparent :: Rgba
transparent = Rgba 0 0 0 0

black :: Rgba
black = rgb 0 0 0

white :: Rgba
white = rgb 255 255 255

-- | Replace the alpha channel, keeping RGB.
withAlpha :: Word8 -> Rgba -> Rgba
withAlpha a c = c { rgbaA = a }

-- | Parse @#RRGGBB@ / @#RGB@ / @RRGGBB@ to an opaque colour. 'Nothing' for
-- malformed input so a bad palette entry fails gracefully (the theme falls
-- back to the default token rather than rendering garbage).
fromHex :: String -> Maybe Rgba
fromHex s0 = case dropWhile (== '#') s0 of
  [r, g, b] ->
    let v c = let n = hexDigit c in n * 16 + n
     in if all isHex [r, g, b]
          then Just (rgb (fromIntegral (v r)) (fromIntegral (v g)) (fromIntegral (v b)))
          else Nothing
  [r0, r1, g0, g1, b0, b1] ->
    let v a b = hexDigit a * 16 + hexDigit b
     in if all isHex [r0, r1, g0, g1, b0, b1]
          then Just (rgb (fromIntegral (v r0 r1)) (fromIntegral (v g0 g1)) (fromIntegral (v b0 b1)))
          else Nothing
  _ -> Nothing

isHex :: Char -> Bool
isHex c =
  (c >= '0' && c <= '9')
    || (c >= 'a' && c <= 'f')
    || (c >= 'A' && c <= 'F')

-- | A single hex digit to its 0–15 value. Caller validates with 'isHex'.
hexDigit :: Char -> Int
hexDigit c
  | c >= '0' && c <= '9' = fromEnum c - fromEnum '0'
  | c >= 'a' && c <= 'f' = fromEnum c - fromEnum 'a' + 10
  | c >= 'A' && c <= 'F' = fromEnum c - fromEnum 'A' + 10
  | otherwise = 0

-- | Linear interpolation between two colours by @t ∈ [0,1]@. Used by the
-- crossfade bitmap blender and the theme's accent shade generator.
lerp :: Double -> Rgba -> Rgba -> Rgba
lerp t a b =
  Rgba
    { rgbaR = clampByte (round (fromIntegral (rgbaR a) + t' * delta rgbaR))
    , rgbaG = clampByte (round (fromIntegral (rgbaG a) + t' * delta rgbaG))
    , rgbaB = clampByte (round (fromIntegral (rgbaB a) + t' * delta rgbaB))
    , rgbaA = clampByte (round (fromIntegral (rgbaA a) + t' * delta rgbaA))
    }
  where
    t' = max 0 (min 1 t)
    delta f = fromIntegral (f b) - fromIntegral (f a)

-- | Source-over compositing: paint 'src' over 'dst' using 'src' alpha. The
-- pane background a mosaic cell is blended against is always opaque, so the
-- result is opaque (alpha 255).
blendOver :: Rgba -> Rgba -> Rgba
blendOver src dst =
  rgb r' g' b'
  where
    a = fromIntegral (rgbaA src) / 255
    mix f = round (a * fromIntegral (f src) + (1 - a) * fromIntegral (f dst))
    r' = mix rgbaR
    g' = mix rgbaG
    b' = mix rgbaB

-- | Clamp a rounded channel into the Word8 range.
clampByte :: Int -> Word8
clampByte n
  | n < 0 = 0
  | n > 255 = 255
  | otherwise = fromIntegral n