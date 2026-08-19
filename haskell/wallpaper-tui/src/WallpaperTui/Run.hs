{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The interactive TUI entry point: terminal setup, the abstracttui
-- 'Driver' loop, and the worker threads. Mirrors
-- @rust/wallpaper-tui/src/main.rs@'s @run_tui@. The key bridge lives in
-- "WallpaperTui.Ui" (it calls 'WallpaperTui.App.handleKey'); this module
-- owns the 'Signal' 'App' \/ 'Signal' 'Fx', drains the worker 'TChan's,
-- dispatches pending ops onto worker threads, advances the 'Fx' crossfade
-- one frame per turn, and paces the loop. The non-interactive CLI paths
-- (@--restore@, @--cache-previews@, @--output PATH@) live in @app\/Main.hs@.
module WallpaperTui.Run
  ( runTui
  , idleIntervalMs
  , clockNow
  , installPanicHook
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM
  ( TChan
  , atomically
  , newTChanIO
  , tryReadTChan
  , writeTChan
  )
import Control.Exception (SomeException, finally, try)
import Control.Monad (unless, void, when)
import Control.Monad.IO.Class (liftIO)
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Maybe (listToMaybe)
import Data.Time.Clock.POSIX (getPOSIXTime)
import GHC.Conc.Sync (getUncaughtExceptionHandler, setUncaughtExceptionHandler)
import System.Environment (lookupEnv)
import System.Exit (exitWith, ExitCode (..))
import System.IO (hPutStrLn, stderr)
import System.IO.Unsafe (unsafePerformIO)
import Text.Read (readMaybe)

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
  , waitUntil
  )
import AbstractTUI.Reactive (Signal, sigReadRef, sigUpdateIO, signal)
import AbstractTUI.Term (CaptureTerm, emergencyRestore, haveTty, newRealTerm, termSize)

import qualified WallpaperTui.App as App
import WallpaperTui.App
  ( App (..)
  , Event
  , PendingOp (..)
  , onEvent
  , requestPreview
  )
import WallpaperTui.Accent (TintBackend)
import WallpaperTui.Awww (Group (..), applyWallpaper, liveAwww, restoreGroups)
import WallpaperTui.Config
  ( Config
  , State
  , configTransitionDuration
  , configTransitionType
  , configWallpaperFolder
  , saveState
  )
import WallpaperTui.Fx (Fx, animationsEnabled, fxNew, fxTickAt)
import WallpaperTui.Preview (loadPreview)
import WallpaperTui.Tint (Status (stQt), applyTint)
import WallpaperTui.Ui (rootView)

-- * Existential signal wrappers

-- | A 'Signal' 'App' existentially-quantified over the Reflex timeline @t@ so
-- the mount closure (polymorphic in @t@) can publish the app signal to the
-- main loop (which knows only the concrete Spider timeline). 'sigReadRef'\/
-- 'sigUpdateIO' are polymorphic in @t@, so the loop operates on the unwrapped
-- existential without ever naming @t@. Mirrors hyprmon's @SomeFrameSignal@.
data SomeAppSig = forall t. SomeAppSig (Signal t App)

-- | Same, for the 'Fx' signal.
data SomeFxSig = forall t. SomeFxSig (Signal t Fx)

-- * Run

-- | Run the interactive wallpaper picker. Bails with a stderr message + exit
-- failure if stdin isn't a tty; otherwise hosts the pure 'App' state machine
-- in the abstracttui 'Driver' and drives the loop until the picker quits.
-- The apply\/tint and preview decode run on worker threads so wallpaper
-- selection never blocks on rendering; results flow back over 'TChan's the
-- loop drains each frame. The terminal is always restored, even on the error
-- path, via 'finish' (and the panic hook for a crash). Mirrors @run_tui@.
runTui ::
  Config ->
  State ->
  Bool ->
  TintBackend ->
  IO ()
runTui config state noTint backend = do
  isTty <- haveTty
  if not isTty
    then do
      hPutStrLn stderr "wallpaper TUI needs a tty (run on a real console)"
      exitWith (ExitFailure 1)
    else do
      app0 <- App.appNew config state noTint backend
      let app0' = requestPreview app0
          isEmpty = null (App.wpWallpapers app0')
          folder = configWallpaperFolder config
      appRef <- newIORef (Nothing :: Maybe SomeAppSig)
      fxRef <- newIORef (Nothing :: Maybe SomeFxSig)
      term <- newRealTerm
      vp <- termSize term
      app <- newApp vp
      appMount app $ \scope -> do
        a <- signal app0' scope
        f <- signal fxNew scope
        anim <- liftIO animationsEnabled
        liftIO (writeIORef appRef (Just (SomeAppSig a)))
        liftIO (writeIORef fxRef (Just (SomeFxSig f)))
        pure (rootView isEmpty folder a f anim)
      dr <- newDriver app term defaultRunConfig{rcProbe = False}
      installPanicHook term
      poll <- idleIntervalMs
      Just (SomeAppSig appSig) <- readIORef appRef
      Just (SomeFxSig fxSig) <- readIORef fxRef
      applyChan <- newTChanIO
      previewChan <- newTChanIO
      let loop = do
            requestFullRedraw dr
            applyEvts <- drainChan applyChan
            mapM_ (applyEvent (SomeAppSig appSig)) applyEvts
            previewEvts <- drainChan previewChan
            mapM_ (applyEvent (SomeAppSig appSig)) previewEvts
            now <- clockNow
            sigUpdateIO fxSig (fxTickAt now)
            dispatch (SomeAppSig appSig) applyChan previewChan
            t' <- turn dr
            quit <- App.wpShouldQuit <$> sigReadRef appSig
            if quit
              then pure ()
              else do
                when (turnIdle t') (waitUntil dr poll)
                loop
      _ <-
        try (loop `finally` finish dr) ::
          IO (Either SomeException ())
      pure ()

-- * Loop helpers

-- | Drain a 'TChan' non-blockingly, returning all available events in arrival
-- order. Mirrors Rust's @mpsc::Receiver::try_recv@ loop.
drainChan :: TChan a -> IO [a]
drainChan ch = go
  where
    go = do
      m <- atomically (tryReadTChan ch)
      case m of
        Nothing -> pure []
        Just x -> (x :) <$> go

-- | Fold a worker event into the app state via 'onEvent'. Pure mutation via
-- 'sigUpdateIO' — the 'Dynamic' (and the view) refresh on the next 'turn'.
applyEvent :: SomeAppSig -> Event -> IO ()
applyEvent (SomeAppSig s) ev = sigUpdateIO s (\a -> onEvent a ev)

-- | Extract the pending op the state machine queued via 'handleKey' (or the
-- initial 'requestPreview'), clearing it. Read-then-clear is safe: the loop
-- is single-threaded and signal mutation only happens inside 'turn' (the key
-- bridge) or this loop's own drain\/dispatch — never between the read and the
-- clear.
takePending :: SomeAppSig -> IO (Maybe PendingOp)
takePending (SomeAppSig s) = do
  a <- sigReadRef s
  case App.wpPending a of
    Nothing -> pure Nothing
    Just op -> do
      sigUpdateIO s (\a' -> a'{App.wpPending = Nothing})
      pure (Just op)

-- | Dispatch a pending op onto a worker thread. Apply\/Restore save the
-- state (deferred from the pure 'handleKey' — the state machine cannot do
-- IO), spawn the awww+tint worker, and report back via the apply channel.
-- Preview spawns the JuicyPixels decode worker. Restore resolves the groups
-- via 'restoreGroups' (IO, file-existence check) — the pure state machine
-- only records the 'PendingRestore' marker.
dispatch :: SomeAppSig -> TChan Event -> TChan Event -> IO ()
dispatch sigApp applyChan previewChan = do
  mOp <- takePending sigApp
  case mOp of
    Nothing -> pure ()
    Just (PendingApply group ttype tdur noTint backend) -> do
      app <- readApp sigApp
      saveState (App.wpState app)
      void $ forkIO $ do
        applyWallpaper liveAwww [group] ttype tdur
        mStatus <- applyTint (gPath group) noTint backend
        let msg = case mStatus of
              Just st -> "applied " <> gPath group <> " (tint " <> stQt st <> ")"
              Nothing -> "applied " <> gPath group
        atomically (writeTChan applyChan (App.EventApplyDone msg))
    Just PendingRestore -> do
      app <- readApp sigApp
      groups <- restoreGroups (App.wpConfig app) (App.wpState app)
      if null groups
        then
          sigUpdateApp sigApp (\a -> a{App.wpStatus = Just "nothing to restore"})
        else do
          let ttype = configTransitionType (App.wpConfig app)
              tdur = configTransitionDuration (App.wpConfig app)
              noTint = App.wpNoTint app
              backend = App.wpBackend app
          void $ forkIO $ do
            applyWallpaper liveAwww groups ttype tdur
            let tintPath = maybe "" gPath (listToMaybe groups)
            mStatus <-
              if null tintPath
                then pure Nothing
                else applyTint tintPath noTint backend
            let msg = case mStatus of
                  Just st ->
                    "restored " <> show (length groups) <> " (tint " <> stQt st <> ")"
                  Nothing ->
                    "restored " <> show (length groups) <> " output(s)"
            atomically (writeTChan applyChan (App.EventApplyDone msg))
    Just (PendingPreview path) ->
      void $ forkIO $ do
        e <- loadPreview path
        let mImg = either (const Nothing) Just e
        atomically (writeTChan previewChan (App.EventPreviewReady path mImg))

-- | Read the 'App' mirror through the existential.
readApp :: SomeAppSig -> IO App
readApp (SomeAppSig s) = sigReadRef s

-- | Update the 'App' through the existential.
sigUpdateApp :: SomeAppSig -> (App -> App) -> IO ()
sigUpdateApp (SomeAppSig s) = sigUpdateIO s

-- * Clock + idle interval

-- | The current wall time in milliseconds. Used to seed 'fxTickAt' each
-- frame so the pure 'Fx' crossfade advances with real time (the Rust crate
-- uses @Instant::now()@; POSIX time in ms is equivalent for elapsed-time
-- math). The crossfade only uses @now - start@, so wall-clock vs monotonic
-- does not matter for a TUI session.
clockNow :: IO Int
clockNow = do
  t <- getPOSIXTime
  pure (round (realToFrac t * 1000) :: Int)

-- | The idle poll interval in milliseconds, read from @DOTS_TUI_IDLE_MS@
-- (default 50, min 1). Mirrors Rust's @idle_interval@: @u64@ parse parity — a
-- negative value fails the @u64@ parse and falls back to the default (50),
-- while @0@ parses and is clamped to 1. Reading 'Int' with a @>= 0@ guard
-- reproduces that (a negative parses but the guard rejects it → default).
idleIntervalMs :: IO Int
idleIntervalMs = do
  let defaultMs = 50 :: Int
  m <- lookupEnv "DOTS_TUI_IDLE_MS"
  pure $ case (readMaybe =<< m) :: Maybe Int of
    Just n | n >= 0 -> max 1 n
    _ -> defaultMs

-- * Panic hook

-- | The global guard for 'installPanicHook' (idempotent across the process).
-- 'unsafePerformIO' here is the standard top-level-mutable-state idiom: the
-- 'IORef' is created once at link time and shared. 'NOINLINE' keeps GHC from
-- floating the binding and re-running the 'unsafePerformIO'. Mirrors
-- hyprmon's @panicHookGuard@.
{-# NOINLINE panicHookGuard #-}
panicHookGuard :: IORef Bool
panicHookGuard = unsafePerformIO (newIORef False)

-- | Chain a terminal emergency-restore before the previous uncaught-
-- exception handler so panic messages print AFTER the controlling tty is
-- back in cooked mode (readable, not scattered over the alt screen).
-- Idempotent across the process via the 'panicHookGuard' 'IORef' (a Haskell
-- stand-in for Rust's @static Once@). Mirrors @install_panic_hook@.
installPanicHook :: CaptureTerm -> IO ()
installPanicHook term = do
  first <- atomicModifyIORef' panicHookGuard (\b -> (True, b))
  unless first $ do
    prev <- getUncaughtExceptionHandler
    setUncaughtExceptionHandler $ \e -> do
      _ <- try (emergencyRestore term) :: IO (Either SomeException ())
      prev e