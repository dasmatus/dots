-- | An RGBA raster — the source the 'Image' widget downsamples into mosaic
-- cells and the crossfade blender lerp target. Mirrors
-- @abstracttui::gfx::bitmap@.
module AbstractTUI.Gfx.Bitmap
  ( Bitmap (..)
  , bitmap
  , fromPixels
  , bmpIsEmpty
  , bmpWidth
  , bmpHeight
  , pixelAt
  , pixels
  , mapPixels
  , blendBitmap
  , resizeNearest
  ) where

import qualified Data.Vector as V
import AbstractTUI.Base.Color (Rgba, black, lerp)

-- | A width × height RGBA buffer. Pixels are row-major, left-to-right,
-- top-to-bottom.
data Bitmap = Bitmap
  { bmpW :: !Int
  , bmpH :: !Int
  , bmpPx :: !(V.Vector Rgba)
  }
  deriving (Show, Eq)

-- | A solid fill of @w × h@.
bitmap :: Int -> Int -> Rgba -> Bitmap
bitmap w h fill =
  Bitmap
    { bmpW = max 0 w
    , bmpH = max 0 h
    , bmpPx = V.replicate (max 0 w * max 0 h) fill
    }

-- | Build from a pixel vector. Returns 'Nothing' on a length mismatch (the
-- caller falls back to a labelled broken-source widget, never a panic).
fromPixels :: Int -> Int -> V.Vector Rgba -> Maybe Bitmap
fromPixels w h px
  | w >= 0 && h >= 0 && V.length px == w * h = Just Bitmap { bmpW = w, bmpH = h, bmpPx = px }
  | otherwise = Nothing

bmpIsEmpty :: Bitmap -> Bool
bmpIsEmpty b = bmpW b == 0 || bmpH b == 0

bmpWidth :: Bitmap -> Int
bmpWidth = bmpW

bmpHeight :: Bitmap -> Int
bmpHeight = bmpH

-- | Lookup a pixel; out-of-bounds returns 'black' (matches the Rust
-- bounds-checked accessor's default for the mosaic sampler).
pixelAt :: Bitmap -> Int -> Int -> Rgba
pixelAt (Bitmap w _ px) x y
  | x < 0 || y < 0 || x >= w = black
  | otherwise = case px V.!? (y * w + x) of Just c -> c; Nothing -> black

-- | The underlying pixel vector (row-major). Exposed so the mosaic 'Image'
-- widget and tests can read raw pixels without per-cell bounds checks.
pixels :: Bitmap -> V.Vector Rgba
pixels = bmpPx

-- | Apply a function to every pixel, preserving the bitmap's dimensions.
-- Used by the wallpaper crossfade ('blendBitmap') and any pixel-level effect.
mapPixels :: (Rgba -> Rgba) -> Bitmap -> Bitmap
mapPixels f (Bitmap w h px) = Bitmap w h (V.map f px)

-- | Crossfade a bitmap toward a solid background by @opacity ∈ [0,1]@: each
-- pixel is 'lerp'ed from its current colour toward @bg@ by @opacity@, so
-- @0@ leaves the image intact and @1@ collapses it to @bg@. The wallpaper
-- port builds the crossfade 'Behavior' from the Fx transition's opacity and
-- the selected bitmap via this. The 'DOTS_NO_ANIM' gate skips it (raw bitmap).
blendBitmap :: Bitmap -> Rgba -> Double -> Bitmap
blendBitmap bmp bg opacity = mapPixels (\p -> lerp opacity p bg) bmp

-- | Nearest-neighbour resize to a target cell footprint. Used by the
-- 'Image' widget's contain-fit (cheap; the apps' thumbnails are small).
resizeNearest :: Int -> Int -> Bitmap -> Bitmap
resizeNearest tw th (Bitmap sw sh px)
  | tw <= 0 || th <= 0 = bitmap 0 0 black
  | sw == 0 || sh == 0 = bitmap tw th black
  | otherwise =
      Bitmap
        { bmpW = tw
        , bmpH = th
        , bmpPx = V.generate (tw * th) mkPx
        }
  where
    mkPx i =
      let tx = i `mod` tw
          ty = i `div` tw
          sx = min (sw - 1) ((tx * sw) `div` tw)
          sy = min (sh - 1) ((ty * sh) `div` th)
       in case px V.!? (sy * sw + sx) of
            Just c -> c
            Nothing -> black