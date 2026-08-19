-- | Tasty driver for the wallpaper-tui Haskell test suite. Mirrors the
-- eight Rust integration test binaries (@accent@, @awww@, @config@, @fx@,
-- @preview@, @tint@, @view@) as one tasty tree of per-module groups.
module Main (main) where

import Test.Tasty (defaultMain, testGroup)

import qualified AccentSpec
import qualified AwwwSpec
import qualified ConfigSpec
import qualified FxSpec
import qualified PreviewSpec
import qualified TintSpec
import qualified AppSpec
import qualified ViewSpec

main :: IO ()
main =
  defaultMain $
    testGroup
      "wallpaper-tui"
      [ AccentSpec.tests
      , AwwwSpec.tests
      , ConfigSpec.tests
      , FxSpec.tests
      , PreviewSpec.tests
      , TintSpec.tests
      , AppSpec.tests
      , ViewSpec.tests
      ]