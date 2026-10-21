# systemd-sysupdate for the one image this repository publishes on a
# schedule: the nightly LiveISO (.github/workflows/nightly.yml), kept as a
# current installer/rescue image under /var/lib/dots-iso.
#
# The system itself is not a sysupdate image. It updates through
# nixos-rebuild (maintenance.nix), and the A/B /usr model sysupdate was built
# for was dropped with the Gentoo pipeline (nix/README.md). So the transfer
# lives in a component of its own, /etc/sysupdate.dots-iso.d, which the stock
# systemd-sysupdate.timer never reads: nothing downloads until asked to.
#
#   systemctl start dots-iso-update         # fetch the newest nightly
#   systemd-sysupdate --component=dots-iso list
#
# (systemd-sysupdate lives in the systemd package's lib/systemd, off PATH.)
#
# dots.sysupdate.installerTimer turns on a weekly fetch.
#
# dots.sysupdate.flake adds a second component, dots-flake, for the flake
# source tarball the same nightly release carries. The LiveISO turns it on
# (nix/system/iso.nix): the installer TUI runs
# `systemd-sysupdate --component=dots-flake update` before it stages the flake
# (rust/installer-tui/src/install.rs), so an old ISO still installs the newest
# configuration, and falls back to the ISO's own /etc/dots when offline.
#
# Verify=no because the release is unsigned. sysupdate still checks every
# file against the release's SHA256SUMS, fetched over HTTPS from the same
# GitHub release, so this guards against corruption but not against someone
# who can write to the repository's releases.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.dots.sysupdate;
  dir = "/var/lib/dots-iso";
  pattern = "tokyonight-dots-installer_@v.iso";
  flakeDir = "/var/lib/dots-flake";
  sysupdate = "${config.systemd.package}/lib/systemd/systemd-sysupdate";
in
{
  options.dots.sysupdate = {
    installerTimer = lib.mkEnableOption "a weekly fetch of the nightly LiveISO into ${dir}";
    source = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/dasmatus/dots/releases/download/nightly/";
      description = ''
        Directory holding the nightly LiveISOs and their SHA256SUMS, in the
        layout systemd-sysupdate's url-file source reads.
      '';
    };
    flake = lib.mkEnableOption "the dots-flake sysupdate component, which unpacks the newest nightly flake source into ${flakeDir}";
  };

  config = lib.mkMerge [
    {
      environment.etc."sysupdate.dots-iso.d/50-installer.transfer".text =
        lib.generators.toINI { listsAsDuplicateKeys = true; }
          {
            Transfer.Verify = false;
            Source = {
              Type = "url-file";
              Path = cfg.source;
              MatchPattern = pattern;
            };
            Target = {
              Type = "regular-file";
              Path = dir;
              MatchPattern = pattern;
              Mode = "0444";
              # The one in use by a running `dd` survives the next fetch.
              InstancesMax = 2;
            };
          };

      systemd.tmpfiles.settings."10-dots-iso".${dir}.d.mode = "0755";

      systemd.services.dots-iso-update = {
        description = "Fetch the nightly tokyonight-dots LiveISO";
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${sysupdate} --component=dots-iso update";
        };
      };

      systemd.timers.dots-iso-update = lib.mkIf cfg.installerTimer {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "weekly";
          Persistent = true;
          RandomizedDelaySec = "6h";
        };
      };
    }

    (lib.mkIf cfg.flake {
      # url-tar unpacks each tarball into its own directory, dots-flake_<v>;
      # the installer stages whichever sorts last.
      environment.etc."sysupdate.dots-flake.d/50-flake.transfer".text =
        lib.generators.toINI { listsAsDuplicateKeys = true; }
          {
            Transfer.Verify = false;
            Source = {
              Type = "url-tar";
              Path = cfg.source;
              MatchPattern = "tokyonight-dots-flake_@v.tar.gz";
            };
            Target = {
              Type = "directory";
              Path = flakeDir;
              MatchPattern = "dots-flake_@v";
              InstancesMax = 2;
            };
          };

      systemd.tmpfiles.settings."10-dots-flake".${flakeDir}.d.mode = "0755";

      # systemd-sysupdate lives in lib/systemd, off PATH; the installer calls
      # it by name.
      environment.systemPackages = [
        (pkgs.writeShellScriptBin "systemd-sysupdate" ''exec ${sysupdate} "$@"'')
      ];
    })
  ];
}
