-- | lsblk parsing + partition-suffix tests. Faithful Haskell port of
-- @rust/installer-tui/tests/disks.rs@.
module DisksSpec (tests) where

import Data.Either (isLeft)
import Data.List (isInfixOf)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

import Dots.Installer.Disks
  ( Disk (..)
  , autodetectDisk
  , gib
  , humanSize
  , parentDisk
  , parseLsblk
  , requiredGib
  )

import Common (fixtureLsblk)

tests :: TestTree
tests =
  testGroup
    "Disks"
    [ testCase "keeps only writable physical disks" $ do
        let Right disks = parseLsblk fixtureLsblk
            paths = map diskPath disks
        assertEqual "paths" ["/dev/nvme0n1", "/dev/sda"] paths
    , testCase "parses model and removable flag" $ do
        let Right disks = parseLsblk fixtureLsblk
        assertEqual "nvme model" "Samsung SSD 980" (diskModel (disks !! 0))
        assertBool "nvme not removable" (not (diskRemovable (disks !! 0)))
        assertBool "sda removable (string \"1\" rm)" (diskRemovable (disks !! 1))
    , testCase "human_size renders GiB" $ do
        let d = Disk "/dev/nvme0n1" 512110190592 "" False
        assertEqual "human_size" "476.9 GiB" (humanSize d)
    , testCase "rejects garbage json" $ do
        assertBool "is left" (isLeft (parseLsblk "not json"))
    , testCase "parent_disk strips partition suffixes" $ do
        assertEqual "sda1" "/dev/sda" (parentDisk "/dev/sda1")
        assertEqual "nvme p2" "/dev/nvme0n1" (parentDisk "/dev/nvme0n1p2")
        assertEqual "mmc p1" "/dev/mmcblk0" (parentDisk "/dev/mmcblk0p1")
        assertEqual "vda" "/dev/vda" (parentDisk "/dev/vda")
        assertEqual "nvme" "/dev/nvme0n1" (parentDisk "/dev/nvme0n1")
    , testCase "autodetects the only fixed disk" $ do
        let Right disks = parseLsblk fixtureLsblk
            Right d = autodetectDisk disks 8
        assertEqual "path" "/dev/nvme0n1" (diskPath d)
    , testCase "required_gib sums esp swap and root" $ do
        assertEqual "0" 22 (requiredGib 0)
        assertEqual "8" 30 (requiredGib 8)
        assertEqual "16" 38 (requiredGib 16)
    , testCase "autodetection rejects ambiguous fixed disks" $ do
        let disks =
              [ Disk "/dev/vda" (64 * gib) "" False
              , Disk "/dev/vdb" (64 * gib) "" False
              ]
            Left e = autodetectDisk disks 8
        assertBool "ambiguous" ("ambiguous" `isInfixOf` e)
    , testCase "autodetection rejects disks that are too small" $ do
        let disks = [Disk "/dev/vda" (20 * gib) "" False]
            Left e = autodetectDisk disks 8
        assertBool "required 30 GiB" ("required 30 GiB" `isInfixOf` e)
    ]