-- | Enumerate installable target disks by parsing @lsblk -J@.
-- Faithful Haskell port of @rust/installer-tui/src/disks.rs@.
--
-- The lsblk argv is exact (@-J -b -d -o NAME,PATH,SIZE,MODEL,RM,TYPE,RO@) and
-- the live-medium exclusion is parity-critical: a bug here would offer the ISO
-- medium itself in the picker, letting the user erase the disk the installer
-- is running from.
module Dots.Installer.Disks
  ( Disk (..)
  , GIB
  , gib
  , espGib
  , rootGib
  , requiredGib
  , humanSize
  , autodetectDisk
  , parseLsblk
  , parentDisk
  , liveMediumDisk
  , listDisks
  ) where

import Control.Exception (try)
import Data.Aeson (Value (..))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Char8 as BC
import Data.Char (isDigit)
import Data.List (isPrefixOf, intercalate)
import Data.Maybe (fromMaybe, mapMaybe)
import qualified Data.Scientific as Sci
import qualified Data.Text as T
import System.Exit (ExitCode (..))
import System.Process (readProcess, readProcessWithExitCode)

-- | One disk presented in the manual picker. Field names mirror the Rust
-- record; 'diskPath' is the @/dev/...@ node disko targets.
data Disk = Disk
  { diskPath :: !String
  , diskSizeBytes :: !Integer
  , diskModel :: !String
  , diskRemovable :: !Bool
  }
  deriving (Show, Eq)

-- | One GiB in bytes — the unit 'requiredGib' speaks in.
gib :: Integer
gib = 1024 * 1024 * 1024

-- | Re-exported as a noun for callers that want the constant by name.
type GIB = Integer

-- | ESP\/boot partition size in the disko layout (GiB). Mirrors @ESP_GIB@.
espGib :: Integer
espGib = 2

-- | Floor for the btrfs root: the desktop closure alone is ~12 GiB (GiB).
-- Mirrors @ROOT_GIB@.
rootGib :: Integer
rootGib = 20

-- | Minimum target disk size for the disko layout (ESP + swap + root), in GiB.
-- Shared by 'autodetectDisk' and the manual picker so the two can't drift.
requiredGib :: Integer -> Integer
requiredGib swapGib = espGib + swapGib + rootGib

-- | @476.9 GiB@-style rendering. Uses fixed-point at one decimal to match
-- Rust's @{:.1}@ (one digit after the decimal point, no trailing exponent,
-- and @20@ renders as @20.0@ — Rust keeps the @.0@).
humanSize :: Disk -> String
humanSize d =
  let g = fromIntegral (diskSizeBytes d) / (fromIntegral gib :: Double)
  in showFFloatAt 1 g ++ " GiB"

-- | Choose one sufficiently large target, preferring the sole fixed disk.
-- Mirrors the Rust @autodetect_disk@ exactly:
--
-- 1. @eligible@ = disks whose size ≥ required_gib * GIB
-- 2. @fixed@ = eligible disks that are NOT removable
-- 3. @candidates@ = fixed if non-empty else eligible
-- 4. Exactly 1 candidate, else an 'Left' describing the failure mode.
autodetectDisk :: [Disk] -> Integer -> Either String Disk
autodetectDisk disks swapGib =
  let reqGib = requiredGib swapGib
      reqBytes = reqGib * gib
      eligible = filter (\d -> diskSizeBytes d >= reqBytes) disks
      fixed = filter (not . diskRemovable) eligible
      candidates = if null fixed then eligible else fixed
      pathsJoined = intercalate ", " (map diskPath candidates)
  in case candidates of
       [] -> Left ("no installable disk has the required " <> show reqGib <> " GiB capacity")
       [d] -> Right d
       _ -> Left ("disk autodetection is ambiguous: " <> pathsJoined)

-- | Parse @lsblk -J -b -d -o NAME,PATH,SIZE,MODEL,RM,TYPE,RO@ output. Keeps
-- writable physical disks only: excludes non-@"disk"@ types (rom, loop),
-- read-only devices, zram, and zero-sized entries.
parseLsblk :: String -> Either String [Disk]
parseLsblk json = case Aeson.decode (BL.fromStrict (BC.pack json)) of
  Nothing -> Left "lsblk output missing 'blockdevices'"
  Just v -> case lookupKey v "blockdevices" of
    Just (Array arr) -> Right (mapMaybe devToDisk (foldr (:) [] arr))
    _ -> Left "lsblk output missing 'blockdevices'"

-- | Extract one key from a JSON object (String-keyed, for aeson >= 2.0 which
-- uses 'KeyMap.Key').
lookupKey :: Value -> String -> Maybe Value
lookupKey (Object o) k = KeyMap.lookup (Key.fromString k) o
lookupKey _ _ = Nothing

-- | Coerce a JSON value to a String (text-decoding it if it's a 'String').
asString :: Value -> Maybe String
asString (String t) = Just (T.unpack t)
asString _ = Nothing

-- | lsblk emits native booleans (util-linux >= 2.37) or @"0"@\/@"1"@ strings.
flag :: Value -> Bool
flag (Bool b) = b
flag (String s) = s == "1" || s == "true"
flag (Number n) = Sci.toBoundedInteger n == Just (1 :: Integer)
flag _ = False

-- | Size accepts a JSON number (u64) or a string of digits.
sizeOf :: Value -> Integer
sizeOf (Number n) = fromMaybe 0 (Sci.toBoundedInteger n)
sizeOf (String s) = case reads (filter (not . isSpaceW) (T.unpack s)) of
  [(x, _)] -> x
  _ -> 0
sizeOf _ = 0

-- | Build a 'Disk' from one lsblk device object, applying the filters.
devToDisk :: Value -> Maybe Disk
devToDisk dev
  | (lookupKey dev "type" >>= asString) /= Just "disk" = Nothing
  | otherwise =
      let name = fromMaybe "" (lookupKey dev "name" >>= asString)
      in if "zram" `isPrefixOf` name || flagOrFalse "ro"
           then Nothing
           else let sz = maybe 0 sizeOf (lookupKey dev "size")
                in if sz == 0
                     then Nothing
                     else Just Disk
                       { diskPath = fromMaybe ("/dev/" <> name) (lookupKey dev "path" >>= asString)
                       , diskSizeBytes = sz
                       , diskModel = trim (fromMaybe "" (lookupKey dev "model" >>= asString))
                       , diskRemovable = flagOrFalse "rm"
                       }
  where
    flagOrFalse k = case lookupKey dev k of
      Just v -> flag v
      Nothing -> False

-- | Strip leading/trailing whitespace (Rust @str::trim@).
trim :: String -> String
trim = f . f where f = reverse . dropWhile isSpaceW

-- | Local 'isSpace' (agrees with Rust @char::is_whitespace@ for lsblk output).
isSpaceW :: Char -> Bool
isSpaceW c = c `elem` (" \t\n\r\f\v" :: String)

-- | Show a 'Double' at a fixed number of decimal places. Rust's @{:.1}@ keeps
-- the trailing @.0@ (so @20@ → @"20.0"@); we do too.
showFFloatAt :: Int -> Double -> String
showFFloatAt n x =
  let isNeg = x < 0 && x /= 0
      a = abs x
      scaled = a * (10 ^ n)
      whole = floor scaled
      -- Round half away from zero (matches Rust's default @{:.N}@).
      rounded = if scaled - fromIntegral whole >= 0.5 then whole + 1 else whole
      intPart = rounded `div` (10 ^ n)
      fracPart = rounded `mod` (10 ^ n)
      intStr = show intPart
      fracStr = replicate (n - length (show fracPart)) '0' ++ show fracPart
      body = if n == 0 then intStr else intStr ++ "." ++ fracStr
  in (if isNeg then "-" else "") ++ body

-- | Strip a partition suffix: /dev/sda1 → /dev/sda, /dev/nvme0n1p2 →
-- /dev/nvme0n1. Heuristic fallback — 'liveMediumDisk' prefers lsblk's
-- authoritative PKNAME. Mirrors the Rust @parent_disk@ state machine exactly.
parentDisk :: String -> String
parentDisk path =
  let stripped = dropTrailingDigits path
  in if stripped == path || stripped == "/dev/"
       then path
       else case stripSuffixChar 'p' stripped of
              Just pre | endsWithDigit pre -> pre
              _ ->
                let base = lastSegment stripped
                in if any isDigit base then path else stripped

-- | Drop trailing ASCII digits.
dropTrailingDigits :: String -> String
dropTrailingDigits = reverse . dropWhile isDigit . reverse

-- | Strip a single trailing occurrence of a character.
stripSuffixChar :: Char -> String -> Maybe String
stripSuffixChar c s = case reverse s of
  (x : xs) | x == c -> Just (reverse xs)
  _ -> Nothing

-- | True if the string ends with an ASCII digit.
endsWithDigit :: String -> Bool
endsWithDigit s = case reverse s of
  (c : _) -> isDigit c
  _ -> False

-- | The substring after the last @\/@ (or the whole string if no @\/@).
lastSegment :: String -> String
lastSegment s = reverse (takeWhile (/= '/') (reverse s))

-- | The disk backing the running live system (the NixOS ISO mounts its
-- medium at /iso) — offering it in the picker would let the user erase the
-- medium the installer is running from.
liveMediumDisk :: IO (Maybe String)
liveMediumDisk = do
  eout <- try (readProcess "findmnt" ["-rn", "-o", "SOURCE", "/iso"] "") :: IO (Either IOError String)
  case eout of
    Left _ -> pure Nothing
    Right out -> do
      let src = trim out
      if not ("/dev/" `isPrefixOf` src)
        then pure Nothing
        else do
          (code, pkout, _) <- readProcessWithExitCode "lsblk" ["-no", "PKNAME", src] ""
          let parent = trim pkout
          if code == ExitSuccess && not (null parent)
            then pure (Just ("/dev/" <> parent))
            else pure (Just (parentDisk src))

-- | Shell out to lsblk and parse, excluding the live boot medium. The argv
-- is the parity contract — disko, the manual picker, and the capacity gate
-- all depend on these exact flags. Returns @[]@ on any failure (mirroring
-- the Rust @Result<Vec<Disk>>@ which the caller @unwrap_or_default@s).
listDisks :: IO [Disk]
listDisks = do
  (code, out, _) <- readProcessWithExitCode "lsblk" argv ""
  if code /= ExitSuccess
    then pure []
    else case parseLsblk out of
      Left _ -> pure []
      Right ds -> do
        live <- liveMediumDisk
        pure $ case live of
          Just l -> filter (\d -> diskPath d /= l) ds
          Nothing -> ds
  where
    argv = ["-J", "-b", "-d", "-o", "NAME,PATH,SIZE,MODEL,RM,TYPE,RO"]