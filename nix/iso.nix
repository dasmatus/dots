# LiveISO: minimal installation CD + the dots-installer TUI auto-launched on
# tty1 + this whole flake at /etc/dots (the installer copies it to the target
# and points nixos-install at it). The default .#iso is lean (packages come
# from the binary cache during install); .#iso-full sets isoImage.storeContents
# from flake.nix to embed prebuilt system closures for offline installs.
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
  imports = [ "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix" ];

  image.baseName = lib.mkForce "tokyonight-dots-installer";
  isoImage.squashfsCompression = "zstd -Xcompression-level 6";

  # The flake rides on the ISO.
  environment.etc."dots".source = dotsSelf;

  environment.systemPackages = [
    installer
    inputs.disko.packages.x86_64-linux.disko
    pkgs.git
    pkgs.cryptsetup
    pkgs.tpm2-tools
    pkgs.gptfdisk
    # The installer runs this on the target to generate nix/facter.json for
    # the hardware detection in nix/hosts.nix.
    pkgs.nixos-facter
  ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  networking.networkmanager.enable = true;
  networking.wireless.enable = lib.mkForce false;

  # Serial console for the VM smoke test (harmless on real hardware);
  # tty0 stays last so /dev/console is the local display.
  boot.kernelParams = [
    "console=ttyS0,115200n8"
    "console=tty0"
  ];

  systemd.services.dots-installer = {
    description = "tokyonight-dots installer TUI";
    wantedBy = [ "multi-user.target" ];
    # After getty@tty1 orders the conflict as stop-getty-then-start-us;
    # without it the two race for the tty.
    after = [
      "systemd-udev-settle.service"
      "getty@tty1.service"
    ];
    wants = [ "systemd-udev-settle.service" ];
    conflicts = [ "getty@tty1.service" ];
    # Units get a bare default PATH — the TUI spawns lsblk/disko/nixos-facter/
    # nixos-install/systemd-cryptenroll/nixos-enter/findmnt/shred/systemctl
    # from the system profile, and `sh` for the copy step.
    path = [
      "/run/current-system/sw"
      pkgs.bash
    ];
    unitConfig.ConditionPathExists = "/dev/tty1";
    serviceConfig = {
      # Markers for tests/nix-smoke.sh — land on the serial console. The
      # second one reads the SecureBoot efivar (skip 4 attribute bytes,
      # data byte is 0/1) so the --secure-boot smoke run can assert the
      # firmware really enforced Secure Boot, not just that we booted.
      ExecStartPre = [
        "${pkgs.runtimeShell} -c 'echo DOTS_TUI_READY | ${pkgs.coreutils}/bin/tee /dev/console /dev/ttyS0 2>/dev/null || true'"
        (pkgs.writeShellScript "dots-sb-marker" ''
          sb=$(${pkgs.coreutils}/bin/od -An -tu1 -j4 -N1 \
            /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c \
            2>/dev/null | ${pkgs.coreutils}/bin/tr -d ' ')
          echo "DOTS_SECUREBOOT=''${sb:-absent}" \
            | ${pkgs.coreutils}/bin/tee /dev/console /dev/ttyS0 2>/dev/null || true
        '')
      ];
      ExecStart = "${installer}/bin/dots-installer";
      StandardInput = "tty";
      StandardOutput = "tty";
      StandardError = "journal";
      TTYPath = "/dev/tty1";
      TTYReset = true;
      TTYVHangup = true;
      Type = "idle";
      Restart = "on-failure";
      RestartSec = 2;
    };
  };

  system.stateVersion = "26.05";
}
