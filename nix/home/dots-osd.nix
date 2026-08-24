# dots-osd, the half of the desktop that talks back.
#
# Moving everything into beamenu made the machine wonderfully answerable and
# completely mute. You can ask it the volume; it will never tell you the volume
# moved. You can ask whether the VPN is up; it will not mention that the VPN
# went down. A bar had one real virtue and this is it: things you did not think
# to ask about.
#
# So, two halves, wired here. The media keys stop calling `wpctl` and
# `brightnessctl` directly and call `dots-osd` instead, which does the same
# thing and then puts the result on screen. And a user service watches the
# snapshot `beamenu --status-daemon` already writes, announcing the transitions
# worth announcing.
#
# The watcher is a reader of someone else's poll, deliberately: every expensive
# reading here is one the status daemon is already taking every five seconds, so
# noticing costs a file read rather than a second set of forks. It is ordered
# after that unit for tidiness, not correctness. A missing snapshot is an
# ordinary state the watcher already handles by staying quiet.
{
  dotsOsd,
  lib,
  pkgs,
  ...
}:
{
  home.packages = [
    dotsOsd
    # What the actuators shell out to. wireplumber and brightnessctl are
    # already reachable in this session (beamenu.nix and default.nix put them
    # there); naming them again here is what keeps this module standing on its
    # own rather than on another module's package list.
    pkgs.wireplumber # volume and microphone (wpctl)
    pkgs.brightnessctl # panel backlight
  ];

  # No dunst rules here, deliberately. The obvious shape, a rule matching
  # `appname = "dots-osd"` that shortens the timeout, does not survive
  # contact with how the dunstrc is assembled: dunst applies rules and its
  # `[urgency_*]` sections in file order, Home Manager renders the settings
  # attrset alphabetically, and `osd` sorts before `urgency_critical`. The rule
  # would be silently overridden by the section that follows it.
  #
  # So dots-osd sends its own `expire_timeout` instead (see `Linger` in
  # rust/dots-osd/src/model.rs), which the spec puts above any daemon default
  # and which needs nothing declared here at all. The notifications keep their
  # place in dunst's history, one entry per stack tag: holding the volume key
  # down replaces its own entry rather than filling the list.

  # The watcher. No ConditionEnvironment on WAYLAND_DISPLAY: it needs a session
  # bus to reach the notification daemon, not a display of its own.
  systemd.user.services.dots-osd = {
    Unit = {
      Description = "dots-osd system state watcher";
      PartOf = [ "graphical-session.target" ];
      After = [
        "graphical-session.target"
        # Not a dependency, an ordering: the watcher reads this unit's
        # snapshot and copes with its absence, so starting first would cost a
        # few quiet ticks rather than anything worse.
        "beamenu-status.service"
      ];
    };
    Service = {
      Type = "simple";
      ExecStart = "${lib.getExe dotsOsd} watch";
      Restart = "on-failure";
      RestartSec = 3;
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };
}
