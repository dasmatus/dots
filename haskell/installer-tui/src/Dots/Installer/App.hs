{-# LANGUAGE BangPatterns #-}
-- | Wizard state machine. Faithful Haskell port of
-- @rust/installer-tui/src/app.rs@.
--
-- 'handleKey' is a pure transition function over 'App' — all screen flow logic
-- lives here so it is unit-testable without a terminal. Mirrors the Rust
-- @handle_key@ exactly.
module Dots.Installer.App
  ( Screen (..)
  , aiOptions
  , App (..)
  , appNew
  , handleKey
  , onInstallEvent
  , onNetEvent
  ) where

import Data.List (intercalate)

import Dots.Installer.Config
  ( InstallConfig (..)
  , validateGitEmail
  , validateGitName
  , validateHostname
  , validateUsername
  )
import Dots.Installer.Disks (Disk (..), espGib, rootGib, gib, requiredGib)
import Dots.Installer.Input (KeyCode (..), KeyEvent (..))
import Dots.Installer.Install (Event (..))
import Dots.Installer.Net (Event (..), Op (..), WifiNetwork (..), wifiIsOpen)

-- | Number of toggles on the 'AiScreen' screen (Claude, Codex, Ollama). Keeps
-- the 'KeyDown' cursor clamp and the 'KeySpace' toggle dispatch in sync with
-- the view. Mirrors @AI_OPTIONS@.
aiOptions :: Int
aiOptions = 3

-- | The wizard screen. Mirrors the Rust @Screen@ enum (17 variants).
data Screen
  = ScreenWelcome
  | ScreenNetwork
  | ScreenWifiPassword
  | ScreenWifiConnecting
  | ScreenDiskSelect
  | ScreenHostname
  | ScreenUsername
  | ScreenGitName
  | ScreenGitEmail
  | ScreenAi
  | ScreenUserPassword
  | ScreenUserPasswordConfirm
  | ScreenConfirm
  | ScreenInstalling
  | ScreenDone
  | ScreenFailed
  deriving (Show, Eq)

-- | The wizard state. Field names mirror the Rust struct fields (prefixed
-- @app@ to avoid clashing with the 'Screen' constructors). The 'IORef'-like
-- fields are plain Haskell records — the whole 'App' lives in a 'Signal' and
-- is updated by 'handleKey' / 'onInstallEvent' / 'onNetEvent'.
data App = App
  { appScreen :: !Screen
  , appConfig :: !InstallConfig
  -- | Disks offered by the manual picker; empty when autodetection succeeded.
  , appDisks :: ![Disk]
  , appSelected :: !Int
  -- | Per-'appDisks' selection mask for the multi-select picker.
  , appPicked :: ![Bool]
  -- | Cursor on the 'ScreenAi' toggle list (0 = Claude, 1 = Codex, 2 = Ollama).
  , appAiSelected :: !Int
  -- | True when 'autodetectDisk' pre-picked the disk → skip 'ScreenDiskSelect'.
  , appDiskAuto :: !Bool
  , appInput :: !String
  , appPendingPassword :: !String
  , appError :: !(Maybe String)
  , appLog :: ![String]
  , appCurrentStep :: !Int
  , appTotalSteps :: !Int
  , appStepTitle :: !String
  , appRecoveryKey :: !(Maybe String)
  , appShouldQuit :: !Bool
  -- | Set when the user finishes the 'ScreenConfirm' screen; the loop spawns
  -- the runner.
  , appStartInstall :: !Bool
  -- | Set on the 'ScreenDone' screen when the user asks to reboot.
  , appReboot :: !Bool
  , appWifiNetworks :: ![WifiNetwork]
  , appWifiSelected :: !Int
  -- | SSID awaiting a passphrase / being connected to.
  , appWifiSsid :: !String
  -- | 'Nothing' until the first connectivity check answers.
  , appOnline :: !(Maybe Bool)
  -- | Worker status shown on the 'ScreenNetwork' screen ("scanning…" / "connecting…").
  , appNetBusy :: !(Maybe String)
  -- | Set by 'handleKey'; the loop takes it and spawns the worker (keeps the
  -- state machine pure).
  , appPendingNetOp :: !(Maybe Op)
  }
  deriving (Show, Eq)

-- | Build the wizard. @auto@ is the path 'autodetectDisk' picked, when it
-- could pick one unambiguously — in that case 'ScreenDiskSelect' is skipped.
-- When @auto@ is 'Nothing', @disks@ is offered via the multi-select picker.
-- Mirrors @App::new@.
appNew :: [Disk] -> Maybe String -> App
appNew disks auto = case auto of
  Just d -> App
    { appScreen = ScreenWelcome
    , appConfig = InstallConfig
        { icDisks = [d]
        , icHostname = ""
        , icUsername = ""
        , icGitName = ""
        , icGitEmail = ""
        , icUserPassword = ""
        , icSwapSizeGib = 0
        , icAiClaude = True
        , icAiCodex = True
        , icAiOllama = True
        }
    , appDisks = disks
    , appSelected = 0
    , appPicked = replicate (length disks) False
    , appAiSelected = 0
    , appDiskAuto = True
    , appInput = ""
    , appPendingPassword = ""
    , appError = Nothing
    , appLog = []
    , appCurrentStep = 0
    , appTotalSteps = 0
    , appStepTitle = ""
    , appRecoveryKey = Nothing
    , appShouldQuit = False
    , appStartInstall = False
    , appReboot = False
    , appWifiNetworks = []
    , appWifiSelected = 0
    , appWifiSsid = ""
    , appOnline = Nothing
    , appNetBusy = Nothing
    , appPendingNetOp = Nothing
    }
  Nothing -> App
    { appScreen = ScreenWelcome
    , appConfig = InstallConfig
        { icDisks = []
        , icHostname = ""
        , icUsername = ""
        , icGitName = ""
        , icGitEmail = ""
        , icUserPassword = ""
        , icSwapSizeGib = 0
        , icAiClaude = True
        , icAiCodex = True
        , icAiOllama = True
        }
    , appDisks = disks
    , appSelected = 0
    , appPicked = replicate (length disks) False
    , appAiSelected = 0
    , appDiskAuto = False
    , appInput = ""
    , appPendingPassword = ""
    , appError = Nothing
    , appLog = []
    , appCurrentStep = 0
    , appTotalSteps = 0
    , appStepTitle = ""
    , appRecoveryKey = Nothing
    , appShouldQuit = False
    , appStartInstall = False
    , appReboot = False
    , appWifiNetworks = []
    , appWifiSelected = 0
    , appWifiSsid = ""
    , appOnline = Nothing
    , appNetBusy = Nothing
    , appPendingNetOp = Nothing
    }

-- | Where the 'ScreenNetwork' screen hands off to: the manual picker when
-- autodetection didn't pre-pick the disk, else straight to 'ScreenHostname'.
-- Mirrors @after_network@.
afterNetwork :: App -> Screen
afterNetwork app
  | appDiskAuto app = ScreenHostname
  | otherwise = ScreenDiskSelect

-- | The pure transition function. All screen flow logic lives here so it is
-- unit-testable without a terminal. Mirrors @handle_key@ exactly.
handleKey :: App -> KeyEvent -> App
handleKey app (KeyEvent code) = case appScreen app of
  ScreenWelcome -> case code of
    KeyEnter -> app
      { appScreen = ScreenNetwork
      , appPendingNetOp = Just Scan
      , appNetBusy = Just "scanning for networks…"
      }
    KeyEsc -> app { appShouldQuit = True }
    KeyChar 'q' -> app { appShouldQuit = True }
    _ -> app

  ScreenNetwork -> case code of
    KeyUp -> app { appWifiSelected = max 0 (appWifiSelected app - 1) }
    KeyDown ->
      if appWifiSelected app + 1 < length (appWifiNetworks app)
        then app { appWifiSelected = appWifiSelected app + 1 }
        else app
    KeyChar 'r' | appNetBusy app == Nothing -> app
      { appError = Nothing
      , appNetBusy = Just "scanning for networks…"
      , appPendingNetOp = Just Scan
      }
    KeyChar 's' -> app
      { appScreen = afterNetwork app
      , appError = Nothing
      }
    KeyEnter | appNetBusy app == Nothing ->
      case atMaybe (appWifiNetworks app) (appWifiSelected app) of
        Just n ->
          let ssid = wnSsid n
          in if wifiIsOpen n
               then app
                 { appWifiSsid = ssid
                 , appError = Nothing
                 , appPendingNetOp = Just (Connect ssid Nothing)
                 , appNetBusy = Just ("connecting to " <> ssid <> "…")
                 , appScreen = ScreenWifiConnecting
                 }
               else app
                 { appWifiSsid = ssid
                 , appError = Nothing
                 , appInput = ""
                 , appScreen = ScreenWifiPassword
                 }
        Nothing -> app { appError = Just "no networks found — r to rescan, s to skip" }
    KeyEsc -> app { appScreen = ScreenWelcome }
    _ -> app

  ScreenWifiPassword -> case code of
    KeyChar c -> app { appInput = appInput app <> [c] }
    KeyBackspace -> app { appInput = popLast (appInput app) }
    KeyEnter ->
      let l = length (appInput app)
      in if l >= 8 && l <= 63
        then
          let pw = appInput app
          in app
            { appInput = ""
            , appPendingNetOp = Just (Connect (appWifiSsid app) (Just pw))
            , appNetBusy = Just ("connecting to " <> appWifiSsid app <> "…")
            , appError = Nothing
            , appScreen = ScreenWifiConnecting
            }
        else app { appError = Just "passphrase must be 8–63 characters" }
    KeyEsc -> app
      { appInput = ""
      , appError = Nothing
      , appScreen = ScreenNetwork
      }
    _ -> app

  ScreenDiskSelect -> case code of
    KeyUp -> app { appSelected = max 0 (appSelected app - 1) }
    KeyDown ->
      if appSelected app + 1 < length (appDisks app)
        then app { appSelected = appSelected app + 1 }
        else app
    KeyChar ' ' ->
      case atMaybe (appPicked app) (appSelected app) of
        Just _ -> app
          { appPicked = toggleAt (appPicked app) (appSelected app)
          , appError = Nothing
          }
        Nothing -> app
    KeyEnter ->
      let chosen = [d | (d, p) <- zip (appDisks app) (appPicked app), p]
      in if null chosen
        then app { appError = Just "select at least one disk (Space to toggle)" }
        else
          let needGib = requiredGib (icSwapSizeGib (appConfig app))
              total = sum (map diskSizeBytes chosen)
          in if total < needGib * gib
               then
                 let paths = intercalate ", " (map diskPath chosen)
                     totalGib = total `div` gib
                 in app
                   { appError = Just ("span too small: need ≥ " <> show needGib
                     <> " GiB across the VG (" <> show espGib <> "G ESP + "
                     <> show (icSwapSizeGib (appConfig app)) <> "G swap + "
                     <> show rootGib <> "G root), " <> paths <> " total "
                     <> show totalGib <> " GiB")
                   }
               else app
                 { appConfig = (appConfig app) { icDisks = map diskPath chosen }
                 , appError = Nothing
                 , appScreen = ScreenHostname
                 }
    KeyEsc -> app { appScreen = ScreenNetwork }
    _ -> app

  ScreenHostname -> case code of
    KeyChar c -> app { appInput = appInput app <> [c] }
    KeyBackspace -> app { appInput = popLast (appInput app) }
    KeyEnter ->
      let candidate = if null (appInput app) then "tokyonight" else appInput app
      in case validateHostname candidate of
        Right () -> app
          { appConfig = (appConfig app) { icHostname = candidate }
          , appInput = ""
          , appError = Nothing
          , appScreen = ScreenUsername
          }
        Left e -> app { appError = Just e }
    _ -> app

  ScreenUsername -> case code of
    KeyChar c -> app { appInput = appInput app <> [c] }
    KeyBackspace -> app { appInput = popLast (appInput app) }
    KeyEnter -> case validateUsername (appInput app) of
      Right () -> app
        { appConfig = (appConfig app) { icUsername = appInput app }
        , appInput = ""
        , appError = Nothing
        , appScreen = ScreenGitName
        }
      Left e -> app { appError = Just e }
    _ -> app

  ScreenGitName -> case code of
    KeyChar c -> app { appInput = appInput app <> [c] }
    KeyBackspace -> app { appInput = popLast (appInput app) }
    KeyEnter -> case validateGitName (appInput app) of
      Right () -> app
        { appConfig = (appConfig app) { icGitName = appInput app }
        , appInput = ""
        , appError = Nothing
        , appScreen = ScreenGitEmail
        }
      Left e -> app { appError = Just e }
    KeyEsc -> app
      { appInput = ""
      , appError = Nothing
      , appScreen = ScreenUsername
      }
    _ -> app

  ScreenGitEmail -> case code of
    KeyChar c -> app { appInput = appInput app <> [c] }
    KeyBackspace -> app { appInput = popLast (appInput app) }
    KeyEnter -> case validateGitEmail (appInput app) of
      Right () -> app
        { appConfig = (appConfig app) { icGitEmail = appInput app }
        , appInput = ""
        , appError = Nothing
        , appScreen = ScreenAi
        }
      Left e -> app { appError = Just e }
    KeyEsc -> app
      { appInput = ""
      , appError = Nothing
      , appScreen = ScreenGitName
      }
    _ -> app

  ScreenAi -> case code of
    KeyUp -> app { appAiSelected = max 0 (appAiSelected app - 1) }
    KeyDown ->
      if appAiSelected app + 1 < aiOptions
        then app { appAiSelected = appAiSelected app + 1 }
        else app
    KeyChar ' ' -> case appAiSelected app of
      0 -> app { appConfig = (appConfig app) { icAiClaude = not (icAiClaude (appConfig app)) }, appError = Nothing }
      1 -> app { appConfig = (appConfig app) { icAiCodex = not (icAiCodex (appConfig app)) }, appError = Nothing }
      _ -> app { appConfig = (appConfig app) { icAiOllama = not (icAiOllama (appConfig app)) }, appError = Nothing }
    KeyEnter -> app { appScreen = ScreenUserPassword }
    KeyEsc -> app { appScreen = ScreenGitEmail }
    _ -> app

  ScreenUserPassword -> case code of
    KeyChar c -> app { appInput = appInput app <> [c] }
    KeyBackspace -> app { appInput = popLast (appInput app) }
    KeyEnter ->
      if null (appInput app)
        then app { appError = Just "password must not be empty" }
        else app
          { appPendingPassword = appInput app
          , appInput = ""
          , appError = Nothing
          , appScreen = ScreenUserPasswordConfirm
          }
    _ -> app

  ScreenUserPasswordConfirm -> case code of
    KeyChar c -> app { appInput = appInput app <> [c] }
    KeyBackspace -> app { appInput = popLast (appInput app) }
    KeyEnter ->
      let confirmed = appInput app
      in if confirmed == appPendingPassword app
        then app
          { appConfig = (appConfig app) { icUserPassword = appPendingPassword app }
          , appPendingPassword = ""
          , appInput = ""
          , appScreen = ScreenConfirm
          , appError = Nothing
          }
        else app
          { appPendingPassword = ""
          , appError = Just "passwords do not match, try again"
          , appScreen = ScreenUserPassword
          }
    _ -> app

  ScreenConfirm -> case code of
    KeyChar c -> app { appInput = appInput app <> [c] }
    KeyBackspace -> app { appInput = popLast (appInput app) }
    KeyEnter ->
      if appInput app == "ERASE"
        then app
          { appInput = ""
          , appError = Nothing
          , appStartInstall = True
          , appScreen = ScreenInstalling
          }
        else app { appError = Just "type ERASE (uppercase) to proceed" }
    KeyEsc -> app
      { appInput = ""
      , appError = Nothing
      , appScreen = afterNetwork app
      }
    _ -> app

  -- No user-cancel mid-install/mid-connect: a half-written disk is worse, and
  -- interrupting nmcli mid-handshake helps nobody.
  ScreenInstalling -> app
  ScreenWifiConnecting -> app

  ScreenDone -> case code of
    KeyEnter -> app { appReboot = True, appShouldQuit = True }
    _ -> app

  ScreenFailed -> case code of
    KeyEnter -> app { appShouldQuit = True }
    KeyEsc -> app { appShouldQuit = True }
    KeyChar 'q' -> app { appShouldQuit = True }
    _ -> app

-- | Apply an install worker event. Mirrors @on_install_event@.
onInstallEvent :: App -> Event -> App
onInstallEvent app ev = case ev of
  StepStarted i total title -> app
    { appCurrentStep = i
    , appTotalSteps = total
    , appLog = appLog app <> ["==> " <> title]
    , appStepTitle = title
    }
  Log line -> app
    { appLog = let l = appLog app <> [line]
               in if length l > 1000 then drop (length l - 1000) l else l
    }
  RecoveryKey k -> app { appRecoveryKey = Just k }
  Finished -> app { appScreen = ScreenDone }
  Failed e -> app
    { appError = Just ("Installation failed: " <> e)
    , appScreen = ScreenFailed
    }

-- | Apply a network worker event. 'ScanDone'/'Connectivity' never change the
-- screen — they may arrive after the user has skipped ahead; only
-- 'ConnectDone' transitions, and only from 'ScreenWifiConnecting'. Mirrors
-- @on_net_event@.
onNetEvent :: App -> Event -> App
onNetEvent app ev = case ev of
  Connectivity online -> app { appOnline = Just online }
  ScanDone (Right nets) -> app
    { appWifiNetworks = nets
    , appWifiSelected = 0
    , appNetBusy = Nothing
    }
  ScanDone (Left e) -> app
    { appNetBusy = Nothing
    , appError = Just ("Wi-Fi scan failed: " <> e)
    }
  ConnectDone (Right ()) -> app
    { appNetBusy = Nothing
    , appOnline = Just True
    , appError = Nothing
    , appScreen = if appScreen app == ScreenWifiConnecting
      then afterNetwork app else appScreen app
    }
  ConnectDone (Left e) -> app
    { appNetBusy = Nothing
    , appError = Just ("connection failed: " <> e)
    , appScreen = if appScreen app == ScreenWifiConnecting
      then ScreenNetwork else appScreen app
    }

-- * Small local helpers

-- | Pop the last character off a string (mirrors Rust @String::pop@).
popLast :: String -> String
popLast s = case reverse s of
  (_ : rest) -> reverse rest
  [] -> []

-- | Index into a list, 'Nothing' if out of range.
atMaybe :: [a] -> Int -> Maybe a
atMaybe xs i
  | i < 0 = Nothing
  | otherwise = case drop i xs of
      (x : _) -> Just x
      [] -> Nothing

-- | Toggle the Bool at index @i@ in a list.
toggleAt :: [Bool] -> Int -> [Bool]
toggleAt xs i = go xs 0
  where
    go [] _ = []
    go (b : rest) n
      | n == i = not b : rest
      | otherwise = b : go rest (n + 1)