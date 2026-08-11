{-# LANGUAGE BangPatterns #-}
-- | A capture terminal: a mock 'Graphics.Vty.Vty' over
-- "Graphics.Vty.Output.Mock" that records every 'Picture' handed to 'update'
-- and every byte the mock output's byte buffer receives, so the headless
-- test driver can inspect the rendered frame cell-by-cell and assert on the
-- emitted bytes.
--
-- 'captureCell' flattens the top 'Image' layer of the last 'Picture' to a
-- (x,y) → 'Char' grid by recursing through the 'Image' constructors (see
-- "Graphics.Vty.Image.Internal"). 'captureEmit' drains the frame's emitted
-- bytes. The mock 'Vty' is built with 'mkVtyFromPair' so 'update' runs the
-- real 'outputPicture' renderer against the mock output (its
-- 'outputByteBuffer' is overridden to record bytes instead of printing
-- them), and the picture is intercepted before rendering for 'captureCell'.
module AbstractTUI.Term
  ( CaptureTerm (..)
  , newCaptureTerm
  , captureCell
  , captureEmit
  ) where

import Control.Concurrent.STM (newTChanIO)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import qualified Data.Text.Lazy as TL
import Graphics.Vty.Image (DisplayRegion, Image, imageHeight, imageWidth)
import qualified Graphics.Vty.Image.Internal as V.Image
import Graphics.Vty.Picture (Picture, picLayers)
import qualified Graphics.Vty as V
import Graphics.Vty.Output.Mock (mockTerminal)
import System.IO.Unsafe (unsafePerformIO)

-- | A mock vty terminal that captures the last rendered 'Picture' and the
-- bytes the mock output received this frame.
data CaptureTerm = CaptureTerm
  { ctVty :: !V.Vty
  -- ^ The mock 'V.Vty' handle. 'update' records the picture and forwards
  -- to the real renderer.
  , ctPicture :: !(IORef (Maybe Picture))
  -- ^ The last 'Picture' handed to 'update' this frame (or 'Nothing' if
  -- no frame has been rendered yet).
  , ctEmitted :: !(IORef ByteString)
  -- ^ The bytes the mock output's 'outputByteBuffer' received this
  -- frame. Drained by 'captureEmit'.
  , ctSize :: !DisplayRegion
  -- ^ The fixed display bounds (width, height) the mock terminal reports.
  }

-- | Build a capture terminal of the given width and height. The mock
-- 'V.Vty' forwards 'update' to the real 'outputPicture' renderer against a
-- mock 'Output' (its byte buffer records into 'ctEmitted' instead of
-- printing), and records the 'Picture' for 'captureCell'.
newCaptureTerm :: Int -> Int -> IO CaptureTerm
newCaptureTerm w h = do
  (_, mockOut) <- mockTerminal (w, h)
  picRef <- newIORef Nothing
  emitRef <- newIORef BS.empty
  -- Override the mock output's byte buffer to record bytes silently
  -- (the stock mock 'outputByteBuffer' prints to stdout, which would
  -- pollute test output).
  let out =
        mockOut
          { V.outputByteBuffer = \bs -> modifyIORef' emitRef (<> bs)
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
  -- renderer ('outputPicture') writes the picture's bytes to the mock
  -- output's (overridden) byte buffer, so 'captureEmit' sees them.
  let vty =
        vty0
          { V.update = \pic -> do
              writeIORef picRef (Just pic)
              V.update vty0 pic
          }
  pure CaptureTerm {ctVty = vty, ctPicture = picRef, ctEmitted = emitRef, ctSize = (w, h)}

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

-- | Drain and return the bytes the mock output received this frame. The
-- buffer is reset to empty after the call so the next call only sees bytes
-- emitted after it.
captureEmit :: CaptureTerm -> IO ByteString
captureEmit term =
  -- atomicModifyIORef' with a strict pair would also work; the emitted
  -- buffer is only touched from the driver's single-threaded frame loop.
  readIORef (ctEmitted term) >>= \bs -> case bs of
    _ -> do
      writeIORef (ctEmitted term) BS.empty
      pure bs

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