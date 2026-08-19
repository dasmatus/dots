-- | nmcli output parsing + Wi-Fi op contract tests. Faithful Haskell port of
-- @rust/installer-tui/tests/net.rs@.
module NetSpec (tests) where

import Control.Concurrent.STM
  ( TChan
  , atomically
  , newTChanIO
  , tryReadTChan
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

import Dots.Installer.Net
  ( Event (..)
  , Op (..)
  , WifiNetwork (..)
  , parseConnectivity
  , parseWifiList
  , runOp
  , signalBars
  , wifiIsOpen
  )

import Common (withEnv)

-- | Non-blockingly drain every queued value from a 'TChan', in arrival order.
drainTChan :: TChan a -> IO [a]
drainTChan chan = atomically go
  where
    go = do
      m <- tryReadTChan chan
      case m of
        Just x -> (x :) <$> go
        Nothing -> pure []

tests :: TestTree
tests =
  testGroup
    "Net"
    [ testCase "parse_wifi_list sorts by signal desc, ties by ssid asc" $ do
        let terse = "b-net:40:WPA2\na-net:70:WPA2\nc-net:70:WPA2\n"
        assertEqual "order"
          [ WifiNetwork "a-net" 70 "WPA2"
          , WifiNetwork "c-net" 70 "WPA2"
          , WifiNetwork "b-net" 40 "WPA2"
          ]
          (parseWifiList terse)
    , testCase "parse_wifi_list handles escaped colon in ssid" $ do
        let nets = parseWifiList "home\\:net:72:WPA2\n"
        assertEqual "ssid" [WifiNetwork "home:net" 72 "WPA2"] nets
    , testCase "parse_wifi_list handles escaped backslash in ssid" $ do
        let nets = parseWifiList "foo\\\\bar:50:WPA2\n"
        assertEqual "ssid" [WifiNetwork "foo\\bar" 50 "WPA2"] nets
    , testCase "parse_wifi_list skips hidden and dedupes by strongest" $ do
        let terse = ":90:WPA2\nmulti-ap:35:WPA2\nmulti-ap:68:WPA2\n"
            nets = parseWifiList terse
        assertEqual "count" 1 (length nets)
        assertEqual "ssid" "multi-ap" (wnSsid (nets !! 0))
        assertEqual "signal" 68 (wnSignal (nets !! 0))
    , testCase "parse_wifi_list ignores malformed and defaults bad signal to 0" $ do
        let terse = "too:few\ntoo:many:fields:here\ngood-net:not-a-number:WPA2\n"
        assertEqual "nets"
          [WifiNetwork "good-net" 0 "WPA2"]
          (parseWifiList terse)
    , testCase "parse_connectivity only full is online" $ do
        assertBool "full" (parseConnectivity "full\n")
        assertBool "limited" (not (parseConnectivity "limited"))
        assertBool "none" (not (parseConnectivity "none"))
        assertBool "portal" (not (parseConnectivity "portal"))
        assertBool "empty" (not (parseConnectivity ""))
    , testCase "is_open recognizes empty and dashes" $ do
        let open = WifiNetwork "a" 50 ""
            dashes = WifiNetwork "b" 50 "--"
            secured = WifiNetwork "c" 50 "WPA2"
        assertBool "open" (wifiIsOpen open)
        assertBool "dashes" (wifiIsOpen dashes)
        assertBool "secured" (not (wifiIsOpen secured))
    , testCase "signal_bars quartile boundaries" $ do
        let bars signal = signalBars (WifiNetwork "x" signal "")
        assertEqual "0" "▂___" (bars 0)
        assertEqual "24" "▂___" (bars 24)
        assertEqual "25" "▂▄__" (bars 25)
        assertEqual "49" "▂▄__" (bars 49)
        assertEqual "50" "▂▄▆_" (bars 50)
        assertEqual "74" "▂▄▆_" (bars 74)
        assertEqual "75" "▂▄▆█" (bars 75)
        assertEqual "100" "▂▄▆█" (bars 100)
    -- Scan and Connect are exercised in ONE test: DOTS_INSTALLER_DRY_RUN is
    -- process-global env state and tasty runs tests in parallel, so a second
    -- test setting/clearing the same var would race this one.
    , testCase "dry_run contract for scan and connect" $
        withEnv "DOTS_INSTALLER_DRY_RUN" (Just "1") $ do
          chan <- newTChanIO :: IO (TChan Event)
          runOp Scan chan
          evts <- drainTChan chan
          assertEqual "scan events" 2 (length evts)
          assertEqual "connectivity" (Connectivity False) (evts !! 0)
          case evts !! 1 of
            ScanDone (Right nets) -> assertEqual "nets" 3 (length nets)
            other -> error ("expected ScanDone(Ok(_)), got " <> show other)
          chan2 <- newTChanIO :: IO (TChan Event)
          runOp (Connect "tokyonight-cafe" (Just "hunter22")) chan2
          evts2 <- drainTChan chan2
          assertEqual "connect events" [ConnectDone (Right ())] evts2
    ]