{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeOperators #-}

{- | View tree as a reflex-vty widget description.

A 'View' is a small sum type mirroring @abstracttui::ui::ViewNode@:

@
data View t = ViewElement (Element t) | ViewText Text LayoutStyle
           | ViewDyn (DynView t)     | ViewRaw (forall m. WidgetEnv t m => m (Event t ()))
@

'ViewElement' carries its 'LayoutStyle' so a parent 'Element' can derive the
child's slot constraint when it places it (the Rust layout engine reads the
child's style the same way). 'ViewRaw' is the escape hatch a hand-rolled
widget ('RichTextView', 'Block', …) uses to inject a direct reflex-vty
widget action. 'unView' walks the tree into the rank-2 widget action that
'AbstractTUI.Driver.vtyGuest' runs once at mount.

The full widget-context capability stack is captured by the 'WidgetEnv'
constraint alias: every 'View' runs inside 'vtyGuest's 'initManager_'
(which supplies 'HasLayout'\/'HasFocus') over the 'HasImageWriter'\/
'HasDisplayRegion'\/'HasTheme'\/'HasInput'\/'HasFocusReader'\/
'HasColorProfile'\/'HasCursor'\/'HasScreenMode' stack that 'vtyGuest' sets
up. Widgets therefore can assume the lot.
-}
module AbstractTUI.View (
    View (..),
    unView,
    BuildEnv,
    WidgetEnv,
    Element,
    elementNew,
    style,
    child,
    children,
    onEvent,
    shortcut,
    build,
    DynView,
    dynView,
    text,
    useTheme,
    UiEvent (..),
    vtyEventToUiEvent,
    Key (..),
    Mods (..),
    noMods,
    ctrl,
    shift,
    alt,
    KeyChord (..),
    chord,
    plainChord,
    chordMatches,
) where

import Control.Monad (forM_, void)
import Control.Monad.Fix (MonadFix)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.NodeId (MonadNodeId)
import Data.Kind (Type)
import Data.List (intersperse)
import Data.Text (Text)
import qualified Graphics.Vty as V
import Reflex (
    Behavior,
    Dynamic,
    Event,
    MonadHold,
    MonadSample,
    PerformEvent (..),
    Performable,
    PostBuild,
    Reflex,
    constant,
    ffilter,
    ffor,
    never,
    performEvent_,
 )
import Reflex.Vty.Widget (
    HasColorProfile,
    HasCursor,
    HasDisplayRegion,
    HasFocusReader,
    HasImageWriter,
    HasInput,
    HasScreenMode,
    HasTheme,
    Region (..),
    blank,
    displayHeight,
    displayWidth,
    input,
    pane,
    tellImages,
 )
import Reflex.Vty.Widget.Layout (
    Constraint,
    HasFocus,
    HasLayout,
    Orientation (..),
    axis,
    fixed,
    flex,
    grout,
    stretch,
 )
import qualified Reflex.Vty.Widget.Text as VtyText

import AbstractTUI.Layout.Style (
    Dimension (..),
    Direction (..),
    LayoutStyle,
    defaultStyle,
    edgesLeft,
    edgesTop,
    hEdges,
    lsDirection,
    lsGap,
    lsGrow,
    lsH,
    lsPadding,
    lsW,
    vEdges,
 )
import AbstractTUI.Reactive (Scope)
import AbstractTUI.Theme (TokenSet, defaultTokens)

{- | The capability stack the app's /mount closure/ may assume. This is the
reflex-vty widget stack *outside* 'initManager_' (see
'AbstractTUI.Driver.vtyGuest'). It does /not/ include 'HasLayout'\/
'HasFocus' (those come from 'initManager_') — the mount closure only builds
the 'View' tree (pure data + 'Signal' allocation), it does not lay out
children. It also does /not/ include 'MonadRef' or 'MonadReflexCreateTrigger':
the reflex-vty widget transformers lift Reflex's own classes
('MonadHold'/'MonadSample'/'PerformEvent'/etc.) but NOT ref-tf's 'MonadRef',
and 'MonadReflexCreateTrigger' is neither in 'MonadVtyApp' nor provided by
the transformers (it is newtype-derived through 'Layout'\/'Focus' from the
underlying @m@, which lacks it). 'Signal' allocation therefore goes through
the 'Scope's 'TriggerFactory' (invoked via 'liftIO') instead of
'newEventWithTriggerRef' directly. 'WidgetEnv' is a /separate/ alias (not a
superset) for 'unView', which runs inside 'initManager_' where 'HasLayout'
is available but 'MonadRef' is not.
-}
type BuildEnv t m =
    ( Reflex t
    , MonadHold t m
    , MonadFix m
    , PostBuild t m
    , PerformEvent t m
    , MonadIO (Performable m)
    , MonadIO m
    , MonadSample t m
    , HasImageWriter t m
    , HasDisplayRegion t m
    , HasTheme t m
    , HasInput t m
    , HasFocusReader t m
    , HasColorProfile t m
    , HasCursor t m
    , HasScreenMode t m
    , MonadNodeId m
    )

{- | The capability stack a 'View' /action/ may assume when it runs (inside
'initManager_'). This is deliberately NOT a superset of 'BuildEnv': the
'Layout' monad supplies 'HasLayout'\/'HasFocus' and newtype-derives
'MonadHold'\/'PerformEvent'\/'PostBuild' etc. from the underlying @m@, but
it does /not/ lift 'MonadRef' and 'MonadReflexCreateTrigger' is unavailable
(see 'BuildEnv'). 'WidgetEnv' therefore omits both, plus 'MonadSample'
(which layout-time actions do not need). 'unView' and the
'ViewRaw'\/'DynView' closures require this because they lay out children
('axis'\/'grout'\/'pane'); none of them create raw events, so they do not
need 'MonadReflexCreateTrigger'.
-}
type WidgetEnv t m =
    ( Reflex t
    , MonadHold t m
    , MonadFix m
    , PostBuild t m
    , PerformEvent t m
    , MonadIO (Performable m)
    , MonadIO m
    , HasImageWriter t m
    , HasDisplayRegion t m
    , HasTheme t m
    , HasInput t m
    , HasFocusReader t m
    , HasColorProfile t m
    , HasCursor t m
    , HasScreenMode t m
    , HasLayout t m
    , HasFocus t m
    , MonadNodeId m
    )

{- | A view tree node. 'ViewElement' is a styled container; 'ViewText' a text
leaf with its style; 'ViewDyn' a reactive image-producer region; 'ViewRaw'
a direct widget action (the escape hatch for hand-rolled widgets).
-}
data View t
    = ViewElement !(Element t)
    | ViewText !Text !LayoutStyle
    | ViewDyn !(DynView t)
    | ViewRaw (forall (m :: Type -> Type). (WidgetEnv t m) => m (Event t ()))

{- | A styled box: layout style, children, key-event handlers, shortcuts.
Mirrors @abstracttui::ui::Element@ (minus the focus/draw/measure fields no
bin uses). Handlers are @'UiEvent' -> IO ()@ because signal mutation is
IO-callable ('AbstractTUI.Reactive.sigSetIO'\/'sigUpdateIO') and quit is
'AbstractTUI.Driver.quitterQuit' — both plain 'IO', so the handler does not
need the widget monad (see the project memory note on signal-mutation-from-
IO-handlers).
-}
data Element t = Element
    { elStyle :: !LayoutStyle
    , elChildren :: ![View t]
    , elOnEvent :: ![UiEvent -> IO ()]
    , elShortcuts :: ![(KeyChord, IO ())]
    }

{- | A reactive region: a 'Behavior' of image layers built once at mount from
captured 'Signal' 'Dynamic's (via 'current') + the display extents. Mirrors
@abstracttui::ui::DynView@, but under the reflex-vty port the build closure
is an image /producer/ ('Behavior t [V.Image]'), not a 'View' tree — the
bins' per-screen builders are rewritten as @state -> [Image]@ pure
functions lifted to a 'Behavior' (see OQ#2 of the widget-port design).
-}
data DynView t = DynView
    { dvStyle :: !LayoutStyle
    , dvBuild :: forall (m :: Type -> Type). (WidgetEnv t m) => m (Behavior t [V.Image])
    }

{- | Run a 'View' tree into the widget action 'vtyGuest' mounts. The rank-2
quantification keeps 'View' host-monad-independent.
-}
unView :: View t -> (forall (m :: Type -> Type). (WidgetEnv t m) => m (Event t ()))
unView (ViewElement el) = elementAction el
unView (ViewText t _) = textAction t
unView (ViewDyn d) = dynAction d
unView (ViewRaw a) = a

-- | The empty element: default (row) style, no children, no handlers.
elementNew :: Element t
elementNew = Element defaultStyle [] [] []

-- | Set the element's layout style (@.style(..)@).
style :: LayoutStyle -> Element t -> Element t
style s e = e{elStyle = s}

{- | Append a child view (@.child(view)@). The child carries its own style
(it is a 'View' node), which 'elementAction' reads to derive its slot
constraint.
-}
child :: View t -> Element t -> Element t
child v e = e{elChildren = elChildren e ++ [v]}

-- | Replace the element's children (@.children(..)@).
children :: [View t] -> Element t -> Element t
children vs e = e{elChildren = vs}

{- | Attach a key-event handler (@.on_event(FnMut(&EventCtx, &UiEvent))@). The
handler fires on every key the element receives (the bins attach it to the
root element, which receives all input). Mouse/resize events are filtered
out ('vtyEventToUiEvent' returns 'Nothing' for them).
-}
onEvent :: (UiEvent -> IO ()) -> Element t -> Element t
onEvent h e = e{elOnEvent = h : elOnEvent e}

{- | Attach a key shortcut (@.shortcut(chord, FnMut(&EventCtx))@). Fires when
the element receives an input event matching the chord.
-}
shortcut :: KeyChord -> IO () -> Element t -> Element t
shortcut kc a e = e{elShortcuts = (kc, a) : elShortcuts e}

-- | Freeze an 'Element' into a 'View' (@.build()@).
build :: Element t -> View t
build = ViewElement

{- | A reactive image region (@dyn_view(style, build)@). The closure runs once
at mount in the widget monad and returns a 'Behavior' of image layers;
'tellImages' makes it auto-reactive (no 'runWithReplace'\/'switchHold').
-}
dynView ::
    LayoutStyle ->
    (forall (m :: Type -> Type). (WidgetEnv t m) => m (Behavior t [V.Image])) ->
    View t
dynView s b = ViewDyn (DynView s b)

{- | A static text leaf (@text(..)@) with the default style. Its slot size is
governed by the parent's constraint (derived from this leaf's 'defaultStyle'
— typically 'flex' unless the caller wraps it in a sized element).
-}
text :: Text -> View t
text t = ViewText t defaultStyle

{- | Read the active theme token set (@use_theme(&Scope)@). The three bins all
resolve to 'defaultTokens' (abstractDark) once at startup and never switch,
so this is a constant — no theme-switch reactivity (matching the bins'
untracked one-shot read).
-}
useTheme :: (Applicative m) => Scope t -> m TokenSet
useTheme _ = pure defaultTokens

{- | The subset of @abstracttui::UiEvent@ any bin exercises. Only the 'Key'
variant is used (the bins pattern-match @UiEvent::Key(k)@ and early-return
on anything else); mouse/resize variants are omitted.
-}
data UiEvent = UiEventKey !Key
    deriving (Show, Eq)

{- | Inverse of 'AbstractTUI.Testing.Capture.toVtyKey': lift a vty 'V.Event'
into a 'UiEvent'. Key events become 'UiEventKey'; everything else (mouse,
resize, paste) is 'Nothing' — the bins' @on_event@ closures early-return on
those, so dropping them here is faithful.
-}
vtyEventToUiEvent :: V.Event -> Maybe UiEvent
vtyEventToUiEvent (V.EvKey k _mods) = UiEventKey <$> vtyKeyToKey k
vtyEventToUiEvent _ = Nothing

-- * Internals: layout engine + handler wiring

{- | Walk an 'Element': wire its 'onEvent' handlers and 'shortcut's against
the element's input stream, then lay out its children along the element's
main axis (with gap spacers and a padding pane).
-}
elementAction :: Element t -> (forall (m :: Type -> Type). (WidgetEnv t m) => m (Event t ()))
elementAction (Element sty kids onEvts scs) = do
    dw <- displayWidth
    dh <- displayHeight
    i <- input
    -- on_event: dispatch every key event to each handler.
    performEvent_
        ( ffor i $ \ev ->
            case vtyEventToUiEvent ev of
                Just ue -> forM_ onEvts (\h -> liftIO (h ue))
                Nothing -> pure ()
        )
    -- shortcuts: one performEvent_ per chord.
    forM_ scs $ \(kc, action) ->
        performEvent_ (liftIO action <$ ffilter (chordMatches kc) i)
    -- layout
    let pad = lsPadding sty
        gapN = lsGap sty
        orient = case lsDirection sty of Column -> Orientation_Column; Row -> Orientation_Row
        mainExtent = case lsDirection sty of Column -> dh; Row -> dw
        innerReg =
            Region
                <$> pure (edgesLeft pad)
                <*> pure (edgesTop pad)
                <*> (max 0 . subtract (hEdges pad) <$> dw)
                <*> (max 0 . subtract (vEdges pad) <$> dh)
        placeChild ch =
            void $ grout (childConstraint (lsDirection sty) (childStyle ch) mainExtent) (unView ch)
        childActions = map placeChild kids
        spaced =
            if gapN > 0
                then intersperse (grout (fixed (pure gapN)) blank) childActions
                else childActions
        childAxis = axis (pure orient) flex (sequence_ spaced)
        content =
            if hEdges pad == 0 && vEdges pad == 0
                then childAxis
                else pane innerReg (pure True) childAxis
    content
    pure never

{- | The slot constraint for a child along the parent's main axis. Priority:
an explicit 'Cells' main-axis size wins (fixed slot); else a 'Percent'
fraction of the parent's main extent (min slot); else 'grow' > 0 (flex);
else flex (the reflex-vty fallback — see OQ#4 of the widget-port design).
-}
childConstraint ::
    (Reflex t) =>
    Direction ->
    LayoutStyle ->
    Dynamic t Int ->
    Dynamic t Constraint
childConstraint parentDir childSty mainExtent =
    case mainAxisSize parentDir childSty of
        Just (Cells n) -> fixed (pure n)
        Just (Percent f) -> stretch ((\e -> floor (f * fromIntegral e)) <$> mainExtent)
        Just Auto -> flex
        Nothing
            | lsGrow childSty > 0 -> flex
            | otherwise -> flex
  where
    mainAxisSize dir sty = case dir of
        Column -> lsH sty
        Row -> lsW sty

{- | Render a static text leaf via reflex-vty's @text@ widget into the current
(parent-granted) display region.
-}
textAction :: Text -> (forall (m :: Type -> Type). (WidgetEnv t m) => m (Event t ()))
textAction t = do
    VtyText.text (constant t)
    pure never

-- | Run a 'DynView': build its image 'Behavior' once and 'tellImages' it.
dynAction :: DynView t -> (forall (m :: Type -> Type). (WidgetEnv t m) => m (Event t ()))
dynAction (DynView _ buildBeh) = do
    beh <- buildBeh
    tellImages beh
    pure never

{- | A child's outer layout style — read by 'elementAction' to derive the
child's slot constraint. A 'ViewRaw' widget has no style, so it defaults to
'defaultStyle' (flex unless the caller wraps it in a sized element).
-}
childStyle :: View t -> LayoutStyle
childStyle (ViewElement el) = elStyle el
childStyle (ViewText _ s) = s
childStyle (ViewDyn d) = dvStyle d
childStyle (ViewRaw _) = defaultStyle

-- | Map a vty 'V.Key' back to the abstract 'Key' (inverse of 'eqKey').
vtyKeyToKey :: V.Key -> Maybe Key
vtyKeyToKey = \case
    V.KChar c
        | c == '\t' -> Just KeyTab
        | c == ' ' -> Just KeySpace
        | otherwise -> Just (KeyChar c)
    V.KEnter -> Just KeyEnter
    V.KEsc -> Just KeyEsc
    V.KBS -> Just KeyBackspace
    V.KUp -> Just KeyUp
    V.KDown -> Just KeyDown
    V.KLeft -> Just KeyLeft
    V.KRight -> Just KeyRight
    V.KHome -> Just KeyHome
    V.KEnd -> Just KeyEnd
    V.KPageUp -> Just KeyPgUp
    V.KPageDown -> Just KeyPgDn
    V.KDel -> Just KeyDelete
    _ -> Nothing

-- | Does a vty 'V.Event' match the given 'KeyChord'? Used by 'shortcut'.
chordMatches :: KeyChord -> V.Event -> Bool
chordMatches (KeyChord mods k) = \case
    V.EvKey vk vmods -> eqKey k vk && eqMods mods vmods
    _ -> False

{- | Compare the abstract 'Key' to the vty 'V.Key'. vty has no 'KTab'
constructor — Tab is @KChar '\\t'@.
-}
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
