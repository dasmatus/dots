# LiveISO: minimal installation CD + the dots-installer TUI
# (rust/installer-tui) auto-launched on tty1 + this whole flake at /etc/dots
# (read-only). Before it installs, the TUI pulls the newest flake source the
# nightly release publishes through systemd-sysupdate (the dots-flake
# component, nix/modules/system/sysupdate.nix) and falls back to /etc/dots
# when that fails, so an old stick still installs the current configuration.
# The installer stages a writable copy for disko and nixos-install and stashes
# the install answers (nix/data/facter.json + nix/data/settings.nix) at
# /var/lib/dots on the target; installed systems clone the repo to
# ~/Dokumente/gitlab/personal/dots on first login (dots-clone Home Manager
# user service) and restore those answers into it. The default .#iso is lean
# (packages come from the binary cache during install); .#iso-full sets
# isoImage.storeContents from flake.nix to embed prebuilt system closures for
# offline installs.
{
  pkgs,
  lib,
  modulesPath,
  inputs,
  dotsSelf,
  ...
}:
let
  installer = dotsSelf.packages.x86_64-linux.dots-installer;
in
{
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
    ../modules/system/sysupdate.nix
  ];
  dots.sysupdate.flake = true;
  networking.networkmanager.wifi.backend = lib.mkForce "wpa_supplicant";
  image.baseName = lib.mkForce "tokyonight-dots-installer";
  isoImage.squashfsCompression = "xz -Xdict-size 100%";
  networking.hostName = "installer";
  # The flake rides on the ISO.
  environment.etc."dots".source = dotsSelf;

  environment.systemPackages = [
    installer
    inputs.disko.packages.x86_64-linux.disko
    pkgs.git
    pkgs.cryptsetup
    pkgs.tpm2-tools
    pkgs.gptfdisk
    # disko's luks.nix (`_pkgs`, evaluated for every LUKS-typed device
    # regardless of config) puts `pkgs.openssl` on the generated
    # destroy/format/mount script's PATH unconditionally. nix/system/disko.nix
    # never triggers the one line that actually calls it (`openssl rand
    # -hex 32`, gated on `enrollFido2`, which we don't set; we pass our own
    # passwordFile instead), but PATH membership is still a build input the
    # script's derivation cannot be realised without, called or not. The
    # PATH= line disko emits resolves this to openssl's "bin" output
    # specifically (`lib.makeBinPath`-style selection, since only "bin"
    # carries an actual bin/ dir), a separate store path from the "out"
    # output something else in this closure already happens to pull in, so
    # having openssl elsewhere in the closure does not cover this. Without
    # it, `disko --mode destroy,format,mount` (the exact command
    # install.rs::plan() runs) has no way to realise that PATH entry on a
    # `.#iso-full` install with no network: nothing here provides a C
    # toolchain, so building openssl from source stalls on an
    # unfetchable stdenv bootstrap chain, the same failure class as if
    # this package were entirely absent. Verified against the real
    # destroy-format-mount script's PATH= line and a `nix-store -q
    # --requisites` of a built `.#iso`: this is the only PATH entry in that
    # script missing from the ISO closure.
    pkgs.openssl.bin
    # The installer runs this on the target to generate nix/data/facter.json for
    # the hardware detection in nix/system/hosts.nix.
    pkgs.nixos-facter
  ];

  # disko's cryptsetup-wrapping step (luks.nix, `runCommand … { nativeBuildInputs
  # = [ pkgs.makeWrapper ]; }`) needs pkgs.makeBinaryWrapper's setup-hook
  # derivation at BUILD time to realise disko-destroy-format-mount at all, a
  # separate requirement from the openssl.bin PATH entry above, and one no
  # existing package pulls in as a side effect. makeBinaryWrapper's own build
  # environment is the ordinary (cc-having) stdenv, not stdenvNoCC (which
  # installation-cd-minimal.nix's installation-device.nix already stages here
  # "for runCommand"), so without its output already valid, disko's in-VM
  # `nix build` falls back to compiling gcc/binutils from source through the
  # full stdenv bootstrap chain, offline-unfetchable, same failure class as
  # the openssl gap. Confirmed absent from a built `.#iso`'s closure (no
  # gcc-wrapper, no make-binary-wrapper-hook, no bash-static anywhere in it)
  # and confirmed as the fix: staging just this one derivation is what took a
  # decoupled reproduction of this exact disko invocation past every build
  # error, down to disko's own partitioning logic.
  system.extraDependencies = [ pkgs.makeBinaryWrapper ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # The LiveISO does not import nix/modules/system/core.nix (flake/lib.nix's
  # mkIso only pulls in this file and nix/modules/system/network.nix), so the
  # matusdasdots Cachix substituter configured there does nothing for the
  # installer environment. Without a copy here, a real `nixos-install --flake
  # .#tokyonight` run from the ISO falls back to building from source
  # whatever of the closure isn't already on cache.nixos.org. That coverage
  # is narrower than the whole dots closure: no CI job builds
  # nixosConfigurations.tokyonight.system.build.toplevel itself. The weekly
  # `limine-install-boot` check (vm-boot, schedule/dispatch only — a push to
  # main refreshes none of this) builds `testToplevel`
  # (tests/default.nix:99), a VM-disk-sized *variant* of it, so the bulk of
  # ordinary packages in the closure does get cached and the substituter
  # does pay off for those — but the exact tokyonight toplevel derivation and
  # the disk-config-dependent paths under it never get pushed by anything.
  # The honest tradeoff: on a machine with no network during install, an
  # unreachable substituter is not one quick failed attempt —
  # tests/default.nix:298-303 measured this exact scenario (nixos-install
  # from an offline installer) and found nix retries every path 5x with
  # backoff against cache.nixos.org alone, thousands of paths × 5 retries =
  # hours, which is why that VM forces `substituters = lib.mkForce [ ]`
  # alongside a 1s `connect-timeout` (tests/default.nix:304-305). But
  # `https://cache.nixos.org/` is already in this file's substituter list and
  # is equally unreachable offline (verified: `live-iso` evaluates to
  # `["https://matusdasdots.cachix.org","https://cache.nixos.org/"]`), so
  # adding ours doubles an existing cost rather than introducing a new
  # failure mode. core.nix is the installed system; this is the installer,
  # where the network is normally present already
  # (networking.networkmanager.enable below) and the substitution win — for
  # the part of the closure the weekly check actually pushes — is real.
  nix.settings.substituters = [ "https://matusdasdots.cachix.org" ];
  nix.settings.trusted-public-keys = [
    "matusdasdots.cachix.org-1:iTh1MBvMxZLOGy2d4/piAOjD6MbInPpUliYFhxKG258="
  ];

  networking.networkmanager.enable = true;
  networking.wireless.enable = true;

  # Serial console for the VM smoke test (harmless on real hardware);
  # tty0 stays last so /dev/console is the local display.
  boot.kernelParams = [
    "console=ttyS0,115200n8"
    "console=tty0"
  ];

  # 26.11 will default this to false; the live ISO never has a ZFS root to
  # force-import, so opt in early.
  boot.zfs.forceImportRoot = false;

  systemd.services.dots-installer = {
    description = "tokyonight-dots installer TUI";
    wantedBy = [ "multi-user.target" ];
    # After getty@tty1 orders the conflict as stop-getty-then-start-us;
    # without it the two race for the tty.
    after = [
      "systemd-udev-settle.service"
      "getty@tty1.service"
      "NetworkManager.service"
    ];
    wants = [ "systemd-udev-settle.service" ];
    conflicts = [ "getty@tty1.service" ];
    unitConfig.ConditionPathExists = "/dev/tty1";
    # The install steps call disko, nixos-install, nixos-facter, nmcli,
    # systemd-sysupdate and friends by name, and a system unit's PATH carries
    # none of the system profile.
    path = [ "/run/current-system/sw" ];
    serviceConfig = {
      ExecStart = "${installer}/bin/dots-installer";
      Environment = [
        "TERM=linux"
        # The TUI writes DOTS_UI_READY here once its first frame is drawn;
        # the iso-boot check (tests/default.nix) watches the serial console
        # for it. tty0 is /dev/console and the TUI's own screen, so the
        # marker never goes there.
        "DOTS_UI_READY_TTY=/dev/ttyS0"
      ];
      StandardInput = "tty";
      StandardOutput = "tty";
      # journal+console also copies stderr to ttyS0, so a crash shows up in
      # the serial log the smoke test watches instead of only in the journal.
      StandardError = "journal+console";
      TTYPath = "/dev/tty1";
      TTYReset = true;
      TTYVHangup = true;
      TTYVTDisallocate = true;
      Type = "idle";
      Restart = "on-failure";
      RestartSec = 2;
      # Five failures inside a minute is already proof the unit is broken;
      # StartLimitBurst marks it failed instead of looping until the smoke
      # test times out.
      StartLimitIntervalSec = 60;
      StartLimitBurst = 5;
    };
  };
}
