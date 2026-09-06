# Boot chain: Limine + systemd initrd (TPM2 auto-unlock of the disko LUKS
# volume) + the kernel cmdline carried over from the retired Gentoo installer
# (git history). No Secure Boot / UKI signing — Limine boots the kernel + initrd
# straight off the ESP and sidesteps the /etc/machine-id dependency that
# impermanence (tmpfs `/` + tmpfs-wiped `/etc` + non-persisted machine-id)
# creates for systemd-boot at install time. See nix/README.md.
{
  lib,
  pkgs,
  settings,
  ...
}:
{
  boot = {
    plymouth = {
      enable = true;
      theme = settings.plymouthTheme;
      themePackages =
        with pkgs;
        # No theme → no extra package; otherwise pin just the chosen one so we
        # don't pull every adi1090x theme into the closure.
        if settings.plymouthTheme == "" then
          [ ]
        else
          [
            (adi1090x-plymouth-themes.override {
              selected_themes = [ settings.plymouthTheme ];
            })
          ];
    };
    loader.limine = {
      enable = true;
      # was loader.systemd-boot.configurationLimit = 2 — Limine's equivalent.
      maxGenerations = 2;
      # was loader.systemd-boot.editor = false. Must be explicit: with Secure
      # Boot off the Limine module does not force-disable the editor, so without
      # this the boot menu would allow `init=/bin/sh` root access.
      enableEditor = false;
      # secureBoot.enable stays false (default) — enabling it would flip PCR 7
      # and break the TPM2 unseal, and Limine Secure Boot is upstream-in-development.
      style.wallpapers = [
        "${../../../Wallpapers/wh/wallhaven-k81776.jpg}"
      ];
    };
    # was true. Makes efiInstallAsRemovable default to true → Limine installs to
    # \EFI\BOOT\BOOTX64.EFI and SKIPS efibootmgr, immune to nixpkgs #493017
    # (efibootmgr NVRAM write failure on quirky firmware, unfixed on master).
    loader.efi.canTouchEfiVariables = false;
    zswap = {
      enable = true;
      compressor = settings.zswapCompressor;
    };
    # settings.bootKernelParams from nix/system/defaults.nix; list-concat merged with
    # the hardening params in nix/modules/system/hardening.nix.
    kernelParams = settings.bootKernelParams;
    # systemd in the initrd honors the TPM2 token enrolled by the installer
    # (crypttabExtraOpts tpm2-device=auto comes from nix/system/disko.nix).
    initrd.systemd.enable = true;
    initrd.availableKernelModules = [
      "nvme"
      "xhci_pci"
      "ahci"
      "usbhid"
      "sd_mod"
      "virtio_pci"
      "virtio_blk"
      "virtio_scsi"
      "amdgpu"
    ];
  };

  # `nixos-rebuild build-vm` could not evaluate this configuration at all
  # before this block, which cost the one cheap way to rehearse a switch
  # before performing it:
  #
  #   error: Failed assertions:
  #   - Zswap requires at least one physical swap device to function as a
  #     backing store.
  #
  # The assertion is upstream's and it is correct. `boot.zswap` above is a
  # compressed cache in front of swap, not swap itself, so it needs a real
  # backing device; on hardware that device comes from disko
  # (nix/system/disko.nix builds the swap partition). The VM variant never
  # runs disko — it synthesises its own qcow2 root — so `swapDevices` is
  # empty there and the assertion fires before anything builds.
  #
  # Turning zswap off for the VM only is the honest fix. Giving the variant a
  # synthetic swapfile purely to satisfy an assertion would be worse: it would
  # make the VM's memory behaviour differ from the host it is supposed to be
  # rehearsing, in exactly the subsystem being faked. A VM without zswap is
  # still a faithful rehearsal of boot, greetd, the session and the units,
  # which is what build-vm is for. It is NOT a rehearsal of USBGuard (VM USB
  # enumeration bears no resemblance to a real hub chain) or of the GPU and
  # Wayland stack, so a green VM is necessary and not sufficient before a
  # switch.
  virtualisation.vmVariant.boot.zswap.enable = lib.mkForce false;

  hardware.enableRedistributableFirmware = true;
  security.tpm2.enable = true;
}
