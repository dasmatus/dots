# Minimal hardening: keep the least problematic options, leave the rest to the
# stock NixOS defaults. Firewall rules live in nix/modules/system/network.nix.
{ ... }:
{
  security.protectKernelImage = true;

  boot.kernel.sysctl = {
    "kernel.kptr_restrict" = 2;
    "kernel.dmesg_restrict" = 1;
    "kernel.kexec_load_disabled" = 1;
  };

  systemd.coredump.enable = false;
}
