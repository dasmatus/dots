-- | Byte -> key-chord decoding. Mirrors the @abstracttui::input@ layer: a
-- small state machine that turns raw stdin bytes into the 'KeyChord' values
-- the driver dispatches. Handles the escape sequences the three apps care
-- about (arrows, Home/End, PgUp/PgDn, Delete, Shift-Tab) plus ctrl+letter
-- and plain printable bytes.
--
-- Salvaged verbatim from the stash's @Term/Input.hs@; only the import of
-- 'Key'/'KeyChord'/'Mods'/'chord'/'noMods'/'ctrl'/'shift' is repointed from
-- the stash's @AbstractTUI.UI.View@ to the reflex port's
-- "AbstractTUI.View". The module stays pure (no Reflex/vty imports).
module AbstractTUI.Term.Input
  ( decodeBytes
  , decodeByte
  ) where

import Data.Word (Word8)

import AbstractTUI.View
  ( Key (..)
  , KeyChord (..)
  , noMods
  , ctrl
  , shift
  )

-- | Decode a batch of input bytes into zero or more key chords. The decoder
-- is byte-by-byte so a partial escape sequence at the buffer boundary just
-- yields nothing for the prefix and is revisited when more bytes arrive —
-- in practice the terminal sends each @ESC[…]@ sequence atomically.
decodeBytes :: [Word8] -> [KeyChord]
decodeBytes = go
  where
    go [] = []
    go (b : rest) = case decodeByte b rest of
      Just (ch, consumed) -> ch : go (drop consumed rest)
      Nothing -> go rest

-- | Decode one chord starting at @b@, possibly consuming following bytes.
-- Returns the chord and the number of *extra* bytes consumed (0 for a
-- single-byte key, 2 for an @ESC[…]@ sequence). 'Nothing' means the byte is
-- ignorable (e.g. a stray mid-sequence byte).
decodeByte :: Word8 -> [Word8] -> Maybe (KeyChord, Int)
decodeByte b rest
  -- ESC on its own (no following [ or O) -> Esc.
  | b == 27 =
      case rest of
        next : _
          | next == 91 -> escBracket rest  -- ESC [
          | next == 79 -> escO rest        -- ESC O
          | next == 90 -> Just (KeyChord shift KeyTab, 1) -- ESC Z = Shift-Tab? actually CSI Z
        _ -> Just (KeyChord noMods KeyEsc, 0)
  | b == 13 || b == 10 = Just (KeyChord noMods KeyEnter, 0)
  | b == 9 = Just (KeyChord noMods KeyTab, 0)
  | b == 127 || b == 8 = Just (KeyChord noMods KeyBackspace, 0)
  | b <= 26 = Just (KeyChord ctrl (KeyChar (toEnum (fromIntegral b + 96))), 0)
    -- \x01 -> ctrl+a, ... \x1a -> ctrl+z.
  | b == 32 = Just (KeyChord noMods KeySpace, 0)
  | b >= 32 && b < 127 =
      let c = toEnum (fromIntegral b)
          ms = if c >= 'A' && c <= 'Z' then shift else noMods
       in Just (KeyChord ms (KeyChar c), 0)
  | otherwise = Nothing

-- | Decode an @ESC [@ (CSI) sequence: the @[@ is @rest !! 0@.
escBracket :: [Word8] -> Maybe (KeyChord, Int)
escBracket bs = case bs of
  -- rest = '[' : body
  _ : 65 : _ -> Just (KeyChord noMods KeyUp, 2)        -- ESC [ A
  _ : 66 : _ -> Just (KeyChord noMods KeyDown, 2)      -- ESC [ B
  _ : 67 : _ -> Just (KeyChord noMods KeyRight, 2)      -- ESC [ C
  _ : 68 : _ -> Just (KeyChord noMods KeyLeft, 2)      -- ESC [ D
  _ : 72 : _ -> Just (KeyChord noMods KeyHome, 2)      -- ESC [ H
  _ : 70 : _ -> Just (KeyChord noMods KeyEnd, 2)       -- ESC [ F
  _ : 53 : 126 : _ -> Just (KeyChord noMods KeyPgUp, 3)    -- ESC [ 5 ~
  _ : 54 : 126 : _ -> Just (KeyChord noMods KeyPgDn, 3)    -- ESC [ 6 ~
  _ : 51 : 126 : _ -> Just (KeyChord noMods KeyDelete, 3)  -- ESC [ 3 ~
  _ : 90 : _ -> Just (KeyChord shift KeyTab, 2)       -- ESC [ Z = Shift-Tab
  _ : 49 : 126 : _ -> Just (KeyChord noMods KeyHome, 3)    -- ESC [ 1 ~ (some)
  _ : 52 : 126 : _ -> Just (KeyChord noMods KeyEnd, 3)     -- ESC [ 4 ~
  _ -> Nothing

-- | @ESC O X@ (SS3) sequences — some terminals send Home/End/arrows here.
escO :: [Word8] -> Maybe (KeyChord, Int)
escO bs = case bs of
  _ : 65 : _ -> Just (KeyChord noMods KeyUp, 2)
  _ : 66 : _ -> Just (KeyChord noMods KeyDown, 2)
  _ : 67 : _ -> Just (KeyChord noMods KeyRight, 2)
  _ : 68 : _ -> Just (KeyChord noMods KeyLeft, 2)
  _ : 72 : _ -> Just (KeyChord noMods KeyHome, 2)
  _ : 70 : _ -> Just (KeyChord noMods KeyEnd, 2)
  _ -> Nothing