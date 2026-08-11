{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TypeOperators #-}
-- | abstracttui-shaped reactive shim over Reflex.
--
-- 'Signal' is a Reflex 'Dynamic' paired with a trigger ref so that
-- 'sigSet'/'sigUpdate' can mutate it synchronously from within a Reflex host
-- frame (via 'fireEventRef'). 'Scope' is, for now, a trivial marker for the
-- reactive context; later tasks (Task 8) extend it with the widget env.
--
-- The library is host-agnostic: it depends only on the abstract
-- "Reflex.Host.Class" / "Reflex.TriggerEvent.Class" interfaces, never on
-- "Reflex.Spider". The Spider-host runner lives in the test suite.
module AbstractTUI.Reactive
  ( Signal (..)
  , Scope (..)
  , signal
  , sigGet
  , sigSet
  , sigUpdate
  , wakeHandle
  ) where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Ref (MonadRef, Ref)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Kind (Type)
import Reflex
  ( Dynamic
  , Event
  , MonadHold
  , MonadSample
  , Reflex
  , TriggerEvent
  , current
  , holdDyn
  , newTriggerEvent
  , sample
  )
import Reflex.Host.Class
  ( EventTrigger
  , MonadReflexCreateTrigger
  , MonadReflexHost
  , fireEventRef
  , newEventWithTriggerRef
  )

-- | abstracttui's 'Signal' is a Reflex 'Dynamic' whose value can be
-- imperatively mutated. The 'IORef' mirrors the current value so the
-- latest write is observable; the trigger ref fires the event that drives
-- the 'Dynamic' (and any downstream subscribers) synchronously inside the
-- host frame.
data Signal t a = Signal
  { sigRef  :: !(IORef a)
  , sigTrig :: !(IORef (Maybe (EventTrigger t a)))
  , sigDyn  :: !(Dynamic t a)
  }

-- | abstracttui's 'Scope': the reactive context. Carries no data yet — the
-- reactive capabilities ('MonadHold'/'MonadReflexCreateTrigger'/'MonadIO')
-- come from the 'm' monad's constraint context, not from 'Scope' itself.
-- Later tasks extend this with the widget env.
newtype Scope t (m :: Type -> Type) = Scope ()

-- | Allocate a settable 'Signal' at @initial@. The underlying 'Dynamic' is
-- driven by a trigger event whose fire is held in the 'Signal'; mutating it
-- ('sigSet'/'sigUpdate') propagates synchronously within the host frame.
signal
  :: ( MonadReflexCreateTrigger t m
     , MonadHold t m
     , MonadRef m
     , Ref m ~ Ref IO
     , MonadIO m
     )
  => a
  -> Scope t m
  -> m (Signal t a)
signal initial _ = do
  ref <- liftIO (newIORef initial)
  (e, trigRef) <- newEventWithTriggerRef
  d <- holdDyn initial e
  pure (Signal ref trigRef d)

-- | Read the current value of a 'Signal' by sampling its underlying
-- 'Dynamic'.
sigGet
  :: (Reflex t, MonadSample t m)
  => Signal t a
  -> m a
sigGet (Signal _ _ d) = sample (current d)

-- | Overwrite a 'Signal'. Writes the mirror 'IORef' and fires the trigger,
-- so the 'Dynamic' (and downstream) update synchronously in the host frame.
sigSet
  :: ( MonadReflexHost t m
     , MonadRef m
     , Ref m ~ Ref IO
     , MonadIO m
     )
  => Signal t a
  -> a
  -> m ()
sigSet (Signal ref trigRef _) x = do
  liftIO (writeIORef ref x)
  fireEventRef trigRef x

-- | Apply a function to a 'Signal' and fire the new value.
sigUpdate
  :: ( MonadReflexHost t m
     , MonadRef m
     , Ref m ~ Ref IO
     , MonadIO m
     )
  => Signal t a
  -> (a -> a)
  -> m ()
sigUpdate (Signal ref trigRef _) f = do
  v' <- liftIO $ do
    v <- readIORef ref
    let v' = f v
    writeIORef ref v'
    pure v'
  fireEventRef trigRef v'

-- | Create a triggerable 'Event' for external wakes. The returned fire
-- callback (@a -> IO ()@) schedules an occurrence from 'IO' (e.g. another
-- thread); the host loop (Task 8 Driver) drains it into a frame. This wraps
-- Reflex's 'newTriggerEvent'. Unlike 'signal'/'sigSet' (which fire
-- synchronously within a host frame), 'wakeHandle' is the
-- external-wake bridge and is processed by the driver's event loop.
wakeHandle
  :: TriggerEvent t m
  => Scope t m
  -> m (Event t a, a -> IO ())
wakeHandle _ = newTriggerEvent