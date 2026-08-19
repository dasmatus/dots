-- | Pure 'handleKey' state-machine tests. Faithful Haskell port of the
-- @rust/wallpaper-tui/tests/app.rs@ contract (the Rust file is empty — the
-- state machine is exercised here, not in the crate). 'appNew' is IO (it
-- lists wallpapers and detects outputs); the transitions themselves are
-- pure, so each test builds an 'App' under a temp wallpaper folder and
-- asserts on the post-'handleKey' state.
module AppSpec (tests) where

import qualified Data.Map.Strict as Map
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

import WallpaperTui.Accent (TintBackend (..))
import WallpaperTui.App
  ( App (..)
  , PendingOp (..)
  , appNew
  , handleKey
  )
import WallpaperTui.Config (Config (..), State (..), defaultConfig)
import WallpaperTui.Input (KeyCode (..))

import Common (makeImage, withTmp)

-- | Build an 'App' with @count@ flat-color wallpapers under a temp dir.
withApp :: Int -> (App -> IO a) -> IO a
withApp count action =
  withTmp $ \tmp -> do
    mapM_
      ( \i -> makeImage (tmp </> ("wp" <> show i <> ".png")) (40, 200, 60) 16)
      [0 .. count - 1]
    let cfg = defaultConfig{configWallpaperFolder = tmp}
    app <- appNew cfg (State Map.empty) False Internal
    action app

tests :: TestTree
tests =
  testGroup
    "App"
    [ testCase "j moves the cursor down with wrap" $
        withApp 2 $ \app -> do
          let app1 = handleKey app (Char 'j')
          assertEqual "j -> 1" 1 (wpSelected app1)
          let app2 = handleKey app1 (Char 'j')
          assertEqual "j wrap -> 0" 0 (wpSelected app2)
    , testCase "k moves the cursor up with wrap" $
        withApp 2 $ \app -> do
          let app1 = handleKey app (Char 'k')
          assertEqual "k wrap -> 1" 1 (wpSelected app1)
          let app2 = handleKey app1 (Char 'k')
          assertEqual "k -> 0" 0 (wpSelected app2)
    , testCase "q sets should_quit" $
        withApp 1 $ \app -> do
          let app1 = handleKey app (Char 'q')
          assertBool "quit" (wpShouldQuit app1)
    , testCase "Esc sets should_quit" $
        withApp 1 $ \app -> do
          let app1 = handleKey app Esc
          assertBool "quit" (wpShouldQuit app1)
    , testCase "Enter queues a PendingApply" $
        withApp 1 $ \app -> do
          let app1 = handleKey app Enter
          case wpPending app1 of
            Just (PendingApply _ _ _ _ _) -> assertBool "apply queued" True
            other -> assertBool ("expected PendingApply, got " <> show other) False
    , testCase "p toggles show_preview" $
        withApp 1 $ \app -> do
          let app1 = handleKey app (Char 'p')
          assertBool "preview off after one p" (not (wpShowPreview app1))
          let app2 = handleKey app1 (Char 'p')
          assertBool "preview on after two p" (wpShowPreview app2)
    , testCase "r queues a PendingRestore" $
        withApp 1 $ \app -> do
          let app1 = handleKey app (Char 'r')
          case wpPending app1 of
            Just PendingRestore -> assertBool "restore queued" True
            other -> assertBool ("expected PendingRestore, got " <> show other) False
    , testCase "Down/Up mirror j/k" $
        withApp 3 $ \app -> do
          let app1 = handleKey app Down
          assertEqual "Down -> 1" 1 (wpSelected app1)
          let app2 = handleKey app1 Up
          assertEqual "Up -> 0" 0 (wpSelected app2)
    ]