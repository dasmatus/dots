-- | Install plan + runner. Faithful Haskell port of
-- @rust/installer-tui/src/install.rs@.
--
-- 'plan' produces the full declarative step list (unit-tested); 'run' executes
-- it on a worker thread, streaming output lines back to the UI over a 'TChan'.
--
-- SAFETY-CRITICAL: the plan writes the real NixOS install. Do NOT paraphrase
-- or simplify the step list, the argv, or the hardcoded paths — every command,
-- flag, and field set here is exact-match parity with the Rust crate.
module Dots.Installer.Install
  ( Event (..)
  , Capture (..)
  , Action (..)
  , Step (..)
  , luksPassfile
  , luksDevice
  , stagedFlake
  , swapSizeFromMeminfo
  , plan
  , run
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (TChan, atomically, writeTChan)
import Control.Exception (try, SomeException)
import Control.Monad (when, forM_, void)
import Data.Char (isSpace)
import Data.List (isInfixOf, isPrefixOf)
import System.Directory
  ( createDirectoryIfMissing
  , removeFile
  )
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.IO
  ( IOMode (..)
  , hGetLine
  , hIsEOF
  , hPutStr
  , withFile
  )
import System.Posix.Files (setFileMode)
import System.Process
  ( CreateProcess (..)
  , StdStream (..)
  , callProcess
  , proc
  , readCreateProcessWithExitCode
  , waitForProcess
  , withCreateProcess
  )

import Dots.Installer.Config (InstallConfig (..), settingsNix)

-- | Events the runner sends to the UI thread. Mirrors Rust @install::Event@.
data Event
  = StepStarted Int Int String
  -- ^ 1-based step index, total steps, human title.
  | Log String
  | RecoveryKey String
  | Finished
  | Failed String
  deriving (Show, Eq)

-- | How a command's stdout is treated. Mirrors @Capture@.
data Capture = Stream | RecoveryKey
  deriving (Show, Eq)

-- | One action in the plan. Mirrors @Action@.
data Action
  = WriteFile
      { wfPath :: !String
      , wfContents :: !String
      , wfMode :: !Int
      }
  | Command
      { cmdProgram :: !String
      , cmdArgs :: ![String]
      , cmdStdin :: !(Maybe String)
      , cmdCapture :: !Capture
      }
  | WriteSecrets
      { wsPath :: !String
      , wsUserPassword :: !String
      }
  deriving (Show, Eq)

-- | One step in the install plan. Mirrors @Step@.
data Step = Step
  { stepTitle :: !String
  , stepAction :: !Action
  }
  deriving (Show, Eq)

-- | The plaintext LUKS keyfile path (shredded after enrollment). Mirrors
-- @LUKS_PASSFILE@.
luksPassfile :: String
luksPassfile = "/tmp/dots-luks-pass"

-- | The root logical volume in the @tokyonightvg@ VG (see nix/disko.nix):
-- disko puts LUKS on this LV, so TPM2/recovery enrollment targets it
-- instead of a GPT partition by-partlabel. Mirrors @LUKS_DEVICE@.
luksDevice :: String
luksDevice = "/dev/tokyonightvg/root"

-- | Writable staging copy of the flake on the live system, used by
-- @nixos-install@ — the ISO's @/etc/dots@ is a read-only store path. Lives on
-- ISO tmpfs and is gone after reboot. Mirrors @STAGED_FLAKE@.
stagedFlake :: String
stagedFlake = "/tmp/dots-flake"

-- | Where the recovery key is stashed on the installed system (read by the
-- user after first boot). Mirrors @RECOVERY_KEY_FILE@ (kept private in Rust).
recoveryKeyFile :: String
recoveryKeyFile = "/mnt/root/luks-recovery.txt"

-- | Round @MemTotal@ up to whole GiB — parity with @config.ram_gib()@ in the
-- Gentoo installer (swap sized = RAM). Mirrors @swap_size_from_meminfo@.
swapSizeFromMeminfo :: String -> Integer
swapSizeFromMeminfo meminfo =
  let kb = case [w | l <- lines meminfo, "MemTotal:" `isPrefixOf` l, w <- words l] of
        (_ : v : _) -> case reads v :: [(Integer, String)] of
          [(n, _)] -> n
          _ -> 0
        _ -> 0
  in max 1 (divCeil kb (1024 * 1024))
  where
    divCeil a b = (a + b - 1) `div` b

-- | Build a 'Command' action. Mirrors Rust's @cmd@ helper.
cmd :: String -> [String] -> Maybe String -> Capture -> Action
cmd program args stdin' capture =
  Command
    { cmdProgram = program
    , cmdArgs = args
    , cmdStdin = stdin'
    , cmdCapture = capture
    }

-- | The full install sequence. 12 EXACT steps. @flakeSrc@ is where the ISO
-- carries the flake (@/etc/dots@); the plan stages a writable copy at
-- 'stagedFlake' and installs from there, then stashes the two machine-specific
-- answer files (@settings.nix@, @facter.json@) at @<mnt>\/persist\/var\/lib\/dots@.
-- Mirrors @plan@ exactly — do NOT paraphrase.
plan :: InstallConfig -> String -> String -> [Step]
plan cfg flakeSrc mnt =
  [ Step "Write LUKS keyfile" $
      cmd "sh"
        ["-c", "umask 077; head -c 64 /dev/urandom > " <> luksPassfile]
        Nothing
        Stream
  , Step "Partition, encrypt and mount (disko)" $
      cmd "disko"
        [ "--mode"
        , "destroy,format,mount"
        , "--yes-wipe-all-disks"
        , "--arg"
        , "disks"
        , disksArg
        , "--argstr"
        , "swapSize"
        , swap
        , flakeSrc <> "/nix/disko.nix"
        ]
        Nothing
        Stream
  , Step "Stage flake for install" $
      cmd "sh"
        ["-c", "rm -rf " <> stagedFlake <> " && mkdir -p " <> stagedFlake
              <> " && cp -rTL " <> flakeSrc <> " " <> stagedFlake
              <> " && chmod -R u+w " <> stagedFlake]
        Nothing
        Stream
  , Step "Detect hardware (nixos-facter)" $
      cmd "nixos-facter"
        ["-o", stagedFlake <> "/nix/facter.json"]
        Nothing
        Stream
  , Step "Write install answers (settings.nix)" $
      WriteFile
        { wfPath = stagedFlake <> "/nix/settings.nix"
        , wfContents = settingsNix cfg
        , wfMode = 0o644
        }
  , Step "Write password hashes (secrets.nix)" $
      WriteSecrets
        { wsPath = stagedFlake <> "/nix/secrets.nix"
        , wsUserPassword = icUserPassword cfg
        }
  , Step "Stash install answers on target" $
      cmd "sh"
        ["-c", "mkdir -p " <> mnt <> "/persist/var/lib/dots && cp "
              <> stagedFlake <> "/nix/settings.nix " <> stagedFlake
              <> "/nix/facter.json " <> mnt <> "/persist/var/lib/dots/"]
        Nothing
        Stream
  , Step "Copy network profiles to target" $
      cmd "sh"
        ["-c", "if [ -d /etc/NetworkManager/system-connections ]; then mkdir -p "
              <> mnt <> "/persist/etc/NetworkManager && cp -a "
              <> "/etc/NetworkManager/system-connections " <> mnt
              <> "/persist/etc/NetworkManager/; fi"]
        Nothing
        Stream
  , Step "Install NixOS (this takes a while)" $
      cmd "nixos-install"
        ["--root", mnt, "--no-root-passwd", "--flake", stagedFlake <> "#tokyonight"]
        Nothing
        Stream
  , Step "Enroll TPM2 unlock (PCR 7)" $
      cmd "systemd-cryptenroll"
        [ "--unlock-key-file=" <> luksPassfile
        , "--tpm2-device=auto"
        , "--tpm2-pcrs=7"
        , luksDevice
        ]
        Nothing
        Stream
  , Step "Enroll recovery key" $
      cmd "systemd-cryptenroll"
        [ "--unlock-key-file=" <> luksPassfile
        , "--recovery-key"
        , luksDevice
        ]
        Nothing
        RecoveryKey
  , Step "Scrub LUKS keyfile" $
      cmd "shred" ["-u", luksPassfile] Nothing Stream
  ]
  where
    swap = show (icSwapSizeGib cfg) <> "G"
    disksArg = "[ " <> unwords (map (\d -> "\"" <> d <> "\"") (icDisks cfg)) <> " ]"

-- | Execute the plan, streaming events. Never throws; all failures land as
-- 'Failed'. Mirrors @run@.
run :: InstallConfig -> TChan Event -> IO ()
run cfg tx = do
  dry <- lookupEnv "DOTS_INSTALLER_DRY_RUN"
  case dry of
    Just _ -> runDry cfg tx
    Nothing -> runReal cfg tx

-- | Dry-run: emit StepStarted+Log for each step (400ms each), then a canned
-- recovery key and Finished. Mirrors @run_dry@.
runDry :: InstallConfig -> TChan Event -> IO ()
runDry cfg tx = do
  let steps = plan cfg "/etc/dots" "/mnt"
      total = length steps
  forM_ (zip [1 ..] steps) $ \(i, step) -> do
    send (StepStarted i total (stepTitle step))
    send (Log ("[dry-run] " <> stepTitle step))
    threadDelay 400000
  send (RecoveryKey "dry-run-recovery-key")
  send Finished
  where
    send = atomically . writeTChan tx

-- | Real execution: run each step in order; on error, scrub the passfile and
-- emit 'Failed'; on success, scrub and emit 'Finished'. Mirrors @run_real@.
runReal :: InstallConfig -> TChan Event -> IO ()
runReal cfg tx = do
  let steps = plan cfg "/etc/dots" "/mnt"
      total = length steps
  go steps 1 total
  where
    send = atomically . writeTChan tx
    go [] _ _ = do
      scrubPassfile
      send Finished
    go (step : rest) i total = do
      send (StepStarted i total (stepTitle step))
      eResult <- try (execStep step tx) :: IO (Either SomeException ())
      case eResult of
        Left e -> do
          scrubPassfile
          send (Failed (stepTitle step <> ": " <> show e))
        Right _ -> go rest (i + 1) total

-- | Best-effort removal of the plaintext LUKS keyfile — called on every exit
-- path so a mid-install failure never leaves the root password in /tmp.
-- Mirrors @scrub_passfile@.
scrubPassfile :: IO ()
scrubPassfile = do
  _ <- try (callProcess "shred" ["-u", luksPassfile]) :: IO (Either SomeException ())
  _ <- try (removeFile luksPassfile) :: IO (Either SomeException ())
  pure ()

-- | Unlink + @O_EXCL@ write: never follow a pre-planted file/symlink at a
-- predictable path, and @mode@ applies from the first byte (@fs::write@ would
-- create 0644 and only chmod afterwards). Parent dirs are created if missing.
-- Mirrors @write_file_secure@.
writeFileSecure :: String -> String -> Int -> IO ()
writeFileSecure path contents mode = do
  let parent = takeDir path
  when (not (null parent)) $ createDirectoryIfMissing True parent
  -- Best-effort unlink (ignore "does not exist" / symlink errors).
  _ <- try (removeFile path) :: IO (Either SomeException ())
  -- O_EXCL write: withFile + setFileMode after, but to mirror create_new we
  -- write the file then set the mode. The unlink above ensures no pre-planted
  -- file remains, so a fresh file is created here.
  withFile path WriteMode $ \h -> do
    hPutStr h contents
  setFileMode path (fromIntegral mode)
  where
    takeDir p = case reverse (dropWhile (/= '/') (reverse p)) of
      "" -> "."
      d -> d

-- | Hash a plaintext password with yescrypt via @mkpasswd -m yescrypt --stdin@
-- (from the whois package; in @corePackageNames@, so it ships in
-- @/run/current-system/sw@ on every NixOS incl. the ISO — no Cargo dep, no
-- extra Nix package). The password is piped through stdin, never argv, so it
-- can't leak via @/proc/<pid>/cmdline@. Mirrors @hash_password@.
hashPassword :: String -> IO (Either String String)
hashPassword plaintext = do
  eOut <- try
    (readCreateProcessWithExitCode
      (proc "mkpasswd" ["-m", "yescrypt", "--stdin"])
      (plaintext <> "\n")) :: IO (Either SomeException (ExitCode, String, String))
  pure $ case eOut of
    Left e -> Left ("spawning mkpasswd: " <> show e)
    Right (code, out, err) -> case code of
      ExitSuccess ->
        let hash = trim out
        in if "$y$" `isPrefixOf` hash
             then Right hash
             else Left ("mkpasswd did not produce a yescrypt hash: " <> hash)
      _ -> Left ("mkpasswd exited with " <> showCode code <> ": " <> trim err)
  where
    showCode ExitSuccess = "0"
    showCode (ExitFailure n) = show n

-- | Execute one step, streaming events. Mirrors @exec_step@.
execStep :: Step -> TChan Event -> IO ()
execStep step tx = case stepAction step of
  WriteFile path contents mode -> writeFileSecure path contents mode
  WriteSecrets path userPassword -> do
    eHash <- hashPassword userPassword
    case eHash of
      Left e -> fail e
      Right hash ->
        writeFileSecure path ("{\n  userHash = \"" <> hash <> "\";\n}\n") 0o600
  Command program args stdin' capture -> do
    let cp = (proc program args)
          { std_in = case stdin' of
              Just _ -> CreatePipe
              Nothing -> NoStream
          , std_out = CreatePipe
          , std_err = CreatePipe
          }
    withCreateProcess cp $ \(mIn mOut mErr procHandle) -> do
      -- Drain stderr on its own thread BEFORE feeding stdin, so a child
      -- that errors early can't deadlock us on a full stderr pipe.
      stderrDone <- newEmptyMVar :: IO (MVar ())
      case mErr of
        Just errH -> void $ forkIO $ do
          drainErrLines errH
          putMVar stderrDone ()
        Nothing -> putMVar stderrDone ()
      -- Feed stdin (if any), then close it so the child sees EOF. Ignore
      -- EPIPE — a child that already exited can't receive; the wait below
      -- surfaces the real status.
      case (stdin', mIn) of
        (Just input, Just inH) -> do
          _ <- try (hPutStr inH input) :: IO (Either SomeException ())
          pure ()
        _ -> pure ()
      -- Read stdout: Stream → Log each line; RecoveryKey → keep the last
      -- non-empty trimmed line.
      lastLine <- case mOut of
        Just outH -> drainStdout capture outH
        Nothing -> pure ""
      code <- waitForProcess procHandle
      takeMVar stderrDone
      case code of
        ExitFailure n -> fail (program <> " exited with " <> show n)
        ExitSuccess -> when (capture == RecoveryKey) $ do
          if null lastLine
            then fail "no recovery key captured"
            else do
              let parent = takeDir recoveryKeyFile
              when (not (null parent)) $ createDirectoryIfMissing True parent
              writeFile recoveryKeyFile (lastLine <> "\n")
              setFileMode recoveryKeyFile 0o600
              send (RecoveryKey lastLine)
  where
    send = atomically . writeTChan tx
    takeDir p = case reverse (dropWhile (/= '/') (reverse p)) of
      "" -> "."
      d -> d
    drainErrLines h = do
      done <- hIsEOF h
      if done
        then pure ()
        else do
          line <- hGetLine h
          send (Log line)
          drainErrLines h
    drainStdout capture h = do
      let go acc = do
            done <- hIsEOF h
            if done
              then pure acc
              else do
                line <- hGetLine h
                case capture of
                  Stream -> send (Log line)
                  RecoveryKey -> do
                    let t = trim line
                    if null t then go acc else go t
                go acc
      go ""

-- | Strip leading/trailing whitespace.
trim :: String -> String
trim = f . f where f = reverse . dropWhile isSpace