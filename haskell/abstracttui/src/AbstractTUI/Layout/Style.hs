-- | Layout style — the flexbox-ish container description. Mirrors
-- @abstracttui::layout::{style,mod}@: 'LayoutStyle' is the builder chain the
-- apps compose (@column . gap 1 . padding (all 1)@), and the layout engine in
-- "AbstractTUI.Render.Paint" turns a 'LayoutStyle' + children into placed
-- cell rectangles.
module AbstractTUI.Layout.Style
  ( LayoutStyle (..)
  , Direction (..)
  , Dimension (..)
  , Edges (..)
  , edges
  , zeroEdges
  , allEdges
  , hvEdges
  , Inset (..)
  , Justify (..)
  , Align (..)
  , column
  , row
  , fill
  , line
  , defaultStyle
  , gap
  , padding
  , margin
  , w
  , h
  , width
  , height
  , minWidth
  , minHeight
  , grow
  , shrink
  , withWrap
  , justify
  , align
  , inset
  , hEdges
  , vEdges
  , edgesLeft
  , edgesRight
  , edgesTop
  , edgesBottom
  , innerBox
  ) where

-- | Main-axis direction of a container.
data Direction = Row | Column
  deriving (Show, Eq)

-- | A dimension along an axis. 'Auto' defers to the child's natural size;
-- 'Cells' is a fixed number of cells; 'Percent' is a fraction of the
-- available extent (0.0–1.0, NOT 0–100 — matching the Rust enum).
data Dimension
  = Auto
  | Cells Int
  | Percent Float
  deriving (Show, Eq)

-- | Uniform-ish four-side spacing. Used for both padding and margin.
data Edges = Edges
  { eLeft :: !Int
  , eRight :: !Int
  , eTop :: !Int
  , eBottom :: !Int
  }
  deriving (Show, Eq)

-- | Construct from four explicit sides.
edges :: Int -> Int -> Int -> Int -> Edges
edges = Edges

zeroEdges :: Edges
zeroEdges = Edges 0 0 0 0

allEdges :: Int -> Edges
allEdges n = Edges n n n n

hvEdges :: Int -> Int -> Edges
hvEdges h v = Edges h h v v

hEdges :: Edges -> Int
hEdges (Edges l r _ _) = l + r

vEdges :: Edges -> Int
vEdges (Edges _ _ t b) = t + b

edgesLeft, edgesRight, edgesTop, edgesBottom :: Edges -> Int
edgesLeft (Edges l _ _ _) = l
edgesRight (Edges _ r _ _) = r
edgesTop (Edges _ _ t _) = t
edgesBottom (Edges _ _ _ b) = b

-- | Absolute (out-of-flow) positioning insets. The apps don't use these
-- (their layouts are pure flex), so the engine treats an unset 'Inset' as
-- "in flow"; kept here for API parity.
data Inset = Inset
  { iLeft :: !(Maybe Int)
  , iRight :: !(Maybe Int)
  , iTop :: !(Maybe Int)
  , iBottom :: !(Maybe Int)
  }
  deriving (Show, Eq)

data Justify = JustifyStart | JustifyCenter | JustifyEnd | JustifyStretch
  deriving (Show, Eq)

data Align = AlignStart | AlignCenter | AlignEnd | AlignStretch
  deriving (Show, Eq)

-- | The container description. 'lsGrow' is the flex-grow factor on the main
-- axis; 'lsShrink' the shrink factor (used when the engine clamps children
-- that overflow).
data LayoutStyle = LayoutStyle
  { lsDirection :: !Direction
  , lsGap :: !Int
  , lsPadding :: !Edges
  , lsMargin :: !Edges
  , lsW :: !(Maybe Dimension)
  , lsH :: !(Maybe Dimension)
  , lsMinW :: !(Maybe Int)
  , lsMinH :: !(Maybe Int)
  , lsGrow :: !Float
  , lsShrink :: !Float
  , lsWrap :: !Bool
  , lsJustify :: !Justify
  , lsAlign :: !Align
  , lsInset :: !(Maybe Inset)
  }
  deriving (Show, Eq)

-- | A row container (the default — matches Rust's @Style::default()@).
defaultStyle :: LayoutStyle
defaultStyle =
  LayoutStyle
    { lsDirection = Row
    , lsGap = 0
    , lsPadding = zeroEdges
    , lsMargin = zeroEdges
    , lsW = Nothing
    , lsH = Nothing
    , lsMinW = Nothing
    , lsMinH = Nothing
    , lsGrow = 0
    , lsShrink = 1
    , lsWrap = False
    , lsJustify = JustifyStart
    , lsAlign = AlignStretch
    , lsInset = Nothing
    }

-- | Stack children top-to-bottom.
column :: LayoutStyle
column = defaultStyle { lsDirection = Column }

-- | Place children left-to-right.
row :: LayoutStyle
row = defaultStyle { lsDirection = Row }

-- | Grow on both axes (fill the parent).
fill :: LayoutStyle
fill = defaultStyle { lsGrow = 1 }

-- | A full-width slot of exactly @n@ rows.
line :: Int -> LayoutStyle
line n = column { lsH = Just (Cells n), lsW = Just (Percent 1) }

gap :: Int -> LayoutStyle -> LayoutStyle
gap n s = s { lsGap = n }

padding :: Edges -> LayoutStyle -> LayoutStyle
padding e s = s { lsPadding = e }

margin :: Edges -> LayoutStyle -> LayoutStyle
margin e s = s { lsMargin = e }

-- | Fixed width in cells — the @.w(i32)@ builder. The Rust API has both
-- @w(i32)@ and @width(Dimension)@; this is the cells-only shortcut.
w :: Int -> LayoutStyle -> LayoutStyle
w n s = s { lsW = Just (Cells n) }

-- | Fixed height in cells — the @.h(i32)@ builder.
h :: Int -> LayoutStyle -> LayoutStyle
h n s = s { lsH = Just (Cells n) }

-- | Width as a 'Dimension' — the @.width(Dimension)@ builder. @Percent 1.0@
-- is load-bearing for the installer/wallpaper ports (full-width fills);
-- @Cells n@ matches 'w'; 'Auto' defers to the child's natural size.
width :: Dimension -> LayoutStyle -> LayoutStyle
width d s = s { lsW = Just d }

-- | Height as a 'Dimension' — the @.height(Dimension)@ builder.
height :: Dimension -> LayoutStyle -> LayoutStyle
height d s = s { lsH = Just d }

minWidth :: Int -> LayoutStyle -> LayoutStyle
minWidth n s = s { lsMinW = Just n }

minHeight :: Int -> LayoutStyle -> LayoutStyle
minHeight n s = s { lsMinH = Just n }

-- | Flex-grow factor on the main axis.
grow :: Float -> LayoutStyle -> LayoutStyle
grow f s = s { lsGrow = f }

-- | Shrink factor (1 by default — overflow clamps children).
shrink :: Float -> LayoutStyle -> LayoutStyle
shrink f s = s { lsShrink = f }

withWrap :: Bool -> LayoutStyle -> LayoutStyle
withWrap b s = s { lsWrap = b }

justify :: Justify -> LayoutStyle -> LayoutStyle
justify j s = s { lsJustify = j }

align :: Align -> LayoutStyle -> LayoutStyle
align a s = s { lsAlign = a }

inset :: Inset -> LayoutStyle -> LayoutStyle
inset i s = s { lsInset = Just i }

-- | Subtract padding from a @(w,h)@ extent to get the inner content box.
innerBox :: Edges -> (Int, Int) -> (Int, Int)
innerBox p (w, h) = (max 0 (w - hEdges p), max 0 (h - vEdges p))