{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}

-- | Shared helpers for the integration tests: the headless render harness
-- ('renderToString' / 'renderWithFx'), an hermetic env-var bracket, and the
-- embedded lsblk fixture. Faithful Haskell port of @rust/installer-tui/tests@.
module Common
  ( withEnv
  , renderToString
  , renderWithFx
  , cellsToString
  , fixtureLsblk
  ) where

import Control.Exception (bracket)
import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import System.Environment (lookupEnv, setEnv, unsetEnv)

import AbstractTUI.Anim (clockFixed)
import AbstractTUI.Base.Geom (size)
import AbstractTUI.Driver
  ( RunConfig (..)
  , appMount
  , defaultRunConfig
  , newApp
  , newDriver
  , turn
  )
import AbstractTUI.Reactive (Signal, signal)
import AbstractTUI.Testing.Capture (CaptureTerm, captureCell, newCaptureTerm)

import Dots.Installer.App (App)
import Dots.Installer.Fx (ScreenFx, screenFxNew)
import Dots.Installer.Ui (rootView)

-- | Existential wrapper so the mount closure (polymorphic in @t@) can publish
-- the 'Signal' 'ScreenFx' to the test body. 'sigReadRef'\/'sigSetIO' are
-- polymorphic in @t@, so the test drives the fx without ever naming @t@.
data SomeFxSig = forall t. SomeFxSig (Signal t ScreenFx)

-- | Run an action with @name@ set to @val@ (or unset), restoring the previous
-- value afterwards. Hermetic so the env-gate tests do not bleed into the rest
-- of the suite (tests run in parallel threads sharing one process env).
withEnv :: String -> Maybe String -> IO a -> IO a
withEnv name val action =
  bracket
    ( do
        old <- lookupEnv name
        case val of
          Just v -> setEnv name v
          Nothing -> unsetEnv name
        pure old
    )
    (\old -> maybe (unsetEnv name) (setEnv name) old)
    (const action)

-- | Render @app@ at @cols×rows@ and return the concatenated cell text, one row
-- per line. Pumps one frame into a 'CaptureTerm' via the engine 'Driver'.
renderToString :: App -> Int -> Int -> IO String
renderToString app cols rows = renderWithFx app (\_ -> pure ()) cols rows

-- | Like 'renderToString' but also hands the mounted 'Signal' 'ScreenFx' to an
-- action, then re-pumps one frame so the mutation lands on screen (used by the
-- shake test to fire + advance the fx before render).
renderWithFx ::
  App ->
  (forall t. Signal t ScreenFx -> IO ()) ->
  Int ->
  Int ->
  IO String
renderWithFx app driveFx cols rows = do
  fxRef <- newIORef (Nothing :: Maybe SomeFxSig)
  eng <- newApp (size cols rows)
  appMount eng $ \scope -> do
    a <- signal app scope
    clock <- liftIO clockFixed
    fx0 <- liftIO (screenFxNew clock)
    f <- signal fx0 scope
    liftIO (writeIORef fxRef (Just (SomeFxSig f)))
    pure (rootView a f)
  term <- newCaptureTerm cols rows
  dr <- newDriver eng term defaultRunConfig{rcProbe = False}
  _ <- turn dr
  Just (SomeFxSig f) <- readIORef fxRef
  driveFx f
  _ <- turn dr
  cellsToString term cols rows

-- | Concatenate every cell into a string, one row per line. Empty cells become
-- a space (vty's blank).
cellsToString :: CaptureTerm -> Int -> Int -> IO String
cellsToString term cols rows = do
  rows' <- mapM row [0 .. rows - 1]
  pure (unlines rows')
  where
    row y = concat <$> mapM (\x -> (: []) <$> captureCell term x y) [0 .. cols - 1]

-- | The lsblk fixture from @rust/installer-tui/tests/fixtures/lsblk.json@,
-- embedded so the test doesn't depend on the working directory.
fixtureLsblk :: String
fixtureLsblk =
  unlines
    [ "{"
    , "   \"blockdevices\": ["
    , "      {\"name\":\"nvme0n1\",\"path\":\"/dev/nvme0n1\",\"size\":512110190592,\"model\":\"Samsung SSD 980\",\"rm\":false,\"type\":\"disk\",\"ro\":false},"
    , "      {\"name\":\"sda\",\"path\":\"/dev/sda\",\"size\":15931539456,\"model\":\"USB Flash\",\"rm\":\"1\",\"type\":\"disk\",\"ro\":false},"
    , "      {\"name\":\"zram0\",\"path\":\"/dev/zram0\",\"size\":4294967296,\"model\":null,\"rm\":false,\"type\":\"disk\",\"ro\":false},"
    , "      {\"name\":\"sr0\",\"path\":\"/dev/sr0\",\"size\":800000000,\"model\":\"QEMU DVD-ROM\",\"rm\":true,\"type\":\"rom\",\"ro\":false},"
    , "      {\"name\":\"loop0\",\"path\":\"/dev/loop0\",\"size\":1000000,\"model\":null,\"rm\":false,\"type\":\"loop\",\"ro\":true},"
    , "      {\"name\":\"vda\",\"path\":\"/dev/vda\",\"size\":42949672960,\"model\":null,\"rm\":false,\"type\":\"disk\",\"ro\":true}"
    , "   ]"
    , "}"
    ]