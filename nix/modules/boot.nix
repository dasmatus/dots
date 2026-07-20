# Boot chain: systemd-boot + systemd initrd (TPM2 auto-unlock of the disko LUKS
# volume) + the kernel cmdline carried over from the retired Gentoo installer
# (git history). UKIs are built by default via lanzaboote — secureboot.nix is
# ON by default, which disables this systemd-boot block (mkForce) and ships
# signed UKIs instead; set dots.secureboot.enable = false to fall back to plain
# systemd-boot. See nix/README.md.
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
    loader.systemd-boot = {
      enable = true;
      configurationLimit = 2;
      editor = false;
    };
    loader.efi.canTouchEfiVariables = true;
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
    ];
  };

  hardware.enableRedistributableFirmware = true;
  security.tpm2.enable = true;
}
