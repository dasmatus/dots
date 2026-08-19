# Boot chain: Limine + systemd initrd (TPM2 auto-unlock of the disko LUKS
# volume) + the kernel cmdline carried over from the retired Gentoo installer
# (git history). No Secure Boot / UKI signing — Limine boots the kernel + initrd
# straight off the ESP and sidesteps the /etc/machine-id dependency that
# impermanence (tmpfs `/` + tmpfs-wiped `/etc` + non-persisted machine-id)
# creates for systemd-boot at install time. See nix/README.md.
{
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
        "${../../Wallpapers/wh/wallhaven-k81776.jpg}"
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
    # settings.bootKernelParams from nix/defaults.nix; list-concat merged with
    # the hardening params in nix/modules/hardening.nix.
    kernelParams = settings.bootKernelParams;
    # systemd in the initrd honors the TPM2 token enrolled by the installer
    # (crypttabExtraOpts tpm2-device=auto comes from nix/disko.nix).
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

  hardware.enableRedistributableFirmware = true;
  security.tpm2.enable = true;
}
