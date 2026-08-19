-- | Wizard state-machine tests (screen flow, validation, install/net events).
-- Faithful Haskell port of @rust/installer-tui/tests/app.rs@.
module AppSpec (tests) where

import Data.Maybe (isJust, isNothing)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

import Dots.Installer.App
  ( App (..)
  , Screen (..)
  , aiOptions
  , appNew
  , handleKey
  , onInstallEvent
  , onNetEvent
  )
import Dots.Installer.Config (InstallConfig (..))
import Dots.Installer.Disks (Disk (..), gib)
import Dots.Installer.Input (KeyCode (..), KeyEvent (..))
import Dots.Installer.Install (Event (..))
import Dots.Installer.Net (Event (..), Op (..), WifiNetwork (..))

key :: KeyCode -> KeyEvent
key = KeyEvent

-- | An app with autodetection assumed (the common path): no picker shown.
app :: App
app = appNew [] (Just "/dev/nvme0n1")

-- | An app where autodetection failed → manual DiskSelect flow is reachable.
appNoAuto :: App
appNoAuto =
  appNew
    [ Disk "/dev/vda" (64 * gib) "VMware" False
    , Disk "/dev/vdb" (32 * gib) "USB SSD" True
    ]
    Nothing

-- | An App parked on the Network screen with a canned two-network list.
appOnNetworkScreen :: App
appOnNetworkScreen =
  app
    { appScreen = ScreenNetwork
    , appWifiNetworks =
        [ WifiNetwork "secured-net" 80 "WPA2"
        , WifiNetwork "open-net" 60 ""
        ]
    }

typeStr :: App -> String -> App
typeStr a s = foldl (\acc c -> handleKey acc (key (KeyChar c))) a s

-- | A helper to set a field then run a key. Mirrors the Rust @mut app; app.x =
-- ..; app.handle_key(..)@ pattern.
setScreen :: Screen -> App -> App
setScreen s a = a{appScreen = s}

tests :: TestTree
tests =
  testGroup
    "App"
    [ testGroup "welcome + network"
        [ testCase "welcome enter opens network screen and requests scan" $ do
            let a1 = handleKey app (key KeyEnter)
            assertEqual "screen" ScreenNetwork (appScreen a1)
            assertEqual "pending op" (Just Scan) (appPendingNetOp a1)
            assertBool "busy set" (isJust (appNetBusy a1))
        , testCase "welcome esc quits" $ do
            let a1 = handleKey app (key KeyEsc)
            assertBool "should_quit" (appShouldQuit a1)
        , testCase "network skip advances to hostname" $ do
            let a1 = handleKey appOnNetworkScreen (key (KeyChar 's'))
            assertEqual "screen" ScreenHostname (appScreen a1)
        , testCase "network esc returns to welcome" $ do
            let a1 = handleKey appOnNetworkScreen (key KeyEsc)
            assertEqual "screen" ScreenWelcome (appScreen a1)
        , testCase "scan results populate list and clear busy" $ do
            let a0 = app{appScreen = ScreenNetwork, appNetBusy = Just "scanning for networks…"}
                a1 = onNetEvent a0 (ScanDone (Right [WifiNetwork "one" 50 "WPA2", WifiNetwork "two" 30 ""]))
            assertEqual "count" 2 (length (appWifiNetworks a1))
            assertEqual "selected" 0 (appWifiSelected a1)
            assertBool "busy cleared" (isNothing (appNetBusy a1))
        , testCase "scan failure surfaces error" $ do
            let a0 = app{appScreen = ScreenNetwork, appNetBusy = Just "scanning for networks…"}
                a1 = onNetEvent a0 (ScanDone (Left "nmcli not found"))
            assertBool "busy cleared" (isNothing (appNetBusy a1))
            assertBool "error contains msg" (maybe False (elem "nmcli not found" . words) (appError a1))
            assertEqual "screen stays" ScreenNetwork (appScreen a1)
        , testCase "selecting secured network prompts for passphrase" $ do
            let a1 = handleKey appOnNetworkScreen (key KeyEnter)
            assertEqual "screen" ScreenWifiPassword (appScreen a1)
            assertEqual "ssid" "secured-net" (appWifiSsid a1)
            assertEqual "no pending op" Nothing (appPendingNetOp a1)
        , testCase "selecting open network connects immediately" $ do
            let a0 = appOnNetworkScreen{appWifiSelected = 1}
                a1 = handleKey a0 (key KeyEnter)
            assertEqual "screen" ScreenWifiConnecting (appScreen a1)
            assertEqual "pending op" (Just (Connect "open-net" Nothing)) (appPendingNetOp a1)
        , testCase "enter during scan is ignored" $ do
            let a0 = appOnNetworkScreen{appNetBusy = Just "scanning for networks…"}
                a1 = handleKey a0 (key KeyEnter)
            assertEqual "screen" ScreenNetwork (appScreen a1)
            assertEqual "no pending op" Nothing (appPendingNetOp a1)
        ]
    , testGroup "wifi password"
        [ testCase "passphrase length enforced" $ do
            let a0 = appOnNetworkScreen{appWifiSsid = "secured-net", appScreen = ScreenWifiPassword}
                a1 = typeStr a0 "short"
                a2 = handleKey a1 (key KeyEnter)
            assertEqual "stays" ScreenWifiPassword (appScreen a2)
            assertBool "error set" (isJust (appError a2))
            let a3 = handleKey (a2{appInput = "", appError = Nothing}) (key (KeyChar 'a')) -- start fresh
                a4 = typeStr a3 (replicate 64 'a')
                a5 = handleKey a4 (key KeyEnter)
            assertEqual "stays on too long" ScreenWifiPassword (appScreen a5)
            assertBool "error set on too long" (isJust (appError a5))
        , testCase "passphrase enter starts connection" $ do
            let a0 = appOnNetworkScreen{appWifiSsid = "secured-net", appScreen = ScreenWifiPassword}
                a1 = typeStr a0 "hunter222"
                a2 = handleKey a1 (key KeyEnter)
            assertEqual "screen" ScreenWifiConnecting (appScreen a2)
            assertEqual "pending op" (Just (Connect "secured-net" (Just "hunter222"))) (appPendingNetOp a2)
            assertBool "input cleared" (null (appInput a2))
        , testCase "wifi password esc backs out to network" $ do
            let a0 = appOnNetworkScreen{appScreen = ScreenWifiPassword}
                a1 = typeStr a0 "partial"
                a2 = handleKey a1 (key KeyEsc)
            assertEqual "screen" ScreenNetwork (appScreen a2)
            assertBool "input cleared" (null (appInput a2))
        , testCase "connect success advances to hostname" $ do
            let a0 = app{appScreen = ScreenWifiConnecting}
                a1 = onNetEvent a0 (ConnectDone (Right ()))
            assertEqual "screen" ScreenHostname (appScreen a1)
            assertEqual "online" (Just True) (appOnline a1)
        , testCase "connect failure returns to network with error" $ do
            let a0 = app{appScreen = ScreenWifiConnecting}
                a1 = onNetEvent a0 (ConnectDone (Left "bad passphrase"))
            assertEqual "screen" ScreenNetwork (appScreen a1)
            assertBool "error contains msg" (maybe False (elem "bad passphrase" . words) (appError a1))
        , testCase "late scan event never changes screen" $ do
            let a0 = app{appScreen = ScreenHostname}
                a1 = onNetEvent a0 (ScanDone (Right [WifiNetwork "late" 10 ""]))
            assertEqual "screen stays" ScreenHostname (appScreen a1)
        , testCase "wifi connecting ignores keys" $ do
            let a0 = app{appScreen = ScreenWifiConnecting}
                a1 = handleKey (handleKey a0 (key KeyEsc)) (key KeyEnter)
            assertEqual "screen stays" ScreenWifiConnecting (appScreen a1)
        , testCase "connectivity event sets online flag" $ do
            let a1 = onNetEvent app (Connectivity True)
            assertEqual "online" (Just True) (appOnline a1)
            let a2 = onNetEvent a1 (Connectivity False)
            assertEqual "offline" (Just False) (appOnline a2)
        ]
    , testGroup "disks"
        [ testCase "app stores autodetected disks" $ do
            assertEqual "disks" ["/dev/nvme0n1"] (icDisks (appConfig app))
        , testCase "no_auto disk starts unpicked with picker reachable" $ do
            let a = appNoAuto
            assertBool "not auto" (not (appDiskAuto a))
            assertBool "empty config disks" (null (icDisks (appConfig a)))
            assertEqual "disk count" 2 (length (appDisks a))
            assertBool "all unpicked" (all not (appPicked a))
        , testCase "network skip opens disk select when not autodetected" $ do
            let a1 = handleKey (setScreen ScreenNetwork appNoAuto) (key (KeyChar 's'))
            assertEqual "screen" ScreenDiskSelect (appScreen a1)
        , testCase "disk select space toggles membership" $ do
            let a0 = setScreen ScreenDiskSelect appNoAuto
                a1 = handleKey a0 (key (KeyChar ' '))
                a2 = handleKey a1 (key (KeyChar ' '))
            assertBool "toggled on" (appPicked a1 !! 0)
            assertBool "toggled off" (not (appPicked a2 !! 0))
        , testCase "disk select enter requires at least one picked" $ do
            let a0 = setScreen ScreenDiskSelect appNoAuto
                a1 = handleKey a0 (key KeyEnter)
            assertBool "no disks" (null (icDisks (appConfig a1)))
            assertEqual "stays" ScreenDiskSelect (appScreen a1)
            assertBool "error mentions at least one disk" (maybe False (isInfix "at least one disk") (appError a1))
        , testCase "disk select confirm picks large enough disk" $ do
            let a0 = setScreen ScreenDiskSelect appNoAuto
                a1 = handleKey (handleKey a0 (key (KeyChar ' '))) (key KeyEnter)
            assertEqual "disks" ["/dev/vda"] (icDisks (appConfig a1))
            assertEqual "screen" ScreenHostname (appScreen a1)
            assertBool "no error" (isNothing (appError a1))
        , testCase "disk select spans multiple disks" $ do
            let a0 = setScreen ScreenDiskSelect appNoAuto
                a1 = handleKey (handleKey a0 (key (KeyChar ' '))) (key KeyDown)
                a2 = handleKey (handleKey a1 (key (KeyChar ' '))) (key KeyEnter)
            assertEqual "disks" ["/dev/vda", "/dev/vdb"] (icDisks (appConfig a2))
            assertEqual "screen" ScreenHostname (appScreen a2)
        , testCase "disk select rejects span below capacity" $ do
            let a0 = (setScreen ScreenDiskSelect appNoAuto){appSelected = 1, appConfig = (appConfig appNoAuto){icSwapSizeGib = 16}}
                a1 = handleKey (handleKey a0 (key (KeyChar ' '))) (key KeyEnter)
            assertBool "no disks" (null (icDisks (appConfig a1)))
            assertEqual "stays" ScreenDiskSelect (appScreen a1)
            assertBool "span too small" (maybe False (isInfix "span too small") (appError a1))
        , testCase "disk select esc returns to network" $ do
            let a1 = handleKey (setScreen ScreenDiskSelect appNoAuto) (key KeyEsc)
            assertEqual "screen" ScreenNetwork (appScreen a1)
        , testCase "wifi connect success opens disk select when not autodetected" $ do
            let a0 = appNoAuto{appScreen = ScreenWifiConnecting}
                a1 = onNetEvent a0 (ConnectDone (Right ()))
            assertEqual "screen" ScreenDiskSelect (appScreen a1)
        ]
    , testGroup "hostname + username + git"
        [ testCase "hostname empty uses default" $ do
            let a1 = handleKey (setScreen ScreenHostname app) (key KeyEnter)
            assertEqual "hostname" "tokyonight" (icHostname (appConfig a1))
            assertEqual "screen" ScreenUsername (appScreen a1)
        , testCase "hostname rejects invalid and stays" $ do
            let a1 = handleKey (typeStr (setScreen ScreenHostname app) "Bad_Host!") (key KeyEnter)
            assertEqual "stays" ScreenHostname (appScreen a1)
            assertBool "error set" (isJust (appError a1))
        , testCase "username is required" $ do
            let a1 = handleKey (setScreen ScreenUsername app) (key KeyEnter)
            assertEqual "stays" ScreenUsername (appScreen a1)
            assertBool "error set" (isJust (appError a1))
        , testCase "username advances to git name" $ do
            let a1 = handleKey (typeStr (setScreen ScreenUsername app) "alice") (key KeyEnter)
            assertEqual "username" "alice" (icUsername (appConfig a1))
            assertEqual "screen" ScreenGitName (appScreen a1)
        , testCase "git name required and advances on valid" $ do
            let a0 = setScreen ScreenGitName app
                a1 = handleKey a0 (key KeyEnter)
            assertEqual "stays" ScreenGitName (appScreen a1)
            assertBool "error set" (isJust (appError a1))
            let a2 = handleKey (typeStr a0 "Alice Q") (key KeyEnter)
            assertEqual "git name" "Alice Q" (icGitName (appConfig a2))
            assertEqual "screen" ScreenGitEmail (appScreen a2)
            assertBool "no error" (isNothing (appError a2))
        , testCase "git name esc backs out to username" $ do
            let a1 = handleKey (typeStr (setScreen ScreenGitName app) "partial") (key KeyEsc)
            assertEqual "screen" ScreenUsername (appScreen a1)
            assertBool "input cleared" (null (appInput a1))
        , testCase "git email required and advances on valid" $ do
            let a0 = setScreen ScreenGitEmail app
                a1 = handleKey a0 (key KeyEnter)
            assertEqual "stays empty" ScreenGitEmail (appScreen a1)
            assertBool "error set" (isJust (appError a1))
            let a2 = handleKey (typeStr a0 "not-an-email") (key KeyEnter)
            assertEqual "stays invalid" ScreenGitEmail (appScreen a2)
            assertBool "error set" (isJust (appError a2))
            let a3 = handleKey (typeStr a0 "alice@example.org") (key KeyEnter)
            assertEqual "git email" "alice@example.org" (icGitEmail (appConfig a3))
            assertEqual "screen" ScreenAi (appScreen a3)
            assertBool "no error" (isNothing (appError a3))
        , testCase "git email esc backs out to git name" $ do
            let a1 = handleKey (typeStr (setScreen ScreenGitEmail app) "partial") (key KeyEsc)
            assertEqual "screen" ScreenGitName (appScreen a1)
            assertBool "input cleared" (null (appInput a1))
        ]
    , testGroup "ai"
        [ testCase "ai defaults to all enabled" $ do
            let cfg = appConfig app
            assertBool "claude" (icAiClaude cfg)
            assertBool "codex" (icAiCodex cfg)
            assertBool "ollama" (icAiOllama cfg)
            assertEqual "selected" 0 (appAiSelected app)
        , testCase "ai space toggles each option" $ do
            let a0 = setScreen ScreenAi app
                a1 = handleKey a0 (key (KeyChar ' '))
            assertBool "claude off" (not (icAiClaude (appConfig a1)))
            let a2 = handleKey (handleKey a1 (key KeyDown)) (key (KeyChar ' '))
            assertBool "codex off" (not (icAiCodex (appConfig a2)))
            let a3 = handleKey (handleKey a2 (key KeyDown)) (key (KeyChar ' '))
            assertBool "ollama off" (not (icAiOllama (appConfig a3)))
            let a4 = handleKey a3 (key (KeyChar ' '))
            assertBool "ollama back on" (icAiOllama (appConfig a4))
        , testCase "ai cursor clamps at bottom" $ do
            let a1 = foldl (\a _ -> handleKey a (key KeyDown)) (setScreen ScreenAi app) [0 :: Int .. 4]
            assertEqual "clamped" (aiOptions - 1) (appAiSelected a1)
        , testCase "ai cursor up clamps at top" $ do
            let a1 = handleKey (setScreen ScreenAi app) (key KeyUp)
            assertEqual "clamped" 0 (appAiSelected a1)
        , testCase "ai enter advances to user password" $ do
            let a1 = handleKey (setScreen ScreenAi app) (key KeyEnter)
            assertEqual "screen" ScreenUserPassword (appScreen a1)
        , testCase "ai esc backs out to git email" $ do
            let a1 = handleKey (setScreen ScreenAi app) (key KeyEsc)
            assertEqual "screen" ScreenGitEmail (appScreen a1)
        ]
    , testGroup "passwords + confirm"
        [ testCase "password mismatch restarts entry with error" $ do
            let a0 = setScreen ScreenUserPassword app
                a1 = handleKey (typeStr a0 "hunter2") (key KeyEnter)
            assertEqual "confirm" ScreenUserPasswordConfirm (appScreen a1)
            let a2 = handleKey (typeStr a1 "different") (key KeyEnter)
            assertEqual "back to pw" ScreenUserPassword (appScreen a2)
            assertBool "error set" (isJust (appError a2))
            assertBool "pw empty" (null (icUserPassword (appConfig a2)))
        , testCase "matching passwords advance" $ do
            let a0 = setScreen ScreenUserPassword app
                a1 = handleKey (typeStr a0 "hunter2") (key KeyEnter)
                a2 = handleKey (typeStr a1 "hunter2") (key KeyEnter)
            assertEqual "pw" "hunter2" (icUserPassword (appConfig a2))
            assertEqual "screen" ScreenConfirm (appScreen a2)
        , testCase "empty password rejected" $ do
            let a1 = handleKey (setScreen ScreenUserPassword app) (key KeyEnter)
            assertEqual "stays" ScreenUserPassword (appScreen a1)
            assertBool "error set" (isJust (appError a1))
        , testCase "confirm requires exact erase" $ do
            let a0 = setScreen ScreenConfirm app
                a1 = handleKey (typeStr a0 "erase") (key KeyEnter)
            assertEqual "lowercase rejected" ScreenConfirm (appScreen a1)
            assertBool "no start" (not (appStartInstall a1))
            let a2 = handleKey (typeStr a0 "ERASE") (key KeyEnter)
            assertEqual "screen" ScreenInstalling (appScreen a2)
            assertBool "start" (appStartInstall a2)
        , testCase "confirm esc backs out to hostname" $ do
            let a1 = handleKey (setScreen ScreenConfirm app) (key KeyEsc)
            assertEqual "screen" ScreenHostname (appScreen a1)
        ]
    , testGroup "install + done + failed"
        [ testCase "installing ignores keys" $ do
            let a1 = handleKey (handleKey (setScreen ScreenInstalling app) (key KeyEsc)) (key KeyEnter)
            assertEqual "stays" ScreenInstalling (appScreen a1)
            assertBool "no quit" (not (appShouldQuit a1))
        , testCase "install events drive progress and completion" $ do
            let a0 = setScreen ScreenInstalling app
                a1 = onInstallEvent a0 (StepStarted 2 6 "disko")
            assertEqual "step" 2 (appCurrentStep a1)
            assertEqual "total" 6 (appTotalSteps a1)
            let a2 = onInstallEvent a1 (Log "formatting")
            assertEqual "log last" "formatting" (last (appLog a2))
            let a3 = onInstallEvent a2 (RecoveryKey "abc-def")
            assertEqual "recovery" (Just "abc-def") (appRecoveryKey a3)
            let a4 = onInstallEvent a3 Finished
            assertEqual "screen" ScreenDone (appScreen a4)
        , testCase "install failure shows failed screen" $ do
            let a1 = onInstallEvent (setScreen ScreenInstalling app) (Failed "boom")
            assertEqual "screen" ScreenFailed (appScreen a1)
            assertBool "error contains boom" (maybe False (isInfix "boom") (appError a1))
        , testCase "done enter requests reboot" $ do
            let a1 = handleKey (setScreen ScreenDone app) (key KeyEnter)
            assertBool "reboot" (appReboot a1)
            assertBool "should_quit" (appShouldQuit a1)
        ]
    ]

-- | Local 'isInfixOf' (avoids the Data.List import elsewhere).
isInfix :: String -> String -> Bool
isInfix needle hay = go hay
  where
    go s@(c : rest)
      | needle `isPrefixOfS` s = True
      | otherwise = go rest
    go [] = needle == []
    isPrefixOfS [] _ = True
    isPrefixOfS (n : ns) (h : hs) = n == h && isPrefixOfS ns hs
    isPrefixOfS (_ : _) [] = False