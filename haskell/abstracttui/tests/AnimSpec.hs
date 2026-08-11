module Main (main) where

import AbstractTUI.Anim (Easing (EaseOut), ease, transition, transitionTick,
                         transitionSetTarget, transitionValue)
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit ((@=?), testCase)

main :: IO ()
main = defaultMain $ testGroup "anim"
  [ testCase "easeout midpoint" $ 0.75 @=? ease EaseOut 0.5
  , testCase "transition retargets toward new target" $
      let t0 = transition 0 1000 EaseOut
          t1 = transitionTick 500 t0
          v1 = transitionValue t1
          t2 = transitionSetTarget 100 500 t1
          t3 = transitionTick 600 t2
          v2 = transitionValue t3
      in True @=? (v2 > v1 && v2 < 100)
  ]