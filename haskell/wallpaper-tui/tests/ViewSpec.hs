{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Headless render tests for the wallpaper TUI view. Each test mounts
-- 'rootView' over a 'Signal' 'App' (and 'Signal' 'Fx') set to a canned
-- state, pumps one frame into a 'CaptureTerm', and asserts the rendered
-- cells contain the expected user-visible strings. Faithful Haskell port of
-- @rust/wallpaper-tui/tests/view.rs@.
module ViewSpec (tests) where

import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import qualified Data.Map.Strict as Map
import Data.List (isInfixOf)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

import AbstractTUI.Base.Color (rgb)
import AbstractTUI.Base.Geom (size)
import AbstractTUI.Driver
  ( RunConfig (..)
  , appMount
  , defaultRunConfig
  , newApp
  , newDriver
  , turn
  )
import AbstractTUI.Gfx.Bitmap (Bitmap, bitmap)
import AbstractTUI.Reactive (Signal, sigReadRef, sigUpdateIO, signal)
import AbstractTUI.Testing.Capture (CaptureTerm, captureCell, newCaptureTerm)

import WallpaperTui.Accent (TintBackend (..))
import WallpaperTui.App (App (..), appNew)
import WallpaperTui.Config (Config (..), State (..), defaultConfig)
import WallpaperTui.Fx
  ( Fx (..)
  , crossfadeOpacity
  , fxAdvance
  , fxNew
  , retargetCrossfadeForce
  )
import WallpaperTui.Ui (rootView)

import Common (makeImage, withTmp)

-- | Existential wrapper so the mount closure (polymorphic in @t@) can publish
-- the @Signal Fx@ to the test body (which knows only the concrete Spider
-- timeline). 'sigReadRef'/'sigUpdateIO' are polymorphic in @t@, so the test
-- drives the crossfade without ever naming @t@.
data SomeFxSig = forall t. SomeFxSig (Signal t Fx)

-- | A config whose @wallpaper_folder@ is a temp dir holding @count@ flat-color
-- PNGs named @wp0.png@..@wp{count-1}.png@.
configWithWallpapers :: Int -> (Config -> IO a) -> IO a
configWithWallpapers count action =
  withTmp $ \tmp -> do
    mapM_
      ( \i -> makeImage (tmp </> ("wp" <> show i <> ".png")) (40 + i * 10, 200, 60) 16)
      [0 .. count - 1]
    action defaultConfig{configWallpaperFolder = tmp}

-- | Build the initial picker 'App' for @cfg@ (no tint, 'Internal' backend).
newApp' :: Config -> IO App
newApp' cfg = appNew cfg (State Map.empty) False Internal

-- | Render @app@ at @cols×rows@ and return the concatenated cell text, one row
-- per line. Uses the engine 'Driver' + 'CaptureTerm' headless path.
renderToString :: App -> Bool -> String -> Int -> Int -> IO String
renderToString app isEmpty folder cols rows = do
  (out, _) <- renderWithFx' app isEmpty folder cols rows (\_ -> pure ())
  pure out

-- | Like 'renderToString' but also hands the mounted 'Signal' 'Fx' to an
-- action (for the crossfade retarget test), then re-pumps one frame so the
-- mid-fade state is on screen.
renderWithFx' ::
  App ->
  Bool ->
  String ->
  Int ->
  Int ->
  (forall t. Signal t Fx -> IO ()) ->
  IO (String, ())
renderWithFx' app isEmpty folder cols rows driveFx = do
  fxRef <- newIORef (Nothing :: Maybe SomeFxSig)
  eng <- newApp (size cols rows)
  appMount eng $ \scope -> do
    a <- signal app scope
    f <- signal fxNew scope
    liftIO (writeIORef fxRef (Just (SomeFxSig f)))
    pure (rootView isEmpty folder a f True)
  term <- newCaptureTerm cols rows
  dr <- newDriver eng term defaultRunConfig{rcProbe = False}
  _ <- turn dr
  Just (SomeFxSig f) <- readIORef fxRef
  driveFx f
  _ <- turn dr
  out <- cellsToString term cols rows
  pure (out, ())

-- | Concatenate every cell into a string, one row per line. Empty cells
-- become a space (vty's blank).
cellsToString :: CaptureTerm -> Int -> Int -> IO String
cellsToString term cols rows = do
  rows' <- mapM row [0 .. rows - 1]
  pure (unlines rows')
  where
    row y = concat <$> mapM (\x -> (: []) <$> captureCell term x y) [0 .. cols - 1]

-- | A flat-color 8×8 bitmap for the preview-present tests (small enough that
-- the half-block mosaic emits ▀\/▄\/█).
smallTestBitmap :: Bitmap
smallTestBitmap = bitmap 8 8 (rgb 255 0 0)

tests :: TestTree
tests =
  testGroup
    "View"
    [ testCase "empty state lists no-wallpapers message" $
        configWithWallpapers 0 $ \cfg -> do
          app <- newApp' cfg
          out <- renderToString app True (configWallpaperFolder cfg) 80 24
          assertBool ("missing empty msg: " <> out) ("No wallpapers found" `isInfixOf` out)
          assertBool ("missing help line: " <> out) ("Enter:apply" `isInfixOf` out)
    , testCase "list shows wallpaper names, title, info and help" $
        configWithWallpapers 3 $ \cfg -> do
          app <- newApp' cfg
          out <- renderToString app False (configWallpaperFolder cfg) 80 24
          assertBool ("missing list title: " <> out) ("wallpapers" `isInfixOf` out)
          assertBool ("missing wp0: " <> out) ("wp0.png" `isInfixOf` out)
          assertBool ("missing wp1: " <> out) ("wp1.png" `isInfixOf` out)
          assertBool ("missing wp2: " <> out) ("wp2.png" `isInfixOf` out)
          assertBool ("missing info bar: " <> out) ("Output:" `isInfixOf` out)
          assertBool ("missing mode: " <> out) ("Mode:" `isInfixOf` out)
          assertBool ("missing help: " <> out) ("Enter:apply  j/k:move" `isInfixOf` out)
    , testCase "list highlights selected entry with arrow" $
        configWithWallpapers 2 $ \cfg -> do
          app <- newApp' cfg
          out <- renderToString app False (configWallpaperFolder cfg) 80 24
          let marked = filter ("> wp" `isInfixOf`) (lines out)
          assertEqual ("expected one highlighted entry, got " <> show marked) 1 (length marked)
    , testCase "preview pane shows unavailable label when no bitmap" $
        configWithWallpapers 1 $ \cfg -> do
          app <- newApp' cfg
          out <- renderToString app False (configWallpaperFolder cfg) 80 24
          assertBool ("missing preview fallback: " <> out)
            ("[preview unavailable]" `isInfixOf` out || "rendering" `isInfixOf` out)
    , testCase "preview pane shows image when bitmap present" $
        configWithWallpapers 1 $ \cfg -> do
          app <- newApp' cfg
          let app' = app{wpPreview = Just smallTestBitmap}
          out <- renderToString app' False (configWallpaperFolder cfg) 80 24
          assertBool ("label shown despite bitmap: " <> out)
            (not ("[preview unavailable]" `isInfixOf` out))
          assertBool ("missing preview title: " <> out) ("preview" `isInfixOf` out)
    , testCase "preview pane blank when preview hidden" $
        configWithWallpapers 1 $ \cfg -> do
          app <- newApp' cfg
          let app' = app{wpShowPreview = False, wpPreview = Just smallTestBitmap}
          out <- renderToString app' False (configWallpaperFolder cfg) 80 24
          assertBool ("label shown despite preview hidden: " <> out)
            (not ("[preview unavailable]" `isInfixOf` out))
    , testCase "crossfade retarget drives opacity through the signal" $
        configWithWallpapers 1 $ \cfg -> do
          app <- newApp' cfg
          let app' = app{wpPreview = Just smallTestBitmap}
          out <- renderWithFx' app' False (configWallpaperFolder cfg) 80 24 $ \fx -> do
            idle <- sigReadRef fx
            assertBool "idle opacity 1.0" (abs (crossfadeOpacity idle - 1.0) < 1e-6)
            sigUpdateIO fx retargetCrossfadeForce
            sigUpdateIO fx (fxAdvance 75)
            mid <- sigReadRef fx
            let midOp = crossfadeOpacity mid
            assertBool ("mid-fade in (0,1), got " <> show midOp)
              (midOp > 0.0 && midOp < 1.0)
          assertBool ("missing preview title mid-fade: " <> fst out) ("preview" `isInfixOf` fst out)
    , testCase "preview renders mosaic glyph when bitmap present" $
        configWithWallpapers 1 $ \cfg -> do
          app <- newApp' cfg
          let app' = app{wpPreview = Just smallTestBitmap}
          out <- renderToString app' False (configWallpaperFolder cfg) 80 24
          assertBool ("missing mosaic glyph: " <> out)
            ('▀' `elem` out || '▄' `elem` out || '█' `elem` out)
    ]