{-# LANGUAGE LambdaCase #-}
-- | Headless testing rig over the reflex-vty mock-Vty 'CaptureTerm'. The
-- public test-harness facade: re-exports 'CaptureTerm'/'newCaptureTerm'/
-- 'captureCell' from "AbstractTUI.Term" and adds the input/output/parse
-- surface the smoke tests use:
--
-- * 'feedInput' — decode raw bytes to vty 'V.Event's (via the salvaged
--   "AbstractTUI.Term.Input" byte->'KeyChord' decoder + a
--   'keyChordToVtyEvent' mapping) and enqueue them on the capture
--   terminal. The 'Driver' 'turn' drains the queue and fires each via the
--   input 'EventTrigger' so subscribed widgets (e.g. 'shortcut') receive
--   them.
-- * 'drainOutput' — snapshot and clear the accumulated emitted bytes
--   (alias for 'captureEmit').
-- * 'parseScreen' / 'vtChar' / 'VtScreen' / 'VtCell' — a pure VT100/ANSI
--   byte parser (salvaged verbatim from the stash's @Testing.Capture@)
--   that turns the emitted bytes back into a cell grid, so a test can
--   assert the glyph at @(x,y)@. It only understands the escapes the ANSI
--   'DisplayContext' in "AbstractTUI.Term" produces (cursor positioning,
--   SGR, printable bytes), so the two are a closed pair.
module AbstractTUI.Testing.Capture
  ( CaptureTerm
  , newCaptureTerm
  , captureCell
  , feedInput
  , drainOutput
  , keyChordToVtyEvent
  , VtCell (..)
  , VtScreen (..)
  , vtAt
  , vtChar
  , parseScreen
  , blankScreen
  ) where

import Data.Bits ((.&.), (.|.), shiftL)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.Char as C
import Data.Word (Word8)
import qualified Data.Word as W
import qualified Graphics.Vty as V

import AbstractTUI.Base.Color (Rgba, black, rgb)
import AbstractTUI.Term (CaptureTerm, captureCell, captureEmit, captureFeedInput, newCaptureTerm)
import AbstractTUI.Term.Input (decodeBytes)
import AbstractTUI.View (Key (..), KeyChord (..), Mods (..))

-- * Input

-- | Decode raw input bytes to vty 'V.Event's and enqueue them on the
-- capture terminal. The bytes are decoded via "AbstractTUI.Term.Input"'s
-- 'decodeBytes' (bytes -> 'KeyChord's), each chord is mapped to a
-- 'V.Event' via 'keyChordToVtyEvent', and the events are appended (in
-- order) to the terminal's input queue. The 'Driver' 'turn' drains the
-- queue and fires each event via the input 'EventTrigger'. Multiple feeds
-- concatenate in order.
feedInput :: CaptureTerm -> [Word8] -> IO ()
feedInput term bs =
  let evts = map keyChordToVtyEvent (decodeBytes bs)
  in captureFeedInput term evts

-- | Map an abstract 'KeyChord' to a vty 'V.Event' ('V.EvKey').
keyChordToVtyEvent :: KeyChord -> V.Event
keyChordToVtyEvent (KeyChord mods k) = V.EvKey (toVtyKey k) (toVtyMods mods)

-- | Map the abstract 'Key' to the vty 'V.Key'. vty has no 'KTab'
-- constructor — Tab is @KChar '\\t'@.
toVtyKey :: Key -> V.Key
toVtyKey = \case
  KeyChar c -> V.KChar c
  KeyEnter -> V.KEnter
  KeyEsc -> V.KEsc
  KeyBackspace -> V.KBS
  KeyTab -> V.KChar '\t'
  KeyUp -> V.KUp
  KeyDown -> V.KDown
  KeyLeft -> V.KLeft
  KeyRight -> V.KRight
  KeyHome -> V.KHome
  KeyEnd -> V.KEnd
  KeyPgUp -> V.KPageUp
  KeyPgDn -> V.KPageDown
  KeyDelete -> V.KDel
  KeySpace -> V.KChar ' '

-- | Map the abstract 'Mods' to the vty modifier list. vty's 'V.MMeta' is
-- the super/meta slot; 'V.MAlt' is the alt slot.
toVtyMods :: Mods -> [V.Modifier]
toVtyMods mods =
  [V.MCtrl | modCtrl mods]
    ++ [V.MShift | modShift mods]
    ++ [V.MAlt | modAlt mods]
    ++ [V.MMeta | modSuper mods]

-- * Output

-- | Snapshot and clear the accumulated emitted bytes (so a test can assert
-- one frame's worth of bytes in isolation). Alias for 'captureEmit'.
drainOutput :: CaptureTerm -> IO ByteString
drainOutput = captureEmit

-- * The VT parser (salvaged verbatim from the stash's @Testing.Capture@)

-- | One parsed cell: a glyph plus the resolved ink. Attributes are folded
-- back into fg/bg via the SGR semantics the emitter uses (invert swaps
-- fg/bg, dim is dropped on parse since the cell grid is for visual
-- equality only).
data VtCell = VtCell
  { vtCh :: !Char
  , vtFg :: !(Maybe Rgba)
  , vtBg :: !(Maybe Rgba)
  , vtBold :: !Bool
  , vtUnderline :: !Bool
  , vtInvert :: !Bool
  }
  deriving (Show, Eq)

-- | A grid of cells, viewport @w x h@, row-major. Named 'VtScreen' to
-- match the stash's surface (the brief allows 'Screen' or 'VtScreen').
data VtScreen = VtScreen
  { vsW :: !Int
  , vsH :: !Int
  , vsCells :: ![VtCell]
  }

-- | A blank screen (spaces, no ink).
blankScreen :: Int -> Int -> VtScreen
blankScreen w h = VtScreen w h (replicate (max 0 (w * h)) blankVt)
  where
    blankVt = VtCell ' ' Nothing Nothing False False False

-- | Read the cell at @(x, y)@; out-of-bounds returns the blank cell.
vtAt :: VtScreen -> Int -> Int -> VtCell
vtAt (VtScreen w _ cs) x y
  | x < 0 || y < 0 || x >= w = VtCell ' ' Nothing Nothing False False False
  | otherwise = cs !! (y * w + x)

-- | The glyph at @(x, y)@ (blank space if nothing was written).
vtChar :: VtScreen -> Int -> Int -> Char
vtChar s x y = vtCh (vtAt s x y)

-- | Parse the recorded output into a screen of the given size. Walks the
-- bytes, maintaining a cursor @(x,y)@ and a current SGR state, and writes
-- printable bytes into the grid; CSI sequences move the cursor or change
-- the ink. Unknown CSI sequences are skipped (the emitter never produces
-- them, so a skip signals an emitter/parser mismatch worth a test
-- failure).
parseScreen :: Int -> Int -> ByteString -> VtScreen
parseScreen w h bs = finish (go initSt (BS.unpack bs) (blankScreen w h))
  where
    initSt = PSt 0 0 Nothing Nothing False False False
    finish (_ , s) =
      let apply c = if vtInvert c then c { vtFg = vtBg c, vtBg = vtFg c } else c
       in s { vsCells = map apply (vsCells s) }

-- | Parser state: cursor x/y, current fg/bg, bold/underline/invert flags.
data PSt = PSt
  { psX :: !Int
  , psY :: !Int
  , psFg :: !(Maybe Rgba)
  , psBg :: !(Maybe Rgba)
  , psBold :: !Bool
  , psUnderline :: !Bool
  , psInvert :: !Bool
  }

-- | Write a printable byte at the cursor and advance (with line wrap).
putCh :: Int -> Int -> PSt -> Char -> VtScreen -> VtScreen
putCh w h st c s
  | psX st < 0 || psY st < 0 || psX st >= w || psY st >= h = s
  | otherwise =
      let cell = VtCell c (psFg st) (psBg st) (psBold st) (psUnderline st) (psInvert st)
          i = psY st * w + psX st
       in s { vsCells = setAt i cell (vsCells s) }

setAt :: Int -> a -> [a] -> [a]
setAt _ _ [] = []
setAt 0 x (_ : xs) = x : xs
setAt i x (y : xs) = y : setAt (i - 1) x xs

go :: PSt -> [Word8] -> VtScreen -> (PSt, VtScreen)
go st [] s = (st, s)
go st (b : bs) s
  -- ESC begins a CSI sequence.
  | b == 27 =
      case bs of
        (c : rest) | c == 91 -> csi st rest s   -- ESC [
                   | c == 93 -> skipOsc st rest s  -- ESC ] (OSC) — skip to BEL/ST
                   | otherwise -> go st rest s     -- lone ESC or SS3 the emitter doesn't use
        [] -> (st, s)
  -- Printable ASCII (the emitter only writes ASCII + UTF-8 multi-byte glyphs).
  | b == 10 = go (st { psX = 0, psY = psY st + 1 }) bs s -- LF
  | b == 13 = go (st { psX = 0 }) bs s                   -- CR
  | b >= 32 = utf8Step st (b : bs) s
  | otherwise = go st bs s

-- | Consume one UTF-8 codepoint starting at the head, write it, continue.
utf8Step :: PSt -> [Word8] -> VtScreen -> (PSt, VtScreen)
utf8Step st (b : bs) s
  | b < 0x80 =
      let s' = putCh w h st (C.chr (fromIntegral b)) s
       in go (st { psX = psX st + 1 }) bs s'
  | b < 0xC0 =
      -- stray continuation byte; skip
      go st bs s
  | otherwise =
      let (cp, consumed) = decodeUtf8 (b : bs)
          c = case cp of Just n -> C.chr n; Nothing -> ' '
          s' = putCh w h st c s
       in go (st { psX = psX st + 1 }) (drop consumed (b : bs)) s'
  where
    w = vsW s
    h = vsH s
utf8Step st [] s = (st, s)

-- | Decode one UTF-8 codepoint from the head; returns (Just cp, byteLen) or
-- (Nothing, 1) for a malformed lead byte.
decodeUtf8 :: [Word8] -> (Maybe Int, Int)
decodeUtf8 (b : bs)
  | b < 0x80 = (Just (fromIntegral b), 1)
  | b < 0xC0 = (Nothing, 1)
  | b < 0xE0 = two b bs
  | b < 0xF0 = three b bs
  | otherwise = four b bs
  where
    cont x = if x >= 0x80 && x < 0xC0 then fromIntegral (x .&. 0x3F) else 0
    two a (b1 : _) = (Just ((fromIntegral (a .&. 0x1F) `shiftL` 6) .|. cont b1), 2)
    two a _ = (Just (fromIntegral (a .&. 0x1F)), 1)
    three a (b1 : b2 : _) =
      (Just ((fromIntegral (a .&. 0x0F) `shiftL` 12) .|. (cont b1 `shiftL` 6) .|. cont b2), 3)
    three a _ = (Just (fromIntegral (a .&. 0x0F)), 1)
    four a (b1 : b2 : b3 : _) =
      (Just ((fromIntegral (a .&. 0x07) `shiftL` 18) .|. (cont b1 `shiftL` 12) .|. (cont b2 `shiftL` 6) .|. cont b3), 4)
    four a _ = (Just (fromIntegral (a .&. 0x07)), 1)
decodeUtf8 [] = (Nothing, 0)

-- | Parse a CSI (@ESC [@) body: read until the final byte (0x40-0x7E), then
-- dispatch on it (H = cursor position, m = SGR, J/K = clear/erase — the
-- emitter doesn't emit these but a future clear-screen might).
csi :: PSt -> [Word8] -> VtScreen -> (PSt, VtScreen)
csi st0 bs0 s0 =
  let (params, final, rest) = splitCsi bs0
      st1 = case final of
        72 -> cursorPos params st0    -- 'H'
        102 -> cursorPos params st0   -- 'f'
        109 -> applySGR params st0    -- 'm'
        74 -> st0                     -- 'J' erase — no-op for our grid
        75 -> st0                     -- 'K' erase line — no-op
        _ -> st0                      -- unknown: skip
   in go st1 rest s0

-- | Split a CSI body into parameter bytes (as a list of Int), the final
-- byte, and the remainder after it. Parameter bytes are 0x30-0x3F (digits
-- + ';'); the final byte is 0x40-0x7E.
splitCsi :: [Word8] -> ([Int], Word8, [Word8])
splitCsi = goP [] []
  where
    goP acc _ [] = (reverse acc, 0, [])
    goP acc ds (b : rest)
      | b >= 0x30 && b <= 0x3F =
          if b == 59
            then goP (parseRev ds : acc) [] rest          -- ';'
            else goP acc (b : ds) rest                      -- digit
      | b >= 0x40 && b <= 0x7E = (reverse (parseRev ds : acc), b, rest)
      | otherwise = goP acc ds rest
    parseRev ds = foldl (\n d -> n * 10 + fromIntegral (d - 0x30)) 0 (reverse ds)

cursorPos :: [Int] -> PSt -> PSt
cursorPos ps st =
  let row = at 0 ps 1 - 1
      col = at 1 ps 1 - 1
   in st { psX = max 0 col, psY = max 0 row }
  where
    at _ [] d = d
    at i xs _ = xs !! min i (length xs - 1)

-- | Apply an SGR parameter list to the parser state. Handles the subset
-- the emitter emits: 0 (reset), 1 (bold), 2 (dim, dropped), 3 (italic,
-- dropped), 4 (underline), 7 (invert), 38;2;r;g;b / 48;2;r;g;b
-- (truecolour), 38;5;n / 48;5;n (256-colour, expanded back to RGB via the
-- cube).
applySGR :: [Int] -> PSt -> PSt
applySGR = goS
  where
    goS [] st = st
    goS (0 : rest) st = goS rest st { psFg = Nothing, psBg = Nothing, psBold = False, psUnderline = False, psInvert = False }
    goS (1 : rest) st = goS rest st { psBold = True }
    goS (2 : rest) st = goS rest st            -- dim: ignored
    goS (3 : rest) st = goS rest st            -- italic: ignored
    goS (4 : rest) st = goS rest st { psUnderline = True }
    goS (7 : rest) st = goS rest st { psInvert = True }
    goS (22 : rest) st = goS rest st { psBold = False }
    goS (24 : rest) st = goS rest st { psUnderline = False }
    goS (27 : rest) st = goS rest st { psInvert = False }
    goS (38 : 2 : r : g : b' : rest) st = goS rest st { psFg = Just (rgb (i r) (i g) (i b')) }
    goS (38 : 5 : n : rest) st = goS rest st { psFg = Just (from256 (i n)) }
    goS (48 : 2 : r : g : b' : rest) st = goS rest st { psBg = Just (rgb (i r) (i g) (i b')) }
    goS (48 : 5 : n : rest) st = goS rest st { psBg = Just (from256 (i n)) }
    goS (_ : rest) st = goS rest st
    i n = fromIntegral (max 0 (min 255 n)) :: W.Word8

-- | Reverse the 256-colour cube to an approximate RGB (good enough for
-- equality assertions — the emitter quantizes to the same cube).
from256 :: W.Word8 -> Rgba
from256 n
  | n < 16 = black
  | n >= 232 =
      let v = 8 + (n - 232) * 10 :: W.Word8
       in rgb v v v
  | otherwise =
      let n' = n - 16
          r = n' `div` 36
          g = (n' `div` 6) `mod` 6
          b = n' `mod` 6
          lvl i = ([0, 95, 135, 175, 215, 255] :: [W.Word8]) !! i
       in rgb (lvl (fromIntegral r)) (lvl (fromIntegral g)) (lvl (fromIntegral b))

-- | Skip an OSC (@ESC ]@) body up to a BEL (0x07) or ST (@ESC \@).
skipOsc :: PSt -> [Word8] -> VtScreen -> (PSt, VtScreen)
skipOsc st [] s = (st, s)
skipOsc st (7 : rest) s = go st rest s
skipOsc st (27 : 92 : rest) s = go st rest s
skipOsc st (_ : rest) s = skipOsc st rest s