module Main (main) where

import AbstractTUI.Base.Color (Rgba (..), rgb, withAlpha)
import AbstractTUI.Gfx.Mosaic (MosaicMode (..), cellPixels)
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit ((@=?), testCase)

main :: IO ()
main = defaultMain $ testGroup "color/geom/mosaic"
  [ testCase "rgba rgb is opaque" $ 255 @=? rgbaAlpha (rgb 1 2 3)
  , testCase "with_alpha sets alpha" $ 128 @=? rgbaAlpha (withAlpha 128 (rgb 1 2 3))
  , testCase "half-block packs 1x2" $ (1, 2) @=? cellPixels HalfBlock
  ]
  where
    rgbaAlpha (Rgba _ _ _ a) = a