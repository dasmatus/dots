{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeOperators #-}

{- | abstracttui-shaped reactive shim over Reflex.

'Signal' is a Reflex 'Dynamic' paired with a mirror 'IORef' and an
'EventTrigger' ref. The tricky part is that the bins allocate 'Signal's
inside the view-builder closure, which runs in the reflex-vty widget stack
— and that stack lifts Reflex's own classes ('MonadHold'/
'MonadReflexCreateTrigger'/'MonadSample') but NOT ref-tf's 'MonadRef'. So
'newEventWithTriggerRef' (which needs 'MonadRef') cannot run in the widget
stack; it can only run in the bare 'SpiderHost'.

The bridge is a 'TriggerFactory' stored in 'Scope': the 'Driver' creates it
in the bare host (@'runSpiderHost' 'newEventWithTriggerRef'@) and 'signal'
invokes it from the closure via 'liftIO'. That nested 'runSpiderHost' call
only /allocates/ an event + trigger-ref (no frame processing), which is
safe under Reflex's shared 'Global' timeline. 'signal's closure constraints
stay minimal ('MonadHold'+'MonadIO'), while mutation stays synchronous via
'fireEventRef' in the host frame.

Key-handler closures run inside 'performEvent_' whose 'Performable m ~ IO'
for the Spider host. They cannot fire 'Signal' triggers directly
('fireEventRef' needs the host monad, not 'IO'), so 'Signal' also carries a
@sigQueue@ of pending final values: 'sigSetIO'/'sigUpdateIO' (IO-callable)
append to it, and the 'Driver.turn' collects the queued values as
'EventTrigger' assignments ('drainScopeTriggers') and fires them through
the host's 'FireCommand' — the same path reflex-vty's own loop uses
('Reflex.Vty.Host' 'fireEventTriggerRefs') — so the 'Dynamic' and the
downstream push-'Behavior's ('tellImages' \/ the picture) update in the
same host frame, before render. 'fireEventRef' alone is NOT enough here: it
fires the trigger but bypasses the 'hostPerformEventT' frame, so the
'BehaviorWriter' merge that feeds the picture keeps its last-frame cache.
See the project memory note on signal-mutation-from-IO-handlers.
-}
module AbstractTUI.Reactive (
    Signal (..),
    Scope,
    TriggerFactory (..),
    newScope,
    signal,
    sigGet,
    sigGetUntracked,
    sigSet,
    sigUpdate,
    sigSetIO,
    sigUpdateIO,
    sigWith,
    sigWithUntracked,
    sigReadRef,
    drainScopeTriggers,
    wakeHandle,
    requestFrame,
    afterMs,
) where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Ref (MonadRef, Ref (..))
import Data.Dependent.Sum (DSum ((:=>)))
import Data.Functor.Identity (Identity (..))
import Data.IORef (
    IORef,
    atomicModifyIORef',
    newIORef,
    readIORef,
    writeIORef,
 )
import Data.Kind (Type)
import Reflex (
    Dynamic,
    Event,
    MonadHold,
    MonadSample,
    Reflex,
    TriggerEvent,
    current,
    holdDyn,
    newTriggerEvent,
    sample,
 )
import Reflex.Host.Class (
    EventTrigger,
    MonadReflexHost,
    fireEventRef,
 )

{- | A host-supplied factory that allocates a fresh triggerable 'Event' plus
its 'EventTrigger' ref from 'IO'. The 'Driver' constructs this in the bare
'SpiderHost' (where 'MonadRef' is available) and stores it in 'Scope';
'signal' invokes it from the widget-stack closure via 'liftIO' (a nested
'runSpiderHost' that only allocates — no frame processing — safe under the
shared 'Global' timeline). The @forall a@ makes one factory serve signals
of any element type.
-}
newtype TriggerFactory t = TriggerFactory
    { runTriggerFactory :: forall a. IO (Event t a, IORef (Maybe (EventTrigger t a)))
    }

{- | abstracttui's 'Signal' is a Reflex 'Dynamic' whose value can be
mutated. @sigRef@ mirrors the current value; @sigTrig@ is the
'newEventWithTriggerRef' trigger ref that 'fireEventRef' fires to push a
new occurrence through the 'Dynamic'; @sigQueue@ collects final values
queued by IO-context handlers ('sigSetIO'/'sigUpdateIO') for 'drainScope'
to fire.
-}
data Signal t a = Signal
    { sigRef :: !(IORef a)
    , sigTrig :: !(IORef (Maybe (EventTrigger t a)))
    , sigQueue :: !(IORef [a])
    , sigDyn :: !(Dynamic t a)
    }

{- | An existentially-quantified 'Signal' so the registry can hold signals of
different element types. Pattern-matching brings the element type into
scope for firing.
-}
data SomeSignal t where
    SomeSignal :: Signal t a -> SomeSignal t

{- | abstracttui's 'Scope': the reactive context. Carries the 'Signal'
registry that 'drainScope' iterates and the 'TriggerFactory' that 'signal'
uses to allocate events. The type parameter @t@ is the Reflex timeline;
there is no @m@ parameter (the capabilities come from the caller's monad
constraint context, not from 'Scope').
-}
data Scope t = Scope
    { scopeRegistry :: !(IORef [SomeSignal t])
    , scopeFactory :: !(TriggerFactory t)
    }

{- | Allocate a 'Scope' with the host-supplied 'TriggerFactory'. Called once
by the 'Driver' and shared between the view-builder (which allocates
'Signal's into it) and 'turn' (which 'drainScope's it).
-}
newScope :: TriggerFactory t -> IO (Scope t)
newScope tf = Scope <$> newIORef [] <*> pure tf

{- | Allocate a settable 'Signal' at @initial@. Allocates the underlying
'Event' + trigger ref via the 'Scope's 'TriggerFactory' (a nested
'runSpiderHost' call under 'liftIO' — allocation only), then 'holdDyn's it
into a 'Dynamic'. Mutation ('sigSet'/'sigUpdate' directly, or
'sigSetIO'/'sigUpdateIO' + 'drainScope') fires the trigger synchronously
via 'fireEventRef', propagating to the 'Dynamic' and downstream in the same
host frame. The 'Signal' registers itself in the 'Scope' so 'drainScope'
can find it.
-}
signal ::
    forall a t m.
    (MonadHold t m, MonadIO m) =>
    a ->
    Scope t ->
    m (Signal t a)
signal initial (Scope reg tf) = do
    ref <- liftIO (newIORef initial)
    q <- liftIO (newIORef [])
    (e, trigRef) <- liftIO (runTriggerFactory tf)
    d <- holdDyn initial e
    let s = Signal ref trigRef q d
    liftIO (atomicModifyIORef' reg (\ss -> (SomeSignal s : ss, ())))
    pure s

{- | Read the current value of a 'Signal' by sampling its underlying
'Dynamic'. This observes the value as of the last processed host frame.
-}
sigGet ::
    (Reflex t, MonadSample t m) =>
    Signal t a ->
    m a
sigGet (Signal _ _ _ d) = sample (current d)

{- | Read the current value without subscribing to changes. In abstracttui the
tracked/untracked distinction matters because a tracked read inside a
'dyn_view' subscribes the view to that signal; an untracked read peeks
without re-rendering on change. Under our Reflex shim a 'sample (current d)'
is already an untracked read (it does not create an 'Event' subscription),
so 'sigGetUntracked' is observationally the same as 'sigGet' — kept as a
separate name so ports read faithfully. The bins use it for one-shot peeks
(e.g. @should_quit@, @start_install@) inside the loop body.
-}
sigGetUntracked ::
    (Reflex t, MonadSample t m) =>
    Signal t a ->
    m a
sigGetUntracked = sigGet

{- | Sample a 'Signal' and apply a function to its current value. Mirrors
abstracttui's @Signal::with@ / @with_untracked@ — the installer and
wallpaper ports use these /exclusively/ (never 'sigGet'/'sigSet') to read
signal-derived state inside a 'dyn_view' closure.
-}
sigWith ::
    (Reflex t, MonadSample t m) =>
    Signal t a ->
    (a -> r) ->
    m r
sigWith s f = f <$> sigGet s

{- | 'sigWith' without subscribing. Observationally equal to 'sigWith' under
the Reflex shim (see 'sigGetUntracked'); kept for faithful porting.
-}
sigWithUntracked ::
    (Reflex t, MonadSample t m) =>
    Signal t a ->
    (a -> r) ->
    m r
sigWithUntracked = sigWith

{- | Read the mirror 'IORef' directly (no 'Dynamic' sample). Used by tests and
by one-shot peeks that want the latest queued write even before the host
has processed the corresponding 'fireEventRef'.
-}
sigReadRef :: Signal t a -> IO a
sigReadRef (Signal ref _ _ _) = readIORef ref

{- | Synchronous overwrite from the host monad. Writes the mirror 'IORef' and
fires the trigger ref via 'fireEventRef' so the 'Dynamic' (and downstream
'tellImages' behaviors) update in this same host frame. Used by
'drainScope' and by tests; the bins' key handlers use 'sigSetIO' instead
(they run in 'IO' under 'performEvent_').
-}
sigSet ::
    ( MonadReflexHost t m
    , MonadRef m
    , Ref m ~ Ref IO
    , MonadIO m
    ) =>
    Signal t a ->
    a ->
    m ()
sigSet (Signal ref trigRef _ _) x = do
    liftIO (writeIORef ref x)
    fireEventRef trigRef x

{- | Synchronous update from the host monad. Computes the new value against
the mirror 'IORef', writes it back, and fires it via 'fireEventRef'.
-}
sigUpdate ::
    ( MonadReflexHost t m
    , MonadRef m
    , Ref m ~ Ref IO
    , MonadIO m
    ) =>
    Signal t a ->
    (a -> a) ->
    m ()
sigUpdate (Signal ref trigRef _ _) f = do
    v <- liftIO (readIORef ref)
    let v' = f v
    liftIO (writeIORef ref v')
    fireEventRef trigRef v'

{- | IO-callable overwrite for use inside 'performEvent_' handlers (which run
in 'Performable m ~ IO'). Writes the mirror 'IORef' and appends the final
value to the queue; 'drainScopeTriggers' fires it next. The 'Dynamic'
reflects the new value after the 'Driver.turn' fires the trigger through
the host's 'FireCommand' (same turn, before render).
-}
sigSetIO :: Signal t a -> a -> IO ()
sigSetIO (Signal ref _ q _) x = do
    writeIORef ref x
    atomicModifyIORef' q (\xs -> (x : xs, ()))

{- | IO-callable update for 'performEvent_' handlers. Computes the new value
against the mirror 'IORef', writes it back, and queues it for
'drainScopeTriggers'.
-}
sigUpdateIO :: Signal t a -> (a -> a) -> IO ()
sigUpdateIO (Signal ref _ q _) f = do
    v <- readIORef ref
    let v' = f v
    writeIORef ref v'
    atomicModifyIORef' q (\xs -> (v' : xs, ()))

{- | Collect every 'Signal' in the 'Scope' that has a pending queued value and
return its latest value (the head of the prepend-list) as an
@'EventTrigger' :=> 'Identity' value@ assignment, clearing the queue.
Multiple queues per signal collapse to the last write (matching 'holdDyn'
keeping the last occurrence in a frame). The 'Driver.turn' fires the
returned assignments through the host's 'FireCommand' — the same path
reflex-vty's own loop uses ('Reflex.Vty.Host' 'fireEventTriggerRefs') —
which drives a full 'hostPerformEventT' frame so the 'Dynamic' /and/ the
downstream push-'Behavior's ('tellImages' \/ the picture) refresh before
render. 'fireEventRef' is deliberately NOT used here: it fires the trigger
but skips the frame, leaving the 'BehaviorWriter' merge on its last-frame
cache. One pass per turn — a signal→handler→signal chain does not recurse
within a single turn (no bin needs it).
-}
drainScopeTriggers :: Scope t -> IO [DSum (EventTrigger t) Identity]
drainScopeTriggers (Scope reg _) = do
    ss <- readIORef reg
    concat <$> traverse drainOne ss
  where
    drainOne (SomeSignal (Signal _ trigRef q _)) = do
        xs <- readIORef q
        case xs of
            [] -> pure []
            (x : _) -> do
                writeIORef q []
                mt <- readIORef trigRef
                pure $ case mt of
                    Nothing -> []
                    Just tr -> [tr :=> Identity x]

{- | Create a triggerable 'Event' for external wakes. The returned fire
callback (@a -> IO ()@) schedules an occurrence from 'IO' (e.g. another
thread); the host loop drains it into a frame. This wraps Reflex's
'newTriggerEvent' (a 'TriggerEvent' method): unlike 'Signal's
trigger-ref (fired synchronously by 'fireEventRef' in the host monad), the
fire here is async (chan-scheduled) and safe to call from 'IO'.
'wakeHandle' is the external-wake bridge (e.g. a spinner self-rescheduling
timer). NOTE: the reflex-vty driver's manual 'turn' does not yet drain the
'TriggerEvent' chan, so an external fire will not propagate until that loop
is wired — none of the three ports use 'wakeHandle' yet, so this is staged
for when a bin needs it.
-}
wakeHandle ::
    (TriggerEvent t m) =>
    Scope t ->
    m (Event t a, a -> IO ())
wakeHandle _ = newTriggerEvent

{- | Request an immediate redraw of the current frame. In abstracttui the
loop only redraws on an explicit request, so @requestFrame()@ sets a dirty
flag the next loop tick observes. Under our reflex-vty driver the manual
'AbstractTUI.Driver.turn' re-samples the 'Picture' behavior and calls
'V.update' every turn unconditionally, so there is no dirty flag to set:
'requestFrame' is a deliberate no-op, kept so ports read faithfully.
-}
requestFrame :: (Applicative m) => Scope t -> m ()
requestFrame _ = pure ()

{- | Run an action after @ms@ milliseconds. NOT YET wired to a host-thread
bridge under the reflex-vty driver (that belongs to a later task if a bin
needs it); none of the three ports currently call it, so this stub keeps
the port's API surface faithful without paying for the bridge. The action
runs synchronously now — callers must not rely on the delay yet.
-}
afterMs :: Int -> m () -> m ()
afterMs _ io = io
