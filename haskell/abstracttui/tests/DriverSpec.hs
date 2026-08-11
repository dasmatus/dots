module Main (main) where

import AbstractTUI.Base.Geom (size)
import AbstractTUI.Driver
  ( appMount
  , defaultRunConfig
  , newApp
  , newDriver
  , turn
  )
import AbstractTUI.Term (captureCell, newCaptureTerm)
import AbstractTUI.View (text)
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit ((@=?), testCase)

main :: IO ()
main =
  defaultMain $
    testGroup
      "driver"
      [ testCase "render text lands at (0,0)" $ do
          app <- newApp (size 10 1)
          appMount app (\_ -> pure (text "hi"))
          term <- newCaptureTerm 10 1
          dr <- newDriver app term defaultRunConfig
          _ <- turn dr
          'h' @=? captureCell term 0 0
      ]