# hyprmon — declarative multi-monitor auto-detection for Hyprland. The Rust
# crate (../../rust/hyprmon/) parses `hyprctl monitors -j`, matches each output
# against a JSON ruleset, plans a left-to-right layout, and emits
# `hyprctl keyword monitor …` per output. `hyprmon watch` is the daemon: it
# applies once on startup, then re-applies on monitor hotplug (socket2
# `monitoradded`/`monitorremoved`/`configreloaded`, debounced 300 ms).
#
# The ruleset below is the declarative source of truth — written to
# ~/.config/hyprmon/rules.json as JSON so the binary stays config-agnostic.
# The two-monitor setup from AGENTS.md: a 27" 1080p 240Hz VRR panel (DP-1,
# ASUS VG279QM) on the left and a 25" 1200p 60Hz panel (HDMI-A-1, LG 25UM58)
# on its right, plus a `*` fallback so a hotplugged projector gets
# `preferred,auto,1` instead of Hyprland's mirror-default.
#
# The systemd user service runs `hyprmon watch`, ordered after
# `hyprland-session.target` (provided by HM's hyprland module when
# systemd.enable, which is the default) and bound to `graphical-session`
# so it dies with the compositor. `Restart=on-failure` lets it survive a
# transient `hyprctl` hiccup; the daemon's own socket-EOF path exits cleanly
# when Hyprland shuts down (so Restart won't respawn it post-logout).
{
  config,
  pkgs,
  lib,
  hyprmon,
  ...
}:
let
  # The ruleset. Match by name regex AND description substring so a port swap
  # (DP-1 → DP-2) doesn't silently pick up a different monitor that happens
  # to land on the same connector name. Rule order = physical layout order:
  # the first rule is the leftmost monitor, the second continues at
  # x=width-of-the-first, and so on. An explicit `position` pins a monitor
  # absolutely and resets the running x-cursor to that monitor's right edge.
  #
  # Scaling rule: smaller screens get smaller scale factors. Hyprland's
  # auto-detect upscales small panels (this 15" 1080p laptop panel defaults to
  # 1.5, i.e. "grandma mode"). The rules below force 1.0 on the built-in panel
  # and keep 1.0 on the desktop displays, so nothing is oversized.
  rules = {
    rules = [
      {
        name = "laptop-edp";
        match_name = "^eDP-1$";
        scale = 1.0;
        vrr = "off";
      }
      {
        name = "primary-240hz";
        match_name = "^DP-1$";
        match_description = "VG279QM";
        resolution = "1920x1080@240";
        scale = 1.0;
        vrr = "left";
      }
      {
        name = "secondary-60hz";
        match_name = "^HDMI-A-1$";
        match_description = "25UM58";
        resolution = "2560x1200";
        scale = 1.0;
        vrr = "off";
      }
      {
        # Fallback for unknown monitors (projector, a friend's monitor, etc.):
        # let Hyprland auto-pick the preferred mode and place it to the right
        # of whatever came before. No VRR token → Hyprland's default (off).
        name = "*";
        scale = 1.0;
        vrr = "off";
      }
    ];
  };
in
{
  # The rules file the daemon reads. Built with builtins.toJSON rather than
  # writeText so it lands in the read-only HM-managed config tree alongside
  # hyprland.lua — the daemon reads it but never writes it (edits go here,
  # then `home-manager switch`).
  xdg.configFile."hyprmon/rules.json".text = builtins.toJSON rules;

  # The daemon. Bound to graphical-session so it starts with any Wayland
  # compositor session and stops on logout. The upstream Hyprland Home
  # Manager module has `systemd.enable = false`, so `hyprland-session.target`
  # isn't available; `graphical-session.target` is the portable target.
  # Restart=on-failure covers transient `hyprctl` errors.
  # ConditionPathExists gates the socket so a non-Hyprland session (e.g. a
  # GNOME login on the same user) doesn't spawn a dying loop.
  systemd.user.services.hyprmon = {
    Unit = {
      Description = "hyprmon declarative monitor auto-detection";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session-pre.target" ];
      ConditionPathExists = [
        "%t/hypr"
      ];
    };
    Service = {
      ExecStart = "${lib.getExe hyprmon} watch";
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };

  # The binary itself. Listed here (not just in the service ExecStart) so
  # `hyprmon apply` is on $PATH for ad-hoc one-shot runs without restarting
  # the daemon.
  home.packages = [ hyprmon ];

  # hyprmon ships no desktop entry of its own, so without this it is reachable
  # only by typing its name in a shell — the launcher's `apps` provider scans
  # share/applications and nothing else. Declaring one here puts it in the
  # launcher and the app grid alike, and its `actions` become the row's
  # Ctrl+K entries and its indented child rows (rust/beamenu/src/providers/
  # apps.rs reads `[Desktop Action …]` groups).
  #
  # `terminal = false` with the terminal spelled into `exec` rather than
  # `terminal = true`: Terminal is an entry-level key, so it would apply to
  # the actions too, and `apply` would flash a terminal it has no use for.
  xdg.desktopEntries.hyprmon = {
    name = "Monitors";
    genericName = "Display Configuration";
    comment = "Arrange outputs and apply the monitor layout";
    # Named by store path rather than by the bare `hyprmon` theme name: the
    # installed icon themes here ship nothing under `apps/` for a launcher to
    # resolve a name against, and an absolute path is what both beamenu's
    # `resolve_icon` and the app grid accept without a lookup.
    icon = "${hyprmon}/share/icons/hicolor/scalable/apps/hyprmon.svg";
    exec = "${lib.getExe config.programs.kitty.package} -e hyprmon override";
    terminal = false;
    categories = [
      "Settings"
      "HardwareSettings"
    ];
    settings.Keywords = "monitor;display;screen;output;resolution;";
    actions = {
      apply = {
        name = "Apply Layout";
        exec = "hyprmon apply";
      };
      restart-watcher = {
        name = "Restart Hotplug Watcher";
        exec = "systemctl --user restart hyprmon.service";
      };
    };
  };

  # The monitors plugin: single-owner (only this module touches it), so the
  # identity lives here rather than in beamenu.nix's shared-identity block
  # (mirrors settings-menu.nix's whole-plugin-in-owning-module pattern).
  #
  # Ambient rather than keyworded now. The one-shot operations moved to the
  # desktop entry's actions above, which leaves this plugin doing the one
  # thing an entry cannot: rendering the live layout in the canvas. A row
  # that takes no argument belongs in the root list, where it is found by
  # typing its name — a keyword would only be one more prefix to remember.
}
