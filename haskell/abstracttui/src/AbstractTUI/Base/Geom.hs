-- | Geometry primitives. Mirrors @abstracttui::base::geom@: 'Point' and
-- 'Size' are the integer pixel/cell coordinates the layout engine and the
-- presenter pass around.
module AbstractTUI.Base.Geom
  ( Point (..)
  , Size (..)
  , size
  , isEmpty
  , area
  ) where

-- | A cell or pixel coordinate.
data Point = Point
  { ptX :: !Int
  , ptY :: !Int
  }
  deriving (Show, Eq, Ord)

-- | A width × height extent. Kept signed to match the Rust @i32@ so layout
-- math (cursor advance, saturating offsets) stays in the same range.
data Size = Size
  { szW :: !Int
  , szH :: !Int
  }
  deriving (Show, Eq, Ord)

-- | Smart constructor mirroring @Size::new(w, h)@.
size :: Int -> Int -> Size
size = Size

-- | Either dimension non-positive.
isEmpty :: Size -> Bool
isEmpty (Size w h) = w <= 0 || h <= 0

-- | @w * h@, clamped to 0 for degenerate sizes (never negative).
area :: Size -> Int
area (Size w h) = max 0 w * max 0 h