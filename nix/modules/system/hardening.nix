# Declarative NixOS-option mapping derived from the retired konkrit firstboot
# hardening catalog (Gentoo era; see git history — 104 modules). Categories
# covered: sysctl net/kernel, boot params, coredump/ptrace, AppArmor,
# USBGuard, auditd, hidepid, firewall, sudo, kernel image protection,
# tmpfs /tmp.
#
# AppArmor ends up split three ways, so read all three before changing one.
# The stock-profile load stays here because it is a single blunt switch
# rather than a catalog worth its own file. The profiles that actually
# attach on NixOS are written against store paths and outgrew this module:
# nix/modules/system/apparmor.nix holds the per-app profiles aimed at each
# browser's and editor's resolved ELF, and nix/modules/system/apparmor-store.nix
# holds the `mkStoreProfile` generator plus the store-wide complain-mode
# catch-all whose denial log feeds `dots-sandbox triage`. flake/nixos.nix
# imports all three together; none of them is sufficient alone.
#
# A second pass in 2026-09 closed the findings from `lynis audit system`
# (baseline: hardening index 70). Not everything Lynis asks for is right on
# NixOS, and the items deliberately left alone are commented where they sit
# rather than silently ignored, so the next audit does not re-litigate them.
{
  config,
  lib,
  pkgs,
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
    # Lynis KRNL-6000 wants rp_filter=1 (strict). It stays at 2 (loose) on
    # purpose: this machine is multi-homed across libvirt bridges and a VPN,
    # and strict mode drops the return path of any asymmetric route, which
    # breaks both. Loose still discards packets with no route back at all.
    "net.ipv4.conf.all.rp_filter" = lib.mkForce 2;
    "net.ipv4.conf.default.rp_filter" = 2;
    # Unprivileged loading of TTY line disciplines has a long history of local
    # privilege escalation (CVE-2017-2636 and friends). Nothing here needs it.
    "dev.tty.ldisc_autoload" = 0;
    # Log packets with impossible source addresses. Costs some journal volume
    # and is the only way to notice spoofing attempts at all.
    "net.ipv4.conf.all.log_martians" = 1;
    "net.ipv4.conf.default.log_martians" = 1;
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

  # Lynis NETW-3200 flags all four. Nothing on this machine speaks dccp, sctp,
  # rds or tipc, and each is a rarely-audited protocol stack the kernel will
  # autoload on a bare socket() call from any user. Blacklisting removes that.
  boot.blacklistedKernelModules = [
    "dccp"
    "sctp"
    "rds"
    "tipc"
  ];

  # USB-1000 / BadUSB. `implicitPolicyTarget = "block"` refuses anything not
  # already known, and `presentDevicePolicy = "allow"` grandfathers in whatever
  # is plugged in when the daemon starts, so the first boot after this lands
  # does not fight the hardware.
  #
  # This is safe on this machine for a specific reason worth writing down: the
  # keyboard is an `AT Translated Set 2 keyboard` on PS/2 and the touchpad is
  # `ELAN0524:00` on i2c, so neither traverses USB and no USBGuard decision can
  # lock the console out. /proc/bus/input/devices lists no USB input device at
  # all; the only USB attachments are the webcam and the wireless combo. On a
  # machine with a USB keyboard this configuration is one replug away from an
  # unusable console, so re-check that before copying this block elsewhere.
  services.usbguard = {
    enable = true;
    implicitPolicyTarget = "block";
    presentDevicePolicy = "allow";
    # The desktop needs to talk to the daemon to approve a new device without
    # a root shell.
    IPCAllowedUsers = [
      "root"
      config.dots.username
    ];
  };

  # ACCT-9628. Deliberately a short ruleset: auditd bills every matching
  # syscall, and a catch-all ruleset on a desktop buys noise rather than
  # evidence. These watch the files that grant access and the two operations
  # that change what the kernel itself will run.
  security.auditd.enable = true;
  security.audit = {
    enable = true;
    rules = [
      "-w /etc/passwd -p wa -k identity"
      "-w /etc/group -p wa -k identity"
      "-w /etc/shadow -p wa -k identity"
      "-w /etc/sudoers.d -p wa -k privilege"
      "-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k modules"
    ];
  };

  # FILE-6310-adjacent: hide other users' processes from unprivileged users, so
  # a compromised session cannot read another user's command lines and
  # /proc/<pid>/environ. `gid=proc` is the half that makes this survivable:
  # without a group allowed through, systemd-logind loses its view of sessions
  # and the desktop breaks in ways that only appear after a reboot.
  # The gid is pinned rather than left to auto-allocation because the mount
  # option below needs its numeric value at eval time, and an unpinned
  # users.groups entry evaluates to null there. 400 is free on both counts:
  # nixpkgs' static assignments in misc/ids.nix stop at 327, and NixOS allocates
  # dynamic system gids downward from 999.
  users.groups.proc.gid = 400;
  fileSystems."/proc" = {
    device = "proc";
    fsType = "proc";
    options = [
      "nosuid"
      "nodev"
      "noexec"
      "hidepid=2"
      "gid=${toString config.users.groups.proc.gid}"
    ];
  };
  systemd.services.systemd-logind.serviceConfig.SupplementaryGroups = [ "proc" ];

  # Not set, on purpose. Lynis KRNL-6000 wants kernel.modules_disabled=1, which
  # is a one-way switch: once flipped the kernel refuses every later module
  # load, so hotplugging anything, starting a VM, or bringing up a VPN after
  # boot fails with no way back short of a reboot. NixOS loads modules well past
  # early boot, so this would break the system rather than harden it.
}
