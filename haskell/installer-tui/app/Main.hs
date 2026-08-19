-- | Entry point — the installer wizard on the abstracttui runtime. Faithful
-- Haskell port of @rust/installer-tui/src/main.rs@.
--
-- Reads @/proc/meminfo@ for the swap size, autodetects the target disk, builds
-- the initial 'App', and hands off to "Dots.Installer.Run". Any autodetection
-- failure (ambiguous disks, all too small, lsblk error) falls back to the
-- manual 'ScreenDiskSelect' picker instead of aborting before the TUI renders
-- — which would otherwise crash-loop on a blank tty1.
module Main (main) where

import Dots.Installer.App (App (..), appNew)
import Dots.Installer.Config (InstallConfig (..))
import Dots.Installer.Disks (autodetectDisk, diskPath, listDisks)
import Dots.Installer.Install (swapSizeFromMeminfo)
import Dots.Installer.Run (run)

-- | @main@: size swap from RAM, autodetect the target disk, build the wizard,
-- run it.
main :: IO ()
main = do
  meminfo <- readFile "/proc/meminfo"
  let swapSizeGib = swapSizeFromMeminfo meminfo
  disks <- listDisks
  let auto = case autodetectDisk disks swapSizeGib of
        Right d -> Just (diskPath d)
        Left _ -> Nothing
  let app0 = appNew disks auto
      app1 = app0{appConfig = (appConfig app0){icSwapSizeGib = swapSizeGib}}
  run app1