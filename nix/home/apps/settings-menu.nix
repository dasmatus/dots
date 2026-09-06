# Settings menu (rust/settings-global, built at the flake level as
# packages.${system}.settings and handed in via extraSpecialArgs like
# claudeDesktop): edits the installer answers in
# /var/lib/dots/settings.nix. The shell draws the form
# (nix/home/desktop/quickshell/qml/settings) over `dump` and `set`, reached from the
# SUPER+comma bind in hyprland.nix; cheatsheet entry in keybinds.nix.
#
# `serve` is still in the crate and no longer used: it speaks JSON-RPC to
# whatever renders a component tree, which was beamenu-canvas. The plain CLI
# is the smaller interface now that the caller can parse JSON itself.
#
# The menu runs as the user; only the root-owned file write re-execs the
# binary under pkexec. pkexec needs a polkit *authentication agent* in the
# session to show the password dialog — the system polkitd alone cannot
# prompt, and nothing else in this config ships an agent — so
# hyprpolkitagent rides along as a user service. The package ships this
# exact unit, but HM only links units it declares itself, so it is restated
# here with the store-path ExecStart.
{
  settingsMenu,
  pkgs,
  ...
}:
{
  home.packages = [ settingsMenu ];

  systemd.user.services.hyprpolkitagent = {
    Unit = {
      Description = "Hyprland Polkit Authentication Agent";
      PartOf = [ "graphical-session.target" ];
      After = [ "graphical-session.target" ];
      ConditionEnvironment = "WAYLAND_DISPLAY";
    };
    Service = {
      # No bin/ in the package — upstream installs to libexec only, so
      # lib.getExe (bin/hyprpolkitagent) would point at a missing path.
      ExecStart = "${pkgs.hyprpolkitagent}/libexec/hyprpolkitagent";
      Slice = "session.slice";
      TimeoutStopSec = "5sec";
      Restart = "on-failure";

      # Only the seven directives that carry no plausible conflict with
      # this unit's job (showing a polkit auth dialog over D-Bus). Held
      # back on purpose: MemoryDenyWriteExecute (GTK/Qt dialog toolkits can
      # JIT), RestrictAddressFamilies (needs at least AF_UNIX for D-Bus,
      # untested here), ProtectHome/ProtectSystem (untested against
      # whatever the toolkit reads from the user's theme config) — see
      # mkUnit's baseline comment in session/default.nix for the per-
      # directive rationale, identical here: no clock/hostname/kernel-log/
      # cgroup/personality/realtime/setuid-setgid access is needed to draw
      # an auth prompt.
      ProtectClock = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      LockPersonality = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
