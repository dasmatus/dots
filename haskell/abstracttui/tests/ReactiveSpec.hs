{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

{- | Tests for the abstracttui 'Scope'/'Signal' Reflex shim. The Spider-host
runner ('runScopeSpider') lives here so the library stays host-agnostic.

These cover the synchronous host-monad mutation path ('sigSet'/'sigUpdate'
fire 'fireEventRef' and the 'Dynamic' updates immediately) and 'signal'
initial value. The full same-turn IO-handler path (handler queues via
'sigSetIO' → 'Driver.turn' collects the trigger via 'drainScopeTriggers'
and fires it through the host's 'FireCommand' → 'Dynamic' → 'tellImages'
→ picture) is exercised end-to-end by "ElementSpec"'s @onEvent signal
mutation lands same-turn@ test through the real 'Driver'.
-}
module Main (main) where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Ref (MonadRef, Ref)
import Data.IORef (IORef)
import Data.Kind (Type)
import Reflex (Event, MonadHold, MonadSample)
import Reflex.Host.Class (EventTrigger, MonadReflexCreateTrigger, MonadReflexHost, newEventWithTriggerRef)
import Reflex.Spider (Spider, runSpiderHost)
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit (testCase, (@=?))

import AbstractTUI.Reactive (
    Scope,
    TriggerFactory (..),
    newScope,
    sigGet,
    sigSet,
    sigUpdate,
    signal,
 )

main :: IO ()
main =
    defaultMain $
        testGroup
            "reactive"
            [ testCase "signal get/set round-trip" $
                runScopeSpider $ \scope -> do
                    s <- signal (0 :: Int) scope
                    v0 <- sigGet s
                    liftIO (0 @=? v0)
                    sigSet s 42
                    v1 <- sigGet s
                    liftIO (42 @=? v1)
            , testCase "sigUpdate mutates" $
                runScopeSpider $ \scope -> do
                    s <- signal (10 :: Int) scope
                    sigUpdate s (+ 5)
                    v <- sigGet s
                    liftIO (15 @=? v)
            ]

{- | Run a 'Scope'-parameterised action in the Reflex Spider host. Provides
the host-monad capabilities 'signal'/'sigSet'/'sigUpdate' need
('MonadHold'/'MonadReflexHost'/'MonadRef'/'Ref m ~ Ref IO'/'MonadSample'/
'MonadIO'). The 'TriggerFactory' is the same nested-'runSpiderHost'
allocator the 'Driver' uses, so 'signal' here exercises the real allocation
path.
-}
runScopeSpider ::
    ( forall (m :: Type -> Type).
      ( MonadHold Spider m
      , MonadReflexHost Spider m
      , MonadSample Spider m
      , MonadRef m
      , Ref m ~ Ref IO
      , MonadIO m
      ) =>
      Scope Spider -> m a
    ) ->
    IO a
runScopeSpider act = do
    let triggerIO :: forall a. IO (Event Spider a, IORef (Maybe (EventTrigger Spider a)))
        triggerIO = runSpiderHost newEventWithTriggerRef
    scope' <- newScope (TriggerFactory triggerIO)
    runSpiderHost (act scope')
