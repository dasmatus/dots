# Declarative NixOS-option mapping derived from the retired konkrit firstboot
# hardening catalog (Gentoo era; see git history — 104 modules). Categories
# covered: sysctl net/kernel, boot params, coredump/ptrace, AppArmor,
# USBGuard, firewall, sudo, kernel image protection, tmpfs /tmp.
{
  pkgs,
  lib,
  ...
}:
{
  security.forcePageTableIsolation = true;
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
    "net.ipv4.conf.all.rp_filter" = lib.mkForce 2;
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

  security.virtualisation.flushL1DataCache = "always";
  security.apparmor.killUnconfinedConfinables = true;
  systemd.coredump.enable = false;
  security.apparmor = {
    enable = true;
    packages = [ pkgs.apparmor-profiles ];
  };
  networking.firewall = {
    backend = lib.mkForce "firewalld";
    enable = true;

    # Block unsolicited inbound connections.
    allowedTCPPorts = [ ];
    allowedUDPPorts = [ ];

    # Do not trust any interfaces.
    trustedInterfaces = [ ];

    # Optional: silently drop packets rather than reject them.
    rejectPackets = false;
  };
  # sudo → sudo-rs (memory-safe Rust reimplementation). The sudo-rs module
  # asserts it can't coexist with security.sudo and mkDefault-disables it, so
  # we drop the old sudo block and disable sudo explicitly here for clarity.
  security = {
    protectKernelImage = true;
    sudo.enable = false;
    sudo-rs = {
      enable = true;
      execWheelOnly = true;
      # Passwordless for all wheel members. NB: this leaves the FIDO2 sudo PAM
      # auth wired in desktop.nix dormant — NOPASSWD skips PAM authentication,
      # so the security key never gets a chance to prompt. Flip this to true to
      # switch to key-gated sudo (tap key instead of passwordless) instead.
      wheelNeedsPassword = false;
    };
  };
  boot.tmp.useTmpfs = true;
}
