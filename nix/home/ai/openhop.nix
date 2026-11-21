# OpenHop's user half, declaratively. The published installer drops four
# scripts into ~/.local/share, a user unit into ~/.config/systemd/user and
# replaces ~/.local/bin/opencode with its lane shim. None of that survives a
# fresh machine, and clobbering `opencode` breaks T3 Code's own front.
#
# This module keeps the T3 shim untouched and exposes the lane as
# `opencode-lane`. The scripts themselves are vendored under scripts/openhop/
# (from the SHA-256-verified openhop.cfd source) so they are reviewable and
# pinned by this flake rather than fetched at activation time.
#
# What is deliberately NOT here: WARP itself, the root keeper unit and the
# sudoers rule that lets the guard rotate WARP unattended. Standalone Home
# Manager has no root; those remain host-level prerequisites installed once,
# exactly as nix/modules/system/* would install them on a NixOS host.
{
  config,
  pkgs,
  dots,
  lib,
  ...
}:
let
  # One binary per vendored script. The names keep the installer's internal
  # brand so the guard's systemctl calls and the doctor's checks stay valid.
  laneScript = pkgs.writeShellScriptBin "opencode-unlimited-lane" (
    builtins.readFile ../../../scripts/openhop/zen-lane.sh
  );
  guardScript = pkgs.writeShellScriptBin "opencode-unlimited-guard" (
    builtins.readFile ../../../scripts/openhop/zen-guard.sh
  );
  hopScript = pkgs.writeShellScriptBin "opencode-unlimited-hop" (
    builtins.readFile ../../../scripts/openhop/zen-hop.sh
  );
  doctorScript = pkgs.writeShellScriptBin "opencode-unlimited-doctor" (
    builtins.readFile ../../../scripts/openhop/doctor.sh
  );

  # The real binary is whatever the OpenCode HM module installed. Resolving it
  # through the module's own option keeps the lane in step with version bumps
  # and memory-limit wrappers instead of hardcoding ~/.opencode/bin/opencode.
  lane = pkgs.writeShellScriptBin "opencode-lane" ''
    export OUC_REAL_BIN="${lib.getBin config.programs.opencode.package}/bin/opencode"
    exec ${lib.getExe laneScript} "$@"
  '';
in
lib.mkIf dots.ai.opencode {
  home.packages = [
    lane
    laneScript
    guardScript
    hopScript
    doctorScript
  ];

  # The guard is the only part of the user half that has to run unattended.
  # Restart=always matches the installer's unit; WARP is found through PATH,
  # so a NixOS host with a different warp-cli path needs no edit here.
  systemd.user.services."opencode-unlimited-guard" = {
    Unit = {
      Description = "openhop — zen guard (wall watcher, auto /64 rotation)";
      After = [ "network-online.target" ];
    };
    Service = {
      Type = "simple";
      Restart = "always";
      RestartSec = 15;
      ExecStart = lib.getExe guardScript;
      Environment = [ "OUC_KEEPER_UNIT=opencode-unlimited-keeper" ];
    };
    Install.WantedBy = [ "default.target" ];
  };

  # Same command the project-local config used to expose, now global: from
  # any repository, /openhop-doctor reports the actual health of this setup.
  programs.opencode.settings.commands.openhop-doctor = {
    description = "Run the OpenHop health check";
    template = "Run `opencode-unlimited-doctor` with the shell tool and report every ✓, ! and ✗ line verbatim. Do not change any configuration unless I ask.";
  };
}
