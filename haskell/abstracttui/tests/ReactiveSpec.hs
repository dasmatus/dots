{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
-- | Tests for the abstracttui 'Scope'/'Signal' Reflex shim. The Spider-host
-- runner ('runScopeSpider') lives here so the library stays host-agnostic.
module Main (main) where

import AbstractTUI.Reactive
  ( Scope (..)
  , signal
  , sigGet
  , sigSet
  , sigUpdate
  )
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Ref (MonadRef, Ref)
import Data.Kind (Type)
import Reflex (MonadHold, MonadSample)
import Reflex.Host.Class (MonadReflexHost)
import Reflex.Spider (runSpiderHost)
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit ((@=?), testCase)

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

-- | Run a 'Scope'-parameterised action in the Reflex Spider host. The
-- 'Scope' is a trivial marker for now; the reactive capabilities come from
-- the 'SpiderHost' constraint context.
runScopeSpider
  :: ( forall t (m :: Type -> Type)
     . ( MonadHold t m
       , MonadReflexHost t m
       , MonadSample t m
       , MonadRef m
       , Ref m ~ Ref IO
       , MonadIO m
       )
     => Scope t m -> m a
     )
  -> IO a
runScopeSpider act = runSpiderHost (act (Scope ()))