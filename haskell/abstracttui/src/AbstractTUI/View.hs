{-# LANGUAGE KindSignatures #-}
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
-- Task 8 only exercises 'text'; 'element'/'child'/'buildE'/'shortcut' land in
-- later tasks (Plan 2 wires the full widget set).
module AbstractTUI.View
  ( View (..)
  , text
  , element
  , child
  , buildE
  ) where

import Data.Kind (Type)
import Data.Text (Text)
import Reflex (Event, Reflex, constant, never)
import Reflex.Vty.Widget (HasDisplayRegion, HasImageWriter, HasInput, HasTheme)

import qualified Reflex.Vty.Widget.Text as VtyText

-- | A reflex-vty widget description: an action in a widget context
-- ('HasImageWriter'/'HasDisplayRegion'/'HasTheme'/'HasInput') that draws via
-- 'tellImages' and returns a shutdown 'Event'. The 'Scope' argument is the
-- unit newtype from "AbstractTUI.Reactive" — capabilities come from @m@'s
-- 'Has*' constraints, not from 'Scope' itself.
newtype View t = View
  { unView ::
      forall (m :: Type -> Type).
      ( Reflex t
      , HasImageWriter t m
      , HasDisplayRegion t m
      , HasTheme t m
      , HasInput t m
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