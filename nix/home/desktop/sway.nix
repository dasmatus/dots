# Home-manager Sway compositor config. Imported by
# nix/home/profiles/session.nix when dots.desktop.environment == "sway".
# Shares GTK/Qt/dconf/cursor with the other DEs through ./common.nix.
{
  config,
  pkgs,
  lib,
  settings,
  ...
}:
let
  cfg = config.dots.session;
  actions = import ./session/actions.nix;
  keyedActions = builtins.filter (a: a.key != null) actions;

  swaymsg = lib.getExe' pkgs.sway "swaymsg";

  # Sway dispatch map: abstract dispatch names → swaymsg commands.
  # Keyed off `dispatch`, never off `name`: several `name`s share one
  # `dispatch` value.
  dispatchMap =
    {
      "window.close" = "kill";
      "window.float-toggle" = "floating toggle";
      "window.fullscreen" = "fullscreen toggle";
      "window.pseudo" = "layout toggle split";

      "workspace.toggle-scratch" = "scratchpad show";
      "workspace.move-scratch" = "move scratchpad";
      "workspace.toggle-magic" = "workspace magic";
      "workspace.move-magic" = "move workspace magic";
      "workspace.next" = "workspace next";
      "workspace.prev" = "workspace prev";

      "focus.left" = "focus left";
      "focus.right" = "focus right";
      "focus.up" = "focus up";
      "focus.down" = "focus down";

      "window.move-left" = "move left";
      "window.move-right" = "move right";
      "window.move-up" = "move up";
      "window.move-down" = "move down";

      "window.resize-left" = "resize shrink width 40px";
      "window.resize-right" = "resize grow width 40px";
      "window.resize-up" = "resize shrink height 40px";
      "window.resize-down" = "resize grow height 40px";

      "window.drag" = "floating toggle; focus mode_toggle";
      "window.resize" = "floating toggle; resize";
    }
    // lib.listToAttrs (
      map (n: lib.nameValuePair "workspace.focus-${toString n}" "workspace number ${toString n}") (
        lib.range 1 10
      )
    )
    // lib.listToAttrs (
      map (n: lib.nameValuePair "workspace.move-${toString n}" "move container to workspace number ${toString n}") (
        lib.range 1 10
      )
    );

  # Key rendering for sway's bindsym: mods joined with +, key appended.
  mkKey =
    a:
    if a.mods == [ ] then
      a.key
    else
      "${lib.concatStringsSep "+" (map (m: if m == "SUPER" then "Mod4" else m) a.mods)}+${a.key}";

  # Dispatch rendering: dispatch rows look up swaymsg commands; app/action
  # rows run through `exec`.
  mkDispatch =
    a:
    if a.kind == "dispatch" then
      dispatchMap.${a.dispatch}
        or (throw "nix/home/desktop/sway.nix: no swaymsg dispatcher registered for dispatch `${a.dispatch}`, from action `${a.name}`")
    else
      "exec ${cfg.commands.${a.name}}";

  # One bindsym per keyed row.
  mkBind =
    a:
    let
      key = mkKey a;
      cmd = mkDispatch a;
    in
    if a.mouse then
      # Mouse binds use --whole-window for drag/resize.
      "bindsym --whole-window ${key} ${cmd}"
    else if a.repeating then
      # Sway repeats binds by default when held; no special flag needed.
      "bindsym ${key} ${cmd}"
    else
      "bindsym ${key} ${cmd}";
in
{
  imports = [ ./common.nix ];

  # Sway-only session exec entries: reload and screenshots.
  dots.session.exec = {
    reload = "${swaymsg} reload";
    screenshot-output = "${lib.getExe pkgs.grim} -o $(${swaymsg} -t get_outputs | ${lib.getExe pkgs.jq} -r '.[] | select(.focused) | .name')";
    screenshot-region = "${lib.getExe pkgs.grim} -g \"$(${lib.getExe pkgs.slurp})\"";
    screenshot-window = "${lib.getExe pkgs.grim} -g \"$(${swaymsg} -t get_tree | ${lib.getExe pkgs.jq} -r '.. | select(.focused?) | .rect | \"\\(.x),\\(.y) \\(.width)x\\(.height)\"')\"";
  };

  # KillMode=process for screenshot units (same rationale as hyprland.nix:
  # grim backgrounds and the cgroup teardown kills the capture).
  systemd.user.services."dots-screenshot-output@".Service.KillMode = "process";
  systemd.user.services."dots-screenshot-region@".Service.KillMode = "process";
  systemd.user.services."dots-screenshot-window@".Service.KillMode = "process";

  # swaylock service, mirroring hyprlock's unit structure.
  systemd.user.services.swaylock = {
    Unit = {
      Description = "Screen locker for Wayland";
      Documentation = [ "man:swaylock(1)" ];
      OnSuccess = [ "unlock.target" ];
      PartOf = [ "lock.target" ];
      Before = [ "lock.target" ];
    };
    Service = {
      Type = "forking";
      ExecStart = "${lib.getExe pkgs.swaylock}";
      Restart = "on-failure";
      RestartSec = 0;
    };
    Install = {
      WantedBy = [ "lock.target" ];
    };
  };

  wayland.windowManager.sway = {
    enable = true;
    # Use the system package (programs.sway in nix/modules/desktop/sway.nix).
    package = null;
    systemd.enable = false;

    config = {
      modifier = "Mod4";

      # Gaps and borders from settings.
      gaps.inner = settings.wmGapsIn;
      gaps.outer = settings.wmGapsOut;
      window.border = settings.wmBorderSize;

      # Colors matching the Tokyonight palette.
      colors = {
        focused = {
          border = "#9aa5ce";
          background = "#9aa5ce";
          text = "#c0caf5";
          indicator = "#7aa2f7";
          childBorder = "#9aa5ce";
        };
        unfocused = {
          border = "#16161d";
          background = "#16161d";
          text = "#737aa2";
          indicator = "#16161d";
          childBorder = "#16161d";
        };
      };

      # Input.
      input."*" = {
        xkb_layout = "us";
        xkb_options = "caps:escape";
      };
      input."type:touchpad" = {
        natural_scroll = "enabled";
        drag_lock = "disabled";
      };

      # Focus follows mouse.
      focus.followMouse = if settings.wmFollowMouse then "yes" else "no";

      # Animations: Sway has no built-in animation support.
      # (No equivalent to Hyprland's animations.enabled.)

      # Window rules: force blur equivalent doesn't exist in Sway.
      # Sway has no compositor-level blur; transparency is per-application.

      # Keybindings from the actions table.
      keybindings = lib.listToAttrs (
        map (
          a:
          let
            key = mkKey a;
            cmd = mkDispatch a;
          in
          lib.nameValuePair key cmd
        ) (builtins.filter (a: !a.mouse) keyedActions)
      );

      # Mouse bindings (drag/resize) go in the `bindswitches`/`floating` section.
      # Sway handles these via floating_modifier and mouse bindings in the
      # config file, not through the keybindings attrset.
      floating.modifier = "Mod4";

      # Startup: session variables are handled by systemd.user.sessionVariables
      # (nix/home/desktop/session/default.nix), not by Sway's exec.
    };

    # Extra config for things the module doesn't model.
    extraConfig = ''
      # Mouse bindings for drag/resize (Sway's keybindings attrset doesn't
      # model mouse buttons).
      ${lib.concatStringsSep "\n" (
        map (a: "bindsym --whole-window ${mkKey a} ${mkDispatch a}") (
          builtins.filter (a: a.mouse) keyedActions
        )
      )}
    '';
  };

  # Sway-specific packages.
  home.packages = [
    pkgs.grim
    pkgs.slurp
    pkgs.libnotify
    pkgs.xdg-user-dirs
    pkgs.xdg-desktop-portal-gtk
  ];

  # Portal config for Sway sessions.
  xdg.portal.config.sway = {
    default = [
      "wlr"
      "gtk"
    ];
    "org.freedesktop.portal.Settings" = "gtk";
  };

  # swaylock configuration.
  programs.swaylock = {
    enable = true;
    settings = {
      color = "1a1b26";
      font = "Lilex Nerd Font";
      font-size = 96;
      indicator-radius = 100;
      indicator-thickness = 2;
      ring-color = "7aa2f7";
      ring-ver-color = "e0af68";
      ring-wrong-color = "f7768e";
      ring-caps-lock-color = "ff9e64";
      key-hl-color = "9aa5ce";
      inside-color = "1a1b26cc";
      inside-ver-color = "1a1b26cc";
      inside-wrong-color = "1a1b26cc";
      text-color = "c0caf5";
      text-ver-color = "c0caf5";
      text-wrong-color = "c0caf5";
      show-failed-attempts = true;
      show-keyboard-layout = false;
      hide-keyboard-layout = true;
    };
  };

  # redshift -l 48.15:17.11 -t 4500:3000 -b 0.9:0.75 → gammastep.
  services.gammastep = {
    enable = true;
    latitude = "48.15";
    longitude = "17.11";
    temperature = {
      day = 4500;
      night = 3000;
    };
    tray = true;
    settings.general = {
      brightness-day = 0.9;
      brightness-night = 0.75;
    };
  };
}
