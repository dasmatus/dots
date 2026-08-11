-- | Mosaic image-rendering knobs. Mirrors @abstracttui::widgets::ImageFit@ /
-- @ImageAlign@ and @abstracttui::gfx::MosaicMode@. The 'Image' widget always
-- emits unicode mosaic cells (never a native image protocol); these enums
-- pick the glyph set and the fit/align policy.
module AbstractTUI.Gfx.Mosaic
  ( MosaicMode (..)
  , ImageFit (..)
  , ImageAlign (..)
  , cellPixels
  ) where

-- | The sub-cell glyph set used to render one mosaic cell.
data MosaicMode = HalfBlock | Quadrant | Sextant | Braille
  deriving (Show, Eq, Bounded, Enum)

-- | How a source bitmap fits into the available cell rectangle.
data ImageFit = FitContain | FitCover | FitFill | FitNone
  deriving (Show, Eq)

-- | Alignment within the cell rectangle when the bitmap is smaller than it.
-- Constructors are prefixed to avoid clashing with the layout 'Align' enum's
-- 'AlignStart'/'AlignCenter'/'AlignEnd' (Haskell puts all constructors in one
-- namespace, so the Prelude can re-export both enums unambiguously only if the
-- names differ).
data ImageAlign = ImageAlignStart | ImageAlignCenter | ImageAlignEnd
  deriving (Show, Eq)

-- | The (subWidth, subHeight) resolution a mode packs into one cell:
-- HalfBlock = 1×2, Quadrant = 2×2, Sextant = 2×3, Braille = 2×4. The
-- 'Image' widget uses this to compute the target pixel footprint.
cellPixels :: MosaicMode -> (Int, Int)
cellPixels HalfBlock = (1, 2)
cellPixels Quadrant = (2, 2)
cellPixels Sextant = (2, 3)
cellPixels Braille = (2, 4)