-- | 'InstallConfig' rendering + hostname/username/git validation tests.
-- Faithful Haskell port of @rust/installer-tui/tests/config.rs@.
module ConfigSpec (tests) where

import Data.List (isInfixOf)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

import Dots.Installer.Config
  ( InstallConfig (..)
  , nixEscape
  , settingsNix
  , validateGitEmail
  , validateGitName
  , validateHostname
  , validateUsername
  )

-- | A config with the fields the settings.nix tests assert on. Mirrors the
-- Rust @..Default::default()@ fill.
cfg :: InstallConfig
cfg =
  InstallConfig
    { icDisks = ["/dev/vda", "/dev/vdb"]
    , icHostname = "myhost"
    , icUsername = "alice"
    , icGitName = "Alice Q"
    , icGitEmail = "alice@example.org"
    , icUserPassword = ""
    , icSwapSizeGib = 16
    , icAiClaude = True
    , icAiCodex = True
    , icAiOllama = True
    }

tests :: TestTree
tests =
  testGroup
    "Config"
    [ testCase "settings_nix renders all answers" $ do
        let out = settingsNix cfg
        assertBool "username" (isInfixOf "username = \"alice\";" out)
        assertBool "hostname" (isInfixOf "hostname = \"myhost\";" out)
        assertBool "disks" (isInfixOf "disks = [ \"/dev/vda\" \"/dev/vdb\" ];" out)
        assertBool "swapSize" (isInfixOf "swapSize = \"16G\";" out)
        assertBool "gitName" (isInfixOf "gitName = \"Alice Q\";" out)
        assertBool "gitEmail" (isInfixOf "gitEmail = \"alice@example.org\";" out)
        assertBool "starts with {" (head (dropWhile (== ' ') out) == '{')
        assertBool "ends with }" (last (dropWhile (== ' ') (reverse out)) == '}')
    , testCase "settings_nix never contains passwords" $ do
        let c = cfg{icUserPassword = "usersecret"}
            out = settingsNix c
        assertBool "password leaked" (not (isInfixOf "usersecret" out))
    , testCase "settings_nix escapes quotes and backslashes in git identity" $ do
        let c = cfg{icGitName = "Alice \"bo\" \\o/", icGitEmail = "a\\b\"e\"@example.org"}
            out = settingsNix c
        assertBool "gitName escaped" (isInfixOf "gitName = \"Alice \\\"bo\\\" \\\\o/\";" out)
        assertBool "gitEmail escaped" (isInfixOf "gitEmail = \"a\\\\b\\\"e\\\"@example.org\";" out)
    , testGroup "validators"
        [ testCase "hostname accepts rfc1123 labels" $ do
            assertBool "tokyonight" (validateHostname "tokyonight" == Right ())
            assertBool "my-host2" (validateHostname "my-host2" == Right ())
        , testCase "hostname rejects bad labels" $ do
            mapM_ (\h -> assertBool (h <> " rejected") (validateHostname h /= Right ())
              ["", "-leading", "trailing-", "Upper", "under_score", replicate 64 'a'])
        , testCase "username accepts posix names" $ do
            mapM_ (\u -> assertBool (u <> " accepted") (validateUsername u == Right ())
              ["matus", "_svc", "m-user_9"])
        , testCase "username rejects bad names" $ do
            mapM_ (\u -> assertBool (u <> " rejected") (validateUsername u /= Right ())
              ["", "9lives", "Matus", "with space", replicate 32 'a'])
            assertBool "reserved" (validateUsername "root" /= Right ())
        , testCase "git name accepts real names" $ do
            mapM_ (\g -> assertBool (g <> " accepted") (validateGitName g == Right ())
              ["Matus Mastena", "O'Brien", "田中", replicate 128 'a'])
        , testCase "git name rejects empty newlines and too long" $ do
            mapM_ (\g -> assertBool (g <> " rejected") (validateGitName g /= Right ())
              ["", "   ", "with\nnewline", "carriage\rreturn", replicate 129 'a'])
        , testCase "git email accepts well formed" $ do
            mapM_ (\e -> assertBool (e <> " accepted") (validateGitEmail e == Right ())
              ["alice@example.org", "a.b+c@sub.example.org", "user@my.co"])
        , testCase "git email rejects malformed" $ do
            mapM_ (\e -> assertBool (e <> " rejected") (validateGitEmail e /= Right ())
              [ "", "no-at-sign.example.org", "local-only@", "@example.org"
              , "two@@at.example.org", "no-dot@example", "space in @example.org"
              ]
              )
        , testCase "nixEscape round-trips backslash and quote" $ do
            assertEqual "backslash" "\\\\" (nixEscape "\\")
            assertEqual "quote" "\\\"" (nixEscape "\"")
            assertEqual "both" "\\\\\\\"" (nixEscape "\\\"")
        ]
    ]