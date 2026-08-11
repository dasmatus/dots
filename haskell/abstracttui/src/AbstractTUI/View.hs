{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeOperators #-}
-- | Minimal view tree as a reflex-vty widget description.
--
-- The plan moved away from the stash's GADT tree ('VText'/'VElement') to
-- reflex-vty-native widget actions: a 'View' is a widget action that emits
-- images via 'tellImages' and returns a shutdown 'Event'. The rank-2
-- quantification over @t@ and @m@ keeps 'View' independent of the concrete
-- timeline / host monad so a 'View' built at library level can be
-- instantiated inside the Spider host by "AbstractTUI.Driver"'s 'newDriver'.
--
-- Task 8 only exercises 'text'; Task 9 adds the key-chord types
-- ('Key'/'Mods'/'KeyChord') and 'shortcut' (salvaged from the stash's
-- @UI.View@) so a smoke test can attach a quit handler to a key press.
-- 'element'/'child'/'buildE' remain minimal placeholders (Plan 2 wires the
-- full widget set).
module AbstractTUI.View
  ( View (..)
  , text
  , element
  , child
  , buildE
  , shortcut
  , Key (..)
  , Mods (..)
  , noMods
  , ctrl
  , shift
  , alt
  , KeyChord (..)
  , chord
  , plainChord
  ) where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Kind (Type)
import Data.Text (Text)
import qualified Graphics.Vty as V
import Reflex
  ( Event
  , PerformEvent (..)
  , Performable
  , Reflex
  , constant
  , ffilter
  , never
  )
import Reflex.Vty.Widget (HasDisplayRegion, HasImageWriter, HasInput, HasTheme, input)

import qualified Reflex.Vty.Widget.Text as VtyText

-- | A reflex-vty widget description: an action in a widget context
-- ('HasImageWriter'/'HasDisplayRegion'/'HasTheme'/'HasInput') that draws via
-- 'tellImages' and returns a shutdown 'Event'. The 'Scope' argument is the
-- unit newtype from "AbstractTUI.Reactive" — capabilities come from @m@'s
-- 'Has*' constraints, not from 'Scope' itself.
--
-- The constraint set includes 'PerformEvent t m' so 'shortcut' can run IO
-- actions (e.g. 'quitterQuit') in response to key events; the widget monad
-- in "AbstractTUI.Driver"'s 'vtyGuest' satisfies this via 'MonadVtyApp'.
newtype View t = View
  { unView ::
      forall (m :: Type -> Type).
      ( Reflex t
      , HasImageWriter t m
      , HasDisplayRegion t m
      , HasTheme t m
      , HasInput t m
      , PerformEvent t m
      , MonadIO (Performable m)
      ) =>
      m (Event t ())
  }

-- | Render a static text line via reflex-vty's "Reflex.Vty.Widget.Text"'s
-- @text@ widget. The text is lifted to a constant 'Behavior' and the widget
-- never requests shutdown.
text :: Text -> View t
text t =
  View $ do
    VtyText.text (constant t)
    pure never

-- | A view that draws nothing and never shuts down. The "empty element"
-- placeholder until Plan 2 introduces the real element model.
element :: View t
element = View (pure never)

-- | Compose two views sequentially (both draw into the same image writer,
-- in order). Plan 2 will replace this with proper nesting / region-based
-- children; for now it is a trivial monoidal combinator.
child :: View t -> View t -> View t
child (View a) (View b) =
  View $ do
    _ <- a
    b

-- | Force a rebuild of a view when the given 'Event' fires. With the
-- reflex-vty-native model the widget action runs once at mount, so this is
-- currently the identity on the inner action; Plan 2 wires it to
-- 'Reflex.runWithReplace' for dynamic subtrees.
buildE :: View t -> View t
buildE = id

-- | Attach a key shortcut: when the input 'Event' carries a 'V.Event'
-- matching the given 'KeyChord', run the IO action. Mirrors the stash's
-- @shortcut :: KeyChord -> IO () -> Element -> Element@, lifted to the
-- reflex-vty widget model — the action is wired via 'performEvent_' (the
-- widget monad has 'PerformEvent' via 'MonadVtyApp'), not a static
-- dispatch table. The inner 'View' runs as the child (its images and
-- shutdown are preserved).
shortcut :: KeyChord -> IO () -> View t -> View t
shortcut kc action (View inner) =
  View $ do
    shutdown <- inner
    i <- input
    let matched = ffilter (chordMatches kc) i
    performEvent_ (liftIO action <$ matched)
    pure shutdown

-- | Does a vty 'V.Event' match the given 'KeyChord'? Used by 'shortcut'.
-- 'V.EvKey k mods' matches when @k@ equals the chord's 'Key' (converted to
-- vty) and the modifier set equals the chord's 'Mods'. Other event
-- variants (mouse, resize, paste) never match.
chordMatches :: KeyChord -> V.Event -> Bool
chordMatches (KeyChord mods k) = \case
  V.EvKey vk vmods -> eqKey k vk && eqMods mods vmods
  _ -> False

-- | Compare the abstract 'Key' to the vty 'V.Key'. vty has no 'KTab'
-- constructor — Tab is @KChar '\\t'@.
eqKey :: Key -> V.Key -> Bool
eqKey key vk = case (key, vk) of
  (KeyChar c, V.KChar c') -> c == c'
  (KeyEnter, V.KEnter) -> True
  (KeyEsc, V.KEsc) -> True
  (KeyBackspace, V.KBS) -> True
  (KeyTab, V.KChar '\t') -> True
  (KeyUp, V.KUp) -> True
  (KeyDown, V.KDown) -> True
  (KeyLeft, V.KLeft) -> True
  (KeyRight, V.KRight) -> True
  (KeyHome, V.KHome) -> True
  (KeyEnd, V.KEnd) -> True
  (KeyPgUp, V.KPageUp) -> True
  (KeyPgDn, V.KPageDown) -> True
  (KeyDelete, V.KDel) -> True
  (KeySpace, V.KChar ' ') -> True
  _ -> False

-- | Compare the abstract 'Mods' to the vty modifier list. Order-independent.
-- vty's 'V.MMeta' is taken as the super/meta slot (the stash's @modSuper@);
-- 'V.MAlt' is the alt slot.
eqMods :: Mods -> [V.Modifier] -> Bool
eqMods mods vmods =
  modCtrl mods == elem V.MCtrl vmods
    && modShift mods == elem V.MShift vmods
    && modAlt mods == elem V.MAlt vmods
    && modSuper mods == elem V.MMeta vmods

-- * Key chords (salvaged from the stash's @UI.View@)

-- | The keys the apps route. The mosaic/protocol keys are out of scope.
data Key
  = KeyChar !Char
  | KeyEnter
  | KeyEsc
  | KeyBackspace
  | KeyTab
  | KeyUp
  | KeyDown
  | KeyLeft
  | KeyRight
  | KeyHome
  | KeyEnd
  | KeyPgUp
  | KeyPgDn
  | KeyDelete
  | KeySpace
  deriving (Show, Eq)

-- | Modifier flags.
data Mods = Mods
  { modCtrl :: !Bool
  , modShift :: !Bool
  , modAlt :: !Bool
  , modSuper :: !Bool
  }
  deriving (Show, Eq)

noMods :: Mods
noMods = Mods False False False False

ctrl :: Mods
ctrl = Mods True False False False

shift :: Mods
shift = Mods False True False False

alt :: Mods
alt = Mods False False True False

-- | A key + modifier combination.
data KeyChord = KeyChord
  { kcMods :: !Mods
  , kcKey :: !Key
  }
  deriving (Show, Eq)

chord :: Mods -> Key -> KeyChord
chord = KeyChord

-- | A chord with no modifiers — @KeyChord::plain(Key::Char('q'))@.
plainChord :: Key -> KeyChord
plainChord = KeyChord noMods