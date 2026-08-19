-- | Declarative (read-only, from Nix) config and writable runtime state, plus
-- the per-output effective-value merge. Mirrors the two-file split the Nix
-- module writes: @config.json@ is owned by Nix, @state.json@ holds the TUI's
-- runtime overrides. Ports @rust/wallpaper-tui/src/config.rs@; the JSON field
-- names match @nix/home/wallpaper-tui.nix@'s 'declarativeConfig' exactly.
module WallpaperTui.Config
  ( -- * Palette / constants
    colorPalette
  , defaultColor
  , modes
  , defaultAccent
  , defaultAccentDark
  , defaultAccentLight
  , -- * Paths
    xdgDir
  , configFile
  , stateFile
  , previewCacheDir
  , tintDir
  , tintStateFile
  , -- * Config
    Config (..)
  , defaultConfig
  , OutputConfig (..)
  , loadConfig
  , loadConfigFrom
  , -- * State
    State (..)
  , OutputOverride (..)
  , loadState
  , loadStateFrom
  , saveState
  , saveStateTo
  , -- * Effective merge
    Effective (..)
  , effectiveOutput
  , -- * Tint state
    TintState (..)
  , defaultTintState
  , loadTintState
  , loadTintStateFrom
  , saveTintState
  , saveTintStateTo
  ) where

import Control.Exception (SomeException, try)
import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , eitherDecodeStrict'
  , object
  , withObject
  , (.:?)
  , (.!=)
  , (.=)
  )
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString as BS
import Data.Aeson (encode)
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.FilePath ((</>), takeDirectory)

-- | Fill color for the @c@ cycle (letterbox modes) — Tokyonight-adjacent.
colorPalette :: [String]
colorPalette =
  [ "#d2a1a1"
  , "#1a1b26"
  , "#000000"
  , "#ffffff"
  , "#7aa2f7"
  , "#bb9af7"
  , "#9ece6a"
  , "#f7768e"
  ]

-- | The default fill color (also the @--color@ CLI default).
defaultColor :: String
defaultColor = "#d2a1a1"

-- | The awww @--resize@ modes the picker cycles through.
modes :: [String]
modes = ["fill", "stretch", "fit", "center", "tile"]

-- | Fallback accent = Tokyonight blue (the rofi accent), so a failed extraction
-- leaves the themes visually unchanged rather than blank.
defaultAccent :: String
defaultAccent = "#7aa2f7"

defaultAccentDark :: String
defaultAccentDark = "#3b4261"

defaultAccentLight :: String
defaultAccentLight = "#a9b1d6"

-- | ad-hoc resolution of an XDG-ish base dir, matching the Python's
-- @os.environ.get(..., default)@ behaviour.
xdgDir :: String -> String -> IO FilePath
xdgDir env defaultSub = do
  m <- lookupEnv env
  case m of
    Just s | not (null s) -> pure s
    _ -> do
      home <- lookupEnv "HOME"
      pure (fromMaybe "/" home </> defaultSub)

configFile :: IO FilePath
configFile = do
  x <- xdgDir "XDG_CONFIG_HOME" ".config"
  pure (x </> "wallpaper-tui" </> "config.json")

stateFile :: IO FilePath
stateFile = do
  x <- xdgDir "XDG_STATE_HOME" ".local/state"
  pure (x </> "wallpaper-tui" </> "state.json")

-- | @XDG_CACHE_HOME/wallpaper-tui/thumbs@ — chafa-free thumbnail cache.
previewCacheDir :: IO FilePath
previewCacheDir = do
  x <- xdgDir "XDG_CACHE_HOME" ".cache"
  pure (x </> "wallpaper-tui" </> "thumbs")

tintDir :: IO FilePath
tintDir = do
  s <- stateFile
  pure (takeDirectory s </> "tint")

tintStateFile :: IO FilePath
tintStateFile = do
  d <- tintDir
  pure (d </> "current.json")

-- | One declarative output's defaults (Nix is the source of truth).
data OutputConfig = OutputConfig
  { ocPath :: !(Maybe String)
  , ocMode :: !String
  , ocFillColor :: !String
  }
  deriving (Show, Eq, Ord)

instance FromJSON OutputConfig where
  parseJSON = withObject "OutputConfig" $ \o ->
    OutputConfig
      <$> o .:? "path"
      <*> o .:? "mode" .!= "fill"
      <*> o .:? "fill_color" .!= defaultColor

instance ToJSON OutputConfig where
  toJSON (OutputConfig p m fc) =
    object
      [ "path" .= p
      , "mode" .= m
      , "fill_color" .= fc
      ]

-- | The declarative, read-only config written by the Nix module.
data Config = Config
  { configWallpaperFolder :: !String
  , configRecursive :: !Bool
  , configCurrentOutput :: !String
  , configTransitionType :: !String
  , configTransitionDuration :: !Double
  , configOutputs :: !(Map String OutputConfig)
  , configTintBackend :: !String
  }
  deriving (Show, Eq)

-- | @Config::default()@ — every field at its Rust default.
defaultConfig :: Config
defaultConfig =
  Config
    { configWallpaperFolder = ""
    , configRecursive = True
    , configCurrentOutput = ""
    , configTransitionType = "grow"
    , configTransitionDuration = 1.0
    , configOutputs = Map.empty
    , configTintBackend = "pywal"
    }

instance FromJSON Config where
  parseJSON = withObject "Config" $ \o ->
    Config
      <$> o .:? "wallpaper_folder" .!= ""
      <*> o .:? "recursive" .!= True
      <*> o .:? "current_output" .!= ""
      <*> o .:? "transition_type" .!= "grow"
      <*> o .:? "transition_duration" .!= 1.0
      <*> o .:? "outputs" .!= Map.empty
      <*> o .:? "tint_backend" .!= "pywal"

instance ToJSON Config where
  toJSON (Config wf rec cur tt td outs tb) =
    object
      [ "wallpaper_folder" .= wf
      , "recursive" .= rec
      , "current_output" .= cur
      , "transition_type" .= tt
      , "transition_duration" .= td
      , "outputs" .= outs
      , "tint_backend" .= tb
      ]

-- | Read the declarative config; missing/garbage → a permissive default.
loadConfig :: IO Config
loadConfig = configFile >>= loadConfigFrom

loadConfigFrom :: FilePath -> IO Config
loadConfigFrom path = do
  e <- try (BS.readFile path) :: IO (Either SomeException BS.ByteString)
  case e of
    Right bs -> pure (either (const defaultConfig) id (eitherDecodeStrict' bs))
    Left _ -> pure defaultConfig

-- | One output's runtime override (writable; 'Nothing' fields = inherit).
data OutputOverride = OutputOverride
  { ooPath :: !(Maybe String)
  , ooMode :: !(Maybe String)
  , ooFillColor :: !(Maybe String)
  }
  deriving (Show, Eq, Ord)

instance FromJSON OutputOverride where
  parseJSON = withObject "OutputOverride" $ \o ->
    OutputOverride
      <$> o .:? "path"
      <*> o .:? "mode"
      <*> o .:? "fill_color"

instance ToJSON OutputOverride where
  toJSON (OutputOverride p m fc) =
    object
      [ "path" .= p
      , "mode" .= m
      , "fill_color" .= fc
      ]

-- | Writable runtime state: per-output overrides only.
data State = State
  { stateOutputs :: !(Map String OutputOverride)
  }
  deriving (Show, Eq)

instance FromJSON State where
  parseJSON = withObject "State" $ \o -> State <$> o .:? "outputs" .!= Map.empty

instance ToJSON State where
  toJSON (State outs) = object ["outputs" .= outs]

loadState :: IO State
loadState = stateFile >>= loadStateFrom

loadStateFrom :: FilePath -> IO State
loadStateFrom path = do
  e <- try (BS.readFile path) :: IO (Either SomeException BS.ByteString)
  case e of
    Right bs -> pure (either (const (State Map.empty)) id (eitherDecodeStrict' bs))
    Left _ -> pure (State Map.empty)

-- | Pretty-print to the state file (best-effort: errors are swallowed, the
-- caller surfaces them via the status bar).
saveState :: State -> IO ()
saveState s = stateFile >>= saveStateTo s

saveStateTo :: State -> FilePath -> IO ()
saveStateTo s path = do
  createDirectoryIfMissing True (takeDirectory path)
  let json = encodePretty s
  _ <- try (LBS.writeFile path json) :: IO (Either SomeException ())
  pure ()

-- | The effective merge of declarative defaults and runtime overrides for one
-- output. Override wins; empty strings fall back to the declarative value; the
-- final fallback is @fill@ / 'defaultColor'.
data Effective = Effective
  { effPath :: !String
  , effMode :: !String
  , effFillColor :: !String
  }
  deriving (Show, Eq)

effectiveOutput :: Config -> State -> String -> Effective
effectiveOutput config state output =
  Effective
    { effPath = pick (ooPath =<< Map.lookup output (stateOutputs state)) (ocPath =<< Map.lookup output (configOutputs config)) ""
    , effMode = pick (ooMode =<< Map.lookup output (stateOutputs state)) (ocMode <$> Map.lookup output (configOutputs config)) "fill"
    , effFillColor = pick (ooFillColor =<< Map.lookup output (stateOutputs state)) (ocFillColor <$> Map.lookup output (configOutputs config)) defaultColor
    }
  where
    -- Override wins; an empty override string falls back to the declarative
    -- value; the final fallback is @fallback@. Mirrors Rust's @pick@ closure.
    pick mov mdv fallback =
      let ov = nonEmpty =<< mov
          dv = nonEmpty =<< mdv
      in fromMaybe fallback (ov `orElse` dv)
    -- | 'Just' iff the string is non-empty (collapses the Rust @Some("")@
    -- override to a fall-through). Takes a bare 'String' so '=<<' threads it
    -- through the 'Maybe' from 'Map.lookup'.
    nonEmpty s = if null s then Nothing else Just s
    a `orElse` b = case a of
      Just x -> Just x
      Nothing -> b

-- | @{accent, source_path}@ persisted under @tint/current.json@ so the
-- expensive SVG-tree regen can be skipped when the accent is unchanged.
data TintState = TintState
  { tsAccent :: !(Maybe String)
  , tsSourcePath :: !(Maybe String)
  }
  deriving (Show, Eq)

defaultTintState :: TintState
defaultTintState = TintState Nothing Nothing

instance FromJSON TintState where
  parseJSON = withObject "TintState" $ \o ->
    TintState <$> o .:? "accent" <*> o .:? "source_path"

instance ToJSON TintState where
  toJSON (TintState a sp) = object ["accent" .= a, "source_path" .= sp]

loadTintState :: IO TintState
loadTintState = tintStateFile >>= loadTintStateFrom

loadTintStateFrom :: FilePath -> IO TintState
loadTintStateFrom path = do
  e <- try (BS.readFile path) :: IO (Either SomeException BS.ByteString)
  case e of
    Right bs -> pure (either (const defaultTintState) id (eitherDecodeStrict' bs))
    Left _ -> pure defaultTintState

saveTintState :: TintState -> IO ()
saveTintState ts = do
  d <- tintDir
  createDirectoryIfMissing True d
  tintStateFile >>= saveTintStateTo ts

saveTintStateTo :: TintState -> FilePath -> IO ()
saveTintStateTo ts path = do
  createDirectoryIfMissing True (takeDirectory path)
  let json = encodePretty ts
  _ <- try (LBS.writeFile path json) :: IO (Either SomeException ())
  pure ()

-- Local helpers re-exported for the encoder below.

-- | JSON with a trailing newline. Rust uses @serde_json::to_string_pretty@;
-- the Haskell port writes compact JSON (aeson's 'encode') — round-trips
-- identically through the reader, and 'state.json' is only ever read back
-- by this binary, so a compact format is functionally equivalent. Kept as
-- a named helper so the call sites read faithfully.
encodePretty :: ToJSON a => a -> LBS.ByteString
encodePretty = (<> "\n") . encode