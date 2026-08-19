-- | Install-plan contract tests (step order, argv hygiene, TPM2 flow).
-- Faithful Haskell port of @rust/installer-tui/tests/install.rs@.
module InstallSpec (tests) where

import Data.List (isInfixOf, isSuffixOf)
import Data.Maybe (isJust, isNothing)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

import Dots.Installer.Config (InstallConfig (..))
import Dots.Installer.Install
  ( Action (..)
  , Capture (..)
  , Step (..)
  , luksDevice
  , luksPassfile
  , plan
  , stagedFlake
  , swapSizeFromMeminfo
  )

cfg :: InstallConfig
cfg =
  InstallConfig
    { icDisks = ["/dev/vda"]
    , icHostname = "myhost"
    , icUsername = "alice"
    , icGitName = "Alice Q"
    , icGitEmail = "alice@example.org"
    , icUserPassword = "usersecret"
    , icSwapSizeGib = 16
    , icAiClaude = True
    , icAiCodex = True
    , icAiOllama = True
    }

steps :: [Step]
steps = plan cfg "/etc/dots" "/mnt"

-- | Find the first step whose title equals @t@.
findT :: String -> Maybe Step
findT t = go steps
  where
    go (s : rest) | stepTitle s == t = Just s
    go (_ : rest) = go rest
    go [] = Nothing

-- | Join a command's argv for substring assertions (mirrors Rust @args.join(" ")@).
joinArgs :: Action -> String
joinArgs (Command _ args _ _) = unwords args
joinArgs _ = ""

-- | Safe predicate: is the step's action a @Command@ with this program? (The
-- @cmdProgram@ record accessor is partial on non-Command constructors.)
isCmd :: String -> Step -> Bool
isCmd p s = case stepAction s of
  Command prog _ _ _ -> prog == p
  _ -> False

-- | Index of the first step matching a predicate (0-based position in the plan).
idx :: (Step -> Bool) -> Int
idx p = go 0 steps
  where
    go _ [] = error "no matching step"
    go i (s : rest) | p s = i | otherwise = go (i + 1) rest

tests :: TestTree
tests =
  testGroup
    "Install"
    [ testCase "swap_size rounds meminfo up to GiB" $ do
        assertEqual "16GB" 16 (swapSizeFromMeminfo "MemTotal:       16384256 kB\nMemFree: 1 kB")
        assertEqual "1GiB" 1 (swapSizeFromMeminfo "MemTotal: 1048576 kB")
        assertEqual "round up 1048577" 2 (swapSizeFromMeminfo "MemTotal: 1048577 kB")
    , testCase "plan writes random LUKS keyfile from urandom" $ do
        let Just keyfile = findT "Write LUKS keyfile"
            Command "sh" args _ _ = stepAction keyfile
            script = unwords args
        assertBool "urandom" (isInfixOf "/dev/urandom" script)
        assertBool "passfile" (isInfixOf luksPassfile script)
        let passfileWrite = any (\s -> case stepAction s of
                WriteFile path _ _ -> path == luksPassfile
                _ -> False) steps
        assertBool "not a static WriteFile" (not passfileWrite)
    , testCase "plan runs disko with selected disks and swap" $ do
        let disko = head [s | s <- steps, isCmd "disko" s]
            joined = joinArgs (stepAction disko)
        assertBool "disks arg" (isInfixOf "--arg disks [ \"/dev/vda\" ]" joined)
        assertBool "swap arg" (isInfixOf "--argstr swapSize 16G" joined)
        assertBool "mode" (isInfixOf "destroy,format,mount" joined)
    , testCase "plan installs from staged flake" $ do
        let joined = unwords [joinArgs (stepAction s) | s <- steps, isCmd "nixos-install" s]
        assertBool "flake" (isInfixOf ("--flake " <> stagedFlake <> "#tokyonight") joined)
        assertBool "no-root-passwd" (isInfixOf "--no-root-passwd" joined)
    , testCase "plan stages flake before detecting hardware before install" $ do
        let stage = idx (\s -> stepTitle s == "Stage flake for install")
            facter = idx (\s -> isCmd "nixos-facter" s)
            install = idx (\s -> isCmd "nixos-install" s)
        assertBool "stage < facter" (stage < facter)
        assertBool "facter < install" (facter < install)
        let facterStep = steps !! facter
            Command _ args _ _ = stepAction facterStep
        assertEqual "facter argv" ("-o " <> stagedFlake <> "/nix/facter.json") (unwords args)
    , testCase "plan stage step recreates staging dir and copies from flake src" $ do
        let Just stage = findT "Stage flake for install"
            Command "sh" args _ _ = stepAction stage
            script = unwords args
        assertBool "rm -rf" (isInfixOf ("rm -rf " <> stagedFlake) script)
        assertBool "mkdir -p" (isInfixOf ("mkdir -p " <> stagedFlake) script)
        assertBool "cp -rTL" (isInfixOf ("cp -rTL /etc/dots " <> stagedFlake) script)
        assertBool "chmod" (isInfixOf ("chmod -R u+w " <> stagedFlake) script)
    , testCase "plan writes settings.nix into staged flake" $ do
        let found = any (\s -> case stepAction s of
                WriteFile path contents _ -> path == (stagedFlake <> "/nix/settings.nix") && isInfixOf "myhost" contents
                _ -> False) steps
        assertBool "settings.nix step" found
    , testCase "plan writes ai toggles into settings.nix" $ do
        let c = cfg{icAiClaude = True, icAiCodex = False, icAiOllama = True}
            s = plan c "/etc/dots" "/mnt"
            found = any (\step -> case stepAction step of
                WriteFile path contents _ ->
                  path == (stagedFlake <> "/nix/settings.nix")
                    && isInfixOf "aiClaude = true;" contents
                    && isInfixOf "aiCodex = false;" contents
                    && isInfixOf "aiOllama = true;" contents
                _ -> False) s
        assertBool "ai toggles rendered" found
    , testCase "plan stashes exactly settings and facter to var/lib/dots" $ do
        let Just stash = findT "Stash install answers on target"
            Command "sh" args _ _ = stepAction stash
            script = unwords args
        assertBool "mkdir persist" (isInfixOf "mkdir -p /mnt/persist/var/lib/dots" script)
        assertBool "cp settings+facter" (isInfixOf ("cp " <> stagedFlake <> "/nix/settings.nix " <> stagedFlake <> "/nix/facter.json /mnt/persist/var/lib/dots/") script)
    , testCase "plan stashes answers after settings write and before install" $ do
        let settings = idx (\s -> stepTitle s == "Write install answers (settings.nix)")
            stash = idx (\s -> stepTitle s == "Stash install answers on target")
            install = idx (\s -> isCmd "nixos-install" s)
        assertBool "settings < stash" (settings < stash)
        assertBool "stash < install" (stash < install)
    , testCase "plan never references /mnt/etc/dots" $ do
        let anyLeak = any (\s -> case stepAction s of
                Command prog args _ _ -> isInfixOf "/mnt/etc/dots" prog || any (isInfixOf "/mnt/etc/dots") args
                WriteFile path contents _ -> isInfixOf "/mnt/etc/dots" path || isInfixOf "/mnt/etc/dots" contents
                WriteSecrets path _ -> isInfixOf "/mnt/etc/dots" path) steps
        assertBool "no /mnt/etc/dots leak" (not anyLeak)
    , testCase "plan enrolls tpm2 then recovery key" $ do
        let cryptenroll = [stepAction s | s <- steps, isCmd "systemd-cryptenroll" s]
        assertEqual "two enrollments" 2 (length cryptenroll)
        let tpm2 = joinArgs (cryptenroll !! 0)
            rec = joinArgs (cryptenroll !! 1)
        assertBool "tpm2 device" (isInfixOf "--tpm2-device=auto" tpm2)
        assertBool "tpm2 pcrs" (isInfixOf "--tpm2-pcrs=7" tpm2)
        assertBool "luks device" (isInfixOf luksDevice tpm2)
        assertBool "recovery key" (isInfixOf "--recovery-key" rec)
        let captured = any (\s -> case stepAction s of
                Command "systemd-cryptenroll" _ _ RecoveryKey -> True
                _ -> False) steps
        assertBool "recovery captured" captured
    , testCase "plan seeds passwords via secrets.nix not chpasswd" $ do
        let hasChpasswd = any (\s -> case stepAction s of
                Command "nixos-enter" args _ _ -> any (== "chpasswd") args
                _ -> False) steps
        assertBool "no chpasswd" (not hasChpasswd)
        let userPw = [pw | s <- steps, WriteSecrets _ pw <- [stepAction s]]
        assertEqual "user password" ["usersecret"] userPw
        let leaked = any (\s -> case stepAction s of
                Command prog args _ _ -> isInfixOf "usersecret" (prog <> " " <> unwords args)
                _ -> False) steps
        assertBool "no password in argv" (not leaked)
    , testCase "plan writes secrets before install and never stashes them" $ do
        let secrets = idx (\s -> case stepAction s of WriteSecrets _ _ -> True; _ -> False)
            install = idx (\s -> isCmd "nixos-install" s)
        assertBool "secrets < install" (secrets < install)
        let secretsLeak = any (\s -> case stepAction s of
                Command prog args _ _ -> isInfixOf "secrets.nix" (prog <> " " <> unwords args)
                _ -> False) steps
        assertBool "no secrets.nix in commands" (not secretsLeak)
    , testCase "plan copies network profiles to target" $ do
        let Just copy = findT "Copy network profiles to target"
            Command "sh" args _ _ = stepAction copy
            script = unwords args
        assertBool "guard" (isInfixOf "if [ -d /etc/NetworkManager/system-connections ]" script)
        assertBool "mkdir persist" (isInfixOf "mkdir -p /mnt/persist/etc/NetworkManager" script)
        assertBool "cp -a" (isInfixOf "cp -a /etc/NetworkManager/system-connections /mnt/persist/etc/NetworkManager/" script)
    , testCase "plan copies network profiles after mount before install" $ do
        let disko = idx (\s -> isCmd "disko" s)
            copy = idx (\s -> stepTitle s == "Copy network profiles to target")
            install = idx (\s -> isCmd "nixos-install" s)
        assertBool "disko < copy" (disko < copy)
        assertBool "copy < install" (copy < install)
    , testCase "plan shreds passfile last" $ do
        let lastStep = last steps
            Command "shred" args _ _ = stepAction lastStep
        assertBool "shred passfile" (any (== luksPassfile) args)
    ]