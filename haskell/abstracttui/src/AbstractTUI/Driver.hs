{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | The compat core: 'App' (a mounted reflex-vty view-builder + quit flag)
-- and 'Driver' (the per-frame pump that bridges abstracttui's imperative,
-- turn-based 'turn' onto reflex-vty's continuous FRP host).
--
-- The bridge is host-setup replication (the brief's approach b): we cannot
-- build per-frame 'turn' on top of the public entry points
-- 'runVtyAppWithHandle'/'mainWidgetWithHandle' (they run to completion and
-- never expose the 'VtyResult'), so we replicate the host setup that
-- 'Reflex.Vty.Host.runVtyAppWithHandle' uses internally. 'newDriver' builds
-- the 'VtyResult' + 'FireCommand' + input/post-build trigger refs (mirroring
-- Host.hs lines 147-220) and stores them in a Spider-specific 'Driver'.
-- 'turn' drives one frame manually: fire the post-build trigger on the
-- first turn (Host.hs lines 208-213), sample the 'Picture' behavior and call
-- 'V.update' (Host.hs lines 200-201 / 288), and report the 'Turn'.
--
-- 'Driver'/'Term'/'View' are deliberately Spider-specific: they are the host
-- integration point, so host-specificity is correct here (unlike
-- 'AbstractTUI.Reactive', which stays host-agnostic).
module AbstractTUI.Driver
  ( App (..)
  , newApp
  , appMount
  , appQuitter
  , AppView (..)
  , Driver (..)
  , newDriver
  , Turn (..)
  , turn
  , requestFullRedraw
  , Quitter
  , quitterQuit
  , RunConfig (..)
  , defaultRunConfig
  ) where

import Control.Concurrent.Chan (newChan)
import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Monad (forM_, when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Ref (readRef)
import Data.Functor.Identity (Identity (..))
import Data.Dependent.Sum (DSum ((:=>)))
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Kind (Type)
import qualified Data.ByteString as BS
import Reflex
  ( Event
  , FireCommand (..)
  , Reflex (..)
  , ffilter
  , ffor
  , holdDyn
  , hostPerformEventT
  , leftmost
  , never
  , runPostBuildT
  , runTriggerEventT
  , sample
  , current
  )
import Reflex.Host.Class
  ( EventHandle
  , EventTrigger
  , newEventWithTriggerRef
  , subscribeEvent
  )
import Reflex.Spider (Global, Spider, SpiderHost, runSpiderHost)
import qualified Graphics.Vty as V
import Reflex.Vty.Host (AppSignal (..), MonadVtyApp, VtyResult (..))
import Reflex.Vty.Widget
  ( HasDisplayRegion
  , HasImageWriter
  , HasInput
  , HasTheme
  , Region (..)
  , runDisplayRegion
  , runImageWriter
  , runInput
  , runThemeReader
  , tellImages
  )
import Reflex.Vty.Theme (defTheme)
import Control.Monad.NodeId (runNodeIdT)

import AbstractTUI.Base.Geom (Size (..))
import AbstractTUI.Reactive (Scope (..))
import AbstractTUI.Term (CaptureTerm (..))
import AbstractTUI.View (View (..))

-- * App

-- | A rank-2-packaged reflex-vty view-builder. Stored in an 'IORef' on
-- 'App' so 'appMount' can install it after 'newApp'. The builder runs in the
-- widget monad (the inner 'm' of the context stack 'newDriver' sets up),
-- which provides the 'Has*' capabilities the builder needs; the 'Scope' is
-- the unit newtype from "AbstractTUI.Reactive" and carries no data.
newtype AppView = AppView
  { unAppView ::
      forall t (m :: Type -> Type).
      ( Reflex t
      , HasImageWriter t m
      , HasDisplayRegion t m
      , HasTheme t m
      , HasInput t m
      ) =>
      Scope t m -> m (View t)
  }

-- | A mounted app: the fixed viewport, the view-builder (installed by
-- 'appMount'), and the quit flag the loop checks after each turn.
data App = App
  { appViewport :: !Size
  , appViewRef :: !(IORef (Maybe AppView))
  , appQuit :: !Quitter
  }

-- | Allocate an app for a fixed viewport. The view-builder starts unset
-- ('appMount' installs it); the quit flag starts unfired.
newApp :: Size -> IO App
newApp vp = do
  vref <- newIORef Nothing
  q <- quitterNew
  pure App {appViewport = vp, appViewRef = vref, appQuit = q}

-- | Install the root view-builder. The closure receives the 'Scope' and
-- returns the initial 'View'; it is run once inside 'newDriver' when the
-- reflex-vty widget context is set up. Matches @App::mount(FnOnce(Scope)->View)@.
appMount
  :: App
  -> ( forall t (m :: Type -> Type)
        . ( Reflex t
          , HasImageWriter t m
          , HasDisplayRegion t m
          , HasTheme t m
          , HasInput t m
          )
       => Scope t m -> m (View t)
     )
  -> IO ()
appMount app f = writeIORef (appViewRef app) (Just (AppView f))

-- * Quitter

-- | A flip-flag the app checks after each turn to break the loop. Mirrors
-- the stash's @Quitter@.
newtype Quitter = Quitter (TVar Bool)

quitterNew :: IO Quitter
quitterNew = Quitter <$> newTVarIO False

-- | Flip the quit flag. The next 'turn' reports 'turnQuit = True'.
quitterQuit :: Quitter -> IO ()
quitterQuit (Quitter t) = atomically (writeTVar t True)

-- | Read the quit flag (non-blocking).
quitterCheck :: Quitter -> IO Bool
quitterCheck (Quitter t) = readTVarIO t

-- | The 'Quitter' the loop checks after each turn.
appQuitter :: App -> Quitter
appQuitter = appQuit

-- | Force the next 'turn' to re-emit every cell. With the mock-vty host the
-- picture is re-rendered every turn anyway, so this is currently a no-op
-- placeholder; the real invalidation hook (a global trigger that fires a
-- frame tick, draining into the next 'turn') lands in Task 9 when
-- 'feedInput' wires the input path.
requestFullRedraw :: IO ()
requestFullRedraw = pure ()

-- * RunConfig

-- | Run configuration. Only 'rcProbe' is overridden by the apps/tests; the
-- rest of the Rust @RunConfig@ fields are unused here.
data RunConfig = RunConfig
  { rcIdlePollMs :: !Int
  -- ^ The poll interval (ms) between idle turns. Unused by the manual
  -- turn-based driver but kept for parity with the Rust @RunConfig@.
  , rcProbe :: !Bool
  -- ^ Whether to print probe diagnostics each turn.
  }

-- | @RunConfig::default()@ — probe on, 50 ms idle poll.
defaultRunConfig :: RunConfig
defaultRunConfig = RunConfig {rcIdlePollMs = 50, rcProbe = True}

-- * Turn

-- | One pump cycle's outcome, mirroring @abstracttui::app::Turn@.
data Turn = Turn
  { turnEvents :: !Int
  -- ^ Number of input / wake events fired this turn.
  , turnRendered :: !Bool
  -- ^ A new frame was rasterized (always true — the manual driver
  -- samples and updates the display every turn).
  , turnEmitted :: !Bool
  -- ^ The frame produced non-zero bytes (the picture changed or a full
  -- redraw was requested). Derived from the bytes the mock output
  -- received this frame.
  , turnQuit :: !Bool
  -- ^ The quitter flipped — break the loop.
  , turnIdle :: !Bool
  -- ^ Nothing happened this turn (no input, no wake, no emitted bytes).
  }

-- * Driver

-- | The Spider-specific host integration state. Holds the 'VtyResult' (its
-- '_vtyResult_picture' behavior is sampled each turn), the 'FireCommand'
-- (used to fire the post-build trigger on the first turn), the post-build
-- trigger ref, the input trigger ref (Task 9's 'feedInput' writes to it),
-- the shutdown subscription, and the capture terminal.
data Driver = Driver
  { drApp :: !App
  , drTerm :: !CaptureTerm
  , drCfg :: !RunConfig
  , drVtyResult :: !(VtyResult Spider)
  , drFire :: !(FireCommand Spider (SpiderHost Global))
  , drPostBuildTrigger :: !(IORef (Maybe (EventTrigger Spider ())))
  , drVtyEventTrigger :: !(IORef (Maybe (EventTrigger Spider V.Event)))
  , drShutdown :: !(EventHandle Spider ())
  , drFirstTurn :: !(IORef Bool)
  }

-- | Build a driver. Replicates 'Reflex.Vty.Host.runVtyAppWithHandle' lines
-- 147-220: creates the input / post-build / signal events, builds the guest
-- (the widget-context stack with 'appView's builder as the child) in
-- @hostPerformEventT . runPostBuildT . runTriggerEventT@, subscribes to
-- shutdown, and stores everything in 'Driver'. The first 'turn' fires
-- post-build and renders.
--
-- We use reflex's public 'runTriggerEventT' instead of reflex-vty's internal
-- 'runBoundedTriggerT' (which is not exported by reflex-vty 1.2.0.0 — it
-- lives in the hidden "Reflex.Vty.Host.Trigger" module). For Task 8 (no
-- external triggers) the bounded queue is unused, so the unbounded
-- 'TriggerEventT' with a dummy 'Chan' is equivalent; Task 9 will revisit if
-- backpressure is needed.
newDriver :: App -> CaptureTerm -> RunConfig -> IO Driver
newDriver app term cfg =
  (runSpiderHost :: SpiderHost Global Driver -> IO Driver) $ do
    (vtyEvent, vtyEventTriggerRef) <- newEventWithTriggerRef
    (postBuild, postBuildTriggerRef) <- newEventWithTriggerRef
    (signalEvent, _signalTriggerRef) <- newEventWithTriggerRef
    chan <- liftIO newChan
    displayRegion0 <-
      liftIO $ V.displayBounds (V.outputIface (ctVty term))
    mView <- liftIO (readIORef (appViewRef app))
    (vtyResult, fc) <-
      hostPerformEventT $
        flip runPostBuildT postBuild $
          flip runTriggerEventT chan $
            vtyGuest
              displayRegion0
              vtyEvent
              signalEvent
              ( case mView of
                  Just (AppView f) -> f
                  Nothing ->
                    error "newDriver: app has no mounted view (call appMount first)"
              )
    shutdown <- subscribeEvent (_vtyResult_shutdown vtyResult)
    firstTurn <- liftIO (newIORef True)
    pure
      Driver
        { drApp = app
        , drTerm = term
        , drCfg = cfg
        , drVtyResult = vtyResult
        , drFire = fc
        , drPostBuildTrigger = postBuildTriggerRef
        , drVtyEventTrigger = vtyEventTriggerRef
        , drShutdown = shutdown
        , drFirstTurn = firstTurn
        }

-- | The reflex-vty guest: set up the (minimal) widget-context stack and
-- run the app's view-builder as the child widget. The picture is
-- @picForLayers (reverse images)@ — the background fill is told first, the
-- child's images on top, matching 'Reflex.Vty.Widget.mainWidgetWithHandle'.
-- Task 8 uses a simplified stack (Theme/DisplayRegion/ImageWriter/NodeId/Input);
-- Task 9 will widen it (Cursor/ScreenMode/Focus/ColorProfile) as needed.
vtyGuest
  :: forall t m.
     ( MonadVtyApp t m
     )
  => V.DisplayRegion
  -> Event t V.Event
  -> Event t AppSignal
  -> ( forall m'
        . ( Reflex t
          , HasImageWriter t m'
          , HasDisplayRegion t m'
          , HasTheme t m'
          , HasInput t m'
          )
       => Scope t m' -> m' (View t)
     )
  -> m (VtyResult t)
vtyGuest dr0 vtyEvent signalEvent viewBuilder = do
  -- Fixed display size for Task 8 (no resize handling); the size stays at
  -- the capture terminal's initial bounds for the lifetime of the app.
  size <- holdDyn dr0 never
  let inp' = vtyEvent
      sigShutdown =
        () <$
          ffilter
            (\s -> s == AppSignal_Interrupt || s == AppSignal_Terminate || s == AppSignal_Hangup)
            signalEvent
  (shutdown, images) <-
    runThemeReader (pure defTheme) $
      runDisplayRegion (fmap (\(w, h) -> Region 0 0 w h) size) $
        runImageWriter $
          runNodeIdT $
            runInput inp' $ do
              tellImages . ffor (current size) $ \(w, h) -> [V.charFill V.defAttr ' ' w h]
              view <- viewBuilder (Scope ())
              unView view
  pure
    VtyResult
      { _vtyResult_picture =
          (\imgs -> V.picForLayers (reverse imgs)) <$> images
      , _vtyResult_shutdown = leftmost [shutdown, sigShutdown]
      }

-- | Run one pump cycle. Mirrors one iteration of Host.hs lines 265-289, but
-- driven manually per turn instead of blocking on the event queue:
--
-- 1. On the first turn, fire the post-build trigger (line 208-213 pattern)
--    so the guest's 'current'/'getPostBuild' widgets initialize.
-- 2. Render: sample the 'Picture' behavior and call 'V.update' (line
--    200-201), which records the picture and the emitted bytes on the
--    capture terminal.
-- 3. Drain the capture terminal's emitted bytes to set 'turnEmitted'.
-- 4. Read the quit flag for 'turnQuit'.
--
-- Task 8 has no input, so the bounded event queue is not drained here
-- (Task 9's 'feedInput' will post events and wire the batch firing).
turn :: Driver -> IO Turn
turn dr =
  (runSpiderHost :: SpiderHost Global Turn -> IO Turn) $ do
    let FireCommand fire = drFire dr
        vtyResult = drVtyResult dr
        term = drTerm dr
    isFirst <- liftIO (readIORef (drFirstTurn dr))
    -- First turn: fire post-build so the guest's post-build / current
    -- behaviors initialize (Host.hs lines 205-213).
    when isFirst $ do
      mPB <- readRef (drPostBuildTrigger dr)
      forM_ mPB $ \pb -> fire [pb :=> Identity ()] (return ())
      liftIO (writeIORef (drFirstTurn dr) False)
    -- Render: sample the picture and update the (mock) vty. The mock's
    -- 'update' records the picture for 'captureCell' and forwards to the
    -- real renderer, whose bytes land in 'ctEmitted' for 'captureEmit'.
    pic <- sample (_vtyResult_picture vtyResult)
    liftIO $ V.update (ctVty term) pic
    -- Drain this frame's emitted bytes to compute turnEmitted.
    emitted <- liftIO (readIORef (ctEmitted term))
    liftIO (writeIORef (ctEmitted term) BS.empty)
    quit <- liftIO (quitterCheck (appQuit (drApp dr)))
    pure
      Turn
        { turnEvents = if isFirst then 1 else 0
        , turnRendered = True
        , turnEmitted = not (BS.null emitted)
        , turnQuit = quit
        , turnIdle = not isFirst && BS.null emitted && not quit
        }