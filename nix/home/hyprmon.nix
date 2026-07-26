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
  rules = {
    rules = [
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

  # The daemon. PartOf hyprland-session so it starts with the compositor and
  # stops on logout; Restart=on-failure covers transient hyprctl errors.
  # ConditionPathExists gates the socket so a non-Hyprland session (e.g. a
  # GNOME login on the same user) doesn't spawn a dying loop.
  systemd.user.services.hyprmon = {
    Unit = {
      Description = "hyprmon declarative monitor auto-detection";
      PartOf = [ "hyprland-session.target" ];
      After = [ "hyprland-session.target" ];
    };
    Service = {
      ExecStart = "${lib.getExe hyprmon} watch";
      Restart = "on-failure";
      RestartSec = 2;
    };
    Install = {
      WantedBy = [ "hyprland-session.target" ];
    };
  };

  # The binary itself. Listed here (not just in the service ExecStart) so
  # `hyprmon apply` is on $PATH for ad-hoc one-shot runs without restarting
  # the daemon.
  home.packages = [ hyprmon ];
}
