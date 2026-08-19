{-# LANGUAGE LambdaCase #-}

-- | abstracttui view — a static Block\/Element tree mounted once, with each
-- reactive region (list, preview, info, help) a 'dynView' child producing a
-- 'Behavior' of 'V.Image' layers from 'current' ('sigDyn' app) (and
-- 'current' ('sigDyn' fx) for the preview crossfade). No I/O lives here;
-- reactivity comes from 'dynView' re-reading the 'Signal' 'App'\/'Signal'
-- 'Fx' on change. The preview renders through 'Gfx.Mosaic.renderMosaic' on
-- the half-block backend — no native image protocol — and the crossfade
-- blends the new 'Bitmap' toward the pane background by the eased opacity,
-- since the mosaic cells paint opaque. Mirrors @rust/wallpaper-tui/src/ui.rs@.
module WallpaperTui.Ui
  ( rootView
  , paletteBg
  , paletteFg
  , paletteDim
  , helpText
  ) where

import Data.Function ((&))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Graphics.Vty as V
import Reflex (Behavior, current, constant)
import Reflex.Vty.Widget (displayHeight, displayWidth)
import System.FilePath (takeFileName)

import AbstractTUI.Base.Color (Rgba (..), rgb)
import AbstractTUI.Gfx.Bitmap
  ( Bitmap
  , bmpHeight
  , bmpIsEmpty
  , bmpWidth
  , resizeNearest
  )
import AbstractTUI.Gfx.Mosaic
  ( ImageAlign (..)
  , MosaicMode (..)
  , cellPixels
  , renderMosaic
  )
import AbstractTUI.Layout.Style
  ( Dimension (..)
  , LayoutStyle
  , column
  , defaultStyle
  , grow
  , h
  , height
  , row
  , width
  )
import AbstractTUI.Reactive (Signal, sigDyn, sigReadRef, sigUpdateIO)
import AbstractTUI.Render.Paint (rgbaAttr, rgbaColor)
import AbstractTUI.Theme (defaultTokens)
import AbstractTUI.View
  ( Element
  , Key (..)
  , UiEvent (..)
  , View
  , build
  , child
  , dynView
  , elementNew
  , onEvent
  , style
  )
import AbstractTUI.Widget.Block
  ( BorderKind (..)
  , block
  , blockChild
  , blockLayout
  , blockNew
  , blockTitle
  , blockTokens
  , border
  )

import WallpaperTui.App
  ( App
  , handleKey
  , infoText
  , wpPreview
  , wpPreviewPending
  , wpSelected
  , wpShowPreview
  , wpWallpapers
  )
import WallpaperTui.Fx (Fx, blendBitmap, crossfadeOpacity, retargetCrossfade)
import WallpaperTui.Input (KeyCode (..))

-- * Palette

-- | Tokyonight (night) palette as 'Rgba' values — no hex arithmetic in widget
-- code. Mirrors @ui::palette@.
paletteBg, paletteFg, paletteCyan, paletteMagenta, paletteDim, paletteInfoBg, paletteSelBg :: Rgba
paletteBg = rgb 0x1a 0x1b 0x26
paletteFg = rgb 0xc0 0xca 0xf5
paletteCyan = rgb 0x7d 0xcf 0xff
paletteMagenta = rgb 0xbb 0x9a 0xf7
paletteDim = rgb 0x56 0x5f 0x89
paletteInfoBg = rgb 0x16 0x16 0x20
paletteSelBg = rgb 0x7a 0xa2 0xf7

-- | The one-line help footer (verbatim from @ui.rs@).
helpText :: String
helpText =
  "Enter:apply  j/k:move  m:mode  c:color  o:output  p:preview  r:restore  q:quit"

-- * Root view

-- | The root component: a column with the body (list | preview, or the empty
-- notice) above the info bar above the help footer, plus a root 'onEvent'
-- that bridges engine key events into the pure 'App' state machine and
-- retargets the preview crossfade on selection change. The
-- @isEmpty@\/@folder@ args are static (the wallpaper folder is fixed at
-- startup), so the empty-vs-picker branch is chosen once at mount — there
-- is no 'widgetHold' for reactive View subtrees under the abstracttui
-- mapping (see the port design). @animEnabled@ is the cached
-- @DOTS_NO_ANIM@ read (the on-event bridge gates the crossfade retarget on
-- it since 'Fx' is pure and cannot read the env).
rootView ::
  Bool ->
  String ->
  Signal t App ->
  Signal t Fx ->
  Bool ->
  View t
rootView isEmpty folder app fx anim =
  build
    ( elementNew
        & style (grow 1.0 column)
        & onEvent (keyBridge app fx anim)
        & (if isEmpty then child (emptyBody folder) else child (bodyRow app fx anim))
        & child infoBar
        & child helpBar
    )
  where
    infoBar =
      build
        ( elementNew
            & style (h 1 (width (Percent 1.0) defaultStyle))
            & child (infoDynView defaultStyle app)
        )
    helpBar =
      build
        ( elementNew
            & style (h 1 (width (Percent 1.0) defaultStyle))
            & child (helpDynView defaultStyle)
        )

-- | The on-event key bridge. Maps the engine 'Key' to the picker's
-- 'KeyCode', peeks the pre-selection, applies 'handleKey' (pure) via
-- 'sigUpdateIO', peeks the post-selection, and retargets the crossfade when
-- the selection moved. 'sigUpdateIO' writes the mirror 'IORef'
-- synchronously, so the post-mutation 'sigReadRef' sees the new 'App'.
keyBridge :: Signal t App -> Signal t Fx -> Bool -> UiEvent -> IO ()
keyBridge app fx anim ev = case ev of
  UiEventKey k -> case mapKey k of
    Nothing -> pure ()
    Just code -> do
      prev <- sigReadRef app
      sigUpdateIO app (\a -> handleKey a code)
      next <- sigReadRef app
      let moved = wpSelected next /= wpSelected prev
      when' moved $ when' anim $ sigUpdateIO fx retargetCrossfade
  _ -> pure ()
  where
    -- 'when' spelled locally so the bridge reads like the Rust @if@.
    when' True io = io
    when' False _ = pure ()

-- | Map the engine 'Key' to the picker's 'KeyCode'. Unknown keys map to
-- 'Nothing' — the picker ignores them. Mirrors @ui::map_key@.
mapKey :: Key -> Maybe KeyCode
mapKey = \case
  KeyChar c -> Just (Char c)
  KeyEnter -> Just Enter
  KeyEsc -> Just Esc
  KeyBackspace -> Just Backspace
  KeyUp -> Just Up
  KeyDown -> Just Down
  _ -> Nothing

-- * Body row

-- | @list | preview@ — the list grows, the preview is a fixed 50-cell pane
-- (mirroring the old @Length(50)@).
bodyRow :: Signal t App -> Signal t Fx -> Bool -> View t
bodyRow app fx anim =
  build
    ( elementNew
        & style (grow 1.0 (width (Percent 1.0) row))
        & child listWrap
        & child previewWrap
    )
  where
    listWrap =
      build
        ( elementNew
            & style (grow 1.0 (height (Percent 1.0) defaultStyle))
            & child listBlock
        )
      where
        listBlock =
          block
            ( blockNew
                & border Plain
                & blockTitle "wallpapers"
                & blockLayout (grow 1.0 column)
                & blockChild (listDynView defaultStyle app)
                & blockTokens defaultTokens
            )
    previewWrap =
      build
        ( elementNew
            & style (width (Cells 50) (height (Percent 1.0) defaultStyle))
            & child previewBlock
        )
      where
        previewBlock =
          block
            ( blockNew
                & border Plain
                & blockTitle "preview"
                & blockLayout (grow 1.0 column)
                & blockChild (previewDynView defaultStyle app fx anim)
                & blockTokens defaultTokens
            )

-- * List

-- | The wallpaper list — one 'V.Image' row per entry. The selected entry is
-- prefixed with @> @ and drawn black-on-light-blue bold (the old highlight
-- style). Reactive on the 'App' signal.
listDynView :: LayoutStyle -> Signal t App -> View t
listDynView ls app =
  dynView ls $ pure (listImages <$> current (sigDyn app))

listImages :: App -> [V.Image]
listImages app = [V.vertCat (zipWith line [0 ..] (wpWallpapers app))]
  where
    line i p =
      let nm = takeFileName p
      in if i == wpSelected app
           then V.text' selAttr (T.pack ("> " <> nm))
           else V.text' (rgbaAttr paletteFg) (T.pack ("  " <> nm))
    selAttr =
      V.withStyle
        ( V.withForeColor
            (V.withBackColor V.defAttr (rgbaColor paletteSelBg))
            (rgbaColor paletteBg)
        )
        V.bold

-- * Preview

-- | The preview pane — reactive on both 'App' (bitmap, show\/pending) and
-- 'Fx' (crossfade opacity). Reads the display extents so the mosaic fits
-- the pane. When the preview is hidden, the pane is blanked.
previewDynView ::
  LayoutStyle ->
  Signal t App ->
  Signal t Fx ->
  Bool ->
  View t
previewDynView ls app fx anim = dynView ls $ do
  dw <- displayWidth
  dh <- displayHeight
  pure
    ( previewImages anim
        <$> current (sigDyn app)
        <*> current (sigDyn fx)
        <*> current dw
        <*> current dh
    )

-- | Render the preview for one frame. Blend toward the pane ground while
-- the fade is in flight; at full opacity (or with animations off) show the
-- raw bitmap. A pending decode shows @rendering…@; no preview shows
-- @[preview unavailable]@; a hidden preview is blank.
previewImages :: Bool -> App -> Fx -> Int -> Int -> [V.Image]
previewImages anim app fxV w h
  | not (wpShowPreview app) = [V.emptyImage]
  | otherwise = case wpPreview app of
      Just bmp ->
        let opacity = crossfadeOpacity fxV
            displayed
              | abs (opacity - 1.0) < 1e-3 || not anim = bmp
              | otherwise = blendBitmap bmp paletteBg (realToFrac opacity)
        in [renderPreviewImage displayed w h]
      Nothing ->
        let label = case wpPreviewPending app of
              Just _ -> "rendering…"
              Nothing -> "[preview unavailable]"
        in [V.text' (rgbaAttr paletteDim) (T.pack label)]

-- | Place a 'Bitmap' into the @w × h@ cell region: contain-fit (preserve
-- aspect ratio), center-align, half-block mosaic. A copy of
-- "AbstractTUI.Widget.Image"'s @renderImage@ math (which is not exported),
-- specialized to the wallpaper preview's 'FitContain' + 'ImageAlignCenter'
-- + 'HalfBlock' config.
renderPreviewImage :: Bitmap -> Int -> Int -> V.Image
renderPreviewImage bmp cellW cellH
  | bmpIsEmpty bmp || cellW <= 0 || cellH <= 0 = V.emptyImage
  | otherwise =
      let (subW, subH) = cellPixels HalfBlock
          availPW = cellW * subW
          availPH = cellH * subH
          sw = bmpWidth bmp
          sh = bmpHeight bmp
          s =
            min
              (fromIntegral availPW / fromIntegral sw :: Double)
              (fromIntegral availPH / fromIntegral sh)
          tw = max 1 (round (fromIntegral sw * s))
          th = max 1 (round (fromIntegral sh * s))
          scaled = resizeNearest tw th bmp
          img = renderMosaic HalfBlock scaled
          imgW = (tw + subW - 1) `div` subW
          imgH = (th + subH - 1) `div` subH
          offX = alignCenter cellW imgW
          offY = alignCenter cellH imgH
      in V.translate (max 0 offX) (max 0 offY) img
  where
    alignCenter total self = max 0 ((total - self) `div` 2)

-- * Info bar

-- | One-line info bar — 'App.infoText' on a dark-slate ground, bold light
-- text (the old @DarkGray@ + white bold). The first image layer is the
-- full-width background fill; the second is the text on top.
infoDynView :: LayoutStyle -> Signal t App -> View t
infoDynView ls app = dynView ls $ do
  dw <- displayWidth
  pure
    ( (\a w -> [V.charFill infoBgAttr ' ' w 1, V.text' infoFgAttr (T.pack (infoText a))])
        <$> current (sigDyn app)
        <*> current dw
    )
  where
    infoBgAttr = V.withBackColor V.defAttr (rgbaColor paletteInfoBg)
    infoFgAttr =
      V.withStyle
        (V.withBackColor (V.withForeColor V.defAttr (rgbaColor paletteFg)) (rgbaColor paletteInfoBg))
        V.bold

-- * Help footer

-- | One-line dim help footer — static (the text never changes), rendered as
-- a constant 'Behavior'.
helpDynView :: LayoutStyle -> View t
helpDynView ls =
  dynView ls $ pure (constant [V.text' (rgbaAttr paletteDim) (T.pack helpText)])

-- * Empty state

-- | The @No wallpapers found in: <folder>@ message fills the body, with the
-- info + help bars beneath (the bars are the root's, shared with the
-- picker branch).
emptyBody :: String -> View t
emptyBody folder =
  build
    ( elementNew
        & style (grow 1.0 (width (Percent 1.0) defaultStyle))
        & child
            ( dynView
                defaultStyle
                (pure (constant [V.text' (rgbaAttr paletteCyan) (T.pack msg)]))
            )
    )
  where
    msg = "No wallpapers found in: " <> (if null folder then "?" else folder)