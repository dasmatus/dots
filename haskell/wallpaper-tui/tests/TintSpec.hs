-- | Per-target tint writers and the apply_tint orchestrator. Writers are
-- pure (string in → string out); tree tinters and the orchestrator use the
-- 'Common.tintCtx' fixture + synthetic base themes so nothing touches the
-- real @~/.config@ or the Nix store. Faithful Haskell port of
-- @rust/wallpaper-tui/tests/tint.rs@.
module TintSpec (tests) where

import Data.Char (toLower)
import Data.List (isInfixOf)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

import WallpaperTui.Accent (TintBackend (..), hexToHls, hlsToHex)
import WallpaperTui.Config (TintState (..), loadTintStateFrom)
import WallpaperTui.Tint
  ( Status (..)
  , TintCtx (..)
  , applyTintCtx
  , gtkCss
  , hyprlandBorderCommandsFor
  , recolorIconText
  , recolorKvantumText
  , rofiRasiText
  , tintIconTree
  , tintKvantumTree
  , tintStateFileOf
  )

import Common (makeIconBase, makeKvantumBase, tintCtx, wallpaper, withTmp)

accent :: String
accent = "#ff00aa"

accentDark :: String
accentDark = "#330044"

accentLight :: String
accentLight = "#ffaadd"

tests :: TestTree
tests =
  testGroup
    "Tint"
    [ testGroup
        "pure writers"
        [ testCase "rofi_rasi replaces accent and selected_bg" $ do
            let base = unlines
                  [ "* {"
                  , "  accent:      #7aa2f7;"
                  , "  selected-bg: #2d3252;"
                  , "  bg: #1a1b26;"
                  , "}"
                  ]
                out = rofiRasiText base accent accentDark
            assertBool "accent replaced" ("accent:      #ff00aa;" `isInfixOf` out)
            assertBool "selected-bg replaced" ("selected-bg: #330044;" `isInfixOf` out)
            assertBool "bg untouched" ("bg: #1a1b26;" `isInfixOf` out)
        , testCase "rofi_rasi preserves structure" $ do
            let base = unlines
                  [ "configuration { font: \"Lilex 12\"; }"
                  , "* { accent: #7aa2f7; }"
                  , "window { width: 720px; }"
                  ]
                out = rofiRasiText base accent accentDark
            assertBool "font survives" ("Lilex 12" `isInfixOf` out)
            assertBool "width survives" ("width: 720px;" `isInfixOf` out)
        , testCase "gtk_css v3 overrides selection" $ do
            let css = gtkCss accent accentDark accentLight 3
            assertBool "selected_bg" ("@define-color theme_selected_bg_color #ff00aa;" `isInfixOf` css)
            assertBool "unfocused" ("@define-color theme_unfocused_selected_bg_color #330044;" `isInfixOf` css)
            assertBool "no gtk4 accent_*" (not ("accent_bg_color" `isInfixOf` css))
        , testCase "gtk_css v4 overrides accent" $ do
            let css = gtkCss accent accentDark accentLight 4
            assertBool "accent_color" ("@define-color accent_color #ff00aa;" `isInfixOf` css)
            assertBool "accent_bg_color" ("@define-color accent_bg_color #ff00aa;" `isInfixOf` css)
            assertBool "accent_fg_color" ("@define-color accent_fg_color #ffffff;" `isInfixOf` css)
        , testCase "hyprland_borders skip without hyprland" $ do
            assertEqual "Nothing" Nothing (hyprlandBorderCommandsFor Nothing accent accentDark)
        , testCase "hyprland_borders emit two keywords" $ do
            let cmds = hyprlandBorderCommandsFor (Just "deadbeef") accent accentDark
            case cmds of
              Nothing -> assertBool "expected cmds" False
              Just cs -> do
                assertEqual "two cmds" 2 (length cs)
                assertEqual "active"
                  ["hyprctl", "keyword", "general:col.active_border", "rgba(#ff00aaff)"]
                  (cs !! 0)
                assertEqual "inactive"
                  ["hyprctl", "keyword", "general:col.inactive_border", "rgba(#330044ff)"]
                  (cs !! 1)
        , testCase "recolor_kvantum preserves alpha and neutrals" $ do
            let sample = "x:#8CAAEE y:#839EDD z:#98B2EF alpha:#8CAAEE4D neutral:#303446 text:#C6D0F5"
                out = recolorKvantumText sample accent accentDark accentLight
            assertBool "accent present" ("#ff00aa" `isInfixOf` out)
            assertBool "dark present" ("#330044" `isInfixOf` out)
            assertBool "light present" ("#ffaadd" `isInfixOf` out)
            assertBool "alpha preserved" ("#ff00aa4D" `isInfixOf` out)
            assertBool "neutral untouched" ("#303446" `isInfixOf` out)
            assertBool "text untouched" ("#C6D0F5" `isInfixOf` out)
            assertBool "orig accents gone" (not ("#8caaee" `isInfixOf` map toLower out))
        , testCase "recolor_icon shifts hue keeps lightness" $ do
            let sample = "a:#1c71d8 b:#438de6 c:#62a0ea d:#99c1f1 e:#afd4ff keep:#e78284"
                out = recolorIconText sample accent
                (ah, _, asat) = hexToHls accent
            mapM_
              ( \orig -> do
                  let (_, ol, _) = hexToHls orig
                      expect = hlsToHex ah ol asat
                  assertBool (orig <> " -> " <> expect <> " missing")
                    (expect `isInfixOf` out)
              )
              ["#1c71d8", "#438de6", "#62a0ea", "#99c1f1", "#afd4ff"]
            assertBool "non-blue kept" ("#e78284" `isInfixOf` out)
        ]
    , testGroup
        "tree tinters"
        [ testCase "tint_kvantum_tree renames and recolors" $
            withTmp $ \tmp -> do
              base <- makeKvantumBase (tmp </> "base")
              let dest = tmp </> "WallpaperTint"
              tintKvantumTree base dest accent accentDark accentLight
              assertBool "kvconfig exists" =<< doesFileExist (dest </> "WallpaperTint.kvconfig")
              assertBool "svg exists" =<< doesFileExist (dest </> "WallpaperTint.svg")
              oldExists <- doesFileExist (dest </> "catppuccin-frappe-blue.kvconfig")
              assertBool "old name gone" (not oldExists)
              kvc <- readFile (dest </> "WallpaperTint.kvconfig")
              assertBool "alpha preserved" ("highlight.color=#ff00aa4d" `isInfixOf` map toLower kvc)
              assertBool "orig accents gone" (not ("#8caaee" `isInfixOf` map toLower kvc))
              svg <- readFile (dest </> "WallpaperTint.svg")
              assertBool "accent in svg" ("#ff00aa" `isInfixOf` map toLower svg)
              assertBool "neutral in svg" ("#303446" `isInfixOf` svg)
        , testCase "tint_icon_tree rewrites name and recolors" $
            withTmp $ \tmp -> do
              base <- makeIconBase (tmp </> "base")
              let dest = tmp </> "MoreWaita-Tint"
              tintIconTree base dest accent
              idx <- readFile (dest </> "index.theme")
              assertBool "Name rewritten" ("Name=MoreWaita-Tint" `isInfixOf` idx)
              assertBool "Inherits survives" ("Inherits=Adwaita,AdwaitaLegacy,hicolor" `isInfixOf` idx)
              folder <- readFile (dest </> "scalable" </> "places" </> "folder.svg")
              assertBool "orig blue gone (#62a0ea)" (not ("#62a0ea" `isInfixOf` map toLower folder))
              assertBool "orig blue gone (#438de6)" (not ("#438de6" `isInfixOf` map toLower folder))
              ruby <- readFile (dest </> "scalable" </> "places" </> "folder-ruby.svg")
              assertBool "black preserved" ("#000000" `isInfixOf` ruby)
        ]
    , testGroup
        "apply_tint orchestrator"
        [ testCase "apply_tint generates all targets" $
            withTmp $ \tmp -> do
              kv <- makeKvantumBase (tmp </> "kvbase")
              ic <- makeIconBase (tmp </> "iconbase")
              ctx <- tintCtx tmp (Just kv) (Just ic)
              wp <- wallpaper tmp
              mStat <- applyTintCtx ctx wp False Internal
              case mStat of
                Nothing -> assertBool "expected status" False
                Just s -> do
                  assertBool "accent starts with #" ("#" `isInfixOf` take 1 (stAccent s))
                  assertEqual "rofi" "ok" (stRofi s)
                  assertEqual "gtk" "ok" (stGtk s)
                  assertEqual "borders skipped" "skipped" (stBorders s)
                  assertEqual "qt" "ok" (stQt s)
                  assertEqual "icons" "ok" (stIcons s)
                  assertBool "kvconfig written" =<< doesFileExist (tcKvantumDest ctx </> "WallpaperTint.kvconfig")
                  assertBool "icon idx written" =<< doesFileExist (tcIconDest ctx </> "index.theme")
                  idx <- readFile (tcIconDest ctx </> "index.theme")
                  assertBool "Name in idx" ("Name=MoreWaita-Tint" `isInfixOf` idx)
                  assertBool "select written" =<< doesFileExist (tcKvantumSelect ctx)
                  sel <- readFile (tcKvantumSelect ctx)
                  assertBool "theme=WallpaperTint" ("theme=WallpaperTint" `isInfixOf` sel)
                  assertBool "icons not selected" (not (stIconsSelected s))
                  st <- loadTintStateFrom (tintStateFileOf ctx)
                  assertEqual "tint state accent" (Just (stAccent s)) (tsAccent st)
        , testCase "apply_tint caches svg trees on same accent" $
            withTmp $ \tmp -> do
              kv <- makeKvantumBase (tmp </> "kvbase")
              ic <- makeIconBase (tmp </> "iconbase")
              ctx <- tintCtx tmp (Just kv) (Just ic)
              wp <- wallpaper tmp
              first <- applyTintCtx ctx wp False Internal
              second <- applyTintCtx ctx wp False Internal
              case (first, second) of
                (Just f, Just s) -> do
                  assertEqual "same accent" (stAccent f) (stAccent s)
                  assertEqual "qt cached" "cached" (stQt s)
                  assertEqual "icons cached" "cached" (stIcons s)
                _ -> assertBool "expected both to run" False
        , testCase "apply_tint no_tint returns None" $
            withTmp $ \tmp -> do
              ctx <- tintCtx tmp Nothing Nothing
              wp <- wallpaper tmp
              mStat <- applyTintCtx ctx wp True Internal
              assertEqual "None" Nothing mStat
        , testCase "apply_tint skips missing bases" $
            withTmp $ \tmp -> do
              ctx <- tintCtx tmp Nothing Nothing
              wp <- wallpaper tmp
              mStat <- applyTintCtx ctx wp False Internal
              case mStat of
                Nothing -> assertBool "expected status" False
                Just s -> do
                  assertEqual "qt skipped" "skipped" (stQt s)
                  assertEqual "icons skipped" "skipped" (stIcons s)
                  assertEqual "rofi ok" "ok" (stRofi s)
                  assertEqual "gtk ok" "ok" (stGtk s)
        , testCase "apply_tint missing path is noop" $
            withTmp $ \tmp -> do
              ctx <- tintCtx tmp Nothing Nothing
              mStat <- applyTintCtx ctx "/no/such/wp.png" False Internal
              assertEqual "None" Nothing mStat
        ]
    ]