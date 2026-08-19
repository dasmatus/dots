{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | abstracttui view — a pure projection of 'App' onto image layers. Faithful
-- Haskell port of @rust/installer-tui/src/ui.rs@.
--
-- Because the abstracttui 'dynView' closure returns a 'Behavior t [V.Image]'
-- (image layers, NOT a View tree), per-screen rendering is done as pure image
-- functions. The block border and progress bar renderers are replicated here
-- (they are NOT exported from "AbstractTUI.Widget.Block" / "Progress") using
-- the exported 'rgbaAttr' from "AbstractTUI.Render.Paint".
module Dots.Installer.Ui
  ( rootView
  ) where

import Control.Monad.IO.Class (liftIO)
import Data.List (intercalate)
import qualified Data.Text as T
import qualified Graphics.Vty as V
import Reflex (current)

import AbstractTUI.Base.Color (rgb)
import AbstractTUI.Layout.Style (fill)
import AbstractTUI.Reactive (Signal, sigDyn, sigReadRef, sigSetIO)
import AbstractTUI.Render.Paint (rgbaAttr)
import AbstractTUI.View
  ( Key (..)
  , UiEvent (..)
  , View
  , build
  , child
  , displayHeight
  , displayWidth
  , dynView
  , elementNew
  , onEvent
  , style
  )

import Dots.Installer.App
  ( App (..)
  , Screen (..)
  , aiOptions
  , handleKey
  )
import Dots.Installer.Config (InstallConfig (..))
import Dots.Installer.Disks (Disk (..), humanSize)
import Dots.Installer.Fx (ScreenFx (..), progressR, retargetScreen, shake, shakeX)
import Dots.Installer.Input (KeyCode (..), KeyEvent (..))
import Dots.Installer.Install (animationsEnabled)
import Dots.Installer.Net (WifiNetwork (..), signalBars, wifiIsOpen)

-- * Tokyonight palette

fgA :: V.Attr
fgA = rgbaAttr (rgb 0xc0 0xca 0xf5)

blueA :: V.Attr
blueA = rgbaAttr (rgb 0x7a 0xa2 0xf7)

cyanA :: V.Attr
cyanA = rgbaAttr (rgb 0x7d 0xcf 0xff)

greenA :: V.Attr
greenA = rgbaAttr (rgb 0x9e 0xce 0x6a)

magentaA :: V.Attr
magentaA = rgbaAttr (rgb 0xbb 0x9a 0xf7)

redA :: V.Attr
redA = rgbaAttr (rgb 0xf7 0x76 0x8e)

redBoldA :: V.Attr
redBoldA = V.withStyle redA V.bold

yellowA :: V.Attr
yellowA = rgbaAttr (rgb 0xe0 0xaf 0x68)

dimA :: V.Attr
dimA = rgbaAttr (rgb 0x56 0x5f 0x89)

cyanBoldA :: V.Attr
cyanBoldA = V.withStyle cyanA V.bold

greenBoldA :: V.Attr
greenBoldA = V.withStyle greenA V.bold

yellowBoldA :: V.Attr
yellowBoldA = V.withStyle yellowA V.bold

borderAttr :: V.Attr
borderAttr = rgbaAttr (rgb 0x56 0x5f 0x89)

titleAttr :: V.Attr
titleAttr = rgbaAttr (rgb 0xc0 0xca 0xf5)

-- * Root view

-- | Root component: one 'dynView' that re-reads 'app' and 'fx' and dispatches
-- by 'Screen', plus a root 'onEvent' that bridges vty key events into the pure
-- 'App' state machine. 'fx' supplies the animated panel slide + error shake;
-- the installing screen reads its eased progress ratio when animations are on
-- (else the raw step ratio).
rootView ::
  forall t.
  Signal t App ->
  Signal t ScreenFx ->
  View t
rootView appSig fxSig =
  build
    . style fill
    . child
        ( dynView fill $ do
            dw <- displayWidth
            dh <- displayHeight
            -- Snapshot DOTS_NO_ANIM once: env vars don't change mid-session, so
            -- baking the Bool into the behavior keeps per-frame sampling pure.
            animOn <- liftIO animationsEnabled
            pure
              ( ( \a f w h ->
                    let layers = wizardPanel a f animOn w h
                        shx = shakeX f
                    in if shx == 0
                         then layers
                         else map (V.translate shx 0) layers
                )
                  <$> current (sigDyn appSig)
                  <*> current (sigDyn fxSig)
                  <*> dw
                  <*> dh
              )
        )
    . onEvent
        ( \ev -> case ev of
            UiEventKey k -> case mapKey k of
              Just code -> do
                prev <- sigReadRef appSig
                let prevScreen = appScreen prev
                    prevError = appError prev
                    next = handleKey prev (KeyEvent code)
                    nextScreen = appScreen next
                    nextError = appError next
                sigSetIO appSig next
                -- Retarget the panel slide on screen change.
                fx0 <- sigReadRef fxSig
                fx1 <-
                  if nextScreen /= prevScreen
                    then retargetScreen fx0 0.0
                    else pure fx0
                -- Fire the error shake when a new error appears.
                fx2 <- case nextError of
                  Just _ | nextError /= prevError -> shake fx1
                  _ -> pure fx1
                sigSetIO fxSig fx2
              Nothing -> pure ()
        )
    $ elementNew

-- * Wizard panel

-- | The wizard shell: every screen renders as a bordered panel, offset by the
-- animated 'fx' shake. Returns the image layers (border+fill on the bottom,
-- content on top) — the Driver composites them via 'V.picForLayers'. Mirrors
-- @wizard_panel@.
wizardPanel :: App -> ScreenFx -> Bool -> Int -> Int -> [V.Image]
wizardPanel app fx animOn w h =
  let (title, contentLines) = screenContent app fx animOn
      borderImg = renderBlock title w h
      contentImg = renderContent contentLines (max 0 (w - 2))
  in [borderImg, V.pad 1 0 1 0 contentImg]

-- | Per-screen (title, content lines). Mirrors @wizard_panel@ dispatch.
screenContent :: App -> ScreenFx -> Bool -> (String, [Line])
screenContent app fx animOn = case appScreen app of
  ScreenWelcome -> welcomeScreen app
  ScreenNetwork -> networkScreen app
  ScreenWifiPassword -> wifiPasswordScreen app
  ScreenWifiConnecting -> wifiConnectingScreen app
  ScreenDiskSelect -> diskSelectScreen app
  ScreenHostname -> promptScreen
    " hostname " "Hostname (empty = \"tokyonight\"):" (appInput app) False "Enter confirm" app
  ScreenUsername -> promptScreen
    " user " "Username for the primary user:" (appInput app) False "Enter confirm" app
  ScreenGitName -> promptScreen
    " git identity " "Git user.name (commits will be signed with this):" (appInput app) False "Enter confirm · Esc back" app
  ScreenGitEmail -> promptScreen
    " git identity " "Git user.email:" (appInput app) False "Enter confirm · Esc back" app
  ScreenAi -> aiScreen app
  ScreenUserPassword -> promptScreen
    " user password " "User password:" (appInput app) True "Enter confirm" app
  ScreenUserPasswordConfirm -> promptScreen
    " user password " "Repeat user password:" (appInput app) True "Enter confirm" app
  ScreenConfirm -> confirmScreen app
  ScreenInstalling -> installingScreen app fx animOn
  ScreenFailed -> failedScreen app
  ScreenDone -> doneScreen app

-- * Per-screen content

-- | A styled text line: the text and its vty attribute.
data Line = Line String V.Attr

-- | An empty line (vertical spacer).
blank :: Line
blank = Line "" V.defAttr

-- | A plain (default-attr) line.
plain :: String -> Line
plain s = Line s fgA

-- | The Welcome screen: title + intro blurb + hint. Mirrors @welcome_view@.
welcomeScreen :: App -> (String, [Line])
welcomeScreen app =
  ( "tokyonight-dots installer"
  , [ blank
    , Line "  NixOS · TPM2-encrypted btrfs · i3 + Hyprland · Tokyonight" magentaA
    , blank
    , plain "  This wizard ERASES the selected disk(s) and installs the"
    , plain "  NixOS system from the flake bundled with this ISO."
    , blank
    , Line "Enter continue · Esc quit" dimA
    ]
      <> pushError app
  )

-- | The Network screen: status line, busy line, Wi-Fi list, hint. Mirrors
-- @network_view@.
networkScreen :: App -> (String, [Line])
networkScreen app =
  ( " network "
  , [ blank
    , plain "  Wi-Fi setup — nixos-install pulls from the binary cache,"
    , plain "  so get online unless this is the offline (iso-full) image."
    , blank
    , statusLine (appOnline app)
    ]
      <> busyLine (appNetBusy app)
      <> [blank]
      <> wifiListLines
      <> [ blank
          , Line "↑/↓ select · Enter connect · r rescan · s skip · Esc back" dimA
          ]
      <> pushError app
  )
  where
    statusLine Nothing = Line "  status: checking…" dimA
    statusLine (Just True) = Line "  status: online ✓" greenA
    statusLine (Just False) = Line "  status: offline ✗" yellowA
    busyLine Nothing = []
    busyLine (Just b) = [Line ("  " <> b) cyanA]
    wifiListLines
      | null (appWifiNetworks app) && appNetBusy app == Nothing =
          [Line "  no Wi-Fi networks found (wired is fine too — press s)" dimA]
      | otherwise = map renderNet (zip [0 ..] (appWifiNetworks app))
    renderNet (i, n) =
      let marker = if i == appWifiSelected app then "  ▶ " else "    "
          ink = if i == appWifiSelected app then cyanBoldA else fgA
          sec = if wifiIsOpen n then "open" else wnSecurity n
      in Line (marker <> signalBars n <> " " <> wnSsid n <> "  " <> sec) ink

-- | The WifiPassword screen. Mirrors @prompt_screen@ for the Wi-Fi passphrase.
wifiPasswordScreen :: App -> (String, [Line])
wifiPasswordScreen app =
  ( " Wi-Fi passphrase "
  , inputLines
      ("Passphrase for \"" <> appWifiSsid app <> "\":")
      (appInput app)
      True
      <> [blank, Line "Enter connect · Esc back" dimA]
      <> pushError app
  )

-- | The WifiConnecting screen. Mirrors @wifi_connecting_view@.
wifiConnectingScreen :: App -> (String, [Line])
wifiConnectingScreen app =
  ( " connecting "
  , [ blank
    , Line ("  connecting to \"" <> appWifiSsid app <> "\"…") cyanA
    , blank
    , Line "  asking NetworkManager, this can take a few seconds" dimA
    , blank
    , Line "please wait" dimA
    ]
  )

-- | The DiskSelect screen: multi-select list with ASCII markers. Mirrors
-- @disk_select_view@.
diskSelectScreen :: App -> (String, [Line])
diskSelectScreen app =
  ( " target disks "
  , [ blank
    , plain "  Select target disks to span the LVM volume group"
    , plain "  (each will be ERASED):"
    , blank
    ]
      <> (if null (appDisks app)
            then [Line "  no installable disks found" redA]
            else [])
      <> zipWith renderDisk [0 ..] (appDisks app)
      <> [ blank
          , Line "↑/↓ move · Space toggle · Enter confirm · Esc back" dimA
          ]
      <> pushError app
  )
  where
    renderDisk i d =
      let cursor = if i == appSelected app then "▶" else " "
          mark = if atBool (appPicked app) i then "[x]" else "[ ]"
          removable = if diskRemovable d then " [removable]" else ""
          ink = if i == appSelected app then cyanBoldA else fgA
      in Line
          ( " " <> cursor <> " " <> mark <> " " <> diskPath d <> "  "
              <> humanSize d <> "  " <> diskModel d <> removable
          )
          ink

-- | The Ai screen: three-row toggle list. Mirrors @ai_view@.
aiScreen :: App -> (String, [Line])
aiScreen app =
  ( " ai "
  , [ blank
    , plain "  Select AI tooling to enable:"
    , Line "  (written to settings.nix as aiClaude/aiCodex/aiOllama)" dimA
    , blank
    ]
      <> zipWith renderToggle [0 ..] opts
      <> [blank, Line "↑/↓ move · Space toggle · Enter confirm · Esc back" dimA]
      <> pushError app
  )
  where
    opts =
      [ ("Claude Code", icAiClaude cfg)
      , ("Codex CLI", icAiCodex cfg)
      , ("Ollama", icAiOllama cfg)
      ]
    cfg = appConfig app
    renderToggle i (label, on) =
      let cursor = if i == appAiSelected app then "▶" else " "
          mark = if on then "[x]" else "[ ]"
          ink = if i == appAiSelected app then cyanBoldA else fgA
      in Line (" " <> cursor <> " " <> mark <> " " <> label) ink

-- | The Confirm screen: disk info + ERASE prompt. Mirrors @confirm_view@.
confirmScreen :: App -> (String, [Line])
confirmScreen app =
  ( " point of no return "
  , [ blank
    , Line ("  ALL DATA on " <> disks <> " will be permanently erased!") redBoldA
    , blank
    , plain ("    disks     " <> disks)
    , plain ("    hostname  " <> icHostname cfg)
    , plain ("    user      " <> icUsername cfg)
    , plain ("    git       " <> icGitName cfg <> " <" <> icGitEmail cfg <> ">")
    , plain ("    swap      " <> show (icSwapSizeGib cfg) <> "G")
    , plain
        ( "    ai        claude " <> onOff (icAiClaude cfg)
            <> " · codex " <> onOff (icAiCodex cfg)
            <> " · ollama " <> onOff (icAiOllama cfg)
        )
    , blank
    , plain "  Type ERASE to proceed:"
    , Line ("  > " <> appInput app) yellowA
    , blank
    , Line "Enter proceed · Esc back" dimA
    ]
      <> pushError app
  )
  where
    cfg = appConfig app
    disks = intercalate ", " (icDisks cfg)

-- | The Installing screen: step label + progress bar + log tail. Mirrors
-- @installing_view@. Reads the eased progress ratio from 'fx' when animations
-- are on, else the raw step ratio.
installingScreen :: App -> ScreenFx -> Bool -> (String, [Line])
installingScreen app fx animOn =
  ( " installing "
  , [ Line
        ( "step " <> show (appCurrentStep app) <> "/"
            <> show (appTotalSteps app) <> " — " <> appStepTitle app
        )
        cyanA
    , Line (progressBar ratio) cyanA
    ]
      <> map (\l -> Line l dimA) logTail
  )
  where
    raw
      | appTotalSteps app == 0 = 0.0
      | otherwise =
          max 0.0 (min 1.0 (fromIntegral (appCurrentStep app) / fromIntegral (appTotalSteps app)))
    ratio = if animOn then max 0.0 (min 1.0 (progressR fx)) else raw
    -- Last 8 log lines, in order (Rust: rev().take(8).rev()).
    logTail = take 8 (drop (max 0 (length (appLog app) - 8)) (appLog app))

-- | The Failed screen. Mirrors @failed_view@.
failedScreen :: App -> (String, [Line])
failedScreen app =
  ( " installation failed "
  , [ blank
    , Line msg redBoldA
    , blank
    , Line "Ctrl+Alt+F2 opens a root shell · q quits this screen" dimA
    , blank
    ]
      <> map plain logTail
  )
  where
    msg = case appError app of
      Just e -> e
      Nothing -> "unknown error"
    logTail = take 6 (drop (max 0 (length (appLog app) - 6)) (appLog app))

-- | The Done screen. Mirrors @done_view@.
doneScreen :: App -> (String, [Line])
doneScreen app =
  ( " installed "
  , [ blank
    , Line "  Installation finished." greenBoldA
    , blank
    , plain "  LUKS recovery key (also in /root/luks-recovery.txt"
    , plain "  on the installed system) — WRITE IT DOWN:"
    , blank
    , Line ("    " <> key) yellowBoldA
    , blank
    , plain "  Remove the installation medium, then press Enter to reboot."
    , blank
    , Line "Enter reboot" dimA
    ]
  )
  where
    key = case appRecoveryKey app of
      Just k -> k
      Nothing -> "(missing)"

-- | A generic prompt + input-line screen. Mirrors @prompt_screen@.
promptScreen ::
  String ->
  String ->
  String ->
  Bool ->
  String ->
  App ->
  (String, [Line])
promptScreen title prompt input mask hint app =
  ( title
  , inputLines prompt input mask
      <> [blank, Line hint dimA]
      <> pushError app
  )

-- | Prompt + masked/echoed input with a block cursor glyph. Mirrors
-- @input_lines@.
inputLines :: String -> String -> Bool -> [Line]
inputLines prompt input mask =
  [ blank
  , plain ("  " <> prompt)
  , blank
  , Line ("  > " <> shown <> "█") cyanA
  ]
  where
    shown = if mask then replicate (length input) '•' else input

-- | Append the red error line (if any) with a leading blank separator.
-- Mirrors @push_error@.
pushError :: App -> [Line]
pushError app = case appError app of
  Just e -> [blank, Line ("  ✗ " <> e) redA]
  Nothing -> []

-- * Rendering: block border + content

-- | Render the block border (rounded) with a title, full terminal size. The
-- interior is a background fill. Mirrors @renderBlock@ from
-- "AbstractTUI.Widget.Block" (NOT exported, replicated here).
renderBlock :: String -> Int -> Int -> V.Image
renderBlock title w h
  | w <= 0 || h <= 0 = V.emptyImage
  | h == 1 = renderTopRow title w
  | otherwise =
      let topRow = renderTopRow title w
          bottomRow = renderHRow w
          midRows = replicate (max 0 (h - 2)) (renderMidRow w)
      in V.vertCat ([topRow] ++ midRows ++ [bottomRow])

renderTopRow :: String -> Int -> V.Image
renderTopRow title w =
  let innerW = max 0 (w - 2)
      titleT = T.pack title
      cap = T.take (max 0 (innerW - 1)) titleT
      titleImg = V.text' titleAttr cap
      restW = max 0 (innerW - 1 - T.length cap)
      restHline = V.text' borderAttr (T.replicate restW (T.singleton '─'))
  in V.horizCat
       [ V.char borderAttr '╭'
       , V.char borderAttr ' '
       , titleImg
       , restHline
       , V.char borderAttr '╮'
       ]

renderHRow :: Int -> V.Image
renderHRow w =
  let innerW = max 0 (w - 2)
      hline = V.text' borderAttr (T.replicate innerW (T.singleton '─'))
  in V.horizCat [V.char borderAttr '╰', hline, V.char borderAttr '╯']

renderMidRow :: Int -> V.Image
renderMidRow w =
  let innerW = max 0 (w - 2)
  in V.horizCat
       [ V.char borderAttr '│'
       , V.text' V.defAttr (T.replicate innerW (T.singleton ' '))
       , V.char borderAttr '│'
       ]

-- | Render the content lines as a single 'V.Image', clipped to the interior
-- width. Height is whatever the lines produce — the border layer behind fills
-- the rest.
renderContent :: [Line] -> Int -> V.Image
renderContent lines' w = V.vertCat (map renderLine lines')
  where
    renderLine (Line txt attr) = V.text' attr (T.take w (T.pack txt))

-- * Progress bar (replicated from "AbstractTUI.Widget.Progress")

-- | Render the progress bar at 78 columns (the interior of an 80-wide panel).
-- The filled prefix is @█@, the sub-cell remainder one eighth-block glyph, the
-- tail blank space. Mirrors @renderProgress@ from "AbstractTUI.Widget.Progress"
-- (NOT exported).
progressBar :: Float -> String
progressBar f = take barW (full <> part <> empty)
  where
    barW = 78
    frac = max 0.0 (min 1.0 f)
    filled = frac * fromIntegral barW
    fullN = floor filled
    leftover = filled - fromIntegral fullN
    full = replicate fullN '█'
    part = if leftover > 0 then [eighthGlyph leftover] else ""
    empty = repeat ' '

eighths :: String
eighths = "▏▎▍▌▋▊▉"

eighthGlyph :: Float -> Char
eighthGlyph r
  | null eighths = ' '
  | otherwise = eighths !! clamp 0 (length eighths - 1) (round (r * 8) - 1)
  where
    clamp lo hi v = max lo (min hi v)

-- * Small helpers

-- | @true@ → @"on"@, @false@ → @"off"@. Mirrors @on_off@.
onOff :: Bool -> String
onOff True = "on"
onOff False = "off"

-- | Index into a list as a Bool (default False). Mirrors
-- @app.picked.get(i).unwrap_or(&false)@.
atBool :: [Bool] -> Int -> Bool
atBool xs i = case drop i xs of
  (b : _) -> b
  [] -> False

-- | Map the abstracttui 'Key' to the wizard's 'KeyCode'. Unknown keys map to
-- 'Nothing' — the wizard ignores them. Only the keys 'handleKey' reacts to
-- are forwarded. Mirrors @map_key@.
mapKey :: Key -> Maybe KeyCode
mapKey k = case k of
  KeyChar c -> Just (KeyChar c)
  KeyEnter -> Just KeyEnter
  KeyEsc -> Just KeyEsc
  KeyBackspace -> Just KeyBackspace
  KeyUp -> Just KeyUp
  KeyDown -> Just KeyDown
  _ -> Nothing