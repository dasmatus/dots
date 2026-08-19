-- | awww backend: mode mapping, fill-color normalization, argv building, and
-- the apply orchestrator with a stub backend. Faithful Haskell port of
-- @rust/wallpaper-tui/tests/awww.rs@.
module AwwwSpec (tests) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

import WallpaperTui.Awww
  ( AwwwBackend (..)
  , Group (..)
  , applyWallpaper
  , awwwImgArgs
  , mapResize
  , normalizeFillColor
  )

-- | A recording stub backend: @query@ is 'True' (daemon "up") so
-- 'ensureDaemon' never spawns, and each 'abSpawnImg' argv is appended to the
-- 'IORef'. Mirrors the Rust @FakeBackend@.
fakeBackend :: Bool -> IO (AwwwBackend, IORef [[String]])
fakeBackend up = do
  ref <- newIORef []
  pure
    ( AwwwBackend
        { abQuery = pure up
        , abSpawnImg = \argv -> modifyIORef' ref (<> [argv])
        }
    , ref
    )

group :: String -> String -> String -> String -> Group
group output path mode fill = Group output path mode fill

-- | @args !! (i+1)@ where @args !! i == flag@; mirrors the Rust @idx@ helper.
idx :: [String] -> String -> String
idx args flag = case break (== flag) args of
  (_, f : v : _) -> v
  _ -> error ("AwwwSpec.idx: flag " <> flag <> " not found")

tests :: TestTree
tests =
  testGroup
    "Awww"
    [ testCase "map_resize swaybg → awww" $ do
        assertEqual "fill" "crop" (mapResize "fill")
        assertEqual "stretch" "stretch" (mapResize "stretch")
        assertEqual "fit" "fit" (mapResize "fit")
        assertEqual "center" "no" (mapResize "center")
        assertEqual "tile -> no" "no" (mapResize "tile")
        assertEqual "unknown -> crop" "crop" (mapResize "unknown")
    , testCase "normalize_fill_color variants" $ do
        assertEqual "#rrggbb" "d2a1a1ff" (normalizeFillColor "#d2a1a1")
        assertEqual "rrggbb" "d2a1a1ff" (normalizeFillColor "d2a1a1")
        assertEqual "#rrggbbaa" "000000ff" (normalizeFillColor "#000000ff")
        assertEqual "empty -> black" "000000ff" (normalizeFillColor "")
    , testCase "awww_img_args single output" $ do
        let g = group "eDP-1" "/w/p.jpg" "fit" "#d2a1a1"
            args = awwwImgArgs g "grow" 1.0
        assertEqual "head" ["awww", "img", "-o"] (take 3 args)
        assertEqual "output" "eDP-1" (args !! 3)
        assertBool "path present" ("/w/p.jpg" `elem` args)
        assertEqual "resize" "fit" (idx args "--resize")
        assertEqual "fill-color" "d2a1a1ff" (idx args "--fill-color")
        assertEqual "transition-type" "grow" (idx args "--transition-type")
        assertEqual "transition-duration" "1.0" (idx args "--transition-duration")
    , testCase "awww_img_args star output omits -o" $ do
        let g = group "*" "/w/p.jpg" "fill" "#000000"
            args = awwwImgArgs g "fade" 2.0
        assertBool "no -o" (not ("-o" `elem` args))
        assertBool "no --outputs" (not ("--outputs" `elem` args))
        assertBool "path present" ("/w/p.jpg" `elem` args)
    , testCase "apply_wallpaper spawns one img per group" $ do
        (backend, ref) <- fakeBackend True
        let groups =
              [ group "eDP-1" "/w/a.jpg" "fill" "#000000"
              , group "HDMI-1" "/w/b.jpg" "fit" "#d2a1a1"
              ]
        n <- applyWallpaper backend groups "grow" 1.0
        assertEqual "spawned count" 2 n
        spawns <- readIORef ref
        assertEqual "spawns length" 2 (length spawns)
        let expected = map (\g -> awwwImgArgs g "grow" 1.0) groups
        assertEqual "full argv passed through" expected spawns
        assertEqual "first cmd" "awww" (head (head spawns))
        assertEqual "second cmd" "img" (head (spawns) !! 1)
        assertEqual "second output" "HDMI-1" (spawns !! 1 !! 3)
    , testCase "apply_wallpaper empty groups noop" $ do
        (backend, ref) <- fakeBackend True
        n <- applyWallpaper backend [] "grow" 1.0
        assertEqual "noop count" 0 n
        spawns <- readIORef ref
        assertBool "no spawns" (null spawns)
    ]