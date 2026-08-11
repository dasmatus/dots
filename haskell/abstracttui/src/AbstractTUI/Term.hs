{-# LANGUAGE BangPatterns #-}
-- | A capture terminal: a mock 'Graphics.Vty.Vty' over a custom
-- 'Graphics.Vty.Output.Output' that records every 'Picture' handed to
-- 'update' and every byte the renderer emits, so the headless test driver
-- can inspect the rendered frame cell-by-cell and assert on the emitted
-- bytes.
--
-- The mock 'Output' is built on "Graphics.Vty.Output.Mock"'s skeleton but
-- its 'mkDisplayContext' is replaced with a real ANSI
-- 'Graphics.Vty.Output.DisplayContext' (cursor-position @ESC [ row;col H@,
-- no SGR, no cursor-visibility escapes) so the emitted bytes are real VT100
-- escapes that "AbstractTUI.Testing.Capture"'s 'parseScreen' can parse back
-- into a cell grid. vty's 'outputPicture' already diffs each frame against
-- the previous one via 'assumedStateRef'/'prevOutputOps' (per-row), so an
-- identical frame emits nothing; 'requestFullRedraw' (in
-- "AbstractTUI.Driver") resets 'assumedStateRef' to 'initialAssumedState',
-- forcing the next 'update' to re-emit every changed row.
--
-- 'captureCell' flattens the top 'Image' layer of the last 'Picture' to a
-- (x,y) -> 'Char' grid by recursing through the 'Image' constructors (see
-- "Graphics.Vty.Image.Internal"). 'captureEmit' drains the accumulated
-- emitted bytes. The mock 'Vty' is built with 'mkVtyFromPair' so 'update'
-- runs the real 'outputPicture' renderer against the custom 'Output' (its
-- 'outputByteBuffer' is overridden to record bytes instead of printing
-- them), and the picture is intercepted before rendering for 'captureCell'.
--
-- The input side: 'ctInput' is a FIFO of pre-decoded vty 'V.Event's;
-- 'captureFeedInput' enqueues (used by "AbstractTUI.Testing.Capture"'s
-- 'feedInput', which decodes raw bytes to 'V.Event's first) and
-- 'captureDrainInput' atomically drains (used by the 'Driver' 'turn' to fire
-- them via the input 'EventTrigger').
module AbstractTUI.Term
  ( CaptureTerm (..)
  , newCaptureTerm
  , captureCell
  , captureEmit
  , captureFeedInput
  , captureDrainInput
  ) where

import Blaze.ByteString.Builder (Write)
import Blaze.ByteString.Builder.ByteString (writeByteString)
import Control.Concurrent.STM (newTChanIO)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C8
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Text.Lazy as TL
import Graphics.Vty.Image (DisplayRegion, Image, imageHeight, imageWidth)
import qualified Graphics.Vty.Image.Internal as V.Image
import Graphics.Vty.Output
  ( DisplayContext (..)
  )
import Graphics.Vty.Picture (Picture, picLayers)
import qualified Graphics.Vty as V
import Graphics.Vty.Output.Mock (mockTerminal)
import System.IO.Unsafe (unsafePerformIO)

-- | A mock vty terminal that captures the last rendered 'Picture', the bytes
-- the renderer has emitted (accumulating across frames until 'captureEmit'
-- drains them), and a FIFO of pre-decoded input 'V.Event's.
data CaptureTerm = CaptureTerm
  { ctVty :: !V.Vty
  -- ^ The mock 'V.Vty' handle. 'update' records the picture and forwards to
  -- the real renderer.
  , ctPicture :: !(IORef (Maybe Picture))
  -- ^ The last 'Picture' handed to 'update' this frame (or 'Nothing' if no
  -- frame has been rendered yet).
  , ctEmitted :: !(IORef ByteString)
  -- ^ The bytes the mock output's 'outputByteBuffer' has received,
  -- accumulating across frames until 'captureEmit' drains them.
  , ctInput :: !(IORef [V.Event])
  -- ^ The pending input events, enqueued by 'captureFeedInput' (via
  -- 'feedInput') and drained by the 'Driver' 'turn' to fire them as vty
  -- input via the input 'EventTrigger'.
  , ctSize :: !DisplayRegion
  -- ^ The fixed display bounds (width, height) the mock terminal reports.
  }

-- | Build a capture terminal of the given width and height. The mock
-- 'V.Vty' forwards 'update' to the real 'outputPicture' renderer against a
-- custom 'Output' (its byte buffer records into 'ctEmitted' instead of
-- printing, and its 'mkDisplayContext' returns a real ANSI
-- 'DisplayContext' so 'parseScreen' can parse the emitted bytes), and
-- records the 'Picture' for 'captureCell'.
newCaptureTerm :: Int -> Int -> IO CaptureTerm
newCaptureTerm w h = do
  (_, mockOut0) <- mockTerminal (w, h)
  picRef <- newIORef Nothing
  emitRef <- newIORef BS.empty
  inputRef <- newIORef []
  -- Replace the mock's debug 'DisplayContext' (which emits single 'M'/'A'/'D'
  -- marker chars with no position info) with a real ANSI one that emits
  -- @ESC [ row;col H@ cursor positioning, so 'parseScreen' can recover the
  -- cell grid from the emitted bytes. SGR and cursor-visibility escapes are
  -- suppressed (mempty) — the smoke tests use default-attr text, and
  -- 'parseScreen' only understands cursor-position + printable bytes + SGR.
  -- 'supportsCursorVisibility' is False so 'outputPicture' skips hide/show
  -- cursor escapes entirely.
  let out =
        mockOut0
          { V.outputByteBuffer = \bs -> modifyIORef' emitRef (<> bs)
          , V.supportsCursorVisibility = False
          , V.mkDisplayContext = \dev r ->
              pure
                DisplayContext
                  { contextRegion = r
                  , contextDevice = dev
                  , writeMoveCursor = ansiMoveCursor
                  , writeShowCursor = mempty
                  , writeHideCursor = mempty
                  , writeSetAttr = \_ _ _ _ -> mempty
                  , writeDefaultAttr = \_ -> mempty
                  , writeRowEnd = mempty
                  , inlineHack = pure ()
                  }
          }
  chan <- newTChanIO
  let mockIn =
        V.Input
          { V.eventChannel = chan
          , V.shutdownInput = return ()
          , V.restoreInputState = return ()
          , V.inputLogMsg = \_ -> return ()
          }
  vty0 <- V.mkVtyFromPair mockIn out
  -- Intercept 'update' to record the picture before rendering. The real
  -- renderer ('outputPicture') writes the picture's bytes to the custom
  -- output's byte buffer, so 'captureEmit' sees them.
  let vty =
        vty0
          { V.update = \pic -> do
              writeIORef picRef (Just pic)
              V.update vty0 pic
          }
  pure
    CaptureTerm
      { ctVty = vty
      , ctPicture = picRef
      , ctEmitted = emitRef
      , ctInput = inputRef
      , ctSize = (w, h)
      }

-- | @ESC [ (row+1) ; (col+1) H@ — the ANSI cursor-position escape
-- 'parseScreen' understands (CSI 'H'). vty's 'writeMoveCursor' is called
-- with (x=col, y=row), both 0-indexed; the ANSI escape is 1-indexed.
ansiMoveCursor :: Int -> Int -> Write
ansiMoveCursor x y =
  writeByteString (BS.singleton 27) -- ESC
    <> writeByteString (BS.singleton 91) -- '[' (CSI introducer)
    <> writeByteString (C8.pack (show (y + 1) ++ ";" ++ show (x + 1)))
    <> writeByteString (BS.singleton 72) -- 'H'

-- | The character at cell @(x, y)@ of the last rendered frame, or ' ' if
-- the cell is outside the top layer's content. The top 'Image' layer is
-- flattened by recursing through 'Image' constructors; positions outside
-- any 'HorizText' span are treated as the background (space).
--
-- Pure to match the brief's API: the driver's 'turn' writes the picture
-- into the 'ctPicture' 'IORef' (via the mock 'V.Vty' 'update') BEFORE the
-- test reads it, so 'unsafePerformIO' here just observes a ref that has
-- already been settled. Single-threaded (the driver runs on one thread).
captureCell :: CaptureTerm -> Int -> Int -> Char
captureCell term x y = unsafePerformIO $ do
  mpic <- readIORef (ctPicture term)
  case mpic of
    Nothing -> pure ' '
    Just pic ->
      case picLayers pic of
        [] -> pure ' '
        (top : _) -> pure (imageChar top x y)

-- | Drain and return the bytes the mock output has accumulated since the
-- last call. The buffer is reset to empty after the call so the next call
-- only sees bytes emitted after it.
captureEmit :: CaptureTerm -> IO ByteString
captureEmit term = do
  bs <- readIORef (ctEmitted term)
  writeIORef (ctEmitted term) BS.empty
  pure bs

-- | Enqueue pre-decoded vty input events. The 'Driver' 'turn' drains them
-- and fires each via the input 'EventTrigger' so subscribed widgets (e.g.
-- 'shortcut') receive them. Used by "AbstractTUI.Testing.Capture"'s
-- 'feedInput', which decodes raw bytes to 'V.Event's first.
captureFeedInput :: CaptureTerm -> [V.Event] -> IO ()
captureFeedInput term evts = modifyIORef' (ctInput term) (<> evts)

-- | Atomically drain and return the pending input events. Called by the
-- 'Driver' 'turn' to fire them as vty input.
captureDrainInput :: CaptureTerm -> IO [V.Event]
captureDrainInput term = do
  evts <- readIORef (ctInput term)
  writeIORef (ctInput term) []
  pure evts

-- | Flatten an 'Image' to the character at @(x, y)@. Coordinates outside
-- the image's content return the background space. The 'Image'
-- constructors live in "Graphics.Vty.Image.Internal" (the public
-- "Graphics.Vty.Image" module exports 'Image' abstractly); we qualify the
-- constructor names to keep the import list unambiguous.
imageChar :: Image -> Int -> Int -> Char
imageChar img x y = case img of
  V.Image.HorizText _ txt _ _ ->
    let charLen = fromIntegral (TL.length txt) :: Int
    in if y == 0 && x >= 0 && x < charLen
         then TL.index txt (fromIntegral x)
         else ' '
  V.Image.HorizJoin l r _ _ ->
    let lw = imageWidth l
    in if x < lw then imageChar l x y else imageChar r (x - lw) y
  V.Image.VertJoin t b _ _ ->
    let th = imageHeight t
    in if y < th then imageChar t x y else imageChar b x (y - th)
  V.Image.BGFill _ _ -> ' '
  V.Image.Crop i ls ts _ _ -> imageChar i (x + ls) (y + ts)
  V.Image.EmptyImage -> ' '