module Main (main) where

import qualified Data.ByteString as BS
import Data.Function ((&))

import AbstractTUI.Base.Geom (size)
import AbstractTUI.Driver
  ( RunConfig (..)
  , Turn (..)
  , appMount
  , appQuitter
  , defaultRunConfig
  , newApp
  , newDriver
  , quitterQuit
  , requestFullRedraw
  , turn
  )
import AbstractTUI.Testing.Capture
  ( captureCell
  , drainOutput
  , feedInput
  , newCaptureTerm
  , parseScreen
  , vtChar
  )
import AbstractTUI.View
  ( Key (..)
  , buildE
  , child
  , element
  , plainChord
  , shortcut
  , text
  )
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@=?))

main :: IO ()
main =
  defaultMain $
    testGroup
      "smoke"
      [ testCase "paint text lands at (0,0)" $ do
          app <- newApp (size 10 1)
          appMount app (\_ -> pure (text "hi"))
          term <- newCaptureTerm 10 1
          dr <- newDriver app term defaultRunConfig {rcIdlePollMs = 0}
          _ <- turn dr
          'h' @=? captureCell term 0 0
          'i' @=? captureCell term 1 0
      , testCase "capture round-trip" $ do
          app <- newApp (size 20 3)
          appMount app (\_ -> pure (text "hello"))
          term <- newCaptureTerm 20 3
          dr <- newDriver app term defaultRunConfig {rcIdlePollMs = 0}
          t1 <- turn dr
          bs <- drainOutput term
          let scr = parseScreen 20 3 bs
          'h' @=? vtChar scr 0 0
          True @=? turnEmitted t1
      , testCase "full redraw contract" $ do
          app <- newApp (size 12 2)
          appMount app (\_ -> pure (text "frame"))
          term <- newCaptureTerm 12 2
          dr <- newDriver app term defaultRunConfig {rcIdlePollMs = 0}
          _ <- turn dr
          f1 <- drainOutput term
          -- Idle turn: nothing changed -> the per-row diff is empty.
          _ <- turn dr
          fIdle <- drainOutput term
          requestFullRedraw dr
          _ <- turn dr
          f3 <- drainOutput term
          assertBool "f1 should be non-null" (not (BS.null f1))
          assertBool "fIdle should be null" (BS.null fIdle)
          assertBool "f3 should be non-null" (not (BS.null f3))
      , testCase "shortcut quit" $ do
          app <- newApp (size 12 2)
          let q = appQuitter app
          appMount
            app
            ( \_ ->
                pure
                  ( buildE
                      ( element
                          & shortcut (plainChord (KeyChar 'q')) (quitterQuit q)
                          & child (text "press q")
                      )
                  )
            )
          term <- newCaptureTerm 12 2
          dr <- newDriver app term defaultRunConfig {rcIdlePollMs = 0}
          _ <- turn dr -- render the first frame
          _ <- drainOutput term
          feedInput term [113] -- 'q'
          t <- turn dr
          True @=? turnQuit t
      ]