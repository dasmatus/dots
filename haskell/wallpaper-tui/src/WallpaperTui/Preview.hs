-- | The wallpaper thumbnail cache and the preview decode. Mirrors
-- @rust/wallpaper-tui/src/preview.rs@. The thumbnail cache feeds 'thumbFor' so
-- the worker decodes a small PNG rather than the full-res wallpaper on every
-- cursor move; 'loadPreview' returns a 'JP.DynamicImage' the UI thread turns
-- into a mosaic 'Bitmap'.
module WallpaperTui.Preview
  ( thumbFor
  , sha1Hex
  , CacheStats (..)
  , cachePreviews
  , makeThumbnail
  , loadPreview
  , parsePreviewSize
  ) where

import Control.Exception (SomeException, try)
import Data.Char (toLower)
import Data.Time.Clock (UTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Numeric (showHex)
import qualified Codec.Picture as JP
import qualified Crypto.Hash.SHA1 as SHA1
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , getModificationTime
  , renameFile
  )
import System.FilePath ((</>), replaceExtension)
import System.IO (hPutStrLn, stderr)

import WallpaperTui.Config (previewCacheDir)
import WallpaperTui.Wallpapers (listWallpapers)

-- | sha1(@str@) → 40-char lowercase hex. Mirrors the Python hash key.
sha1Hex :: String -> String
sha1Hex s = concatMap pad2 (map (\b -> showHex b "") (BS.unpack (SHA1.hash (BC.pack s))))
  where
    pad2 x = if length x == 1 then '0' : x else x

-- | sha1(@"{path}:{mtime_secs}"@) → the cached thumbnail path, mirroring the
-- Python hash key. Returns @path@ unchanged when no cached thumbnail exists
-- or the source's mtime is unreadable.
thumbFor :: FilePath -> IO FilePath
thumbFor path = do
  e <- try (getModificationTime path) :: IO (Either SomeException UTCTime)
  case e of
    Left _ -> pure path
    Right mt -> do
      let secs = floor (utcTimeToPOSIXSeconds mt) :: Integer
          key = sha1Hex (path <> ":" <> show secs)
      cache <- previewCacheDir
      let thumb = cache </> (key <> ".png")
      exists <- doesFileExist thumb
      pure (if exists then thumb else path)

-- | @{written, skipped}@ — regenerate thumbnails only when the source's mtime
-- is newer than the cached one (or the cache is missing). Atomic (temp +
-- rename) so a failed save never leaves a partial PNG the skip-guard would
-- treat as valid forever. Unreadable images are skipped with a stderr
-- warning.
data CacheStats = CacheStats
  { csWritten :: !Int
  , csSkipped :: !Int
  } deriving (Show, Eq, Ord)

-- | Regenerate the thumbnail cache. Mirrors @cache_previews@.
cachePreviews :: FilePath -> Bool -> FilePath -> (Int, Int) -> IO CacheStats
cachePreviews folder recursive outDir size@(tw, th) = do
  ec <- try (createDirectoryIfMissing True outDir) :: IO (Either SomeException ())
  case ec of
    Left e -> do
      hPutStrLn stderr ("wallpaper-tui: cache mkdir " <> outDir <> ": " <> show e)
      pure (CacheStats 0 0)
    Right _ -> do
      paths <- listWallpapers folder recursive
      foldMk paths (CacheStats 0 0)
  where
    foldMk [] acc = pure acc
    foldMk (p : ps) acc = do
      e <- try (getModificationTime p) :: IO (Either SomeException UTCTime)
      case e of
        Left _ -> foldMk ps acc
        Right srcMt -> do
          let secs = floor (utcTimeToPOSIXSeconds srcMt) :: Integer
              key = sha1Hex (p <> ":" <> show secs)
              thumb = outDir </> (key <> ".png")
          skip <- shouldSkip thumb secs
          if skip
            then foldMk ps acc{csSkipped = csSkipped acc + 1}
            else do
              r <- makeThumbnail p thumb size
              case r of
                Left err -> do
                  hPutStrLn stderr ("wallpaper-tui: cache skip " <> p <> ": " <> err)
                  foldMk ps acc
                Right _ -> foldMk ps acc{csWritten = csWritten acc + 1}

-- | 'True' iff the cached thumb exists and is at least as new as the source
-- (mtime seconds comparison, mirroring Rust's @thumb_mtime >= secs@).
shouldSkip :: FilePath -> Integer -> IO Bool
shouldSkip thumb secs = do
  exists <- doesFileExist thumb
  if not exists
    then pure False
    else do
      e <- try (getModificationTime thumb) :: IO (Either SomeException UTCTime)
      pure (case e of
              Right thumbMt ->
                floor (utcTimeToPOSIXSeconds thumbMt) >= secs
              Left _ -> False)

-- | Decode @src@, downsample to @size@ (aspect-preserving, shrink-only), write
-- a PNG to a sibling @.tmp@ then rename — so an interrupted save can't leave
-- a partial PNG the mtime-skip guard would treat as valid forever.
makeThumbnail :: FilePath -> FilePath -> (Int, Int) -> IO (Either String ())
makeThumbnail src dst (tw, th) = do
  e <- JP.readImage src
  case e of
    Left err -> pure (Left err)
    Right dyn -> do
      let rgb8 = JP.convertRGB8 dyn
          w = JP.imageWidth rgb8
          h = JP.imageHeight rgb8
          thumb = thumbnailOf tw th rgb8
          tmp = replaceExtension dst "png.tmp"
      writePngSafe tmp thumb
      renameResult <- try (renameFile tmp dst) :: IO (Either SomeException ())
      pure (case renameResult of
              Left err -> Left (show err)
              Right _ -> Right ())
  where
    -- 'JP.writePng' can throw on a bad path; wrap it.
    writePngSafe path img = JP.writePng path img

-- | Aspect-preserving nearest-neighbour downsample so both dims ≤ the box.
-- Only shrinks (never enlarges), matching Rust's @DynamicImage::thumbnail@.
thumbnailOf :: Int -> Int -> JP.Image JP.PixelRGB8 -> JP.Image JP.PixelRGB8
thumbnailOf tw th src
  | sw <= tw && sh <= th = src
  | otherwise =
      let scale = min (fromIntegral tw / fromIntegral sw) (fromIntegral th / fromIntegral sh) :: Double
          nw = max 1 (round (fromIntegral sw * scale))
          nh = max 1 (round (fromIntegral sh * scale))
      in JP.generateImage (sampleNearest src sw sh nw nh) nw nh
  where
    sw = JP.imageWidth src
    sh = JP.imageHeight src

-- | Nearest-neighbour sampler (JuicyPixels has no built-in resize).
sampleNearest ::
  JP.Image JP.PixelRGB8 ->
  Int -> Int -> Int -> Int ->
  Int -> Int -> JP.PixelRGB8
sampleNearest src sw sh nw nh tx ty =
  let sx = min (sw - 1) ((tx * sw) `div` max 1 nw)
      sy = min (sh - 1) ((ty * sh) `div` max 1 nh)
  in JP.pixelAt src sx sy

-- | Decode @path@ (cached thumbnail preferred) into a 'JP.DynamicImage'.
-- Propagates the decode error so the worker can signal a failed preview.
loadPreview :: FilePath -> IO (Either String JP.DynamicImage)
loadPreview path = do
  resolved <- thumbFor path
  JP.readImage resolved

-- | Parse a @WxH@ preview-size argument (e.g. @"320x200"@). Case-insensitive.
parsePreviewSize :: String -> Maybe (Int, Int)
parsePreviewSize s =
  let lower = map toLower s
  in case break (== 'x') lower of
       (w, 'x' : h) -> (,) <$> readInt w <*> readInt h
       _ -> Nothing
  where
    readInt x = case reads x of [(n, "")] -> Just n; _ -> Nothing