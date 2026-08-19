{-# LANGUAGE ScopedTypeVariables #-}
-- | Wi-Fi setup via NetworkManager's @nmcli@ (the live ISO and the installed
-- system both run NetworkManager). Faithful Haskell port of
-- @rust/installer-tui/src/net.rs@. Parsing is pure and unit-tested; 'runOp'
-- executes on a worker thread streaming events back over a 'TChan', mirroring
-- @install::run@.
module Dots.Installer.Net
  ( Event (..)
  , Op (..)
  , WifiNetwork (..)
  , wifiIsOpen
  , signalBars
  , splitTerse
  , parseWifiList
  , parseConnectivity
  , runOp
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (TChan, atomically, writeTChan)
import Control.Exception (try)
import Data.Char (isSpace)
import Data.List (foldl', sortBy)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Word (Word8)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.Process (readProcess, readProcessWithExitCode)

-- | Events the network worker sends to the UI thread. Mirrors Rust @Event@.
data Event
  = Connectivity Bool
  -- ^ Result of @nmcli networking connectivity check@ — 'True' only for @"full"@.
  | ScanDone (Either String [WifiNetwork])
  | ConnectDone (Either String ())
  deriving (Show, Eq)

-- | Operations the UI requests; "Dots.Installer.Run" runs each on a worker
-- thread. Mirrors Rust @Op@.
data Op
  = Scan
  | Connect
      { opSsid :: !String
      , opPassword :: !(Maybe String)
      }
  deriving (Show, Eq)

-- | One visible Wi-Fi network. Mirrors Rust @WifiNetwork@.
data WifiNetwork = WifiNetwork
  { wnSsid :: !String
  , wnSignal :: !Word8
  -- ^ 0–100 as reported by nmcli.
  , wnSecurity :: !String
  -- ^ nmcli SECURITY column; empty or @"--"@ means an open network.
  }
  deriving (Show, Eq)

-- | True iff the network has no security (empty or @"--"@). Mirrors
-- @WifiNetwork::is_open@.
wifiIsOpen :: WifiNetwork -> Bool
wifiIsOpen n = null (wnSecurity n) || wnSecurity n == "--"

-- | The 4-bar signal strength meter. Mirrors @WifiNetwork::signal_bars@ exactly
-- (quartile boundaries 0\/24\/49\/74).
signalBars :: WifiNetwork -> String
signalBars n = case wnSignal n of
  s | s <= 24 -> "▂___"
  s | s <= 49 -> "▂▄__"
  s | s <= 74 -> "▂▄▆_"
  _ -> "▂▄▆█"

-- | Split a line of nmcli terse output on unescaped @:@, treating @\@ as an
-- escape for the next character (so @\:@ is a literal colon and @\\@ a literal
-- backslash inside a field). Mirrors Rust @split_terse@.
splitTerse :: String -> [String]
splitTerse line = go line []
  where
    go [] acc = [reverse acc]
    go (c : rest) acc = case c of
      '\\' -> case rest of
        (next : rest') -> go rest' (next : acc)
        [] -> [reverse acc]
      ':' -> reverse acc : go [] []
      _ -> go rest (c : acc)

-- | Parse the output of @nmcli -t -f SSID,SIGNAL,SECURITY device wifi list
-- --rescan yes@. Hidden networks (empty SSID) and malformed lines are
-- skipped; a network seen on multiple BSSIDs\/bands is deduped, keeping the
-- strongest signal. Sorted by signal descending, ties by SSID ascending.
-- Mirrors @parse_wifi_list@.
parseWifiList :: String -> [WifiNetwork]
parseWifiList terse =
  sortBy cmp (Map.elems bySsid)
  where
    bySsid = foldl' insert Map.empty (lines terse)
    insert m line = case splitTerse line of
      (ssid : signal : security : _) | not (null ssid) ->
        let sig = parseSignal signal
        in Map.insertWith merge ssid (WifiNetwork ssid sig security) m
      _ -> m
    merge new old =
      if wnSignal new > wnSignal old
        then new
        else old
    cmp a b = case compare (wnSignal b) (wnSignal a) of
      EQ -> compare (wnSsid a) (wnSsid b)
      o -> o

-- | Parse a signal string to a 'Word8' (0 on failure, matching Rust's
-- @.parse().unwrap_or(0)@).
parseSignal :: String -> Word8
parseSignal s = case reads (filter (not . isSpace) s) of
  [(n, _)] -> n
  _ -> 0

-- | True iff @nmcli networking connectivity check@ reports @"full"@ — the only
-- state reliable enough for @nixos-install@ to reach the binary cache. Mirrors
-- @parse_connectivity@.
parseConnectivity :: String -> Bool
parseConnectivity s = trim s == "full"

-- | Run one network operation, sending progress\/result events. Never throws;
-- all sends and subprocess failures are absorbed. Mirrors @run_op@.
runOp :: Op -> TChan Event -> IO ()
runOp op tx = do
  dry <- lookupEnv "DOTS_INSTALLER_DRY_RUN"
  case dry of
    Just _ -> runDry op tx
    Nothing -> runReal op tx

-- | Dry-run path: emit canned events so the UI can be exercised without a real
-- NetworkManager. Mirrors @run_dry@ exactly (3 fake networks, 300ms\/500ms).
runDry :: Op -> TChan Event -> IO ()
runDry op tx = case op of
  Scan -> do
    send (Connectivity False)
    threadDelay 300000
    send (ScanDone (Right
      [ WifiNetwork "tokyonight-cafe" 82 "WPA2"
      , WifiNetwork "eduroam" 61 "WPA2 802.1X"
      , WifiNetwork "guest-open" 47 ""
      ]))
  Connect {} -> do
    threadDelay 500000
    send (ConnectDone (Right ()))
  where
    send = atomically . writeTChan tx

-- | Real path: shell out to @nmcli@. Mirrors @run_real@.
runReal :: Op -> TChan Event -> IO ()
runReal op tx = case op of
  Scan -> runScan tx
  Connect ssid pw -> runConnect ssid pw tx

-- | @nmcli networking connectivity check@ → Connectivity, then
-- @nmcli radio wifi on@, then @nmcli -t -f SSID,SIGNAL,SECURITY device wifi
-- list --rescan yes@ → ScanDone. Mirrors @run_scan@.
runScan :: TChan Event -> IO ()
runScan tx = do
  eOut <- try (readProcess "nmcli" ["networking", "connectivity", "check"] "")
  let online = case eOut of
        Right out -> parseConnectivity out
        Left (_ :: IOError) -> False
  send (Connectivity online)
  _ <- try (readProcess "nmcli" ["radio", "wifi", "on"] "") :: IO (Either IOError String)
  res <- try (readProcessWithExitCode "nmcli" argv "")
  case res of
    Left e -> send (ScanDone (Left (show e)))
    Right (code, out, _err) -> case code of
      ExitSuccess -> send (ScanDone (Right (parseWifiList out)))
      _ -> send (ScanDone (Left ("nmcli failed")))
  where
    argv = ["-t", "-f", "SSID,SIGNAL,SECURITY", "device", "wifi", "list", "--rescan", "yes"]
    send = atomically . writeTChan tx

-- | @nmcli device wifi connect <ssid> [password <pw>]@ → ConnectDone.
-- Mirrors @run_connect@.
runConnect :: String -> Maybe String -> TChan Event -> IO ()
runConnect ssid pw tx = do
  let args = ["device", "wifi", "connect", ssid] ++ maybe [] (\p -> ["password", p]) pw
  res <- try (readProcessWithExitCode "nmcli" args "")
  case res of
    Left e -> send (ConnectDone (Left (show e)))
    Right (code, _out, err) -> case code of
      ExitSuccess -> send (ConnectDone (Right ()))
      _ -> send (ConnectDone (Left (commandError code err)))
  where
    send = atomically . writeTChan tx

-- | Trimmed stderr, falling back to the exit status when stderr is empty.
-- Mirrors @command_error@.
commandError :: ExitCode -> String -> String
commandError code err =
  let e = trim err
  in if null e then "nmcli exited with " ++ showCode code else e
  where
    showCode ExitSuccess = "0"
    showCode (ExitFailure n) = show n

-- | Strip leading/trailing whitespace.
trim :: String -> String
trim = f . f where f = reverse . dropWhile isSpace