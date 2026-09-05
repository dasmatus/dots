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
  # AppArmor was enabled here but confining nothing. `packages` is, in
  # nixpkgs' own words, "List of packages to be added to AppArmor's include
  # path" — it makes profiles available to `Include` directives and to the
  # policy cache. It does not load them. Loading is driven by `policies`,
  # which was empty, so the generated apparmor.service had an
  # ExecStartPre=aa-teardown, an ExecStop=aa-teardown and no ExecStart at
  # all: it unloaded profiles at boot and loaded none. `aa-enabled` answered
  # "Yes" and /sys/kernel/security/apparmor/profiles held zero entries, which
  # is the worst combination — every surface reported AppArmor as on while
  # nothing was confined.
  #
  # Loading every stock profile is deliberately blunt, and its value on this
  # system is limited in a way worth stating: these are upstream profiles
  # written for FHS distributions, attaching to absolute paths like
  # /usr/bin/brave. NixOS has no such paths, so most will load and match
  # nothing. That makes this close to risk-free and also close to
  # protection-free — real confinement here needs profiles written against
  # Nix store paths, which is nix/modules/system/apparmor-store.nix (see
  # that file for the generator and the store-catchall complain-mode
  # profile it ships; it is imported alongside this module in
  # flake/nixos.nix). What this does buy is honesty: the profile count
  # stops being zero, so the security dashboard can report what is
  # actually loaded instead of implying protection that does not exist.
  #
  # Only regular files are eligible: the directory also holds abstractions/,
  # tunables/ and disable/, which are include fragments rather than profiles,
  # and the module asserts a policy name contains no slash.
  security.apparmor = {
    enable = true;
    packages = [ pkgs.apparmor-profiles ];
    policies =
      let
        profileDir = "${pkgs.apparmor-profiles}/etc/apparmor.d";
      in
      lib.mapAttrs (name: _: {
        path = "${profileDir}/${name}";
        state = "enforce";
      }) (lib.filterAttrs (_: kind: kind == "regular") (builtins.readDir profileDir));
  };
  services.firewalld.enable = true;
  services.firewalld.settings.DefaultZone = "drop";
  networking.nftables.enable = true;
  networking.firewall = {
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
