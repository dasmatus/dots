# Boot chain: systemd-boot + systemd initrd (TPM2 auto-unlock of the disko LUKS
# volume) + the kernel cmdline carried over from the retired Gentoo installer
# (git history).
# Secure Boot is a separate opt-in (secureboot.nix) — see nix/README.md.
{ ... }:
{
  boot.loader.systemd-boot = {
    enable = true;
    configurationLimit = 10;
    editor = false;
  };
  boot.loader.efi.canTouchEfiVariables = true;

  # systemd in the initrd honors the TPM2 token enrolled by the installer
  # (crypttabExtraOpts tpm2-device=auto comes from nix/disko.nix).
  boot.initrd.systemd.enable = true;
  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "ahci"
    "usbhid"
    "sd_mod"
    "virtio_pci"
    "virtio_blk"
    "virtio_scsi"
  ];

  boot.kernelParams = [
    "zswap.enabled=1"
    "zswap.compressor=zstd"
    "zswap.zpool=zsmalloc"
    "zswap.max_pool_percent=25"
    "quiet"
    "loglevel=3"
    "mitigations=auto"
  ];

  hardware.enableRedistributableFirmware = true;
  security.tpm2.enable = true;
}
