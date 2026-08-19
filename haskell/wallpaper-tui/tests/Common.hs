{-# LANGUAGE LambdaCase #-}

-- | Shared fixtures for the integration tests: synthetic images, the
-- Kvantum\/icon base trees, an isolated 'TintCtx', and a flat wallpaper.
-- Faithful Haskell port of @rust/wallpaper-tui/tests/common/mod.rs@. Every
-- I/O test runs under a fresh temp dir so nothing touches the real
-- @~/.config@ or the Nix store, and no test mutates process-global env.
module Common
  ( makeImage
  , makeImageWithPatch
  , makeKvantumBase
  , makeIconBase
  , tintCtx
  , rofiBase
  , wallpaper
  , withTmp
  , module System.IO.Temp
  ) where

import Control.Monad (forM_, when)
import Data.Word (Word8)
import qualified Codec.Picture as JP
import System.Directory
  ( copyFile
  , createDirectoryIfMissing
  , doesDirectoryExist
  )
import System.FilePath ((</>), takeDirectory)
import System.IO.Temp (withSystemTempDirectory)

import WallpaperTui.Tint (TintCtx (..))

-- | Write a flat-color PNG of @size×size@ — the Haskell @image@ equivalent of
-- the Rust @make_image@ (Pillow @Image.new("RGB", ...)@).
makeImage :: FilePath -> (Word8, Word8, Word8) -> Int -> IO ()
makeImage path (r, g, b) size = do
  let img = JP.generateImage (\_ _ -> JP.PixelRGB8 r g b) size size :: JP.Image JP.PixelRGB8
  JP.writePng path img

-- | A flat-color 64×64 PNG with a small differently-colored patch in the
-- top-left — ports the @mostly_blue@ extractor fixture (dominant vibrant
-- wins).
makeImageWithPatch :: FilePath -> (Word8, Word8, Word8) -> (Word8, Word8, Word8) -> IO ()
makeImageWithPatch path base patch = do
  let img = JP.generateImage mk 64 64 :: JP.Image JP.PixelRGB8
  JP.writePng path img
  where
    mk x y =
      let (r, g, b) = if x < 8 && y < 8 then patch else base
      in JP.PixelRGB8 r g b

-- | A minimal Kvantum theme tree mirroring catppuccin-frappe-blue's shape.
makeKvantumBase :: FilePath -> IO FilePath
makeKvantumBase root = do
  let theme = root </> "catppuccin-frappe-blue"
  createDirectoryIfMissing True theme
  writeFile
    (theme </> "catppuccin-frappe-blue.kvconfig")
    (unlines
      [ "[%General]"
      , "comment=Catppuccin-Frappe-Blue"
      , "[GeneralColors]"
      , "highlight.color=#8CAAEE4D"
      , "link.color=#8CAAEE"
      , "link.visited.color=#98B2EF"
      , "window.color=#303446"
      , "text.color=#C6D0F5"
      ])
  writeFile
    (theme </> "catppuccin-frappe-blue.svg")
    "<svg><rect fill=\"#8CAAEE\"/><rect fill=\"#839EDD\"/><rect fill=\"#303446\"/></svg>\n"
  pure theme

-- | A minimal MoreWaita-shaped icon theme tree with the Adwaita-blue family.
makeIconBase :: FilePath -> IO FilePath
makeIconBase root = do
  let theme = root </> "MoreWaita"
      places = theme </> "scalable" </> "places"
  createDirectoryIfMissing True places
  writeFile
    (theme </> "index.theme")
    "[Icon Theme]\nName=MoreWaita\nInherits=Adwaita,AdwaitaLegacy,hicolor\nExample=pamac\n"
  writeFile
    (places </> "folder.svg")
    "<svg><stop stop-color=\"#62a0ea\"/><stop stop-color=\"#afd4ff\"/><rect fill=\"#438de6\"/></svg>\n"
  writeFile
    (places </> "folder-ruby.svg")
    "<svg><rect fill=\"#438de6\"/><rect fill=\"#000000\"/></svg>\n"
  pure theme

-- | The synthetic rofi base rasi matching the tokyonight theme.
rofiBase :: String
rofiBase =
  unlines
    [ "* {"
    , "  accent:      #7aa2f7;"
    , "  selected-bg: #2d3252;"
    , "  bg: #1a1b26;"
    , "}"
    ]

-- | Build a 'TintCtx' whose every path points inside @tmp@, with no Hyprland
-- signature and icon-selection disabled (gsettings absent). Mirrors the
-- pytest @isolated_paths@ fixture: the rofi base is a synthetic rasi, the
-- kvantum\/icon bases are 'Nothing' unless @withBases@ provides them.
tintCtx :: FilePath -> Maybe FilePath -> Maybe FilePath -> IO TintCtx
tintCtx tmp kvantumBase iconBase = do
  let tintDir = tmp </> "tint"
      rb = tmp </> "rofi" </> "tokyonight.rasi"
  createDirectoryIfMissing True (takeDirectory rb)
  writeFile rb rofiBase
  pure
    TintCtx
      { tcKvantumBase = kvantumBase
      , tcIconBase = iconBase
      , tcKvantumDest = tmp </> "Kvantum" </> "WallpaperTint"
      , tcKvantumSelect = tmp </> "Kvantum" </> "kvantum.kvconfig"
      , tcIconDest = tmp </> "icons" </> "MoreWaita-Tint"
      , tcTintDir = tintDir
      , tcRofiBase = rb
      , tcHis = Nothing
      , tcTryIconSelect = False
      }

-- | A flat green wallpaper under @tmp@, the apply_tint fixture input.
wallpaper :: FilePath -> IO FilePath
wallpaper tmp = do
  let p = tmp </> "wp.png"
  makeImage p (40, 200, 60) 64
  pure p

-- | Run an action with a fresh temp dir. Mirrors Rust's @tempdir()@.
withTmp :: (FilePath -> IO a) -> IO a
withTmp = withSystemTempDirectory "wallpaper-tui-test"