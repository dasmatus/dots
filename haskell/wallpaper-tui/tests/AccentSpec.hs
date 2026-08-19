-- | extract_accent — the wallpaper → accent-color extractor. Faithful Haskell
-- port of @rust/wallpaper-tui/tests/accent.rs@. Synthetic flat-color images
-- pin the expected hue; the extractor's remap to a fixed target
-- lightness\/saturation means we assert on *hue* (and that the result is
-- bright, not muddy) rather than exact hexes.
module AccentSpec (tests) where

import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

import WallpaperTui.Accent
  ( TintBackend (Internal)
  , accentShades
  , defaultAccent
  , defaultAccentDark
  , defaultAccentLight
  , extractAccent
  , hexToHls
  , parsePywalColors
  )

import Common (makeImage, makeImageWithPatch, withTmp)

hueOf :: String -> Double
hueOf hexstr = let (h, _, _) = hexToHls hexstr in h

lightOf :: String -> Double
lightOf hexstr = let (_, l, _) = hexToHls hexstr in l

isBrightEnough :: String -> Bool
isBrightEnough hexstr = lightOf hexstr >= 0.45 && lightOf hexstr <= 0.72

tests :: TestTree
tests =
  testGroup
    "Accent"
    [ testCase "solid red yields red hue" $
        withTmp $ \tmp -> do
          let p = tmp </> "red.png"
          makeImage p (220, 30, 30) 64
          let (accent, _, _) = extractAccent p Internal
          let h = hueOf accent
          assertBool ("red wallpaper -> hue " <> show h <> ", expected ~0") (h <= 0.04 || h >= 0.96)
          assertBool ("accent not bright: " <> accent) (isBrightEnough accent)
    , testCase "solid green yields green hue" $
        withTmp $ \tmp -> do
          let p = tmp </> "green.png"
          makeImage p (40, 200, 60) 64
          let (accent, _, _) = extractAccent p Internal
          let h = hueOf accent
          assertBool ("green wallpaper -> hue " <> show h <> ", expected ~0.33") (h > 0.28 && h < 0.38)
    , testCase "solid blue yields blue hue" $
        withTmp $ \tmp -> do
          let p = tmp </> "blue.png"
          makeImage p (60, 120, 230) 64
          let (accent, _, _) = extractAccent p Internal
          let h = hueOf accent
          assertBool ("blue wallpaper -> hue " <> show h <> ", expected ~0.6") (h > 0.55 && h < 0.66)
    , testCase "shades share hue" $
        withTmp $ \tmp -> do
          let p = tmp </> "magenta.png"
          makeImage p (220, 40, 200) 64
          let (accent, dark, light) = extractAccent p Internal
          let (ha, hd, hl) = (hueOf accent, hueOf dark, hueOf light)
          assertBool ("shades should share hue") (maximum [ha, hd, hl] - minimum [ha, hd, hl] < 0.07)
          let (la, ld, ll) = (lightOf accent, lightOf dark, lightOf light)
          assertBool ("dark < accent < light") (ld < la && la < ll)
    , testCase "grayscale falls back to default" $
        withTmp $ \tmp -> do
          let p = tmp </> "gray.png"
          makeImage p (128, 128, 128) 64
          let (accent, dark, light) = extractAccent p Internal
          assertEqual "accent" defaultAccent accent
          assertEqual "dark" defaultAccentDark dark
          assertEqual "light" defaultAccentLight light
    , testCase "near black falls back to default" $
        withTmp $ \tmp -> do
          let p = tmp </> "black.png"
          makeImage p (5, 5, 5) 64
          let (accent, dark, light) = extractAccent p Internal
          assertEqual "accent" defaultAccent accent
          assertEqual "dark" defaultAccentDark dark
          assertEqual "light" defaultAccentLight light
    , testCase "missing path falls back" $ do
        let (accent, dark, light) = extractAccent "/no/such/file.png" Internal
        assertEqual "accent" defaultAccent accent
        assertEqual "dark" defaultAccentDark dark
        assertEqual "light" defaultAccentLight light
    , testCase "dominant vibrant beats small saturated patch" $
        withTmp $ \tmp -> do
          let p = tmp </> "mostly_blue.png"
          makeImageWithPatch p (60, 120, 230) (220, 30, 30)
          let (accent, _, _) = extractAccent p Internal
          let h = hueOf accent
          assertBool ("dominant blue should win, got hue " <> show h <> " (" <> accent <> ")")
            (h > 0.55 && h < 0.66)
    , testCase "accent_shades keeps hue" $ do
        let (accent, dark, light) = accentShades "#ff00aa"
        assertEqual "accent" "#ff00aa" accent
        let (ha, hd, hl) = (hueOf accent, hueOf dark, hueOf light)
        assertBool ("hue shared") (abs (ha - hd) < 0.001 && abs (ha - hl) < 0.001)
        assertBool ("light spans") (lightOf dark < lightOf accent && lightOf accent < lightOf light)
    , testCase "parse_pywal_colors extracts color5 family" $ do
        let json =
              unlines
                [ "{"
                , "  \"special\": {\"background\": \"#1a1b26\", \"foreground\": \"#c0caf5\"},"
                , "  \"colors\": {"
                , "    \"color0\": \"#15161e\", \"color1\": \"#f7768e\", \"color2\": \"#9ece6a\","
                , "    \"color3\": \"#e0af68\", \"color4\": \"#7aa2f7\", \"color5\": \"#bb9af7\","
                , "    \"color6\": \"#7dcfff\", \"color7\": \"#c0caf5\""
                , "  }"
                , "}"
                ]
        case parsePywalColors json of
          Nothing -> assertBool "parse ok" False
          Just (accent, dark, light) -> do
            assertEqual "accent" "#bb9af7" accent
            assertBool "dark != accent" (dark /= accent)
            assertBool "light != accent" (light /= accent)
            assertBool ("light spans") (lightOf dark < lightOf accent && lightOf accent < lightOf light)
    , testCase "parse_pywal_colors rejects malformed" $ do
        assertEqual "not color5" Nothing (parsePywalColors "{\"colors\": {\"color5\": \"nope\"}}")
        assertEqual "not json" Nothing (parsePywalColors "not json")
    ]