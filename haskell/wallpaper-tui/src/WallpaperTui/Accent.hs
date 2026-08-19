{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Wallpaper → accent extraction. 'rgbToHls'/'hlsToRgb' are a faithful port
-- of CPython's @colorsys@ (HLS, same parameter order: h, l, s) so the accent
-- hue matches the Python extractor and the ported tests pass. Mirrors
-- @rust/wallpaper-tui/src/accent.rs@.
--
-- Two palette backends:
--
-- * 'Internal' — in-process thumbnail + hue-bucket extractor (Pillow logic
--   ported to Haskell via JuicyPixels). Fast, deterministic, testable without
--   external tools.
-- * 'Pywal' — shells out to @wal -i <wallpaper> -n -q -s@ and reads the
--   generated @~/.cache/wal/colors.json@. Uses @colors.color5@ as the accent
--   and derives dark/light variants from it. Falls back to 'Internal' if
--   @wal@ is missing or fails.
module WallpaperTui.Accent
  ( -- * Backend
    TintBackend (..)
  , parseTintBackend
  , defaultTintBackend
  , backendName
    -- * colorsys port
  , rgbToHls
  , hlsToRgb
  , hexToRgb
  , rgbToHex
  , hexToHls
  , hlsToHex
  , clampByte
  , roundHalfAway
    -- * Shades
  , accentShades
    -- * Pywal
  , parsePywalColors
    -- * Extraction
  , extractAccent
  , tryExtractAccentInternal
  , extractAccentPywal
  ) where

import Control.Exception (SomeException, try)
import Control.Monad (guard)
import Data.Aeson (Value (..), decodeStrict')
import Data.Aeson.Key (fromString)
import qualified Data.Aeson.KeyMap as KM
import Data.Char (toLower)
import Data.List (isPrefixOf)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import qualified Data.ByteString.Char8 as BC
import Data.Word (Word8)
import Numeric (showHex)
import qualified Codec.Picture as JP
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Unsafe (unsafePerformIO)
import System.Process (system)

import WallpaperTui.Config
  ( defaultAccent
  , defaultAccentDark
  , defaultAccentLight
  , xdgDir
  )

-- * TintBackend

-- | Palette backend used to derive the wallpaper accent. 'Pywal' is the
-- default (matches Rust's @#[default]@).
data TintBackend = Internal | Pywal
  deriving (Show, Eq, Ord, Bounded, Enum)

-- | 'Pywal' — the Rust @#[default]@.
defaultTintBackend :: TintBackend
defaultTintBackend = Pywal

-- | @fmt::Display@: @"internal"@ / @"pywal"@.
backendName :: TintBackend -> String
backendName = \case Internal -> "internal"; Pywal -> "pywal"

-- | Case-insensitive parse, mirroring Rust's @FromStr@. 'Left' on unknown.
parseTintBackend :: String -> Either String TintBackend
parseTintBackend s = case map toLower s of
  "internal" -> Right Internal
  "pywal" -> Right Pywal
  _ -> Left ("unknown tint backend: " <> s)

-- * colorsys port

-- | @(h, l, s)@ — hue, lightness, saturation, all in @[0,1)@. Port of
-- @colorsys.rgb_to_hls@. Inputs are 0..=1 doubles.
rgbToHls :: Double -> Double -> Double -> (Double, Double, Double)
rgbToHls r g b =
  let maxc = r `max` g `max` b
      minc = r `min` g `min` b
      l = (minc + maxc) / 2.0
  in if minc == maxc
       then (0.0, l, 0.0)
       else
         let s' = if l <= 0.5
                    then (maxc - minc) / (maxc + minc)
                    else (maxc - minc) / (2.0 - maxc - minc)
             rc = (maxc - r) / (maxc - minc)
             gc = (maxc - g) / (maxc - minc)
             bc = (maxc - b) / (maxc - minc)
             h0 = if r == maxc
                    then bc - gc
                    else if g == maxc then 2.0 + rc - bc else 4.0 + gc - rc
         in (mod1 (h0 / 6.0), l, s')

-- | @rem_euclid 1.0@ for doubles: a proper mathematical mod giving a result
-- in @[0,1)@ (negative dividends wrap, unlike 'Prelude.rem').
mod1 :: Double -> Double
mod1 x = x - fromIntegral (floor x :: Int)

-- | Port of @colorsys._v@ (the hue → value segment helper).
vTri :: Double -> Double -> Double -> Double
vTri m1 m2 hue0 =
  let hue = mod1 hue0
  in if hue < 1.0 / 6.0
       then m1 + (m2 - m1) * hue * 6.0
       else if hue < 0.5
              then m2
              else if hue < 2.0 / 3.0
                     then m1 + (m2 - m1) * (2.0 / 3.0 - hue) * 6.0
                     else m1

-- | Port of @colorsys.hls_to_rgb(h, l, s)@. Returns @(r, g, b)@ in 0..=1.
hlsToRgb :: Double -> Double -> Double -> (Double, Double, Double)
hlsToRgb h l s
  | s == 0.0 = (l, l, l)
  | otherwise =
      let m2 = if l <= 0.5 then l * (1.0 + s) else l + s - l * s
          m1 = 2.0 * l - m2
      in ( vTri m1 m2 (h + 1.0 / 3.0)
         , vTri m1 m2 h
         , vTri m1 m2 (h - 1.0 / 3.0)
         )

-- | Parse @#rrggbb@ → @(r, g, b)@ bytes. Malformed → @(0,0,0)@ (matches
-- Rust's @unwrap_or(0)@).
hexToRgb :: String -> (Word8, Word8, Word8)
hexToRgb raw =
  let h = dropWhile (== '#') raw
  in if length h >= 6
       then case (hexPairAt h 0, hexPairAt h 2, hexPairAt h 4) of
              (Just r, Just g, Just b) -> (r, g, b)
              _ -> (0, 0, 0)
       else (0, 0, 0)

-- | Two hex digits at index @i@ → a byte, or 'Nothing' if malformed.
hexPairAt :: String -> Int -> Maybe Word8
hexPairAt s i = case drop i s of
  (a : b : _) ->
    (\x y -> fromIntegral (x * 16 + y)) <$> hexDigit a <*> hexDigit b
  _ -> Nothing

hexDigit :: Char -> Maybe Int
hexDigit c
  | c >= '0' && c <= '9' = Just (fromEnum c - fromEnum '0')
  | c >= 'a' && c <= 'f' = Just (fromEnum c - fromEnum 'a' + 10)
  | c >= 'A' && c <= 'F' = Just (fromEnum c - fromEnum 'A' + 10)
  | otherwise = Nothing

-- | @(r, g, b)@ bytes → @#rrggbb@ (lowercase, zero-padded).
rgbToHex :: (Word8, Word8, Word8) -> String
rgbToHex (r, g, b) = "#" <> padHex r <> padHex g <> padHex b
  where
    padHex w = let s = showHex w "" in if length s == 1 then '0' : s else s

-- | @#rrggbb@ → @(h, l, s)@.
hexToHls :: String -> (Double, Double, Double)
hexToHls hex =
  let (r, g, b) = hexToRgb hex
  in rgbToHls (fromIntegral r / 255.0) (fromIntegral g / 255.0) (fromIntegral b / 255.0)

-- | @(h, l, s)@ → @#rrggbb@. Each channel via Python's @int(round(c*255))@
-- (half away from zero — see 'roundHalfAway').
hlsToHex :: Double -> Double -> Double -> String
hlsToHex h l s =
  let (r, g, b) = hlsToRgb h l s
  in rgbToHex (clampByte r, clampByte g, clampByte b)

-- | Round half away from zero — Rust's @f64::round@, NOT Haskell's 'round'
-- (which is half-to-even). Python's @round@ uses this half-away path for the
-- remap values the extractor ever produces, so this keeps the accent
-- byte-identical to the Rust crate.
roundHalfAway :: Double -> Int
roundHalfAway x
  | x >= 0 = floor (x + 0.5)
  | otherwise = ceiling (x - 0.5)

-- | @(c * 255).round()@ clamped to @[0,255]@, half away from zero.
clampByte :: Double -> Word8
clampByte c =
  let v = roundHalfAway (c * 255.0)
  in if v < 0 then 0 else if v > 255 then 255 else fromIntegral v

-- * Shades

-- | Derive dark/light variants from an accent by keeping hue/saturation.
-- Dark is pushed below the accent and light above it, clamped to a usable UI
-- range, so @dark < accent < light@ always holds. Mirrors @accent_shades@.
accentShades :: String -> (String, String, String)
accentShades accent =
  let (h, l, s) = hexToHls accent
      darkL = min (max (l - 0.25) 0.15) (l - 0.02)
      lightL = max (min (l + 0.15) 0.90) (l + 0.02)
  in (accent, hlsToHex h darkL s, hlsToHex h lightL s)

-- * Pywal

-- | Parse pywal's @colors.json@ and return the @color5@ accent family.
-- 'Nothing' on malformed input so a bad palette fails gracefully.
parsePywalColors :: String -> Maybe (String, String, String)
parsePywalColors text = do
  v <- decodeStrict' (BC.pack text) :: Maybe Value
  Object colors <- keyVal "colors" v
  String accentT <- keyVal "color5" (Object colors)
  let accent = T.unpack accentT
  guard ("#" `isPrefixOf` accent && length accent == 7)
  pure (accentShades accent)

-- | Look up a key in a JSON 'Object', 'Nothing' if the value isn't an object
-- or the key is absent.
keyVal :: String -> Value -> Maybe Value
keyVal k (Object o) = KM.lookup (fromString k) o
keyVal _ _ = Nothing

-- * Extraction

-- | @(accent, accent_dark, accent_light)@ from a wallpaper path using the
-- chosen backend. On failure, falls back to the Tokyonight-blue family.
-- Pure (the file is immutable during the call); uses 'unsafePerformIO' to
-- drive the JuicyPixels decode — mirroring Rust's @image::open@ being a pure
-- @fn@ that hides its IO.
extractAccent :: String -> TintBackend -> (String, String, String)
extractAccent path backend =
  fromMaybe
    (defaultAccent, defaultAccentDark, defaultAccentLight)
    (case backend of
       Internal -> tryExtractAccentInternal path
       Pywal -> extractAccentPywal path)

-- | In-process hue-bucket extractor (Pillow logic ported to JuicyPixels).
-- 'Nothing' when the image can't be decoded or has no usable pixels.
tryExtractAccentInternal :: String -> Maybe (String, String, String)
tryExtractAccentInternal path =
  case unsafePerformIO (try (decodeAndExtract path)) :: Either SomeException (Maybe (String, String, String)) of
    Right ma -> ma
    Left _ -> Nothing

-- | The actual decode + bin pass. Aspect-preserving 64×64 downsample (a
-- no-op when the image is already ≤64), drop near-black/white/low-sat pixels,
-- bucket the rest by hue (16 bins), pick the largest saturation-weighted bin.
decodeAndExtract :: String -> IO (Maybe (String, String, String))
decodeAndExtract path = do
  e <- JP.readImage path
  case e of
    Left _ -> pure Nothing
    Right dyn -> do
      let rgb8 = JP.convertRGB8 dyn
          w = JP.imageWidth rgb8
          h = JP.imageHeight rgb8
          thumb = downsample64 w h rgb8
          bins = foldPixels thumb
      case bestBin bins of
        Nothing -> pure Nothing
        Just (hueSum, cnt) ->
          let hue = hueSum / fromIntegral cnt
          in pure (Just (hlsToHex hue 0.62 0.55, hlsToHex hue 0.40 0.55, hlsToHex hue 0.78 0.55))

-- | Aspect-preserving nearest-neighbour downsample so both dims ≤64. Rust's
-- @thumbnail(64,64)@ only shrinks (never enlarges); for the test images
-- (16×16 / 64×64) this is a no-op.
downsample64 :: Int -> Int -> JP.Image JP.PixelRGB8 -> JP.Image JP.PixelRGB8
downsample64 w h src
  | w <= 64 && h <= 64 = src
  | otherwise =
      let scale = min (64.0 / fromIntegral w) (64.0 / fromIntegral h) :: Double
          tw = max 1 (round (fromIntegral w * scale))
          th = max 1 (round (fromIntegral h * scale))
      in JP.generateImage (sampleNearest src w h tw th) tw th

-- | Nearest-neighbour sampler for the downsample (JuicyPixels has no built-in
-- resize). @srcW@/@srcH@ are the source dims; @tw@/@th@ the target.
sampleNearest ::
  JP.Image JP.PixelRGB8 ->
  Int -> Int -> Int -> Int ->
  Int -> Int -> JP.PixelRGB8
sampleNearest src srcW srcH tw th tx ty =
  let sx = min (srcW - 1) ((tx * srcW) `div` max 1 tw)
      sy = min (srcH - 1) ((ty * srcH) `div` max 1 th)
  in JP.pixelAt src sx sy

-- | One pass over the pixels: 16 hue bins, each @(weightSum, hueSum, count)@.
-- A pixel is counted only if @0.1 <= l <= 0.9@ and @s >= 0.2@ (mirrors Rust).
foldPixels :: JP.Image JP.PixelRGB8 -> [(Double, Double, Int)]
foldPixels img = go 0 (replicate 16 (0.0, 0.0, 0))
  where
    w = JP.imageWidth img
    h = JP.imageHeight img
    go !y acc
      | y >= h = acc
      | otherwise = go (y + 1) (goX y 0 acc)
    goX !y !x acc
      | x >= w = acc
      | otherwise =
          let JP.PixelRGB8 r g b = JP.pixelAt img x y
              (h0, l, s) = rgbToHls (fromIntegral r / 255.0)
                                        (fromIntegral g / 255.0)
                                        (fromIntegral b / 255.0)
          in if not (l >= 0.1 && l <= 0.9) || s < 0.2
               then goX y (x + 1) acc
               else
                 let bin = min 15 (floor (h0 * 16.0))
                     (wt, hs, ct) = acc !! bin
                 in goX y (x + 1) (replaceAt bin (wt + s, hs + h0, ct + 1) acc)

-- | The bin with the largest saturation-weighted population (count > 0).
bestBin :: [(Double, Double, Int)] -> Maybe (Double, Int)
bestBin bins =
  case [(wt, hs, ct) | (wt, hs, ct) <- bins, ct > 0] of
    [] -> Nothing
    xs -> Just (let (_, hs, ct) = maximumByWeight xs in (hs, ct))
  where
    maximumByWeight = foldl1 (\a b -> if weight a >= weight b then a else b)
    weight (wt, _, _) = wt

-- | Run @wal -i <path> -n -q -s@ and parse @colors.color5@ from its cache.
-- 'Nothing' on any failure so the caller can fall back.
extractAccentPywal :: String -> Maybe (String, String, String)
extractAccentPywal path =
  case unsafePerformIO (try (walAndParse path)) :: Either SomeException (Maybe (String, String, String)) of
    Right ma -> ma
    Left _ -> Nothing

-- | Shell out to @wal@ and read its cache. The exit code gates the parse.
walAndParse :: String -> IO (Maybe (String, String, String))
walAndParse path = do
  ec <- system ("wal -i " <> shellQuote path <> " >/dev/null 2>&1")
  case ec of
    ExitSuccess -> do
      cache <- (</> "wal" </> "colors.json") <$> xdgDir "XDG_CACHE_HOME" ".cache"
      mt <- try (readFile cache) :: IO (Either SomeException String)
      pure (case mt of Right t -> parsePywalColors t; Left _ -> Nothing)
    _ -> pure Nothing

-- | A minimal single-quote wrapper so a path with spaces survives the shell.
shellQuote :: String -> String
shellQuote s = "'" <> s <> "'"

-- * Small list helpers (kept local to avoid an @unordered-containers@ dep)

replaceAt :: Int -> a -> [a] -> [a]
replaceAt _ _ [] = []
replaceAt 0 y (_ : xs) = y : xs
replaceAt i y (x : xs) = x : replaceAt (i - 1) y xs