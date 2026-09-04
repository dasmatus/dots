# reflex-vty Foundation & Compat Core — Implementation Plan (Plan 1 of 6)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the Haskell rewrite foundation — Nix wiring + reflex-vty override + devShell, salvage the pure-logic modules from the working from-scratch port, and build the abstracttui-shaped compat core (Scope/Signal/Driver/Turn/CaptureTerm) on reflex-vty + vty, with the 4 widget-free smoke tests green.

**Architecture:** A thin `abstracttui` compat library on `reflex-vty 1.2.0.0` + `vty`. Pure data/algorithm modules (Color/Geom/Bitmap/Mosaic/Style/Theme/Anim/Layout) are salvaged verbatim from the from-scratch port (`stash@{0}`, recovered to `/tmp/hs-inspect/haskell/abstracttui/`). The reactive core (`Reactive`) and terminal backend (`Term`/`Render.*`) are replaced by Reflex (`Event`/`Dynamic`) and vty (`Picture`/`Image`/`Input`). A `Scope` shim preserves the abstracttui call shape; `runVtyAppWithHandle`'s per-frame sampling is `Driver::turn`.

**Tech Stack:** GHC 9.10/9.12 (nixpkgs), cabal, reflex 0.9.4.0, reflex-vty 1.2.0.0 (overridden), vty 6.4, vector, text, bytestring, stm, time, JuicyPixels (later), hspec/tasty (tests). Nix flake + `callCabal2nix`.

## Global Constraints

- GHC 9.10.x or 9.12.x from nixpkgs pin `61b7c44c` (dots flake's nixpkgs).
- reflex-vty pinned to **1.2.0.0** via `fetchFromGitHub` + `callCabal2nix` override (deps satisfied: reflex 0.9.4.0, vty 6.4). Fallback to nixpkgs 0.6.2.1 only if the override is unbuildnable — then degrade `Canvas`→direct vty `Image`, `Test.Snapshot`→custom vty-span reader.
- Salvaged modules are copied from `stash@{0}` (`git show stash@{0}:haskell/abstracttui/src/<path>` to read; recreate under `haskell/abstracttui/src/`). They are pure (no IO, no terminal, no Reflex) — keep them that way.
- Tests in `tests/` dirs, never inline (CLAUDE.md). No `Co-Authored-By`/`Assisted-By` tags in commits (CLAUDE.md). No self-promotion / session-link doxxing in GitLab or commits.
- `cargo fmt`/`clippy` do not apply (Haskell). Use `fourmolu` (re-enabled in `nix/home/apps/nixvim.nix`) for formatting; `cabal test` for tests.
- The Rust apps stay in place during this plan (cutover is Plan 6). Do not delete them.
- This plan produces working, testable software on its own: `nix build .#abstracttui` succeeds and `cabal test` (4 smoke tests) passes.

---

## File Structure

```
haskell/abstracttui/
  abstracttui.cabal             — library + test-suite smoke
  src/AbstractTUI/
    Prelude.hs                  — re-exports the public surface
    Base/Color.hs               — Rgba                         (salvage)
    Base/Geom.hs                — Point/Size                   (salvage)
    Gfx/Bitmap.hs               — Bitmap (Vector Rgba)         (salvage)
    Gfx/Mosaic.hs               — MosaicMode/ImageFit/ImageAlign/cellPixels (salvage)
    Render/Style.hs             — Span/RichLine/RichText/coalesce/wrap (salvage)
    Theme.hs                    — TokenSet, defaultTokens        (salvage)
    Anim.hs                     — Easing/Clock/Tween/Transition   (salvage, pure parts)
    Layout/Style.hs             — Dimension/Edges/Inset/flex     (salvage)
    Reactive.hs                 — Scope/Signal shim on Reflex     (NEW)
    Driver.hs                   — App/Driver/Turn/requestFullRedraw/quitter (NEW)
    Term.hs                     — vty-backed Terminal surface    (NEW)
    Testing/Capture.hs          — CaptureTerm (imageToGrid shim)  (NEW)
  tests/Smoke.hs                — 4 ported smoke tests           (NEW)
flake.nix                       — add haskellPackages override + abstracttui pkg + devShell (MODIFY)
```

Responsibilities: each salvaged module is one pure concern; the four NEW modules are the reflex-vty glue layers (Reactive = FRP shim, Driver = loop, Term = vty surface, Testing = headless readback). `Prelude` is the single import apps use.

---

### Task 1: Nix scaffolding — reflex-vty override + abstracttui package + devShell

**Files:**
- Create: `haskell/abstracttui/abstracttui.cabal` (minimal library skeleton)
- Create: `haskell/abstracttui/src/AbstractTUI/Prelude.hs` (empty re-export module so the package builds)
- Modify: `flake.nix` (add `haskellPackages` override + `packages.abstracttui` + `devShells.haskell`)
- Test: `nix build .#abstracttui` (build must succeed — proves the reflex-vty 1.2.0.0 override resolves)

**Interfaces:**
- Produces: a buildable `haskell/abstracttui` package exposing module `AbstractTUI.Prelude` (empty for now); flake attr `.#abstracttui` and devShell `.#haskell`.

- [ ] **Step 1: Read the existing flake structure to place the override correctly**

Run: `grep -nE 'haskellPackages|callCabal2nix|fetchFromGitHub|outputs|perSystem' flake.nix | head -40`
Expected: shows where outputs are defined; identify the `packages`/`perSystem` block to extend.

- [ ] **Step 2: Create the minimal cabal skeleton**

`haskell/abstracttui/abstracttui.cabal`:
```cabal
cabal-version:      2.4
name:               abstracttui
version:            0.1.0
synopsis:           abstracttui-shaped compat layer on reflex-vty
license:            MIT
build-type:         Simple

common shared
  default-language: Haskell2010
  default-extensions: OverloadedStrings
  ghc-options:      -Wall -Wcompat -Widentities -Wincomplete-record-updates
                    -Wredundant-constraints -Wunused-packages

library
  import:           shared
  exposed-modules:  AbstractTUI.Prelude
  hs-source-dirs:   src
  build-depends:    base >= 4.18 && < 5
                  , reflex
                  , reflex-vty
                  , vty
```

`haskell/abstracttui/src/AbstractTUI/Prelude.hs`:
```haskell
-- | Public surface of the abstracttui compat layer. Populated across later
-- tasks; for now just a placeholder so the package builds against reflex-vty.
module AbstractTUI.Prelude (module X) where

import AbstractTUI.Base.Color as X ()
```
(Note: `AbstractTUI.Base.Color` doesn't exist yet — that's fine; the empty import `as X ()` exports nothing. If GHC complains about the missing module, instead use `module AbstractTUI.Prelude () where` until Task 2 lands. Pick whichever compiles.)

- [ ] **Step 3: Add the reflex-vty override + package + devShell to flake.nix**

Add to `flake.nix` (inside the outputs, alongside existing package defs — follow the file's existing idiom; if it uses `perSystem`/`flake-utils`, add there):

```nix
# Haskell packages: pin reflex-vty to the maintained 1.2.0.0 (nixpkgs ships 0.6.2.1).
haskellPackages = pkgs.haskellPackages.override {
  overrides = hpkgs: hprev: {
    reflex-vty = hpkgs.callCabal2nix "reflex-vty"
      (pkgs.fetchFromGitHub {
        owner = "obsidiansystems";
        repo = "reflex-vty";
        rev = "refs/tags/v1.2.0.0";   # confirm exact tag in Step 4
        hash = pkgs.lib.fakeHash;     # replace after first failed build gives the real hash
      })
      { };
  };
};
abstracttui = haskellPackages.callCabal2nix "abstracttui" ../haskell/abstracttui { };
```
Expose `packages.abstracttui = abstracttui;` and a devShell:
```nix
devShells.haskell = pkgs.mkShell {
  packages = [ haskellPackages.ghc pkgs.cabal-install haskellPackages.haskell-language-server haskellPackages.fourmolu ];
  inputsFrom = [ abstracttui ];
};
```
Adapt the exact insertion point and attribute wiring to the existing flake style.

- [ ] **Step 4: Confirm the reflex-vty tag + hash, then build**

Run: `nix build .#abstracttui 2>&1 | tail -40`
Expected: first run fails on `fakeHash` — copy the real `got: sha256-...` from the error, replace `hash`, and confirm the `rev` tag (`v1.2.0.0` vs `1.2.0.0` — check `gh api repos/obsidiansystems/reflex-vty/tags --jq '.[].name' | head`).
Re-run until `nix build .#abstracttui` succeeds. This proves reflex-vty 1.2.0.0 + its transitive deps build under our GHC.

- [ ] **Step 5: Commit**

```bash
git add flake.nix flake.lock haskell/abstracttui/
git commit -m "feat(haskell): scaffold abstracttui package + pin reflex-vty 1.2.0.0"
```

---

### Task 2: Salvage Color/Geom/Bitmap/Mosaic (pure)

**Files:**
- Create: `haskell/abstracttui/src/AbstractTUI/Base/Color.hs` (from stash)
- Create: `haskell/abstracttui/src/AbstractTUI/Base/Geom.hs` (from stash)
- Create: `haskell/abstracttui/src/AbstractTUI/Gfx/Bitmap.hs` (from stash)
- Create: `haskell/abstracttui/src/AbstractTUI/Gfx/Mosaic.hs` (from stash)
- Modify: `haskell/abstracttui/abstracttui.cabal` (expose modules; add `vector` dep)
- Test: `haskell/abstracttui/tests/ColorSpec.hs` (pure property tests)

**Interfaces:**
- Consumes: `base`, `vector` (nixpkgs).
- Produces: `Rgba` (Color), `Point`/`Size` (Geom), `Bitmap` (Gfx.Bitmap), `MosaicMode`/`ImageFit`/`ImageAlign`/`cellPixels` (Gfx.Mosaic) — unchanged signatures from the port.

- [ ] **Step 1: Extract the four modules from the stash**

Run:
```bash
mkdir -p haskell/abstracttui/src/AbstractTUI/{Base,Gfx}
for f in Base/Color Base/Geom Gfx/Bitmap Gfx/Mosaic; do
  git show "stash@{0}:haskell/abstracttui/src/AbstractTUI/$f.hs" > "haskell/abstracttui/src/AbstractTUI/$f.hs"
done
```
Verify the four files landed and have no IO/terminal/Reflex imports: `grep -nE 'import .*Reflex|import .*Vty|IO ' haskell/abstracttui/src/AbstractTUI/{Base,Gfx}/*.hs` — expected empty.

- [ ] **Step 2: Expose the modules + add the vector dep in the cabal**

In `abstracttui.cabal` `library`:
```
  exposed-modules:  AbstractTUI.Prelude
                    AbstractTUI.Base.Color
                    AbstractTUI.Base.Geom
                    AbstractTUI.Gfx.Bitmap
                    AbstractTUI.Gfx.Mosaic
  build-depends:    base >= 4.18 && < 5
                  , vector
                  , text
                  , reflex
                  , reflex-vty
                  , vty
```

- [ ] **Step 3: Write the failing test**

`haskell/abstracttui/tests/ColorSpec.hs`:
```haskell
module Main (main) where

import AbstractTUI.Base.Color (Rgba (..), rgb, withAlpha)
import AbstractTUI.Base.Geom (size)
import AbstractTUI.Gfx.Mosaic (MosaicMode (..), cellPixels)
import Test.Tasty (defaultMain, testGroup, TestTree)
import Test.Tasty.HUnit ((@=?), testCase)

main :: IO ()
main = defaultMain $ testGroup "color/geom/mosaic"
  [ testCase "rgba rgb is opaque" $ 255 @=? rgbaAlpha (rgb 1 2 3)
  , testCase "with_alpha sets alpha" $ 128 @=? rgbaAlpha (withAlpha 128 (rgb 1 2 3))
  , testCase "half-block packs 1x2" $ (1, 2) @=? cellPixels HalfBlock
  ]
  where
    rgbaAlpha (Rgba _ _ _ a) = a
```
(Confirm the `Rgba` constructor field order against the salvaged `Color.hs`; adjust the accessor if it differs. The port's `Rgba` is `Rgba { rW, rH :: ... }`? No — `Rgba` fields are r/g/b/a; verify with `grep 'data Rgba' haskell/abstracttui/src/AbstractTUI/Base/Color.hs`.)

- [ ] **Step 4: Wire the test-suite in the cabal**

Add:
```cabal
test-suite color-spec
  import:        shared
  type:          exitcode-stdio-1.0
  main-is:       ColorSpec.hs
  hs-source-dirs: tests
  build-depends: base, abstracttui, tasty, tasty-hunit
```
Add `tasty`/`tasty-hunit` to the override devShell inputsFrom closure (they're in nixpkgs haskellPackages).

- [ ] **Step 5: Run the test — expect FAIL (constructor/accessor mismatch)**

Run: `nix develop .#haskell -c cabal test color-spec 2>&1 | tail -30`
Expected: compile or assertion failure — fix the accessor in the test to match the salvaged `Rgba`.

- [ ] **Step 6: Fix + rerun until PASS**

Expected: `1 of 1 test suites (3 test cases) passed`.

- [ ] **Step 7: Commit**

```bash
git add haskell/abstracttui/
git commit -m "feat(haskell): salvage Color/Geom/Bitmap/Mosaic from the port"
```

---

### Task 3: Salvage Style (Span/RichLine/RichText)

**Files:**
- Create: `haskell/abstracttui/src/AbstractTUI/Render/Style.hs` (from stash)
- Modify: cabal (expose + dep `text`)
- Test: `haskell/abstracttui/tests/StyleSpec.hs`

**Interfaces:**
- Produces: `Span`, `RichLine` (with `push` coalescing), `RichText` (`fromLines`, `plain`, `wrap`).

- [ ] **Step 1: Extract + check purity**

```bash
mkdir -p haskell/abstracttui/src/AbstractTUI/Render
git show stash@{0}:haskell/abstracttui/src/AbstractTUI/Render/Style.hs > haskell/abstracttui/src/AbstractTUI/Render/Style.hs
grep -nE 'import .*Reflex|import .*Vty|IO ' haskell/abstracttui/src/AbstractTUI/Render/Style.hs
```
Expected: empty (pure). If it imports `AbstractTUI.Base.Color`, that's fine (Task 2).

- [ ] **Step 2: Expose + deps**

Add `AbstractTUI.Render.Style` to `exposed-modules`; ensure `text` is in `build-depends`.

- [ ] **Step 3: Write the failing test (push coalesces equal-ink spans)**

`haskell/abstracttui/tests/StyleSpec.hs`:
```haskell
module Main (main) where

import AbstractTUI.Render.Style (RichLine, newRichLine, pushRichLine, richLineSpans, Span (..), Style (..))
import Test.Tasty (defaultMain, testGroup, TestTree)
import Test.Tasty.HUnit ((@=?), testCase)

main :: IO ()
main = defaultMain $ testGroup "style"
  [ testCase "push coalesces equal-ink spans" $
      1 @=? length (richLineSpans (pushTwice (newRichLine)))
  ]
  where
    pushTwice l = pushRichLine (Span "ab" defaultStyle Nothing) (pushRichLine (Span "cd" defaultStyle Nothing) l)
```
(Confirm the salvaged `Style`/`Span`/`RichLine` record field + function names; adapt `newRichLine`/`pushRichLine`/`richLineSpans`/`defaultStyle` to the port's actual names — `grep -nE 'data Span|data RichLine|richLine|push|defaultStyle|defStyle' haskell/abstracttui/src/AbstractTUI/Render/Style.hs`.)

- [ ] **Step 4: Wire test-suite** (add `style-spec` like Task 2's `color-spec`).

- [ ] **Step 5: Run — expect FAIL** (name mismatches) → fix names → PASS (`1 of 1 ... passed`).

- [ ] **Step 6: Commit** — `feat(haskell): salvage RichText Style from the port`

---

### Task 4: Salvage Theme (TokenSet)

**Files:**
- Create: `haskell/abstracttui/src/AbstractTUI/Theme.hs` (from stash)
- Modify: cabal (expose)
- Test: `haskell/abstracttui/tests/ThemeSpec.hs`

**Interfaces:**
- Produces: `TokenSet`, `defaultTokens`, `TokenId` (Bg/Surface/Accent/Error/...).

- [ ] **Step 1: Extract**
```bash
git show stash@{0}:haskell/abstracttui/src/AbstractTUI/Theme.hs > haskell/abstracttui/src/AbstractTUI/Theme.hs
grep -nE 'data TokenSet|defaultTokens|data TokenId' haskell/abstracttui/src/AbstractTUI/Theme.hs
```

- [ ] **Step 2: Expose** `AbstractTUI.Theme`.

- [ ] **Step 3: Write failing test** — assert `defaultTokens` is non-empty and an `Accent`/`Error` token resolves to a non-transparent `Rgba`.
```haskell
module Main (main) where
import AbstractTUI.Theme (defaultTokens, TokenId (..), tokenRgba)
import AbstractTUI.Base.Color (Rgba (..))
import Test.Tasty.HUnit ((@=?), testCase, assertBool)
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = defaultMain $ testGroup "theme"
  [ testCase "accent is opaque" $ assertBool "accent alpha must be 255" (rgbaAlpha (tokenRgba defaultTokens Accent) == 255)
  ]
  where rgbaAlpha (Rgba _ _ _ a) = a
```
(Confirm `tokenRgba :: TokenSet -> TokenId -> Rgba` exists; adapt name.)

- [ ] **Step 4: Wire + run to FAIL then PASS + Commit** — `feat(haskell): salvage Theme TokenSet from the port`

---

### Task 5: Salvage Anim (Easing/Clock/Tween/Transition)

**Files:**
- Create: `haskell/abstracttui/src/AbstractTUI/Anim.hs` (from stash)
- Modify: cabal (expose + dep `time`)
- Test: `haskell/abstracttui/tests/AnimSpec.hs`

**Interfaces:**
- Produces: `Easing` (`ease`), `Clock` (`clockFixed`/`clockReal`/`clockNow`/`clockAdvance`), `Tween` (`tween`/`tweenSample`), `Transition` (`transition`/`transitionSetTarget`/`transitionTick`/`transitionValue`).

- [ ] **Step 1: Extract**
```bash
git show stash@{0}:haskell/abstracttui/src/AbstractTUI/Anim.hs > haskell/abstracttui/src/AbstractTUI/Anim.hs
grep -nE '^data |^ease|^clock|^tween|^transition' haskell/abstracttui/src/AbstractTUI/Anim.hs | head -30
```
Confirm it stays pure: the `clockReal` path may use `getPOSIXTime` (IO) — that's acceptable (it's the only IO, in `clockNow` for Real mode). Keep everything else pure.

- [ ] **Step 2: Expose + add `time` dep.**

- [ ] **Step 3: Write failing test** (EaseOut + Transition retarget):
```haskell
module Main (main) where
import AbstractTUI.Anim (Easing (..), ease, clockFixed, clockAdvance, clockNow,
                         transition, transitionTick, transitionSetTarget, transitionValue)
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit ((@=?), testCase)

main :: IO ()
main = defaultMain $ testGroup "anim"
  [ testCase "easeout midpoint" $ 0.75 @=? ease EaseOut 0.5            -- 1-(1-0.5)^2 = 0.75
  , testCase "transition retargets" $
      let go = do
            c <- clockFixed
            let t = transition 0 0 -- duration/easing from port; confirm ctor
            _ <- clockAdvance c 10
            t' <- transitionTick t =<< clockNow c
            transitionSetTarget t' 100 =<< clockNow c
            pure ()
      in 0 @=? (0 :: Int)   -- placeholder; expand once ctor confirmed
  ]
```
(The Transition test needs the real constructor shape — confirm with the grep in Step 1 and write a real assertion that `transitionValue` after a retarget+tick moves toward 100. Replace the placeholder.)

- [ ] **Step 4: Wire + run to FAIL then PASS + Commit** — `feat(haskell): salvage Anim Easing/Clock/Tween/Transition from the port`

---

### Task 6: Salvage Layout.Style (Dimension/Edges/Inset/flex)

**Files:**
- Create: `haskell/abstracttui/src/AbstractTUI/Layout/Style.hs` (from stash)
- Modify: cabal (expose)
- Test: `haskell/abstracttui/tests/LayoutSpec.hs`

**Interfaces:**
- Produces: `Dimension` (Auto/Cells/Percent), `Edges` (ZERO/all/hv), `Inset`, layout `Style` builder (column/row/fill/line/gap/padding/margin/w/h/grow/justify/align).

- [ ] **Step 1: Extract**
```bash
mkdir -p haskell/abstracttui/src/AbstractTUI/Layout
git show stash@{0}:haskell/abstracttui/src/AbstractTUI/Layout/Style.hs > haskell/abstracttui/src/AbstractTUI/Layout/Style.hs
```

- [ ] **Step 2: Expose** `AbstractTUI.Layout.Style`.

- [ ] **Step 3: Write failing test** (Edges.all + Dimension):
```haskell
module Main (main) where
import AbstractTUI.Layout.Style (Edges (..), Dimension (..))
import Test.Tasty.HUnit ((@=?), testCase)
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = defaultMain $ testGroup "layout"
  [ testCase "all edges" $ Edges 2 2 2 2 @=? Edges.all 2
  , testCase "percent is fraction" $ 0.5 @=? case Percent 0.5 of Percent f -> f; _ -> -1
  ]
```
(Confirm `Edges` constructor field order + whether `all` is a smart ctor vs `Edges.all`; adapt.)

- [ ] **Step 4: Wire + run FAIL → PASS + Commit** — `feat(haskell): salvage Layout.Style from the port`

---

### Task 7: Compat core — Scope/Signal shim on Reflex

**Files:**
- Create: `haskell/abstracttui/src/AbstractTUI/Reactive.hs`
- Modify: cabal (expose + dep `reflex`)
- Test: `haskell/abstracttui/tests/ReactiveSpec.hs`

**Interfaces:**
- Consumes: `reflex` (`Event`, `Dynamic`, `Behavior`, `holdDyn`, `current`, `updated`, `switchHold`, `newTriggerEvent`, `MonadReflexCreateTrigger`, `MonadHold`, `MonadSample`, `Performable`/`PerformEvent`).
- Produces:
  - `newtype Scope t m` — the abstracttui `Scope`, carrying the Reflex env.
  - `signal :: (Reflex t, MonadHold t m, MonadFix m) => a -> Scope t m -> m (Signal t a)`
  - `sigGet :: (Reflex t, MonadSample t m) => Signal t a -> m a`
  - `sigSet :: (Reflex t, Monad m) => Signal t a -> a -> m ()`  (via `assignDyn`/`current`+`updated` sink — see impl)
  - `sigUpdate :: (Reflex t, Monad m) => Signal t a -> (a -> a) -> m ()`
  - `Signal t a = Dynamic t a` (newtype, to keep the abstracttui name).
  - `wakeHandle :: (Reflex t, MonadReflexCreateTrigger t m) => Scope t m -> m (Event t a, a -> IO ())` — wraps `newTriggerEvent`.

- [ ] **Step 1: Write the failing test** (signal get/set round-trip in the Spider host)

`haskell/abstracttui/tests/ReactiveSpec.hs`:
```haskell
module Main (main) where

import AbstractTUI.Reactive (Scope, signal, sigGet, sigSet, sigUpdate, runScopeSpider)
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit ((@=?), testCase)

main :: IO ()
main = defaultMain $ testGroup "reactive"
  [ testCase "signal get/set round-trip" $ runScopeSpider $ \scope -> do
      s <- signal (0 :: Int) scope
      v0 <- sigGet s
      0 @=? v0
      sigSet s 42
      v1 <- sigGet s
      42 @=? v1
  , testCase "sigUpdate mutates" $ runScopeSpider $ \scope -> do
      s <- signal (10 :: Int) scope
      sigUpdate s (+ 5)
      15 @=? =<< sigGet s
  ]
```
(`runScopeSpider` is a small test helper that runs a `Scope Spider m -> m a` action in the Reflex Spider host — implement it in `Reactive.hs` or a `Test.Run` helper using `refSpider`/`runSpiderHost`.)

- [ ] **Step 2: Implement the shim**

`haskell/abstracttui/src/AbstractTUI/Reactive.hs`:
```haskell
{-# LANGUAGE ScopedTypeVariables #-}
-- | abstracttui-shaped reactive shim over Reflex.
-- Signal t a is a Dynamic under the hood; Scope carries the Reflex env.
module AbstractTUI.Reactive
  ( Signal (..)
  , Scope (..)
  , signal
  , sigGet
  , sigSet
  , sigUpdate
  , wakeHandle
  , runScopeSpider
  ) where

import Control.Monad.Fix (MonadFix)
import Reflex

-- | abstracttui's Signal is a Reflex Dynamic.
newtype Signal t a = Signal (Dynamic t a)

-- | abstracttui's Scope: the reactive context. Carries enough of the Reflex
-- env that 'signal' can allocate a Dynamic. For now a thin newtype; later
-- tasks add the widget-env capabilities.
newtype Scope t m = Scope { unScope :: m }

signal :: (Reflex t, MonadHold t m, MonadFix m) => a -> Scope t m -> m (Signal t a)
signal initial (Scope m) = do
  _ <- m  -- m is unit-valued here; present so the API mirrors abstracttui's cx use
  Signal <$> holdDyn initial never   -- a settable Dynamic; sigSet updates via a sink (see below)

sigGet :: (Reflex t, MonadSample t m) => Signal t a -> m a
sigGet (Signal d) = sample (current d)

-- NOTE: a Dynamic is updated by an Event, not by an imperative set. To provide
-- sigSet/sigUpdate as pure-ish calls in tests, drive the Dynamic from an
-- IORef-backed Event: see the full impl in Step 2b. The minimal impl below uses
-- an internal update Event stored alongside the Dynamic.
sigSet :: (Reflex t, Monad m) => Signal t a -> a -> m ()
sigSet = error "filled in Step 2b: update via the stored sink Event"

sigUpdate :: (Reflex t, Monad m) => Signal t a -> (a -> a) -> m ()
sigUpdate = error "filled in Step 2b"

wakeHandle :: (Reflex t, MonadReflexCreateTrigger t m) => Scope t m -> m (forall a. (Event t a, a -> IO ()))
wakeHandle (Scope _) = do
  (e, fire) <- newTriggerEvent
  pure (e, fire)

runScopeSpider :: (forall t m. (Reflex t, MonadHold t m, MonadFix m, MonadSample t m) => Scope t m -> m a) -> IO a
runScopeSpider = error "filled in Step 2b: runSpiderHost . (Scope (...))"
```

- [ ] **Step 2b: Make sigSet/sigUpdate real**

The honest implementation: a `Signal t a` is `(Dynamic t a, a -> IO ())` — a Dynamic driven by a trigger event whose `fire` is held in the Signal. Redefine:
```haskell
data Signal t a = Signal
  { sigDyn   :: Dynamic t a
  , sigApply :: (a -> a) -> IO ()   -- fire the update event with f applied to the last value
  }
```
`signal initial _ = do (e, fire) <- newTriggerEvent; d <- holdDyn initial e; let sigApply f = fire (f initial) ... -- but f needs the *current* value; hold the latest in an IORef.`
Concretely: hold the current value in an `IORef a`; on `sigSet`/`sigUpdate`, read the IORef, apply, write, and `fire` the new value into `e` (which updates the Dynamic). This needs `MonadIO`/`PerformEvent` to fire — but in the Spider host (`runSpiderHost`) `newTriggerEvent`'s fire is `a -> IO ()`, callable from `IO`. So `Signal` carries the `IORef a` + the fire callback:
```haskell
data Signal t a = Signal (IORef a) (a -> IO ()) (Dynamic t a)
signal initial _ = do
  ref <- liftIO (newIORef initial)
  (e, fire) <- newTriggerEvent
  d <- holdDyn initial e
  pure (Signal ref fire d)
sigGet (Signal _ _ d) = sample (current d)
sigSet (Signal ref fire _) x = liftIO (writeIORef ref x >> fire x)
sigUpdate (Signal ref fire _) f = liftIO $ do v <- readIORef ref; let v' = f v; writeIORef ref v'; fire v'
```
`runScopeSpider act = runSpiderHost $ act (Scope (pure ()))` (with `MonadIO` instances available in the Spider host).
This is the real shape — adapt the constraints (`MonadIO`, `MonadReflexCreateTrigger`) and confirm `reflex`'s `runSpiderHost` + `newTriggerEvent`/`fire` exact types against the reflex haddock.

- [ ] **Step 3: Run — expect FAIL (compile)** → fix constraints/imports → PASS (`2 cases passed`).

- [ ] **Step 4: Commit** — `feat(haskell): Scope/Signal shim on Reflex`

---

### Task 8: Compat core — Driver/Turn/Terminal on reflex-vty + vty

**Files:**
- Create: `haskell/abstracttui/src/AbstractTUI/Term.hs`
- Create: `haskell/abstracttui/src/AbstractTUI/Driver.hs`
- Modify: cabal (expose + deps `reflex-vty`, `vty`)
- Test: `haskell/abstracttui/tests/DriverSpec.hs` (a hello-world render + the paint-text smoke assertion)

**Interfaces:**
- Consumes (reflex-vty 1.2.0.0, confirmed signatures):
  - `runVtyAppWithHandle :: VtyAppConfig -> Vty -> (forall t m. VtyApp t m) -> IO ()`
  - `type VtyApp t m = MonadVtyApp t m => DisplayRegion -> Event t Event -> Event t AppSignal -> m (VtyResult t)`
  - `data VtyResult t = VtyResult { _vtyResult_picture :: Behavior t Picture, _vtyResult_shutdown :: Event t () }`
  - `data VtyAppConfig = VtyAppConfig { _vtyConfig_eventQueueCapacity :: !Int }`, `defaultVtyAppConfig`.
  - `mainWidget` / `mainWidgetWithHandle` (entry points) — confirm exact signature against the `Reflex.Vty.Widget` haddock.
- Produces:
  - `newApp :: Size -> IO App`
  - `appMount :: App -> (Scope t m -> m (View t)) -> IO ()`  (mount builds the root view)
  - `newDriver :: App -> Vty -> RunConfig -> IO Driver`
  - `turn :: Driver -> IO Turn`
  - `data Turn = Turn { turnEvents :: Int, turnRendered :: Bool, turnEmitted :: Bool, turnQuit :: Bool, turnIdle :: Bool }`
  - `requestFullRedraw :: IO ()`  (fires the frame tick — a global trigger)
  - `appQuitter :: App -> Quitter`; `quitterQuit :: Quitter -> IO ()`
  - `data RunConfig = RunConfig { rcIdlePollMs :: Int, rcProbe :: Bool }`; `defaultRunConfig`.
  - `View t` — the view tree; minimal here: `text :: Text -> View t`, `element :: View t`, `child :: View t -> View t -> View t`, `buildE :: View t -> View t`. (Full widget set is Plan 2.)

- [ ] **Step 1: Write the failing test** (render text → cell (0,0) == 'h')

`haskell/abstracttui/tests/DriverSpec.hs`:
```haskell
module Main (main) where
import AbstractTUI.Base.Geom (Size, size)
import AbstractTUI.Driver
import AbstractTUI.Term (CaptureTerm, newCaptureTerm, captureCell, captureEmit)
import AbstractTUI.View (text)
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit ((@=?), testCase)

main :: IO ()
main = defaultMain $ testGroup "driver"
  [ testCase "render text lands at (0,0)" $ do
      app <- newApp (size 10 1)
      appMount app (\_ -> pure (text "hi"))
      term <- newCaptureTerm 10 1
      dr <- newDriver app term defaultRunConfig
      _ <- turn dr
      'h' @=? captureCell term 0 0
  ]
```

- [ ] **Step 2: Implement `Term.hs`** — the `CaptureTerm`: a mock `Vty` built on `Graphics.Vty.Output.Mock` (vty 6.4) OR a custom `Vty` record that records the `Picture` each frame and computes cells via `Graphics.Vty.Picture`→`Span`/`PictureToSpans`. Expose `newCaptureTerm :: Int -> Int -> IO CaptureTerm`, `captureCell :: CaptureTerm -> Int -> Int -> Char`, `captureEmit :: CaptureTerm -> IO ByteString` (bytes the mock output received this frame — for the full-redraw contract test). Confirm vty's mock-output module name (`grep -r 'Mock' $(nix eval --raw nixpkgs#haskellPackages.vty.src 2>/dev/null)` or the vty 6.4 haddock for `Graphics.Vty.Output.Mock` / `Graphics.Vty.PictureToSpans`).

- [ ] **Step 3: Implement `Driver.hs`** — wraps `runVtyAppWithHandle` using the `CaptureTerm`'s mock Vty. `turn` samples `_vtyResult_picture` once (one frame), feeds the next input `Event` (queued from `feedInput`), and reports `Turn`:
  - `turnRendered`/`turnEmitted`: from whether the sampled `Picture` differs from the previous (vty's diff is done by the mock output; `turnEmitted` = `not (BS.null (captureEmit term))`).
  - `turnQuit`: from `_vtyResult_shutdown` occurrence.
  - `turnIdle`: no input + no emitted bytes.
  - `requestFullRedraw`: fire a global trigger that invalidates the root Dynamic so the next frame re-emits (or, with the mock, force a full re-draw by resetting the diff base).
  Map the abstracttui `Driver::turn` semantics onto reflex-vty's frame sampling. This is the research-heavy step — confirm against `mainWidgetWithHandle`'s exact type (`Reflex.Vty.Widget` haddock) and vty's mock output API.

- [ ] **Step 4: Implement minimal `View.hs`** (re-export from a new `AbstractTUI.UI.View` or inline in Driver) — `text`, `element`, `child`, `buildE`, `shortcut` (a root key handler that fires on a `KeyChord`). For this task only `text` is exercised; `shortcut` lands in Task 9's smoke test. Keep `View t` as a reflex-vty widget description (`m ()` producing `tellImages`).

- [ ] **Step 5: Run — expect FAIL** (compile + mock-output wiring) → fix → PASS (`1 case passed`).

- [ ] **Step 6: Commit** — `feat(haskell): Driver/Turn/Terminal compat core on reflex-vty`

---

### Task 9: Compat core — CaptureTerm harness + smoke tests

**Files:**
- Create: `haskell/abstracttui/src/AbstractTUI/Testing/Capture.hs` (the public CaptureTerm API + `feedInput`, `drainOutput`, `parseScreen`, `vtChar` — mirrors the port's `Testing.Capture`)
- Modify: cabal (expose)
- Test: `haskell/abstracttui/tests/Smoke.hs` — the 4 ported smoke tests

**Interfaces:**
- Produces: `CaptureTerm`, `newCaptureTerm :: Int -> Int -> IO CaptureTerm`, `feedInput :: CaptureTerm -> [Word8] -> IO ()`, `drainOutput :: CaptureTerm -> IO ByteString`, `parseScreen :: Int -> Int -> ByteString -> Screen`, `vtChar :: Screen -> Int -> Int -> Char`, `captureCell`/`cellText`.

- [ ] **Step 1: Extract the port's `Testing/Capture.hs` as a reference**
```bash
git show stash@{0}:haskell/abstracttui/src/AbstractTUI/Testing/Capture.hs > /tmp/ref-capture.hs
wc -l /tmp/ref-capture.hs
```
The port's version is hand-rolled against its own `Term`; we re-implement against the reflex-vty mock Vty + vty `Picture`→spans. Reuse the *names and semantics* (`feedInput`/`drainOutput`/`parseScreen`/`vtChar`) so the smoke tests port verbatim.

- [ ] **Step 2: Port the 4 widget-free smoke tests** from the stash's `tests/Smoke.hs`:
```bash
git show stash@{0}:haskell/abstracttui/tests/Smoke.hs > /tmp/ref-smoke.hs
grep -nE 'testPaintText|testCaptureRoundTrip|testFullRedrawContract|testShortcutQuit|testFocusListKey' /tmp/ref-smoke.hs
```
Port `testPaintText`, `testCaptureRoundTrip`, `testFullRedrawContract`, `testShortcutQuit` to `haskell/abstracttui/tests/Smoke.hs`. **Defer `testFocusListKey`** to Plan 2 (needs the List widget). `testShortcutQuit` needs `shortcut`/`plainChord`/`quitterQuit` — implement the minimal `shortcut :: KeyChord -> IO () -> View t` in `View.hs` (fires on a key `Event` matching the chord → runs the IO, e.g. `quitterQuit`).

- [ ] **Step 3: Wire `smoke` test-suite** in cabal (like `color-spec`).

- [ ] **Step 4: Run — expect FAIL** (some assertions off, esp. full-redraw byte contract) → fix the mock-output diff so `turn1` emits, idle emits nothing, post-`requestFullRedraw` emits again → PASS (`4 cases passed`).

- [ ] **Step 5: Commit** — `feat(haskell): CaptureTerm harness + 4 ported smoke tests green`

---

### Task 10: Wire into the dots flake CI surface + devShell verification

**Files:**
- Modify: `flake/apps.nix` (add `nix run .#abstracttui-test`? or fold `cabal test` into `nix-lint`) — at minimum, make `nix build .#abstracttui` and the devShell part of the standard surface
- Modify: `nix/home/base/pkgs.nix` or wherever devShell tools are listed (hls/fourmolu already in nixvim; add `cabal-install` to the haskell devShell if not present)

**Interfaces:**
- Produces: `nix run .#nix-lint` now also runs `cabal test` for `abstracttui`; `nix develop .#haskell` works.

- [ ] **Step 1: Extend `nix-lint`** (per CLAUDE.md it runs flake eval + fmt/clippy/test). Add a Haskell lane: `nix build .#abstracttui && (cd haskell/abstracttui && nix run .#cabal-test-wrapper -- test)` OR `nix build .#abstracttui.checks` if a `checks` attr is exposed. Expose `checks.x86_64-linux.abstracttui = abstracttui.checks` if `callCabal2nix` provides `.checks`.

- [ ] **Step 2: Verify the full surface**
```bash
nix flake check --no-build       # eval passes
nix build .#abstracttui          # builds
nix develop .#haskell -c cabal test   # all test-suites green (color, style, theme, anim, layout, reactive, driver, smoke)
```

- [ ] **Step 3: Commit** — `ci(haskell): wire abstracttui build+test into nix-lint + devShell`

---

## Self-Review (run after writing, before handoff)

- **Spec coverage:** Phase 1 (flake/override/devShell) = Task 1, 10. Phase 2 (salvage + compat core + smoke) = Tasks 2-9. Phase 3 widgets = Plan 2 (deferred, intentional — testFocusListKey deferred). ✓
- **Placeholder scan:** Tasks 7-9 flag research-heavy bits ("confirm against haddock") — these are external-library API lookups, not plan placeholders; the executing subagent reads the pinned haddock. The `error "filled in Step 2b"` is an explicit two-step scaffold, acceptable. ✓
- **Type consistency:** `Signal t a`, `Scope t m`, `Turn`, `CaptureTerm`, `View t`, `Size` used consistently across tasks. `captureCell` (Task 8 test) vs `vtChar` (Task 9) — both exist; `CaptureTerm` API finalized in Task 9 (Task 8 uses a provisional `captureCell` that Task 9's `Testing.Capture` exposes under the same name — confirmed in Task 9 Interfaces). ✓
- **Gaps:** The byte-diff full-redraw contract (Task 9 Step 4) is the riskiest; flagged. If the mock-output diff proves intractable, fall back to asserting at the `Picture`/cell level (idle frame == prior frame) and document the deviation in the spec's Risks. ✓

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-08-10-reflex-vty-foundation.md`. This is **Plan 1 of 6**; Plans 2-6 (Widgets/Anim, hyprmon, installer-tui, wallpaper-tui, Cutover) are written after this foundation exists so their code is real against a concrete compat API.

**Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**