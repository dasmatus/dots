# Boot chain: systemd-boot + systemd initrd (TPM2 auto-unlock of the disko LUKS
# volume) + the kernel cmdline carried over from the retired Gentoo installer
# (git history).
# Secure Boot is a separate opt-in (secureboot.nix) — see nix/README.md.
{ pkgs, ... }:
{
  boot = {
    plymouth = {
      enable = true;
      theme = "rings";
      themePackages = with pkgs; [
        # By default we would install all themes
        (adi1090x-plymouth-themes.override {
          selected_themes = [ "rings" ];
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
      compressor = "842";
    };
    kernelParams = [
      "quiet"
      "loglevel=3"
      "mitigations=auto"
    ];
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
