# LiveISO: minimal installation CD + the dots-installer TUI auto-launched on
# tty1 + this whole flake at /etc/dots (read-only). The installer stages a
# writable copy for nixos-install and stashes the install answers
# (nix/facter.json + nix/settings.nix) at /var/lib/dots on the target;
# installed systems clone the repo to ~/Dokumente/gitlab/personal/dots on
# first login (dots-clone Home Manager user service) and restore those
# answers into it. The default .#iso is lean (packages come from the binary
# cache during install); .#iso-full sets isoImage.storeContents from
# flake.nix to embed prebuilt system closures for offline installs.
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
  ];
  networking.networkmanager.wifi.backend = lib.mkForce "wpa_supplicant";
  image.baseName = lib.mkForce "tokyonight-dots-installer";
  isoImage.squashfsCompression = "xz";
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
    # The installer runs this on the target to generate nix/facter.json for
    # the hardware detection in nix/hosts.nix.
    pkgs.nixos-facter
  ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
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
    # Units get a bare default PATH — the TUI spawns lsblk/disko/nixos-facter/
    # nixos-install/systemd-cryptenroll/nixos-enter/findmnt/shred/systemctl/
    # nmcli from the system profile, and `sh` for the copy step.
    path = [
      "/run/current-system/sw"
      pkgs.bash
    ];
    unitConfig.ConditionPathExists = "/dev/tty1";
    serviceConfig = {
      # Marker for the VM smoke test — land on the serial console so the
      # NixOS test (tests/default.nix) can assert the TUI reached tty1.
      ExecStartPre = "${pkgs.runtimeShell} -c 'echo DOTS_TUI_READY | ${pkgs.coreutils}/bin/tee /dev/console /dev/ttyS0 2>/dev/null || true'";
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
}
