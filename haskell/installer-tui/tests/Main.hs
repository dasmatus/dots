-- | Tasty driver for the dots-installer Haskell test suite. Mirrors the Rust
-- integration tests (@app@, @config@, @disks@, @install@, @net@, @fx@,
-- @full_redraw@) as one tasty tree of per-module groups. ViewSpec (the
-- per-screen headless-render suite) is deferred to a hardening pass — the
-- headless coverage already comes via FullRedrawSpec + the AppSpec
-- state-machine assertions.
module Main (main) where

import Test.Tasty (defaultMain, testGroup)

import qualified AppSpec
import qualified ConfigSpec
import qualified DisksSpec
import qualified FxSpec
import qualified FullRedrawSpec
import qualified InstallSpec
import qualified NetSpec

main :: IO ()
main =
  defaultMain $
    testGroup
      "dots-installer"
      [ AppSpec.tests
      , ConfigSpec.tests
      , DisksSpec.tests
      , InstallSpec.tests
      , NetSpec.tests
      , FxSpec.tests
      , FullRedrawSpec.tests
      ]