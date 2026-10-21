# systemd-sysupdate for the images this repository publishes on a schedule,
# kept as current installer/rescue images under /var/lib/dots-iso:
#
#   dots-iso       the lean LiveISO from the rolling `nightly` release
#                  (.github/workflows/nightly.yml), straight from GitHub.
#   dots-iso-full  the full LiveISO from the `weekly-*` releases
#                  (.github/workflows/weekly.yml), through dots-release-proxy.
#
# The full image is over GitHub's 2 GiB asset limit, so each weekly release
# holds it in parts, and every release is a directory of its own while
# sysupdate reads one. dots-release-proxy (rust/dots-release-proxy) answers
# both on loopback, the way the LosOS Desktop proxy answers for GHCR: one
# SHA256SUMS across the weekly releases, and each ISO joined back from its
# parts. systemd holds its loopback socket and starts it on the first
# connection, so it costs nothing until a fetch needs it.
#
# The system itself is not a sysupdate image. It updates through
# nixos-rebuild (maintenance.nix), and the A/B /usr model sysupdate was built
# for was dropped with the Gentoo pipeline (nix/README.md). So each transfer
# lives in a component of its own (/etc/sysupdate.<component>.d), which the
# stock systemd-sysupdate.timer never reads: nothing downloads until asked to.
#
#   systemctl start dots-iso-update        # newest nightly lean ISO
#   systemctl start dots-iso-full-update   # newest weekly full ISO
#   systemd-sysupdate --component=dots-iso-full list
#
# (systemd-sysupdate lives in the systemd package's lib/systemd, off PATH.)
#
# dots.sysupdate.installerTimer and .fullTimer turn on a weekly fetch each.
#
# dots.sysupdate.flake adds one more component, dots-flake, for the flake
# source tarball the nightly release carries next to each lean ISO. The
# LiveISO turns it on (nix/system/iso.nix): the installer TUI runs
# `systemd-sysupdate --component=dots-flake update` before it stages the flake
# (rust/installer-tui/src/install.rs), so an old ISO still installs the newest
# configuration, and falls back to the ISO's own /etc/dots when offline.
#
# Verify=no because the releases are unsigned. sysupdate still checks every
# file against the release's SHA256SUMS, fetched over HTTPS (the proxy fetches
# it over HTTPS too, and only hands it over on loopback), so this guards
# against corruption but not against someone who can write to the releases.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  cfg = config.dots.sysupdate;
  dir = "/var/lib/dots-iso";
  flakeDir = "/var/lib/dots-flake";
  sysupdate = "${config.systemd.package}/lib/systemd/systemd-sysupdate";
  proxy = "127.0.0.1:${toString cfg.proxyPort}";

  transfer =
    { source, pattern }:
    lib.generators.toINI { listsAsDuplicateKeys = true; } {
      Transfer.Verify = false;
      Source = {
        Type = "url-file";
        Path = source;
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

  weekly = {
    OnCalendar = "weekly";
    Persistent = true;
    RandomizedDelaySec = "6h";
  };
in
{
  options.dots.sysupdate = {
    installerTimer = lib.mkEnableOption "a weekly fetch of the nightly lean LiveISO into ${dir}";
    fullTimer = lib.mkEnableOption "a weekly fetch of the weekly full LiveISO into ${dir}";
    source = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/dasmatus/dots/releases/download/nightly/";
      description = ''
        Directory holding the nightly LiveISOs and their SHA256SUMS, in the
        layout systemd-sysupdate's url-file source reads.
      '';
    };
    repository = lib.mkOption {
      type = lib.types.str;
      default = "dasmatus/dots";
      description = "GitHub repository whose weekly releases dots-release-proxy serves.";
    };
    proxyPort = lib.mkOption {
      type = lib.types.port;
      default = 8484;
      description = "Loopback port dots-release-proxy listens on.";
    };
    flake = lib.mkEnableOption "the dots-flake sysupdate component, which unpacks the newest nightly flake source into ${flakeDir}";
  };

  config = lib.mkMerge [
    {
      environment.etc."sysupdate.dots-iso.d/50-installer.transfer".text = transfer {
        inherit (cfg) source;
        pattern = "tokyonight-dots-installer_@v.iso";
      };
      environment.etc."sysupdate.dots-iso-full.d/50-installer-full.transfer".text = transfer {
        source = "http://${proxy}/updates/weekly/x86_64/";
        pattern = "tokyonight-dots-installer-full_@v.iso";
      };

      systemd.tmpfiles.settings."10-dots-iso".${dir}.d.mode = "0755";

      systemd.sockets.dots-release-proxy = {
        description = "Loopback socket for dots-release-proxy";
        wantedBy = [ "sockets.target" ];
        listenStreams = [ proxy ];
      };

      systemd.services.dots-release-proxy = {
        description = "Serve the weekly tokyonight-dots releases to systemd-sysupdate";
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        environment.DOTS_PROXY_REPOSITORY = cfg.repository;
        serviceConfig = {
          ExecStart = "${lib.getExe
            inputs.self.packages.${pkgs.stdenv.hostPlatform.system}.dots-release-proxy
          }";
          DynamicUser = true;
          CapabilityBoundingSet = "";
          NoNewPrivileges = true;
          PrivateDevices = true;
          PrivateTmp = true;
          ProtectHome = true;
          ProtectSystem = "strict";
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
          ];
          RestrictNamespaces = true;
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          SystemCallArchitectures = "native";
          SystemCallFilter = [ "@system-service" ];
        };
      };

      systemd.services.dots-iso-update = {
        description = "Fetch the nightly tokyonight-dots LiveISO";
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${sysupdate} --component=dots-iso update";
        };
      };

      systemd.services.dots-iso-full-update = {
        description = "Fetch the weekly full tokyonight-dots LiveISO";
        wants = [ "network-online.target" ];
        after = [
          "network-online.target"
          "dots-release-proxy.socket"
        ];
        requires = [ "dots-release-proxy.socket" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${sysupdate} --component=dots-iso-full update";
        };
      };

      systemd.timers.dots-iso-update = lib.mkIf cfg.installerTimer {
        wantedBy = [ "timers.target" ];
        timerConfig = weekly;
      };
      systemd.timers.dots-iso-full-update = lib.mkIf cfg.fullTimer {
        wantedBy = [ "timers.target" ];
        timerConfig = weekly;
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
