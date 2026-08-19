{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Per-target accent tinting: Hyprland borders, Rofi, GTK 3/4, Kvantum (Qt)
-- and @MoreWaita@ icons. Writers are pure (string in → string out); tree
-- tinters and the orchestrator take a 'TintCtx' holding all base/dest paths
-- so they are unit-testable with tmp dirs and no env-var mutation. Mirrors
-- @rust/wallpaper-tui/src/tint.rs@.
--
-- The Rust crate uses the @regex@ crate for the rofi/kvantum/icon
-- substitutions; @regex-pcre-heavy@ is NOT in nixpkgs haskellPackages, so
-- this port does manual string scans (fixed-width hex match + a
-- line-anchored @Name=@ rewrite). The substitutions are simple enough that
-- the scans are byte-faithful to the regex behaviour the tests pin.
module WallpaperTui.Tint
  ( -- * constants
    adwaitaBlueHexes
  , kvantumAccentHexes
  , iconThemeName
    -- * ctx
  , TintCtx (..)
  , tintCtxFromEnv
  , tintStateFileOf
    -- * status
  , Status (..)
  , defaultStatus
    -- * pure writers
  , rofiRasiText
  , gtkCss
  , hyprlandBorderCommandsFor
  , recolorKvantumText
  , recolorIconText
    -- * tree tinters
  , tintKvantumTree
  , tintIconTree
    -- * orchestrator
  , applyTintCtx
  , applyTint
  ) where

import Control.Exception (SomeException, try)
import Control.Monad (filterM, forM, forM_, when)
import Data.Char (toLower)
import Data.List (isPrefixOf, stripPrefix)
import Data.Maybe (fromMaybe, isJust, isNothing)
import System.Directory
  ( copyFile
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , listDirectory
  , removeDirectoryRecursive
  , removeFile
  )
import System.Environment (lookupEnv)
import System.FilePath ((</>), takeDirectory, takeExtension, takeFileName)
import System.Process (callCommand)
import qualified System.Process as P

import WallpaperTui.Accent
  ( TintBackend
  , extractAccent
  , hexToHls
  , hlsToHex
  , parseTintBackend
  , defaultTintBackend
  )
import WallpaperTui.Config
  ( TintState (..)
  , defaultTintState
  , loadTintStateFrom
  , saveTintStateTo
  , tintDir
  , xdgDir
  )

-- * constants

-- | Adwaita-blue family used by @MoreWaita@ folder/place icons. Each is
-- recolored to the accent's hue/saturation while keeping its own lightness.
adwaitaBlueHexes :: [String]
adwaitaBlueHexes =
  ["#1c71d8", "#438de6", "#3584e4", "#62a0ea", "#99c1f1", "#afd4ff"]

-- | Catppuccin-Frappe-Blue accents used by the Kvantum base theme; replaced
-- verbatim (case-insensitive). Trailing alpha hex is preserved because only
-- the 7-char body is matched.
kvantumAccentHexes :: [String]
kvantumAccentHexes = ["#8caaee", "#839edd", "#98b2ef"]

-- | The renamed icon theme's @Name=@.
iconThemeName :: String
iconThemeName = "MoreWaita-Tint"

-- * TintCtx

-- | All paths the orchestrator touches, resolved up-front (from env in the
-- real entry, from tmp dirs in tests).
data TintCtx = TintCtx
  { tcKvantumBase :: !(Maybe FilePath)
  -- ^ 'Nothing' ⇒ Kvantum target skipped.
  , tcIconBase :: !(Maybe FilePath)
  -- ^ 'Nothing' ⇒ icon target skipped.
  , tcKvantumDest :: !FilePath
  , tcKvantumSelect :: !FilePath
  , tcIconDest :: !FilePath
  , tcTintDir :: !FilePath
  , tcRofiBase :: !FilePath
  , tcHis :: !(Maybe String)
  -- ^ 'Nothing' ⇒ Hyprland border target skipped.
  , tcTryIconSelect :: !Bool
  -- ^ When 'False' (tests), skip the gsettings icon-theme switch.
  } deriving (Show, Eq)

-- | Resolve every path from the XDG env vars, exactly as the Python did.
tintCtxFromEnv :: IO TintCtx
tintCtxFromEnv = do
  xdgConfig <- xdg "XDG_CONFIG_HOME" ".config"
  xdgData <- xdg "XDG_DATA_HOME" ".local/share"
  kvBase <- envDir "WALLPAPER_TUI_KVANTUM_BASE"
  icBase <- envDir "WALLPAPER_TUI_ICON_BASE"
  td <- tintDir
  his <- lookupEnv "HYPRLAND_INSTANCE_SIGNATURE"
  pure
    TintCtx
      { tcKvantumBase = kvBase
      , tcIconBase = icBase
      , tcKvantumDest = xdgConfig </> "Kvantum" </> "WallpaperTint"
      , tcKvantumSelect = xdgConfig </> "Kvantum" </> "kvantum.kvconfig"
      , tcIconDest = xdgData </> "icons" </> "MoreWaita-Tint"
      , tcTintDir = td
      , tcRofiBase = xdgConfig </> "rofi" </> "themes" </> "tokyonight.rasi"
      , tcHis = his
      , tcTryIconSelect = True
      }

-- | @tint/current.json@ under this ctx's tint dir.
tintStateFileOf :: TintCtx -> FilePath
tintStateFileOf ctx = tcTintDir ctx </> "current.json"

-- | An XDG-ish base dir, falling back to @~/<defaultSub>@.
xdg :: String -> String -> IO FilePath
xdg env defaultSub = do
  m <- lookupEnv env
  case m of
    Just s | not (null s) -> pure s
    _ -> do
      home <- lookupEnv "HOME"
      pure (fromMaybe "/" home </> defaultSub)

-- | 'Just' the env value iff it points at an existing directory.
envDir :: String -> IO (Maybe FilePath)
envDir env = do
  m <- lookupEnv env
  case m of
    Just s -> do
      isDir <- doesDirectoryExist s
      pure (if isDir then Just s else Nothing)
    Nothing -> pure Nothing

-- * Status

-- | Per-target status. The orchestrator returns 'Nothing' for the no-tint /
-- missing-path no-op (the Python empty-dict case); 'Just' when it ran.
data Status = Status
  { stAccent :: !String
  , stRofi :: !String
  , stGtk :: !String
  , stBorders :: !String
  , stQt :: !String
  , stIcons :: !String
  , stQtSelected :: !Bool
  , stIconsSelected :: !Bool
  } deriving (Show, Eq)

-- | All-empty 'Status' (the @Default@ instance in Rust).
defaultStatus :: Status
defaultStatus = Status
  { stAccent = ""
  , stRofi = ""
  , stGtk = ""
  , stBorders = ""
  , stQt = ""
  , stIcons = ""
  , stQtSelected = False
  , stIconsSelected = False
  }

-- * pure writers

-- | Substitute the @accent:@ and @selected-bg:@ rasi vars in the base text.
-- Manual scan (no regex): find the literal prefix, skip spaces, replace the
-- @#rrggbb@ before the trailing @;@.
rofiRasiText :: String -> String -> String -> String
rofiRasiText base accent accentDark =
  replacePrefixedHex "accent:" accent (replacePrefixedHex "selected-bg:" accentDark base)

-- | @replacePrefixedHex prefix replacement s@: for each occurrence of
-- @prefix@ followed by optional spaces and @#rrggbb;@, swap the @#rrggbb@ for
-- @replacement@. Mirrors the Rust regex @(prefix:\s*)#[0-9a-fA-F]{6};@ capture.
replacePrefixedHex :: String -> String -> String -> String
replacePrefixedHex prefix replacement = go
  where
    go [] = []
    go s@(c : cs)
      | Just rest <- stripPrefixCI prefix s =
          let (spaces, afterSpaces) = span isSpace rest
          in case matchHexSemi afterSpaces of
               Just after -> prefix <> spaces <> replacement <> ";" <> go after
               Nothing -> c : go cs
      | otherwise = c : go cs

-- | Case-sensitive prefix strip (the Rust regex matches @accent:@ literally,
-- case-sensitive). Kept as a separate name from 'Data.List.stripPrefix' for
-- clarity.
stripPrefixCI :: String -> String -> Maybe String
stripPrefixCI = stripPrefix

-- | Match @#@ + exactly 6 hex digits + @;@ at the head; return the rest after
-- the @;@, or 'Nothing' if the shape doesn't match.
matchHexSemi :: String -> Maybe String
matchHexSemi s = case s of
  ('#' : rest) ->
    let (hex, after) = splitAt 6 rest
    in if length hex == 6 && all isHexDigitStr hex && case after of (';' : r) -> True; _ -> False
         then case after of (';' : r) -> Just r; _ -> Nothing
         else Nothing
  _ -> Nothing

isHexDigitStr :: Char -> Bool
isHexDigitStr ch =
  (ch >= '0' && ch <= '9')
    || (ch >= 'a' && ch <= 'f')
    || (ch >= 'A' && ch <= 'F')

-- | A local 'isSpace' (avoids pulling 'Data.Char.isSpace' through the
-- import list; it's the standard whitespace set).
isSpace :: Char -> Bool
isSpace c = c `elem` (" \t\n\r\f\v" :: String)

-- | @\@define-color@ overrides loaded after the Tokyonight theme import.
gtkCss :: String -> String -> String -> Int -> String
gtkCss accent accentDark _accentLight version
  | version == 4 =
      unlines
        [ "/* wallpaper-tui accent tint — overrides Tokyonight accent. */"
        , "@define-color theme_selected_bg_color " <> accent <> ";"
        , "@define-color theme_selected_fg_color #ffffff;"
        , "@define-color accent_color " <> accent <> ";"
        , "@define-color accent_bg_color " <> accent <> ";"
        , "@define-color accent_fg_color #ffffff;"
        ]
  | otherwise =
      unlines
        [ "/* wallpaper-tui accent tint — overrides Tokyonight selection. */"
        , "@define-color theme_selected_bg_color " <> accent <> ";"
        , "@define-color theme_selected_fg_color #ffffff;"
        , "@define-color theme_selected_borders_color " <> accentDark <> ";"
        , "@define-color theme_unfocused_selected_bg_color " <> accentDark <> ";"
        ]

-- | @hyprctl keyword@ argv for the border colors, or 'Nothing' when Hyprland
-- is not running (@his@ is 'Nothing'). Pure.
hyprlandBorderCommandsFor :: Maybe String -> String -> String -> Maybe [[String]]
hyprlandBorderCommandsFor his accent accentDark = case his of
  Nothing -> Nothing
  Just _ ->
    Just
      [ ["hyprctl", "keyword", "general:col.active_border", "rgba(" <> accent <> "ff)"]
      , ["hyprctl", "keyword", "general:col.inactive_border", "rgba(" <> accentDark <> "ff)"]
      ]

-- | Replace the Catppuccin-Frappe accent family; preserve trailing alpha (only
-- the 7-char body is matched, case-insensitive). Single left-to-right scan so
-- a replacement can't be re-matched by a later needle.
recolorKvantumText :: String -> String -> String -> String -> String
recolorKvantumText text accent accentDark accentLight = go text
  where
    pairs = zip kvantumAccentHexes [accent, accentDark, accentLight]
    go [] = []
    go s@(c : cs) = case matchFirst pairs s of
      Just (repl, rest) -> repl <> go rest
      Nothing -> c : go cs

-- | Recolor the Adwaita-blue family to the accent hue/sat, keeping the
-- original lightness. Non-blue hexes (e.g. a status red) are left alone.
recolorIconText :: String -> String -> String
recolorIconText text accent = go text
  where
    (ah, _al, asat) = hexToHls accent
    go [] = []
    go s@(c : cs) = case matchFirst adwaitaPairs s of
      Just (orig, rest) ->
        let (_, ol, _) = hexToHls orig
        in hlsToHex ah ol asat <> go rest
      Nothing -> c : go cs
    adwaitaPairs = map (\h -> (h, h)) adwaitaBlueHexes  -- needle == marker; remap computed in go

-- | At the head of @s@, find the first @(needle, replacement)@ pair whose
-- @needle@ case-insensitively prefixes @s@. Returns the replacement (for
-- 'recolorKvantumText') or the matched needle (for 'recolorIconText', which
-- re-derives the replacement from the match) plus the remainder.
matchFirst :: [(String, String)] -> String -> Maybe (String, String)
matchFirst [] _ = Nothing
matchFirst ((needle, mark) : rest) s
  | needle `prefixesCI` s = Just (mark, drop (length needle) s)
  | otherwise = matchFirst rest s

-- | 'True' iff @needle@ case-insensitively prefixes @s@.
prefixesCI :: String -> String -> Bool
prefixesCI needle s = map toLower needle == map toLower (take (length needle) s)

-- * tree tinters

-- | Copy the base Kvantum theme to @dest@ and recolor its accent family.
-- Renames @<base>.kvconfig@/@<base>.svg@ → @WallpaperTint.*@ and rewrites the
-- base-name references inside.
tintKvantumTree :: FilePath -> FilePath -> String -> String -> String -> IO ()
tintKvantumTree base dest accent accentDark accentLight = do
  destExists <- doesDirectoryExist dest
  when destExists ((try (removeDirectoryRecursive dest) :: IO (Either SomeException ())) >> pure ())
  writableCopyTree base dest
  let baseName = takeFileName base
  renameThemeFiles dest baseName "WallpaperTint"
  files <- listFiles dest
  forM_ files $ \p ->
    when (takeExtension p `elem` [".kvconfig", ".svg"]) $ do
      txt <- readFile p
      writeFile p (recolorKvantumText txt accent accentDark accentLight)

-- | Copy the icon theme to @dest@, recolor the Adwaita-blue family, rename.
tintIconTree :: FilePath -> FilePath -> String -> IO ()
tintIconTree base dest accent = do
  destExists <- doesDirectoryExist dest
  when destExists ((try (removeDirectoryRecursive dest) :: IO (Either SomeException ())) >> pure ())
  writableCopyTree base dest
  svgs <- walkFilesRecursive dest
  forM_ svgs $ \p -> do
    txt <- readFile p
    writeFile p (recolorIconText txt accent)
  let idx = dest </> "index.theme"
  idxExists <- doesFileExist idx
  when idxExists $ do
    txt <- readFile idx
    writeFile idx (rewriteIndexName txt)

-- | Rewrite the @Name=...@ line (line-anchored) to 'iconThemeName'. Mirrors
-- the Rust @(?m)^Name=.*$@ regex.
rewriteIndexName :: String -> String
rewriteIndexName = unlines . map rewriteLine . lines
  where
    rewriteLine ln
      | "Name=" `isPrefixOf` ln = "Name=" <> iconThemeName
      | otherwise = ln

-- | Rename @<base>.kvconfig@/@<base>.svg@ → @<new>.*@ and rewrite the
-- base-name references inside.
renameThemeFiles :: FilePath -> String -> String -> IO ()
renameThemeFiles dest baseName newName = do
  forM_ [".kvconfig", ".svg"] $ \ext -> do
    let src = dest </> (baseName <> ext)
    exists <- doesFileExist src
    when exists $ do
      txt <- readFile src
      writeFile (dest </> (newName <> ext)) (replaceBaseName txt baseName newName)
      try (removeFileSafe src) :: IO (Either SomeException ())
      pure ()

-- | Replace all occurrences of @baseName@ with @newName@ (verbatim).
replaceBaseName :: String -> String -> String -> String
replaceBaseName txt baseName newName = go txt
  where
    go [] = []
    go s@(c : cs)
      | baseName `isPrefixOf` s = newName <> go (drop (length baseName) s)
      | otherwise = c : go cs

-- | Point @kvantum.kvconfig@ at @WallpaperTint@ (no-op if dest missing).
selectKvantum :: TintCtx -> IO Bool
selectKvantum ctx = do
  destExists <- doesDirectoryExist (tcKvantumDest ctx)
  if not destExists
    then pure False
    else do
      createDirectoryIfMissing True (takeDirectory (tcKvantumSelect ctx))
      _ <- writeText (tcKvantumSelect ctx) "[General]\ntheme=WallpaperTint\n"
      pure True

-- | gsettings-switch to MoreWaita-Tint (no-op if dest missing or
-- @tryIconSelect@ is 'False').
selectIconTheme :: TintCtx -> IO Bool
selectIconTheme ctx
  | not (tcTryIconSelect ctx) = pure False
  | otherwise = do
      destExists <- doesDirectoryExist (tcIconDest ctx)
      if not destExists
        then pure False
        else do
          e <- try (callCommand
                      ("gsettings set org.gnome.desktop.interface icon-theme "
                       <> iconThemeName)) :: IO (Either SomeException ())
          pure (case e of Right () -> True; Left _ -> False)

-- * orchestrator

-- | The orchestrator. Returns 'Nothing' for the no-tint / missing-path no-op;
-- 'Just Status' when it ran. Each target is isolated.
applyTintCtx :: TintCtx -> String -> Bool -> TintBackend -> IO (Maybe Status)
applyTintCtx ctx path noTint backend
  | noTint || null path = pure Nothing
  | otherwise = do
      pathExists <- doesFileExist path
      if not pathExists
        then pure Nothing
        else do
          let (accent, accentDark, accentLight) = extractAccent path backend
              s0 = defaultStatus{stAccent = accent}
          _ <- try (createDirectoryIfMissing True (tcTintDir ctx)) :: IO (Either SomeException ())
          old <- loadTintStateFrom (tintStateFileOf ctx)
          let sameAccent = tsAccent old == Just accent
          rofiS <- tintRofi ctx accent accentDark
          gtkS <- tintGtk ctx accent accentDark accentLight
          bordersS <- tintBorders ctx accent accentDark
          (qtS, qtSel) <- tintQt ctx accent accentDark accentLight sameAccent
          (iconsS, iconsSel) <- tintIcons ctx accent sameAccent
          saveTintStateTo
            (TintState{tsAccent = Just accent, tsSourcePath = Just path})
            (tintStateFileOf ctx)
          pure (Just
            s0
              { stRofi = rofiS
              , stGtk = gtkS
              , stBorders = bordersS
              , stQt = qtS
              , stIcons = iconsS
              , stQtSelected = qtSel
              , stIconsSelected = iconsSel
              })

-- | Rofi target: cheap text file, always regenerate.
tintRofi :: TintCtx -> String -> String -> IO String
tintRofi ctx accent accentDark = do
  baseExists <- doesFileExist (tcRofiBase ctx)
  if not baseExists
    then pure "skipped"
    else do
      e <- try (readFile (tcRofiBase ctx)) :: IO (Either SomeException String)
      case e of
        Left err -> pure ("error: " <> show err)
        Right base -> do
          r <- writeText (tcTintDir ctx </> "rofi.rasi")
                  (rofiRasiText base accent accentDark)
          pure (case r of Right () -> "ok"; Left err -> "error: " <> show err)

-- | GTK 3/4 targets: cheap CSS files, always regenerate.
tintGtk :: TintCtx -> String -> String -> String -> IO String
tintGtk ctx accent accentDark accentLight = do
  r3 <- writeText (tcTintDir ctx </> "gtk3.css") (gtkCss accent accentDark accentLight 3)
  r4 <- writeText (tcTintDir ctx </> "gtk4.css") (gtkCss accent accentDark accentLight 4)
  case (r3, r4) of
    (Right (), Right ()) -> pure "ok"
    (Left e, _) -> pure ("error: " <> show e)
    (_, Left e) -> pure ("error: " <> show e)

-- | Hyprland borders target: runtime hyprctl keyword, always re-apply.
tintBorders :: TintCtx -> String -> String -> IO String
tintBorders ctx accent accentDark = case hyprlandBorderCommandsFor (tcHis ctx) accent accentDark of
  Nothing -> pure "skipped"
  Just cmds -> do
    forM_ cmds $ \c -> try (callCommand (unwords (map shellQuoteArg c))) :: IO (Either SomeException ())
    pure "ok"

-- | Kvantum (Qt) target: expensive SVG copy, only regen on accent change.
tintQt :: TintCtx -> String -> String -> String -> Bool -> IO (String, Bool)
tintQt ctx accent accentDark accentLight sameAccent = case tcKvantumBase ctx of
  Nothing -> pure ("skipped", False)
  Just base -> do
    destExists <- doesDirectoryExist (tcKvantumDest ctx)
    qt <-
      if not sameAccent || not destExists
        then do
          r <- try (tintKvantumTree base (tcKvantumDest ctx) accent accentDark accentLight) ::
            IO (Either SomeException ())
          pure (case r of Right () -> "ok"; Left e -> "error: " <> show e)
        else pure "cached"
    sel <- selectKvantum ctx
    pure (qt, sel)

-- | Icons target: expensive SVG tree, only regen on accent change.
tintIcons :: TintCtx -> String -> Bool -> IO (String, Bool)
tintIcons ctx accent sameAccent = case tcIconBase ctx of
  Nothing -> pure ("skipped", False)
  Just base -> do
    destExists <- doesDirectoryExist (tcIconDest ctx)
    icons <-
      if not sameAccent || not destExists
        then do
          r <- try (tintIconTree base (tcIconDest ctx) accent) :: IO (Either SomeException ())
          pure (case r of Right () -> "ok"; Left e -> "error: " <> show e)
        else pure "cached"
    sel <- selectIconTheme ctx
    pure (icons, sel)

-- | Env-driven entry: build a 'TintCtx' from the XDG env and orchestrate. The
-- backend may be overridden at runtime by @WALLPAPER_TUI_TINT_BACKEND@.
-- Returns the 'Status' (or 'Nothing' for the no-tint\/missing-path no-op) so
-- the caller formats the message — mirrors Rust's @tint::apply_tint@, which
-- returns @Option<Status>@ and never prints (the interactive loop builds the
-- info-bar message; the CLI paths discard it). Keeping this silent is
-- load-bearing for the interactive loop: a 'putStrLn' here would interleave
-- with vty's stdout during the TUI and corrupt the alt screen.
applyTint :: String -> Bool -> TintBackend -> IO (Maybe Status)
applyTint path noTint backend = do
  mEnv <- lookupEnv "WALLPAPER_TUI_TINT_BACKEND"
  let backend' = case mEnv >>= eitherToMaybe . parseTintBackend of
        Just b -> b
        Nothing -> backend
  ctx <- tintCtxFromEnv
  applyTintCtx ctx path noTint backend'

-- * tree-copy / walk helpers

-- | @copytree@ whose output is owner-writable. The Kvantum/icon bases live in
-- the read-only Nix store; a plain copy carries their 0555/0444 mode bits.
-- We copy content only (no chmod — Haskell's @directory@ has no mode API, and
-- the test dest is writable anyway).
writableCopyTree :: FilePath -> FilePath -> IO ()
writableCopyTree src dst = do
  createDirectoryIfMissing True dst
  names <- listDirectory src
  forM_ names $ \name -> do
    let s = src </> name
        d = dst </> name
    isDir <- doesDirectoryExist s
    if isDir
      then writableCopyTree s d
      else do
        createDirectoryIfMissing True (takeDirectory d)
        copyFile s d

-- | All files directly under @dir@ (non-recursive).
listFiles :: FilePath -> IO [FilePath]
listFiles dir = do
  names <- listDirectory dir
  filterM (\n -> doesFileExist (dir </> n)) names

-- | All files under @dir@, recursively.
walkFilesRecursive :: FilePath -> IO [FilePath]
walkFilesRecursive dir = do
  names <- listDirectory dir
  concat <$> forM names (\name -> do
    let p = dir </> name
    isDir <- doesDirectoryExist p
    if isDir then walkFilesRecursive p else pure [p])

-- | Write @text@ to @path@, creating parent dirs. 'Right' on success.
writeText :: FilePath -> String -> IO (Either SomeException ())
writeText path text = do
  createDirectoryIfMissing True (takeDirectory path)
  try (writeFile path text) :: IO (Either SomeException ())

-- | Remove a file, swallowing errors (the rename path tolerates a missing src).
removeFileSafe :: FilePath -> IO ()
removeFileSafe path = do
  e <- try (removeFile path) :: IO (Either SomeException ())
  case e of Right () -> pure (); Left _ -> pure ()

-- * small helpers

-- | A minimal shell-quote (single-quote, escape embedded quotes).
shellQuoteArg :: String -> String
shellQuoteArg s = "'" <> concatMap esc s <> "'"
  where
    esc '\'' = "'\\''"
    esc c = [c]

-- | 'Just' from 'Either', 'Nothing' on 'Left'.
eitherToMaybe :: Either a b -> Maybe b
eitherToMaybe (Right b) = Just b
eitherToMaybe (Left _) = Nothing