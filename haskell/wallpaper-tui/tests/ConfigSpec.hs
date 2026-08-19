-- | Config / State / effective_output merge. Faithful Haskell port of
-- @rust/wallpaper-tui/tests/config.rs@ (round-trip, missing-file defaults,
-- declarative+override merge).
module ConfigSpec (tests) where

import qualified Data.Map.Strict as Map
import System.FilePath ((</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

import WallpaperTui.Config
  ( Config (..)
  , Effective (..)
  , OutputConfig (..)
  , OutputOverride (..)
  , State (..)
  , defaultColor
  , defaultConfig
  , effectiveOutput
  , loadConfigFrom
  , loadStateFrom
  , saveStateTo
  )

import Common (withTmp)

mkConfig :: Map.Map String OutputConfig -> Config
mkConfig outs =
  Config
    { configWallpaperFolder = "/w"
    , configRecursive = True
    , configCurrentOutput = "eDP-1"
    , configTransitionType = "grow"
    , configTransitionDuration = 1.0
    , configOutputs = outs
    , configTintBackend = "pywal"
    }

tests :: TestTree
tests =
  testGroup
    "Config"
    [ testCase "state round trip" $
        withTmp $ \tmp -> do
          let path = tmp </> "state.json"
              outs = Map.fromList
                [ ( "eDP-1"
                  , OutputOverride
                      { ooPath = Just "/w/p.jpg"
                      , ooMode = Just "fit"
                      , ooFillColor = Nothing
                      }
                  )
                ]
              state = State{stateOutputs = outs}
          saveStateTo state path
          loaded <- loadStateFrom path
          assertEqual "round trip" state loaded
    , testCase "missing file defaults" $
        withTmp $ \tmp -> do
          cfg <- loadConfigFrom (tmp </> "nope.json")
          assertBool "wallpaper_folder empty" (null (configWallpaperFolder cfg))
          assertBool "outputs empty" (Map.null (configOutputs cfg))
          st <- loadStateFrom (tmp </> "nope.json")
          assertBool "state outputs empty" (Map.null (stateOutputs st))
    , testCase "effective output merge" $ do
        let outs = Map.fromList
              [ ( "eDP-1"
                , OutputConfig
                    { ocPath = Just "/decl/default.jpg"
                    , ocMode = "fill"
                    , ocFillColor = "#111111"
                    }
                )
              ]
            config = mkConfig outs
            state = State{stateOutputs = Map.empty}
            eff = effectiveOutput config state "eDP-1"
        assertEqual "path" "/decl/default.jpg" (effPath eff)
        assertEqual "mode" "fill" (effMode eff)
        assertEqual "fill_color" "#111111" (effFillColor eff)
    , testCase "effective output override wins and empty falls back" $ do
        let decl = Map.fromList
              [ ( "eDP-1"
                , OutputConfig
                    { ocPath = Just "/decl.jpg"
                    , ocMode = "fit"
                    , ocFillColor = "#222222"
                    }
                )
              ]
            config = defaultConfig{configOutputs = decl}
            over = Map.fromList
              [ ( "eDP-1"
                , OutputOverride
                    { ooPath = Just "/override.jpg"
                    , ooMode = Just "" -- empty → fall back to declarative
                    , ooFillColor = Nothing -- None → fall back to declarative
                    }
                )
              ]
            state = State{stateOutputs = over}
            eff = effectiveOutput config state "eDP-1"
        assertEqual "path" "/override.jpg" (effPath eff)
        assertEqual "mode (override empty → declarative)" "fit" (effMode eff)
        assertEqual "fill (override None → declarative)" "#222222" (effFillColor eff)
    , testCase "effective output missing output uses defaults" $ do
        let config = defaultConfig
            state = State{stateOutputs = Map.empty}
            eff = effectiveOutput config state "HDMI-1"
        assertBool "path empty" (null (effPath eff))
        assertEqual "mode default" "fill" (effMode eff)
        assertEqual "fill default" defaultColor (effFillColor eff)
    , testCase "config ignores garbage" $
        withTmp $ \tmp -> do
          let path = tmp </> "config.json"
          writeFile path "not json at all"
          cfg <- loadConfigFrom path
          assertEqual "garbage → default" defaultConfig cfg
    ]