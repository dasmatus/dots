# Wrapper around nixpkgs' Limine installer that fixes two chroot hazards that
# abort a fresh nixos-install with "Failed to install bootloader":
#
#   1. nix-env loads nix.conf through the $HOME XDG fallback; when $HOME is
#      unset and the running uid has no /etc/passwd entry in the target chroot
#      (impermanence can leave /etc unpopulated before userborn runs), Nix
#      throws "cannot determine user's home directory" before touching the
#      profile. The wrapper points nix at a home it owns.
#   2. The upstream installer reads `system-{N}-link/boot.json` and enumerates
#      generations via `nix-env --list-generations`; if the system profile does
#      not exist yet, the wrapper provisions a single-generation profile with
#      plain symlinks (no nix-env, so it can't trip hazard 1).
#
# Both fixes are no-ops in the normal case (nixos-install set the profile up
# and $HOME is usable). See the memory note [[limine-nix-env-install-fragility]].
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.boot.loader.limine;
  efi = config.boot.loader.efi;

  # Mirror the upstream limineInstallConfig exactly so the upstream
  # limine-install.py understands the same JSON schema.
  limineInstallConfig = pkgs.writeText "limine-install.json" (
    builtins.toJSON {
      inherit (config.system.nixos) distroName;
      nixPath = config.nix.package;
      efiBootMgrPath = pkgs.efibootmgr;
      liminePath = cfg.package;
      efiMountPoint = efi.efiSysMountPoint;
      fileSystems = config.fileSystems;
      luksDevices = builtins.attrNames config.boot.initrd.luks.devices;
      canTouchEfiVariables = efi.canTouchEfiVariables;
      efiSupport = cfg.efiSupport;
      efiRemovable = cfg.efiInstallAsRemovable;
      secureBoot = cfg.secureBoot;
      biosSupport = cfg.biosSupport;
      biosDevice = cfg.biosDevice;
      partitionIndex = cfg.partitionIndex;
      force = cfg.force;
      enrollConfig = cfg.enrollConfig;
      style = cfg.style;
      resolution = cfg.resolution;
      maxGenerations = if cfg.maxGenerations == null then 0 else cfg.maxGenerations;
      hostArchitecture = pkgs.stdenv.hostPlatform.parsed.cpu;
      timeout = if config.boot.loader.timeout == null then "no" else config.boot.loader.timeout;
      enableEditor = cfg.enableEditor;
      extraConfig = cfg.extraConfig;
      extraEntries = cfg.extraEntries;
      additionalFiles = cfg.additionalFiles;
      validateChecksums = cfg.validateChecksums;
      panicOnChecksumMismatch = cfg.panicOnChecksumMismatch;
    }
  );

  # The upstream Python installer, with the same substitutions the module uses.
  upstreamInstall = pkgs.replaceVarsWith {
    src = pkgs.path + "/nixos/modules/system/boot/loader/limine/limine-install.py";
    isExecutable = true;
    replacements = {
      python3 = pkgs.python3.withPackages (python-packages: [ python-packages.psutil ]);
      configPath = limineInstallConfig;
    };
  };

  # The installBootLoader program switch-to-configuration invokes as
  #   $installBootLoader $toplevel
  installBootLoader = pkgs.writeScript "limine-install.sh" ''
    #!${pkgs.runtimeShell}
    set -euo pipefail

    toplevel=''${1:-}
    profilesDir=/nix/var/nix/profiles
    profile=$profilesDir/system

    # Hazard 1 — home directory lookup. nix-env loads nix.conf via the $HOME
    # XDG fallback (getHome() in Nix's libutil/unix/users.cc), and the upstream
    # installer shells out to `nix-env --list-generations` unconditionally.
    # During nixos-install the bootloader step can run with $HOME unset, and
    # the running uid may have no entry in the target chroot's /etc/passwd:
    # impermanence's createPersistentStorageDirs activation can fail to
    # populate /etc before userborn creates users, so getpwuid_r(geteuid())
    # returns nothing and Nix throws "cannot determine user's home directory"
    # before ever touching the profile. getHome() accepts $HOME when the path
    # does not exist OR is owned by the effective uid; mktemp -d is owned by
    # us, so pointing nix there skips the passwd lookup entirely. Only
    # override when the inherited $HOME is unusable (unset, or an existing
    # dir not owned by us).
    if [ -z "''${HOME:-}" ] || { [ -e "''$HOME" ] && [ ! -O "''$HOME" ]; }; then
      export HOME="$(${pkgs.mktemp} -d)"
    fi

    # Hazard 2 — missing system profile. The upstream installer reads
    # `system-{N}-link/boot.json` and enumerates generations via
    # `nix-env --list-generations -p <profile>`. On a fresh install the
    # profile may not exist yet (no `system` link, no generation symlinks).
    # Provision a minimal single-generation profile with plain symlinks —
    # no nix-env, so this can't trip hazard 1. Normal case (nixos-install
    # already set the profile up) is a no-op.
    if [ ! -e "''$profile" ] || [ ! -e "''$profile/boot.json" ]; then
      echo "limine-install: profile not ready, bootstrapping single generation..." >&2
      mkdir -p "''$profilesDir"
      ln -sfn "''$toplevel" "''$profilesDir/system-1-link"
      ln -sfn system-1-link "''$profile"
    fi

    ${upstreamInstall} "$@"
    ${cfg.extraInstallCommands}
  '';
in
{
  config = lib.mkIf cfg.enable {
    system.build.installBootLoader = lib.mkOverride 50 installBootLoader;
  };
}
