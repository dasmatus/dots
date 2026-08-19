{-# LANGUAGE LambdaCase #-}

-- | Binary entry point: argument dispatch + the non-interactive CLI paths.
-- The interactive TUI loop lives in "WallpaperTui.Run"; this module hosts the
-- argument parser (manual, mirroring the Rust clap surface but without a
-- clap dep) and the three non-interactive paths (@--restore@,
-- @--cache-previews@, @--output NAME PATH@). The CLI surface is identical to
-- the previous Python\/Rust binary so the Nix service, @random_wp.nix@ and
-- the Hyprland @exec-once@ keep working unchanged.
module Main (main) where

import Data.List (isPrefixOf)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

import WallpaperTui.Accent
  ( TintBackend
  , defaultTintBackend
  , parseTintBackend
  )
import WallpaperTui.Awww (Group (..), applyWallpaper, liveAwww, restoreGroups)
import WallpaperTui.Config
  ( Config (..)
  , OutputOverride (..)
  , State (..)
  , configRecursive
  , configTintBackend
  , configTransitionDuration
  , configTransitionType
  , configWallpaperFolder
  , defaultColor
  , loadConfig
  , loadState
  , previewCacheDir
  , saveState
  )
import WallpaperTui.Preview (CacheStats (..), cachePreviews, parsePreviewSize)
import WallpaperTui.Run (runTui)
import WallpaperTui.Tint (applyTint)

-- * Args

-- | The parsed argument surface — mirrors Rust's clap @Args@ struct exactly.
data Args = Args
  { argRestore :: !Bool
  , argOutput :: !(Maybe String)
  , argMode :: !String
  , argColor :: !String
  , argNoTint :: !Bool
  , argTintBackend :: !(Maybe String)
  , argCachePreviews :: !Bool
  , argPreviewSize :: !String
  , argPath :: !(Maybe String)
  }

-- | @Args::default@ — every field at its Rust default.
defaultArgs :: Args
defaultArgs =
  Args
    { argRestore = False
    , argOutput = Nothing
    , argMode = "fill"
    , argColor = defaultColor
    , argNoTint = False
    , argTintBackend = Nothing
    , argCachePreviews = False
    , argPreviewSize = "320x200"
    , argPath = Nothing
    }

-- | Parse the command line. Manual (no clap dep), accepting both
-- @--flag value@ and @--flag=value@ forms. Unknown flags error; the first
-- non-flag token is the positional @PATH@. Mirrors clap's @Args::parse@.
parseArgs :: [String] -> Either String Args
parseArgs = go defaultArgs . normalizeEq
  where
    go acc [] = Right acc
    go acc ("--restore" : rest) = go acc{argRestore = True} rest
    go acc ("--cache-previews" : rest) = go acc{argCachePreviews = True} rest
    go acc ("--no-tint" : rest) = go acc{argNoTint = True} rest
    go acc ("--output" : v : rest) = go acc{argOutput = Just v} rest
    go _ ("--output" : []) = Left "missing value for --output"
    go acc ("--mode" : v : rest) = go acc{argMode = v} rest
    go _ ("--mode" : []) = Left "missing value for --mode"
    go acc ("--color" : v : rest) = go acc{argColor = v} rest
    go _ ("--color" : []) = Left "missing value for --color"
    go acc ("--tint-backend" : v : rest) = go acc{argTintBackend = Just v} rest
    go _ ("--tint-backend" : []) = Left "missing value for --tint-backend"
    go acc ("--preview-size" : v : rest) = go acc{argPreviewSize = v} rest
    go _ ("--preview-size" : []) = Left "missing value for --preview-size"
    go acc (p : rest)
      | "--" `isPrefixOf` p = Left ("unknown flag: " <> p)
      | otherwise = go acc{argPath = Just p} rest

-- | Split every @--flag=value@ into @["--flag", "value"]@ so the parser only
-- deals with the space-separated form.
normalizeEq :: [String] -> [String]
normalizeEq = concatMap splitEq
  where
    splitEq s = case break (== '=') s of
      (_, '=' : _) -> let (k, _ : v) = break (== '=') s in [k, v]
      _ -> [s]

-- * Backend resolution

-- | Resolve the tint backend: the @--tint-backend@ CLI flag wins (falling
-- back to 'defaultTintBackend' on an unparseable value), else the config's
-- @tint_backend@ (same fallback). Mirrors @resolve_backend@.
resolveBackend :: Maybe String -> String -> TintBackend
resolveBackend argsBackend configBackend =
  case argsBackend of
    Just b -> fromRight defaultTintBackend (parseTintBackend b)
    Nothing -> fromRight defaultTintBackend (parseTintBackend configBackend)
  where
    fromRight d (Right x) = x
    fromRight d _ = d

-- * Main

-- | Entry point. Mirrors @main@: dispatch on the args, sharing
-- 'WallpaperTui.Config.loadConfig'\/'loadState'.
main :: IO ()
main = do
  rawArgs <- getArgs
  args <- case parseArgs rawArgs of
    Left err -> do
      hPutStrLn stderr ("wallpaper-tui: " <> err)
      exitWith (ExitFailure 2)
      -- unreachable; keep the type-checker happy
      pure defaultArgs
    Right a -> pure a
  config <- loadConfig
  state <- loadState
  let backend = resolveBackend (argTintBackend args) (configTintBackend config)
  if argRestore args
    then do
      n <- restoreAll config state (argNoTint args) backend
      exitWith (if n == 0 then ExitSuccess else ExitFailure n)
    else if argCachePreviews args
      then do
        runCache config (argPreviewSize args)
        exitWith ExitSuccess
      else case argPath args of
        Just path -> do
          output <- case argOutput args of
            Just o -> pure o
            Nothing -> do
              hPutStrLn stderr "wallpaper-tui: --output is required when a path is given"
              exitWith (ExitFailure 1)
              pure ""
          applyNoninteractive
            config
            state
            output
            path
            (argMode args)
            (argColor args)
            (argNoTint args)
            backend
          exitWith ExitSuccess
        Nothing -> do
          runTui config state (argNoTint args) backend

-- * Non-interactive paths

-- | Re-apply every declared output, tinting from the first output's wallpaper.
-- Returns the exit code (1 if nothing to restore, 0 otherwise). Mirrors
-- @cli::restore_all@.
restoreAll :: Config -> State -> Bool -> TintBackend -> IO Int
restoreAll config state noTint backend = do
  groups <- restoreGroups config state
  if null groups
    then do
      hPutStrLn stderr "wallpaper-tui: nothing to restore."
      pure 1
    else do
      applyWallpaper
        liveAwww
        groups
        (configTransitionType config)
        (configTransitionDuration config)
      _ <- applyTint (gPath (head groups)) noTint backend
      hPutStrLn
        stderr
        ("wallpaper-tui: restored " <> show (length groups) <> " output(s).")
      pure 0

-- | Non-interactive apply of one path to one output, with tint. Mirrors
-- @cli::apply_noninteractive@.
applyNoninteractive ::
  Config ->
  State ->
  String ->
  String ->
  String ->
  String ->
  Bool ->
  TintBackend ->
  IO ()
applyNoninteractive config state output path mode color noTint backend = do
  let ov = OutputOverride (Just path) (Just mode) (Just color)
      state' =
        state{stateOutputs = Map.insert output ov (stateOutputs state)}
  saveState state'
  let group = Group output path mode color
  applyWallpaper
    liveAwww
    [group]
    (configTransitionType config)
    (configTransitionDuration config)
  _ <- applyTint path noTint backend
  hPutStrLn stderr ("wallpaper-tui: applied " <> path <> " to " <> output <> ".")

-- | Regenerate the wallpaper thumbnail cache (@--cache-previews@). Mirrors
-- @cli::run_cache@.
runCache :: Config -> String -> IO ()
runCache config previewSize = do
  let (w, h) = fromMaybe (320, 200) (parsePreviewSize previewSize)
  cacheDir <- previewCacheDir
  stats <-
    cachePreviews
      (configWallpaperFolder config)
      (configRecursive config)
      cacheDir
      (w, h)
  hPutStrLn
    stderr
    ( "wallpaper-tui: cached "
        <> show (csWritten stats)
        <> " new, skipped "
        <> show (csSkipped stats)
        <> "."
    )