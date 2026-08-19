{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The interactive wizard's custom 'Driver' loop. Faithful Haskell port of
-- @rust/installer-tui/src/main.rs@.
--
-- The loop owns three IO concerns the pure 'App' state machine can't: draining
-- the install + network worker 'TChan's (applying 'onInstallEvent' /
-- 'onNetEvent' and retargeting the fx progress on step changes), ticking 'fx'
-- each frame via 'sigSetIO', and the one-shot install-runner guard + net-op
-- spawn. Everything else is the pure 'handleKey' transition in "Dots.Installer.Ui".
module Dots.Installer.Run
  ( run
  , idleIntervalMs
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM
  ( TChan
  , atomically
  , newTChanIO
  , tryReadTChan
  )
import Control.Exception (SomeException, finally, try)
import Control.Monad (unless, void, when, forM_)
import Control.Monad.IO.Class (liftIO)
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import GHC.Conc.Sync (getUncaughtExceptionHandler, setUncaughtExceptionHandler)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import System.IO.Unsafe (unsafePerformIO)
import System.Process (callProcess)

import AbstractTUI.Anim (clockReal)
import AbstractTUI.Base.Geom (size)
import AbstractTUI.Driver
  ( RunConfig (..)
  , appMount
  , defaultRunConfig
  , finish
  , newApp
  , newDriver
  , requestFullRedraw
  , turn
  , turnIdle
  , turnQuit
  , waitUntil
  )
import AbstractTUI.Reactive (Signal, signal, sigReadRef, sigSetIO)
import AbstractTUI.Term (CaptureTerm, emergencyRestore, haveTty, newRealTerm)

import Dots.Installer.App
  ( App (..)
  , onInstallEvent
  , onNetEvent
  )
import Dots.Installer.Config (InstallConfig (..))
import Dots.Installer.Fx
  ( ScreenFx
  , retargetProgress
  , retargetScreen
  , screenFxNew
  , tickFx
  )
import Dots.Installer.Install (Event (..), run)
import Dots.Installer.Net (Event (..), Op (..), runOp)
import Dots.Installer.Ui (rootView)

-- * Existential signal pair

-- | Both signals share the same Spider timeline @t@, so 'rootView' can be
-- built inside the rank-2 mount closure. The main loop (concrete timeline)
-- recovers them by pattern-matching; 'sigReadRef'\/'sigSetIO' are polymorphic
-- in @t@, so the loop never needs to name @t@.
data SomeSignals = forall t. SomeSignals (Signal t App) (Signal t ScreenFx)

-- * Run

-- | Run the wizard against the pre-built initial 'App' (disks autodetected,
-- swap size already set by "Dots.Installer.App.appNew" + 'Main'). Bails if
-- stdin isn't a tty. The loop forces a full-screen rewrite every draw (the
-- desync-healing fullscreen-render contract), drains the install + net workers,
-- ticks 'fx' each frame, spawns the install runner exactly once, and spawns
-- net ops on demand. After the loop, reboots unless @DOTS_INSTALLER_DRY_RUN@
-- is set. The terminal is always restored via 'finish'.
run :: App -> IO ()
run initialApp = do
  isTty <- haveTty
  if not isTty
    then do
      hPutStrLn stderr "dots-installer: needs an interactive terminal"
      exitFailure
    else do
      installChan <- newTChanIO :: IO (TChan Event)
      netChan <- newTChanIO :: IO (TChan Net.Event)
      runnerStarted <- newIORef False
      sigsRef <- newIORef (Nothing :: Maybe SomeSignals)
      app <- newApp (size 80 24)
      appMount app $ \scope -> do
        appSig <- signal initialApp scope
        clock <- liftIO clockReal
        fx0 <- liftIO (screenFxNew clock)
        fxSig <- signal fx0 scope
        liftIO (writeIORef sigsRef (Just (SomeSignals appSig fxSig)))
        pure (rootView appSig fxSig)
      term <- newRealTerm
      dr <- newDriver app term defaultRunConfig{rcProbe = False}
      installPanicHook term
      poll <- idleIntervalMs
      let loop = do
            requestFullRedraw dr
            readIORef sigsRef >>= \case
              Nothing -> pure ()
              Just (SomeSignals appSig fxSig) -> do
                -- Drain install worker events: apply onInstallEvent, retarget
                -- fx progress on StepStarted.
                drainInstall appSig fxSig installChan
                -- Drain net worker events: apply onNetEvent (screen transitions
                -- only from WifiConnecting, handled inside onNetEvent).
                drainNet appSig fxSig netChan
                -- Tick fx (advances transitions + caches eased values).
                fx <- sigReadRef fxSig
                fx' <- tickFx fx
                sigSetIO fxSig fx'
                -- One-shot install runner guard.
                a <- sigReadRef appSig
                started <- readIORef runnerStarted
                when (appStartInstall a && not started) $ do
                  writeIORef runnerStarted True
                  void $ forkIO (run (appConfig a) installChan)
                -- Pending net op: take + spawn.
                case appPendingNetOp a of
                  Just op -> do
                    sigSetIO appSig (a{appPendingNetOp = Nothing})
                    void $ forkIO (runOp op netChan)
                  Nothing -> pure ()
            t' <- turn dr
            if turnQuit t'
              then pure ()
              else do
                when (turnIdle t') (waitUntil dr poll)
                loop
      _ <- try (loop `finally` finish dr) :: IO (Either SomeException ())
      -- Reboot unless dry-run.
      readIORef sigsRef >>= \case
        Nothing -> pure ()
        Just (SomeSignals appSig _fxSig) -> do
          a <- sigReadRef appSig
          dry <- lookupEnv "DOTS_INSTALLER_DRY_RUN"
          when (appReboot a && dry == Nothing) $ callProcess "systemctl" ["reboot"]

-- * Worker channel drains

-- | Drain every queued install event, applying 'onInstallEvent', retargeting
-- the panel slide on any worker-driven screen transition (Finished→Done,
-- Failed→Failed), and retargeting the fx progress on 'StepStarted'. The mirror
-- 'IORef' chain threads the intermediate app states; the queue collapses to
-- the last write at fire time.
drainInstall :: Signal t App -> Signal t ScreenFx -> TChan Event -> IO ()
drainInstall appSig fxSig chan = do
  evts <- drainTChan chan
  forM_ evts $ \evt -> do
    a <- sigReadRef appSig
    let prevScreen = appScreen a
        a' = onInstallEvent a evt
        nextScreen = appScreen a'
    sigSetIO appSig a'
    -- Retarget the panel slide on a worker-driven screen change.
    when (nextScreen /= prevScreen) $ do
      fx <- sigReadRef fxSig
      fx' <- retargetScreen fx 0.0
      sigSetIO fxSig fx'
    -- Retarget the eased progress fill on step change.
    case evt of
      StepStarted i total _ -> do
        let ratio = if total == 0 then 0.0 else fromIntegral i / fromIntegral total
        fx <- sigReadRef fxSig
        fx' <- retargetProgress fx ratio
        sigSetIO fxSig fx'
      _ -> pure ()

-- | Drain every queued net event, applying 'onNetEvent' and retargeting the
-- panel slide on any worker-driven screen transition (ConnectDone→next,
-- ConnectDone error→Network).
drainNet :: Signal t App -> Signal t ScreenFx -> TChan Net.Event -> IO ()
drainNet appSig fxSig chan = do
  evts <- drainTChan chan
  forM_ evts $ \evt -> do
    a <- sigReadRef appSig
    let prevScreen = appScreen a
        a' = onNetEvent a evt
        nextScreen = appScreen a'
    sigSetIO appSig a'
    when (nextScreen /= prevScreen) $ do
      fx <- sigReadRef fxSig
      fx' <- retargetScreen fx 0.0
      sigSetIO fxSig fx'

-- | Non-blockingly drain every queued value from a 'TChan', in arrival order.
drainTChan :: TChan a -> IO [a]
drainTChan chan = atomically go
  where
    go = do
      m <- tryReadTChan chan
      case m of
        Just x -> (x :) <$> go
        Nothing -> pure []

-- * Idle interval

-- | The idle poll interval (ms), read from @DOTS_TUI_IDLE_MS@ (default 50,
-- min 1). Mirrors Rust's @idle_interval@: a negative value falls back to the
-- default, @0@ is clamped to 1.
idleIntervalMs :: IO Int
idleIntervalMs = do
  let defaultMs = 50 :: Int
  m <- lookupEnv "DOTS_TUI_IDLE_MS"
  pure $ case (readInt =<< m) of
    Just n | n >= 0 -> max 1 n
    _ -> defaultMs

-- | Parse an 'Int' (guards against the negative→busy-poll trap).
readInt :: String -> Maybe Int
readInt s = case reads s of
  [(n, "")] -> Just n
  _ -> Nothing

-- * Panic hook

-- | Process-global guard so 'installPanicHook' only chains once.
{-# NOINLINE panicHookGuard #-}
panicHookGuard :: IORef Bool
panicHookGuard = unsafePerformIO (newIORef False)

-- | Chain a terminal emergency-restore before the previous uncaught-exception
-- handler so panic messages print AFTER the controlling tty is back in cooked
-- mode. Idempotent across the process. Mirrors @install_panic_hook@.
installPanicHook :: CaptureTerm -> IO ()
installPanicHook term = do
  first <- atomicModifyIORef' panicHookGuard (\b -> (True, b))
  unless first $ do
    prev <- getUncaughtExceptionHandler
    setUncaughtExceptionHandler $ \e -> do
      _ <- try (emergencyRestore term) :: IO (Either SomeException ())
      prev e