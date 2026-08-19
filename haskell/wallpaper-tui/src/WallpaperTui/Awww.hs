-- | The awww backend: mode/fill-color mapping, the pure @awww img@ argv
-- builder, the apply orchestrator, and a defensive daemon-ensure. Mirrors
-- @rust/wallpaper-tui/src/awww.rs@.
--
-- awww is IPC-driven: one persistent @awww-daemon@ holds the wallpaper, so
-- (unlike swaybg) there is no kill+respawn per apply. The backend is an
-- 'AwwwBackend' record of IO actions so the orchestrator is unit-testable
-- without a real daemon (the test passes a stub that records argv).
module WallpaperTui.Awww
  ( -- * mapping
    mapResize
  , normalizeFillColor
    -- * Group
  , Group (..)
  , groupFromEffective
    -- * argv
  , awwwImgArgs
  , formatTransitionDuration
    -- * backend
  , AwwwBackend (..)
  , liveAwww
  , ensureDaemon
  , applyWallpaper
  , restoreGroups
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Data.Char (toLower)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified System.Process as P
import System.Directory (doesDirectoryExist, doesFileExist)
import System.Exit (ExitCode (..))
import System.Process (callCommand, readProcessWithExitCode)

import WallpaperTui.Config
  ( Config
  , Effective (..)
  , State
  , effectiveOutput
  , configOutputs
  )

-- * mapping

-- | Map a swaybg scaling mode to an awww @--resize@ value. awww has no
-- @tile@ (degrades to centered @no@); it supports @stretch@ directly.
-- Unknown modes default to @crop@ (fill).
mapResize :: String -> String
mapResize mode = case mode of
  "fill" -> "crop"
  "stretch" -> "stretch"
  "fit" -> "fit"
  "center" -> "no"
  "tile" -> "no"
  _ -> "crop"

-- | Normalize a @#rrggbb@/@rrggbb@/@#rrggbbaa@ fill color to bare
-- @RRGGBBAA@. awww's @--fill-color@ is 8-digit RGBA (default @000000ff@),
-- no leading @#@. Empty input falls back to opaque black.
normalizeFillColor :: String -> String
normalizeFillColor color =
  let c = dropWhile (== '#') color
  in if null c
       then "000000ff"
       else if length c == 6 then c <> "ff" else map toLower c

-- * Group

-- | One apply group: the output name (or @"*"@ for all-outputs) and the
-- effective @path/mode/fill_color@ to apply.
data Group = Group
  { gOutput :: !String
  , gPath :: !String
  , gMode :: !String
  , gFillColor :: !String
  } deriving (Show, Eq, Ord)

-- | @Group::from_effective(output, eff)@.
groupFromEffective :: String -> Effective -> Group
groupFromEffective output eff =
  Group
    { gOutput = output
    , gPath = effPath eff
    , gMode = effMode eff
    , gFillColor = effFillColor eff
    }

-- * argv

-- | Build the argv for one @awww img@ IPC command. @-o@ is omitted for the
-- @*@\/all-outputs case (awww has no @*@; an empty @--outputs@ list means all
-- outputs). @fill_color@ is normalized to @RRGGBBAA@.
awwwImgArgs :: Group -> String -> Double -> [String]
awwwImgArgs group transitionType transitionDuration =
  ["awww", "img"]
    ++ (if not (null (gOutput group)) && gOutput group /= "*"
          then ["-o", gOutput group]
          else [])
    ++ [ gPath group
       , "--resize", mapResize (gMode group)
       , "--fill-color", normalizeFillColor (gFillColor group)
       , "--transition-type", transitionType
       , "--transition-duration", formatTransitionDuration transitionDuration
       ]

-- | Format the duration the way the Python @str(1.0)@ did: @1.0@, @2.0@,
-- never @1@ (awww parses a float; keep the @.0@). Haskell's 'show' on a
-- 'Double' already renders whole values with a trailing @.0@ (@show 1.0 =
-- "1.0"@) and non-whole values plainly (@show 1.5 = "1.5"@), so a plain
-- 'show' matches both Rust branches exactly.
formatTransitionDuration :: Double -> String
formatTransitionDuration = show

-- * Backend

-- | Indirection over the @awww@ CLI so the orchestrator is unit-testable
-- without a real daemon: a live backend shells out, the test backend records
-- argv.
data AwwwBackend = AwwwBackend
  { abQuery :: IO Bool
  -- ^ @True@ if @awww query@ succeeds (daemon up).
  , abSpawnImg :: [String] -> IO ()
  -- ^ Spawn one @awww img@ client. Live impl spawns; test impl records argv.
  }

-- | Live backend that actually shells out to @awww@.
liveAwww :: AwwwBackend
liveAwww =
  AwwwBackend
    { abQuery = do
        e <- try (readProcessWithExitCode "awww" ["query"] "") ::
          IO (Either SomeException (ExitCode, String, String))
        pure (case e of
                Right (ExitSuccess, _, _) -> True
                _ -> False)
    , abSpawnImg = \argv -> do
        let cmd = unwords (map shellQuoteArg argv)
        _ <- try (callCommand cmd) :: IO (Either SomeException ())
        pure ()
    }

-- | Best-effort: make sure @awww-daemon@ is running before sending img IPC.
-- @awww query@ returns nonzero if the daemon is down; in that case spawn
-- @awww-daemon@ detached and give it a moment. Never raises.
ensureDaemon :: AwwwBackend -> IO ()
ensureDaemon backend = do
  up <- abQuery backend
  if up
    then pure ()
    else do
      _ <- try (callCommand "awww-daemon >/dev/null 2>&1 &") :: IO (Either SomeException ())
      threadDelay 300000

-- | Apply @groups@ via the awww daemon (one @awww img@ per output). Returns
-- the number of spawned clients. Empty input is a no-op.
applyWallpaper :: AwwwBackend -> [Group] -> String -> Double -> IO Int
applyWallpaper backend groups transitionType transitionDuration
  | null groups = pure 0
  | otherwise = do
      ensureDaemon backend
      mapM_ (\g -> abSpawnImg backend (awwwImgArgs g transitionType transitionDuration)) groups
      pure (length groups)

-- | Build the groups for a full restore: every declared output whose
-- effective path still exists. The order is the map's ascending key order
-- (matches Rust's @BTreeMap@ iteration).
restoreGroups :: Config -> State -> IO [Group]
restoreGroups config state = do
  let outs = Map.keys (configOutputs config)
  effs <- mapM
    (\out -> do
        let eff = effectiveOutput config state out
        ex <- pathExists (effPath eff)
        pure (out, eff, ex))
    outs
  pure [groupFromEffective out eff | (out, eff, True) <- effs]

-- | 'True' iff the path exists (file or dir).
pathExists :: String -> IO Bool
pathExists p = do
  f <- doesFileExist p
  d <- doesDirectoryExist p
  pure (f || d)

-- | A minimal shell-quote: wrap in single quotes, escaping embedded quotes
-- (the standard POSIX @'\\''@ escape). Keeps paths with spaces / shell
-- metacharacters intact under @callCommand@.
shellQuoteArg :: String -> String
shellQuoteArg s = "'" <> concatMap esc s <> "'"
  where
    esc '\'' = "'\\''"
    esc c = [c]