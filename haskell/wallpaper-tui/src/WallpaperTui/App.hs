{-# LANGUAGE LambdaCase #-}

-- | TUI state machine. 'handleKey' is a pure transition function — all
-- interaction logic lives here so it is unit-testable without a terminal
-- (mirrors @rust/wallpaper-tui/src/app.rs::handle_key@). I/O (apply\/tint,
-- preview decode, state save) is expressed as /pending/ ops that
-- "WallpaperTui.Run" spawns on worker threads; the pure state machine just
-- records the request, keeping selection responsive.
--
-- The preview cache ('wpPreviewCache') stores decoded 'JP.DynamicImage's in
-- the 'App' itself (faithful to Rust's @preview_cache: HashMap<String,
-- DynamicImage>@): a return to a previously seen wallpaper rebuilds the
-- 'Bitmap' on the UI thread via 'dynimgToBitmap' — no worker round-trip.
module WallpaperTui.App
  ( -- * State
    App (..)
  , appNew
    -- * Pending ops + events
  , PendingOp (..)
  , Event (..)
    -- * Pure transitions
  , handleKey
  , requestPreview
  , onEvent
    -- * Projections
  , selectedPath
  , outputName
  , infoText
  , dynimgToBitmap
  ) where

import Data.List (elemIndex)
import Data.Maybe (fromMaybe)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Vector as V
import qualified Codec.Picture as JP
import System.FilePath (takeFileName)

import AbstractTUI.Base.Color (Rgba (..), black)
import AbstractTUI.Gfx.Bitmap (Bitmap, bitmap, fromPixels)

import WallpaperTui.Awww (Group (..))
import WallpaperTui.Config
  ( Config (..)
  , Effective (..)
  , State (..)
  , OutputOverride (..)
  , colorPalette
  , effectiveOutput
  , modes
  )
import WallpaperTui.Input (KeyCode (..))
import WallpaperTui.Wallpapers (detectOutputs, listWallpapers)
import WallpaperTui.Accent (TintBackend)

-- | A request the event loop drains off the TUI thread. 'PendingRestore' is a
-- marker: the loop resolves the actual groups via
-- "WallpaperTui.Awww".'WallpaperTui.Awww.restoreGroups' (IO, file-existence
-- check) when it takes the marker — the pure state machine cannot do IO, so
-- it just records the intent. Mirrors @PendingOp@; the Rust @Restore@ variant
-- carries the groups because Rust's @handle_key@ calls @restore_groups@ (IO)
-- inline, whereas this port defers the IO to the loop to keep 'handleKey'
-- pure.
data PendingOp
  = -- | Apply one group + run the accent tint.
    PendingApply !Group !String !Double !Bool !TintBackend
  | -- | Re-apply every declared output + tint the first one (marker; loop
    -- resolves the groups).
    PendingRestore
  | -- | Decode the preview thumbnail for a path.
    PendingPreview !FilePath
  deriving (Show, Eq)

-- | Worker → TUI events. 'EventPreviewReady' carries the decoded
-- 'JP.DynamicImage' (the cache stores it; the UI thread rebuilds the
-- 'Bitmap' via 'dynimgToBitmap' so the cache hit fast path needs no worker
-- round-trip). 'Nothing' means the decode failed.
data Event
  = EventApplyDone !String
  | EventPreviewReady !FilePath !(Maybe JP.DynamicImage)

-- | 'Event' carries a 'JP.DynamicImage' (no 'Show'/'Eq' instances in
-- JuicyPixels), so the derivations are hand-written: the image is shown as
-- its decoded dimensions and compared only by path (the worker never fires
-- two previews for the same path in flight).
instance Show Event where
  show (EventApplyDone msg) = "EventApplyDone " <> show msg
  show (EventPreviewReady path _) = "EventPreviewReady " <> show path

instance Eq Event where
  EventApplyDone a == EventApplyDone b = a == b
  EventPreviewReady pa _ == EventPreviewReady pb _ = pa == pb
  _ == _ = False

-- | The pure picker state. 'wpPreviewCache' memoizes decoded images by path
-- so a return to a previously seen wallpaper rebuilds the on-screen
-- 'Bitmap' without a worker spawn. Faithful to Rust's @App@ (the
-- @preview_cache@ is a field of @App@, not loop state).
data App = App
  { wpConfig :: !Config
  , wpState :: !State
  , wpNoTint :: !Bool
  , wpBackend :: !TintBackend
  , wpWallpapers :: ![FilePath]
  , wpOutputs :: ![String]
  , wpCurrentOutput :: !Int
  , wpSelected :: !Int
  , wpFillMode :: !String
  , wpCurrentColor :: !String
  , wpShowPreview :: !Bool
  , -- | The on-screen preview as a mosaic bitmap. 'Nothing' until the first
    -- decode arrives (or after a failed decode).
    wpPreview :: !(Maybe Bitmap)
  , -- | Decoded preview thumbnails, memoized by path.
    wpPreviewCache :: !(Map FilePath JP.DynamicImage)
  , -- | The path the preview worker is currently decoding (avoids duplicate
    -- requests for the same selection).
    wpPreviewPending :: !(Maybe FilePath)
  , -- | Set by 'handleKey'; the loop takes it and spawns the worker.
    wpPending :: !(Maybe PendingOp)
  , -- | One-line status from the last apply (shown in the info bar).
    wpStatus :: !(Maybe String)
  , wpShouldQuit :: !Bool
  }

-- | Build the initial state: list wallpapers, detect outputs (union with the
-- declared outputs, @\"*\"@ fallback when empty), seed the effective
-- mode\/color from the focused output. IO only for the directory walk +
-- @hyprctl@; the resulting 'App' is pure. Mirrors @App::new@.
appNew :: Config -> State -> Bool -> TintBackend -> IO App
appNew config state noTint backend = do
  wallpapers <- listWallpapers (configWallpaperFolder config) (configRecursive config)
  detected <- detectOutputs
  let configOuts = Map.keys (configOutputs config)
      outputs0 = detected ++ filter (`notElem` detected) configOuts
      outputs = if null outputs0 then ["*"] else outputs0
      currentOutput = case configCurrentOutput config of
        "" -> 0
        cur -> fromMaybe 0 (elemIndex cur outputs)
      eff = effectiveOutput config state (atDef outputs currentOutput)
  pure
    App
      { wpConfig = config
      , wpState = state
      , wpNoTint = noTint
      , wpBackend = backend
      , wpWallpapers = wallpapers
      , wpOutputs = outputs
      , wpCurrentOutput = currentOutput
      , wpSelected = 0
      , wpFillMode = effMode eff
      , wpCurrentColor = effFillColor eff
      , wpShowPreview = True
      , wpPreview = Nothing
      , wpPreviewCache = Map.empty
      , wpPreviewPending = Nothing
      , wpPending = Nothing
      , wpStatus = Nothing
      , wpShouldQuit = False
      }

-- | The currently-focused output name. Safe: 'appNew' guarantees a non-empty
-- 'wpOutputs' (the @\"*\"@ fallback).
outputName :: App -> String
outputName app = atDef (wpOutputs app) (wpCurrentOutput app)

-- | The currently-highlighted wallpaper path, if any.
selectedPath :: App -> Maybe FilePath
selectedPath app = case drop (wpSelected app) (wpWallpapers app) of
  (p : _) -> Just p
  [] -> Nothing

-- | One-line info bar text. Mirrors @App::info_text@.
infoText :: App -> String
infoText app =
  let eff = effectiveOutput (wpConfig app) (wpState app) (outputName app)
      name = if null (effPath eff) then "(none)" else takeFileName (effPath eff)
      base =
        " Output: "
          <> outputName app
          <> " | Mode: "
          <> wpFillMode app
          <> " | Color: "
          <> wpCurrentColor app
          <> " | Current: "
          <> name
          <> " "
      extra = case wpStatus app of
        Just st -> "| " <> st <> " "
        Nothing -> ""
  in base <> extra

-- | Request a preview render for the current selection. A cache hit rebuilds
-- the 'Bitmap' on the UI thread immediately (no worker round-trip); a miss
-- asks the worker to decode the thumbnail. Pure. Mirrors @request_preview@.
requestPreview :: App -> App
requestPreview app
  | not (wpShowPreview app) = app
  | otherwise = case selectedPath app of
      Nothing -> app
      Just path -> case Map.lookup path (wpPreviewCache app) of
        Just dyn -> app{wpPreview = Just (dynimgToBitmap dyn)}
        Nothing
          | wpPreviewPending app == Just path -> app
          | otherwise ->
              app
                { wpPreviewPending = Just path
                , wpPending = Just (PendingPreview path)
                }

-- | The pure key transition. q\/Esc quit, j\/Down + k\/Up (wrap around),
-- Enter apply, m cycle mode, c set color, o cycle output, p toggle preview,
-- r restore. Mirrors @App::handle_key@ exactly (including the wrap-around
-- edge: @selected == 0 → last@, @selected+1 >= len → 0@).
handleKey :: App -> KeyCode -> App
handleKey app key = case key of
  Char 'q' -> app{wpShouldQuit = True}
  Esc -> app{wpShouldQuit = True}
  Char 'j' -> cursorDown app
  Down -> cursorDown app
  Char 'k' -> cursorUp app
  Up -> cursorUp app
  Enter -> apply app
  Char 'm' -> cycleMode app
  Char 'c' -> setColor app
  Char 'o' -> cycleOutput app
  Char 'p' -> app{wpShowPreview = not (wpShowPreview app)}
  Char 'r' -> app{wpPending = Just PendingRestore}
  _ -> app

cursorUp :: App -> App
cursorUp app
  | null wps = app
  | wpSelected app == 0 = requestPreview app{wpSelected = length wps - 1}
  | otherwise = requestPreview app{wpSelected = wpSelected app - 1}
  where
    wps = wpWallpapers app

cursorDown :: App -> App
cursorDown app
  | null wps = app
  | wpSelected app + 1 >= length wps = requestPreview app{wpSelected = 0}
  | otherwise = requestPreview app{wpSelected = wpSelected app + 1}
  where
    wps = wpWallpapers app

cycleMode :: App -> App
cycleMode app =
  let idx = fromMaybe 0 (elemIndex (wpFillMode app) modes)
      next = (idx + 1) `mod` length modes
  in app{wpFillMode = atDef modes next}

setColor :: App -> App
setColor app =
  let idx = fromMaybe 0 (elemIndex (wpCurrentColor app) colorPalette)
      next = (idx + 1) `mod` length colorPalette
  in app{wpCurrentColor = atDef colorPalette next}

cycleOutput :: App -> App
cycleOutput app =
  let outs = wpOutputs app
      n = length outs
      cur = (wpCurrentOutput app + 1) `mod` n
      eff = effectiveOutput (wpConfig app) (wpState app) (atDef outs cur)
  in app{wpCurrentOutput = cur, wpFillMode = effMode eff, wpCurrentColor = effFillColor eff}

-- | Apply the current selection to the focused output: write the override
-- into 'wpState' and queue a 'PendingApply'. The state save (IO) is deferred
-- to the loop (the pure state machine cannot do IO); the loop saves
-- 'wpState' when it dispatches the pending op, mirroring Rust's
-- @self.state.save()@. Mirrors @App::apply@.
apply :: App -> App
apply app =
  case selectedPath app of
    Nothing -> app
    Just path ->
      let output = outputName app
          ov = OutputOverride (Just path) (Just (wpFillMode app)) (Just (wpCurrentColor app))
          state' = (wpState app){stateOutputs = Map.insert output ov (stateOutputs (wpState app))}
          group = Group output path (wpFillMode app) (wpCurrentColor app)
      in app
          { wpState = state'
          , wpPending =
              Just
                ( PendingApply
                    group
                    (configTransitionType (wpConfig app))
                    (configTransitionDuration (wpConfig app))
                    (wpNoTint app)
                    (wpBackend app)
                )
          }

-- | Drain a worker event into state. Pure. Called from the loop each frame
-- (the loop does the IO; this just folds the event into the 'App'). The
-- 'EventPreviewReady' guard clears 'wpPreviewPending' only when it matches
-- the event's path (Rust's @take().filter(|p| p != &path)@); the cache
-- stores the decoded image and the preview is rebuilt on the UI thread.
-- Mirrors @App::on_event@.
onEvent :: App -> Event -> App
onEvent app (EventApplyDone msg) = app{wpStatus = Just msg}
onEvent app (EventPreviewReady path mImg) =
  let pending' = case wpPreviewPending app of
        Just p | p == path -> Nothing
        other -> other
  in case mImg of
      Just dyn ->
        app
          { wpPreviewPending = pending'
          , wpPreview = Just (dynimgToBitmap dyn)
          , wpPreviewCache = Map.insert path dyn (wpPreviewCache app)
          }
      Nothing -> app{wpPreviewPending = pending', wpPreview = Nothing}

-- | Convert a decoded 'JP.DynamicImage' into a mosaic 'Bitmap': take the
-- RGBA8 buffer, map each 'JP.PixelRGBA8' to 'Rgba'. Mirrors
-- @dynimg_to_bitmap@ (Rust uses @to_rgba8()@; this uses 'JP.convertRGBA8' so
-- PNG alpha is preserved byte-faithfully).
dynimgToBitmap :: JP.DynamicImage -> Bitmap
dynimgToBitmap dyn =
  let rgba8 = JP.convertRGBA8 dyn
      w = JP.imageWidth rgba8
      h = JP.imageHeight rgba8
      px =
        V.generate (w * h) $ \i ->
          let y = i `div` w
              x = i `mod` w
              JP.PixelRGBA8 r g b a = JP.pixelAt rgba8 x y
          in Rgba r g b a
  in case fromPixels w h px of
      Just b -> b
      Nothing -> bitmap 0 0 black

-- | List index with a default; crashes only on a negative index (the callers
-- guard against that). Spelled locally so the read mirrors Rust's @xs[i]@.
atDef :: [a] -> Int -> a
atDef xs i
  | i < 0 = error "WallpaperTui.App.atDef: negative index"
  | otherwise = case drop i xs of
      (x : _) -> x
      [] -> error "WallpaperTui.App.atDef: index out of range"