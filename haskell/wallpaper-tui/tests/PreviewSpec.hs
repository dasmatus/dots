-- | Preview decode + the wallpaper thumbnail cache. Faithful Haskell port of
-- @rust/wallpaper-tui/tests/preview.rs@. The half-block cell tests from the
-- Python era are gone (preview rendering is the TUI's job); we assert on the
-- decoded 'JP.DynamicImage' dimensions and the @cache_previews@ mtime-skip +
-- atomic-write behaviour.
module PreviewSpec (tests) where

import qualified Codec.Picture as JP
import System.Directory (createDirectoryIfMissing, listDirectory)
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

import WallpaperTui.Preview
  ( CacheStats (..)
  , cachePreviews
  , loadPreview
  )

import Common (makeImage, withTmp)

-- | Width of a decoded 'JP.DynamicImage' (the @image::DynamicImage::width@
-- equivalent — 'JP.dynamicMap' unwraps the concrete pixel type).
imgWidth :: JP.DynamicImage -> Int
imgWidth = JP.dynamicMap JP.imageWidth

imgHeight :: JP.DynamicImage -> Int
imgHeight = JP.dynamicMap JP.imageHeight

tests :: TestTree
tests =
  testGroup
    "Preview"
    [ testCase "load_preview decodes image" $
        withTmp $ \tmp -> do
          let p = tmp </> "wp.png"
          makeImage p (60, 120, 230) 64
          e <- loadPreview p
          case e of
            Left err -> assertEqual "decode ok" "" err
            Right img -> do
              assertEqual "width" 64 (imgWidth img)
              assertEqual "height" 64 (imgHeight img)
    , testCase "load_preview missing image is error" $ do
        e <- loadPreview "/no/such/image.png"
        assertBool "expected Left" (either (const True) (const False) e)
    , testCase "cache_previews writes thumbnails" $
        withTmp $ \tmp -> do
          let folder = tmp </> "walls"
              out = tmp </> "thumbs"
          createDirectoryIfMissing True folder
          makeImage (folder </> "a.png") (10, 20, 30) 64
          makeImage (folder </> "b.png") (40, 50, 60) 64
          stats <- cachePreviews folder True out (32, 32)
          assertEqual "written" 2 (csWritten stats)
          pngs <- listDirectory out
          assertEqual "png count" 2 (length pngs)
    , testCase "cache_previews skips unchanged" $
        withTmp $ \tmp -> do
          let folder = tmp </> "walls"
              out = tmp </> "thumbs"
          createDirectoryIfMissing True folder
          makeImage (folder </> "a.png") (10, 20, 30) 64
          _ <- cachePreviews folder True out (32, 32)
          stats <- cachePreviews folder True out (32, 32)
          assertEqual "written 0" 0 (csWritten stats)
          assertEqual "skipped 1" 1 (csSkipped stats)
    , testCase "cache_previews nonexistent folder" $
        withTmp $ \tmp -> do
          let out = tmp </> "thumbs"
          stats <- cachePreviews (tmp </> "nope") True out (32, 32)
          assertEqual "written 0" 0 (csWritten stats)
    ]