{-# LANGUAGE LambdaCase #-}

-- | Wallpaper discovery and Hyprland output enumeration. Mirrors
-- @rust/wallpaper-tui/src/wallpapers.rs@. 'listWallpapers' is IO (directory
-- walk + mtime sort); 'detectOutputs' shells out to @hyprctl monitors -j@.
module WallpaperTui.Wallpapers
  ( extensions
  , isImage
  , listWallpapers
  , detectOutputs
  ) where

import Control.Exception (SomeException, try)
import Control.Monad (filterM, forM)
import Data.Aeson (FromJSON (..), Value (..), decodeStrict')
import Data.Aeson.Key (fromString)
import qualified Data.Aeson.KeyMap as KM
import Data.Char (toLower)
import Data.List (sortBy)
import Data.Ord (Down (..), comparing)
import Data.Time.Clock (UTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import qualified Data.ByteString.Char8 as BC
import qualified Data.Text as T
import qualified System.Process as P
import System.Directory
  ( doesDirectoryExist
  , doesFileExist
  , getModificationTime
  , listDirectory
  , pathIsSymbolicLink
  )
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>), takeExtension)
import System.Process (readProcessWithExitCode)

-- | Image extensions recognized by the picker (case-insensitive).
extensions :: [String]
extensions = [".jpg", ".jpeg", ".png", ".webp", ".gif"]

-- | 'True' iff @path@'s extension is a recognized image extension.
isImage :: FilePath -> Bool
isImage path =
  let ext = map toLower (takeExtension path)
  in ext `elem` extensions

-- | List wallpapers in @folder@, newest-first (mtime, descending) —
-- matches waytrogen's default sort. Returns @[]@ when the folder is missing.
listWallpapers :: FilePath -> Bool -> IO [FilePath]
listWallpapers folder recursive
  | null folder = pure []
  | otherwise = do
      isDir <- doesDirectoryExist folder
      if not isDir
        then pure []
        else do
          entries <- walk folder recursive
          withMtime <-
            forM entries $ \p -> do
              mt <- tryMtime p
              pure (p, mt)
          pure (map fst (sortBy (comparing (Down . snd)) withMtime))

-- | Walk @root@: recursively when @recursive@, else just the top level. Only
-- image files are collected; symlinks are not followed (a dangling symlink
-- fails the @is_file@ check, matching the Rust walkdir filter).
walk :: FilePath -> Bool -> IO [FilePath]
walk root recursive = go root
  where
    go dir = do
      names <- tryList dir
      let paths = map (dir </>) names
      files <- filterM (\p -> do isF <- doesFileExist p; pure (isF && isImage p)) paths
      subs <-
        if recursive
          then do
            dirs <- filterM
              (\p -> do
                  isD <- doesDirectoryExist p
                  isLink <- pathIsSymbolicLink p
                  pure (isD && not isLink))  -- don't follow symlinks
              paths
            concat <$> mapM go dirs
          else pure []
      pure (files <> subs)

-- | Best-effort directory listing (swallows permission errors).
tryList :: FilePath -> IO [FilePath]
tryList dir = do
  e <- try (listDirectory dir) :: IO (Either SomeException [FilePath])
  pure (case e of Right xs -> xs; Left _ -> [])

-- | Best-effort mtime (the Unix epoch on failure, so unreadable files sort
-- oldest — matching Rust's @UNIX_EPOCH@ fallback).
tryMtime :: FilePath -> IO UTCTime
tryMtime p = do
  e <- try (getModificationTime p) :: IO (Either SomeException UTCTime)
  pure (case e of Right t -> t; Left _ -> epoch)

-- | The Unix epoch as 'UTCTime' — the unreadable-file fallback (sorts oldest).
epoch :: UTCTime
epoch = posixSecondsToUTCTime 0

-- | Hyprland monitor list JSON shape: @[{"name": "eDP-1"}, ...]@.
newtype Monitor = Monitor { monitorName :: String }

instance FromJSON Monitor where
  parseJSON = \case
    Object o -> pure (Monitor (lookupName o))
    _ -> pure (Monitor "")
    where
      lookupName o = case KM.lookup (fromString "name") o of
        Just (String t) -> T.unpack t
        _ -> ""

-- | Best-effort output enumeration via @hyprctl monitors -j@; @[]@ when not on
-- Hyprland or hyprctl is unavailable.
detectOutputs :: IO [String]
detectOutputs = do
  mhis <- lookupEnv "HYPRLAND_INSTANCE_SIGNATURE"
  case mhis of
    Nothing -> pure []
    Just _ -> do
      e <- try (readProcessWithExitCode "hyprctl" ["monitors", "-j"] "") ::
        IO (Either SomeException (ExitCode, String, String))
      case e of
        Right (ExitSuccess, out, _) ->
          pure (case decodeStrict' (BC.pack out) :: Maybe [Monitor] of
                  Just ms -> map monitorName ms
                  Nothing -> [])
        _ -> pure []