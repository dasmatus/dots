# Declarative NixOS-option mapping derived from the retired konkrit firstboot
# hardening catalog (Gentoo era; see git history — 104 modules). Categories
# covered: sysctl net/kernel, boot params, coredump/ptrace, AppArmor,
# USBGuard, firewall, sudo, kernel image protection, tmpfs /tmp.
{
  lib,
  pkgs,
  config,
  ...
}:
{
  options.dots.hardening.usbguard.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      USBGuard with devices present at boot allowed (so keyboards keep
      working) and new devices blocked. Disable if plugging unknown USB
      devices needs to Just Work.
    '';
  };

  config = {
    boot.kernel.sysctl = {
      "kernel.kptr_restrict" = 2;
      "kernel.dmesg_restrict" = 1;
      "kernel.unprivileged_bpf_disabled" = 1;
      "net.core.bpf_jit_harden" = 2;
      "kernel.yama.ptrace_scope" = 2;
      "kernel.kexec_load_disabled" = 1;
      "kernel.sysrq" = 0;
      "fs.protected_hardlinks" = 1;
      "fs.protected_symlinks" = 1;
      "fs.protected_fifos" = 2;
      "fs.protected_regular" = 2;
      # loose instead of strict: strict rp_filter breaks libvirt NAT return
      # traffic (documented conflict in the retired konkrit firstboot catalog;
      # Gentoo era, see git history)
      "net.ipv4.conf.all.rp_filter" = 2;
      "net.ipv4.conf.default.rp_filter" = 2;
      "net.ipv4.tcp_syncookies" = 1;
      "net.ipv4.conf.all.accept_redirects" = 0;
      "net.ipv4.conf.default.accept_redirects" = 0;
      "net.ipv6.conf.all.accept_redirects" = 0;
      "net.ipv6.conf.default.accept_redirects" = 0;
      "net.ipv4.conf.all.send_redirects" = 0;
      "net.ipv4.conf.default.send_redirects" = 0;
      "net.ipv4.conf.all.accept_source_route" = 0;
      "net.ipv6.conf.all.accept_source_route" = 0;
    };

    boot.kernelParams = [
      "init_on_alloc=1"
      "init_on_free=1"
      "page_alloc.shuffle=1"
      "randomize_kstack_offset=on"
      "slab_nomerge"
    ];

    systemd.coredump.enable = false;

    security.apparmor = {
      enable = true;
      packages = [ pkgs.apparmor-profiles ];
    };

    services.usbguard = lib.mkIf config.dots.hardening.usbguard.enable {
      enable = true;
      presentDevicePolicy = "allow";
      implicitPolicyTarget = "block";
      IPCAllowedGroups = [ "wheel" ];
    };

    networking.firewall.enable = true;

    security.sudo = {
      execWheelOnly = true;
      wheelNeedsPassword = true;
    };

    security.protectKernelImage = true;
    boot.tmp.useTmpfs = true;
  };
}
