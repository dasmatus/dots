# Wrapper around nixpkgs' Limine installer that bootstraps the system profile
# before the upstream script runs. During nixos-install the upstream script
# calls `nix-env --list-generations` unconditionally; if the profile directory
# is missing or the lock cannot be acquired, the install aborts with
# "Failed to install bootloader". This wrapper detects that failure and creates
# a single-generation profile pointing to the toplevel before delegating to the
# upstream installer.
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

    # The upstream installer calls nix-env --list-generations unconditionally.
    # On a fresh nixos-install the profile directory may not exist in the
    # chroot, or the lock file may not be writable, which aborts the install.
    # Bootstrap a single-generation profile when listing would otherwise fail.
    if ! ${config.nix.package}/bin/nix-env \
         --list-generations \
         -p /nix/var/nix/profiles/system \
         --option build-users-group "" \
         >/dev/null 2>&1
    then
      echo "limine-install: profile not ready, bootstrapping single generation..." >&2
      mkdir -p /nix/var/nix/profiles
      ${config.nix.package}/bin/nix-env \
        -p /nix/var/nix/profiles/system \
        --set "''$toplevel"
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
