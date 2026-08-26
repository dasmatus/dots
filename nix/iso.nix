# LiveISO: minimal installation CD + a cage kiosk session auto-launched on
# tty1, running Quickshell's installer.qml (currently plan 0's placeholder —
# the real install screens are a later migration plan) + this whole flake at
# /etc/dots (read-only). The rust dots-installer TUI still ships as a package
# on the ISO (its install logic — disko, nixos-install, secrets — has not
# moved yet) but nothing auto-launches it anymore; that happens once the
# Quickshell screens can drive the same steps. The installer stages a
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
  # Not read from /etc/dots: that copy exists so nixos-install can evaluate
  # the flake on the target, and by the time cage execs qs the ISO's /etc
  # overlay may not even be the source tree's current state (it's `dotsSelf`
  # at ISO-build time either way). The store path here is what `nix build
  # .#quickshell-config` produces — Theme.qml generated, qmldir written,
  # installer.qml copied in verbatim alongside it.
  quickshellConfig = dotsSelf.packages.x86_64-linux.quickshell-config;
in
{
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
  ];
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
    # The installer runs this on the target to generate nix/facter.json for
    # the hardware detection in nix/hosts.nix.
    pkgs.nixos-facter
    # The kiosk compositor dots-installer's systemd unit now launches qs
    # inside of, and the QML runtime it launches. Mesa is listed explicitly
    # (rather than trusted as an implicit dep) because it is the thing that
    # actually renders: cage/wlroots composite in software (see the unit's
    # WLR_RENDERER below) but Quickshell's Qt Quick scene still wants a GL
    # context for its own content, and on a GPU-less VM that context is
    # Mesa's llvmpipe rasterizer, not a hardware driver.
    pkgs.cage
    pkgs.quickshell
    pkgs.mesa
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
    description = "tokyonight-dots installer (cage kiosk)";
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
    serviceConfig = {
      # `-s` allows VT switching (harmless here — nothing else owns a VT to
      # switch to — but matches the upstream-documented invocation rather
      # than an unflagged one). `qs -p` takes a single QML file directly, no
      # config-directory scan; installer.qml's own `import "."` still
      # resolves its siblings (Theme.qml, qmldir) because Quickshell adds a
      # QML file's own directory to its import path regardless of how it was
      # selected.
      ExecStart = "${pkgs.cage}/bin/cage -s -- ${pkgs.quickshell}/bin/qs -p ${quickshellConfig}/installer.qml";
      # wlroots' default renderer (GLES2 via GBM/EGL) wants a DRM render
      # node backed by real GPU acceleration. The smoke-test VM is plain
      # OVMF with no virtio-gpu — a KMS-capable scanout with no 3D behind
      # it — so that render node never appears and cage would sit forever
      # waiting for a renderer that cannot exist. WLR_RENDERER=pixman moves
      # wlroots' own compositing (blitting client buffers to the output) onto
      # the CPU, sidestepping GBM/EGL entirely. WLR_BACKENDS=drm,libinput
      # pins the output/input backends explicitly instead of autodetecting —
      # on a bare VT with no seatd/Wayland/X11 parent session to nest under,
      # autodetection has nothing but drm+libinput to find anyway, but
      # spelling it out fails loudly instead of silently if that ever stops
      # being true. Quickshell's own Qt Quick content still renders through
      # Mesa's llvmpipe (see environment.systemPackages above) — pixman only
      # changes how cage composites what Quickshell hands it, not how
      # Quickshell draws it.
      Environment = [
        "WLR_RENDERER=pixman"
        "WLR_BACKENDS=drm,libinput"
      ];
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
