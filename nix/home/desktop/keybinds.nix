# First-login keybind cheatsheet data. The list feeds the shell's cheatsheet
# overlay (nix/home/desktop/quickshell/qml/cheatsheet), reached with SUPER+/.
#
# Derived from nix/home/desktop/session/actions.nix instead of hand-curated: that
# table carries one row per bind, so this file's only remaining job is
# deciding which of those rows the overlay shows as a single summary line
# instead of one row apiece (the `collapses` table below), and rendering
# the `key` text in this overlay's own human style — `SUPER + Shift + F`,
# not the action table's `SUPER + SHIFT + F`.
#
# Every action name mentioned below, whether inside a collapse entry or as
# a bare one-to-one reference, is checked against actions.nix, and every
# keyed action in actions.nix must be claimed exactly once: not zero times
# (a new bind nobody decided how to show in the cheatsheet) and not twice.
# Get either wrong and evaluation throws, naming the offending action —
# that failure, not the collapsing itself, is what stops this file drifting
# out of step with actions.nix the way the old hand-curated table did with
# hyprland.nix.
#
# Plain data, not a home-manager module, and argument-free like
# actions.nix: it's imported the same way from two places, one of which
# (flake/packages.nix, the qmllint gate) has no evaluated home-manager
# config to draw arguments from, and nix/home/desktop/quickshell/tree.nix runs a
# strict builtins.toJSON over the result — a lambda or a store path
# anywhere in this file would break both.
#
# `touchpad` and `kitty` are the exception: hand-written below because they
# have no rows in actions.nix at all. The touchpad gestures come from
# `hl.gesture` (nix/home/desktop/hyprland.nix:345) and kitty's Shift+Enter bind from
# nix/home/apps/kitty.nix:52 — neither is a `bind` entry, so neither belongs in
# a table about exec/dispatch binds.
#
# Grouped, not flattened — a QML Repeater nests groups without complaint,
# so the shape can say what it means: a list of `{ name; items; }`, one per
# cheatsheet section.
let
  actions = import ./session/actions.nix;
  keyedActions = builtins.filter (a: a.key != null) actions;

  # Every action name this file references is resolved through here, so a
  # typo'd or renamed action fails evaluation instead of silently vanishing
  # from the cheatsheet.
  findAction =
    name:
    let
      matches = builtins.filter (a: a.name == name) actions;
    in
    if matches == [ ] then
      throw "nix/home/desktop/keybinds.nix: references action `${name}`, which does not exist in nix/home/desktop/session/actions.nix"
    else
      builtins.head matches;

  # Human-facing spelling for the cheatsheet, distinct from the WM-facing
  # spelling actions.nix carries: SHIFT/ALT/CTRL there read as
  # Shift/Alt/Ctrl here, and a couple of X11 keysym names read better
  # spelled out. Both are total over their input, on purpose: a mod or key
  # this file doesn't know how to render throws instead of printing raw,
  # which is the same drift the coverage check below exists to catch —
  # silently rendering an unrecognised mod or keysym would be exactly the
  # kind of un-noticed staleness this file was rewritten to make
  # impossible.
  modLabel =
    m:
    if m == "SUPER" then
      "SUPER"
    else if m == "SHIFT" then
      "Shift"
    else if m == "ALT" then
      "Alt"
    else if m == "CTRL" then
      "Ctrl"
    else
      throw "nix/home/desktop/keybinds.nix: renderKey does not know how to render modifier `${m}`";

  # Keysyms the overlay has always printed raw, deliberately: not letters,
  # not digits, not an XF86 media key, not a mouse form, and not worth a
  # human translation either. Written down as a decision rather than left
  # as a silent fallback — anything outside this list and outside the
  # mechanical patterns below throws.
  keyPassthrough = [
    "comma"
    "minus"
    "Space"
    "Print"
  ];

  keyLabel =
    k:
    if k == "Return" then
      "Enter"
    else if k == "slash" then
      "/"
    else if builtins.elem k keyPassthrough then
      k
    else if builtins.match "[A-Z]" k != null then
      k
    else if builtins.match "[0-9]" k != null then
      k
    else if builtins.match "XF86.*" k != null then
      k
    else if builtins.match "mouse.*" k != null then
      k
    else
      throw "nix/home/desktop/keybinds.nix: renderKey does not know how to render key `${k}`";

  renderKey = mods: key: builtins.concatStringsSep " + " (map modLabel mods ++ [ (keyLabel key) ]);

  # A one-to-one cheatsheet row, straight off its actions.nix entry: the
  # `key`/`mods` render through the human style above, the `desc` is used
  # verbatim.
  one =
    name:
    let
      a = findAction name;
    in
    {
      key = renderKey a.mods a.key;
      desc = a.desc;
    };

  collapseRow = c: {
    inherit (c) key desc;
  };

  # The collapse table: every place the cheatsheet prints one summary row
  # for several actions.nix rows instead of one row per bind (`SUPER +
  # H/J/K/L` for four directional focus binds, `SUPER + 1..0` for ten
  # workspace binds, and so on). Each entry names every action it covers —
  # validated below — and the key/desc text to print once for all of them.
  collapses = {
    focusHjkl = {
      names = [
        "focus.left"
        "focus.down"
        "focus.up"
        "focus.right"
      ];
      key = "SUPER + H/J/K/L";
      desc = "Focus left/down/up/right";
    };
    focusArrows = {
      names = [
        "focus.left-arrow"
        "focus.down-arrow"
        "focus.up-arrow"
        "focus.right-arrow"
      ];
      key = "SUPER + Arrows";
      desc = "Focus (arrows)";
    };
    moveHjkl = {
      names = [
        "window.move-left"
        "window.move-down"
        "window.move-up"
        "window.move-right"
      ];
      key = "SUPER + Shift + H/J/K/L";
      desc = "Move window";
    };
    moveArrows = {
      names = [
        "window.move-left-arrow"
        "window.move-down-arrow"
        "window.move-up-arrow"
        "window.move-right-arrow"
      ];
      key = "SUPER + Shift + Arrows";
      desc = "Move window (arrows)";
    };
    workspaceFocus = {
      names = builtins.genList (i: "workspace.focus-${toString (i + 1)}") 10;
      key = "SUPER + 1..0";
      desc = "Workspace 1–10";
    };
    workspaceMove = {
      names = builtins.genList (i: "workspace.move-${toString (i + 1)}") 10;
      key = "SUPER + Shift + 1..0";
      desc = "Move window to workspace 1–10";
    };
    workspaceWheel = {
      names = [
        "workspace.next"
        "workspace.prev"
      ];
      key = "SUPER + mouse wheel";
      desc = "Cycle workspaces";
    };
    windowResize = {
      names = [
        "window.resize-left"
        "window.resize-down"
        "window.resize-up"
        "window.resize-right"
      ];
      key = "SUPER + Alt + H/J/K/L";
      desc = "Resize window";
    };
    mediaMute = {
      names = [
        "volume-mute"
        "mic-mute"
      ];
      key = "Audio/Mic Mute";
      desc = "Mute sink / source (shows an OSD)";
    };
    mediaVolume = {
      names = [
        "volume-up"
        "volume-down"
      ];
      key = "Volume Up/Down";
      desc = "Volume ±5% (shows an OSD)";
    };
    mediaBrightness = {
      names = [
        "brightness-up"
        "brightness-down"
      ];
      key = "Brightness Up/Down";
      desc = "Brightness ±5% (shows an OSD)";
    };
    mouseDrag = {
      names = [
        "window.drag"
        "window.resize"
      ];
      key = "SUPER + L/R-drag";
      desc = "Move / resize window (mouse)";
    };
  };

  # Per-category row order. A bare action name projects one-to-one; a
  # `collapse` prints its table entry's key/desc once. actions.nix's own
  # declaration order does not decide this — e.g. `media` below interleaves
  # collapsed and one-to-one rows in an order its source rows aren't
  # declared in — so order is spelled out here, once, per category.
  categorySpecs = {
    launchers = map (n: { one = n; }) [
      "terminal"
      "launcher-toggle"
      "file-manager"
      "notes"
      "editor"
      "cheatsheet-toggle"
      "settings-toggle"
      "wallpaper-toggle"
      "arrange-toggle"
    ];
    window =
      map (n: { one = n; }) [
        "window.close"
        "window.float-toggle"
        "window.fullscreen"
        "window.pseudo"
      ]
      ++ [ { collapse = collapses.windowResize; } ];
    focus = map (c: { collapse = c; }) [
      collapses.focusHjkl
      collapses.focusArrows
      collapses.moveHjkl
      collapses.moveArrows
    ];
    workspaces = map (c: { collapse = c; }) [
      collapses.workspaceFocus
      collapses.workspaceMove
      collapses.workspaceWheel
    ];
    special = map (n: { one = n; }) [
      "workspace.toggle-scratch"
      "workspace.move-scratch"
      "workspace.toggle-magic"
      "workspace.move-magic"
    ];
    session =
      map (n: { one = n; }) [
        "lock"
        "reload"
        "screenshot-output"
        "screenshot-region"
        "screenshot-window"
      ]
      ++ [ { collapse = collapses.mouseDrag; } ];
    media =
      map (c: { collapse = c; }) [
        collapses.mediaMute
        collapses.mediaVolume
        collapses.mediaBrightness
      ]
      ++ map (n: { one = n; }) [
        "touchpad-toggle"
        "privacy-toggle"
      ];
  };

  renderSpec = spec: if spec ? one then one spec.one else collapseRow spec.collapse;

  # Names claimed by a spec, resolved through `findAction` so a typo in
  # either a bare reference or a collapse's `names` fails evaluation here
  # rather than silently under-counting coverage below.
  specNames =
    spec:
    if spec ? one then
      [ (findAction spec.one).name ]
    else
      map (n: (findAction n).name) spec.collapse.names;

  allSpecs = builtins.concatLists (builtins.attrValues categorySpecs);
  coveredNames = builtins.concatMap specNames allSpecs;
  countOf = name: builtins.length (builtins.filter (n: n == name) coveredNames);

  uncovered = builtins.filter (a: countOf a.name == 0) keyedActions;
  overcovered = builtins.filter (a: countOf a.name > 1) keyedActions;

  derivedCategories = builtins.mapAttrs (_: specs: map renderSpec specs) categorySpecs;

  # touchpad/kitty: no rows in actions.nix at all (see header), so
  # hand-kept rather than derived.
  handWritten = {
    touchpad = [
      {
        key = "3-finger swipe left / right";
        desc = "Switch workspaces";
      }
      {
        key = "4-finger swipe left / right";
        desc = "Move window to adjacent workspace";
      }
      {
        key = "4-finger swipe down";
        desc = "Toggle scratch workspace";
      }
    ];
    kitty = [
      {
        key = "Shift + Enter";
        desc = "Send Ctrl-M (kitty, for zellij)";
      }
    ];
  };

  keybinds = derivedCategories // handWritten;
in
assert
  if uncovered != [ ] then
    throw "nix/home/desktop/keybinds.nix: keyed action(s) not covered by any cheatsheet row or collapse entry: ${
      builtins.concatStringsSep ", " (map (a: a.name) uncovered)
    }"
  else if overcovered != [ ] then
    throw "nix/home/desktop/keybinds.nix: keyed action(s) covered by more than one cheatsheet row or collapse entry: ${
      builtins.concatStringsSep ", " (map (a: a.name) overcovered)
    }"
  else
    true;
map (category: {
  name = category;
  items = keybinds.${category};
}) (builtins.attrNames keybinds)
