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
  #
  # `state` reads "complain", not "enforce": nothing in this repo enforces
  # any more. The two sibling modules (apparmor.nix, apparmor-store.nix) are
  # already complain, and the commit that flipped store-catchall back to
  # complain (`9b069e8`) records what happened the one time it was
  # enforced — `x` vanished for everything outside the store, so
  # sudo/pkexec/unix_chkpwd/newuidmap under /run/wrappers/bin stopped
  # running and greetd restart-looped into start-limit-hit. These stock
  # profiles attach to FHS paths that do not exist on NixOS, so this
  # particular flip changes no behaviour here today; it is stated as
  # policy, not as a fix. The invariant this repo now holds is "no profile
  # enforces until its denial log has been read", and a `state` string
  # that reads `enforce` invites the next person to assume otherwise.
  # Complain-mode profiles still log, and that log is what `dots-sandbox
  # triage` consumes. The honesty argument above still holds under
  # complain: a non-zero profile count is what keeps the dashboard from
  # implying protection that is not there, whether or not that protection
  # is currently switched on.
  security.apparmor = {
    enable = true;
    packages = [ pkgs.apparmor-profiles ];
    policies =
      let
        profileDir = "${pkgs.apparmor-profiles}/etc/apparmor.d";
      in
      lib.mapAttrs (name: _: {
        path = "${profileDir}/${name}";
        state = "complain";
      }) (lib.filterAttrs (_: kind: kind == "regular") (builtins.readDir profileDir));
  };
  services.firewalld.enable = true;
  # No `DefaultZone` override here on purpose. nixpkgs' firewall-firewalld.nix
  # sets `services.firewalld.settings.DefaultZone = lib.mkDefault
  # "nixos-fw-default"` and builds that zone's rules out of
  # `networking.firewall.{allowedTCPPorts,allowedUDPPorts,trustedInterfaces,
  # rejectPackets}` below. A plain-literal override here used to win over
  # that `mkDefault` at normal priority, which made the entire
  # `networking.firewall` block dead code: it kept configuring a zone no
  # interface was bound to any more, while every real interface fell into
  # firewalld's built-in bare `drop` zone instead — a zone this repo
  # configures no exceptions for anywhere. mDNS, IPv6 router advertisements
  # and the DHCPv4 raw-socket DISCOVER/OFFER handshake all died there, on a
  # machine that is multi-homed across libvirt bridges and a VPN (see the
  # rp_filter comment above). Also worth recording: `networking.firewall.backend`
  # auto-resolves to `firewalld` whenever `services.firewalld.enable` is set,
  # so `networking.nftables.enable` below is inert here — there is no
  # dual-writer conflict, which is why the fix is one deletion and not a
  # rework.
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
  # Escalation is `run0` first, sudo-rs second.
  #
  # `run0` (a systemd-run alias, systemd >= 256) asks PID 1 to start the
  # command as a transient unit and authenticates through polkit. It owns no
  # setuid bit and inherits nothing from the calling shell — no environment,
  # no ambient capabilities, a fresh PTY. That property is why it leads here
  # rather than because it is newer: this machine has already had every
  # setuid binary under /run/wrappers/bin stop working at once. Commit
  # 9b069e8 records it — `store-catchall` went to enforce, execute vanished
  # for everything outside the store, and sudo, su, pkexec, passwd and
  # newuidmap all died together while greetd restart-looped. An escalation
  # path that never touches /run/wrappers survives that class of failure.
  #
  # sudo-rs deliberately STAYS enabled underneath. run0 depends on polkit,
  # dbus and a live PID 1 answering on the system bus, which is a longer
  # chain than a setuid binary needs; if any link breaks, sudo-rs is the way
  # back in. Two mechanisms with disjoint failure modes is the point. The day
  # run0 has proven itself here, dropping sudo-rs is one line — but it is a
  # separate, deliberate change, not a side effect of preferring run0.
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

    # Without this, run0 would be strictly worse to use than the sudo-rs
    # sitting next to it: `manage-units` defaults to auth_admin, so every
    # escalation would prompt while `sudo` stayed passwordless, and nobody
    # would reach for run0 twice.
    #
    # This grants no privilege that is not already granted. wheel has
    # passwordless sudo-rs on this machine, i.e. unauthenticated root
    # already; a rule that lets the same group manage units without
    # re-authenticating hands over nothing new. State that plainly rather
    # than pretending the rule is narrow: `manage-units` covers starting and
    # stopping ANY system unit, not just the transient one run0 creates,
    # because systemd exposes no run0-specific action to scope it to.
    #
    # The corollary is that flipping wheelNeedsPassword back to true does NOT
    # by itself restore a password prompt everywhere — this rule has to go
    # with it, or run0 remains the passwordless hole in an otherwise
    # key-gated setup.
    polkit.extraConfig = ''
      // run0 (systemd-run) for wheel, without re-authenticating.
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            subject.isInGroup("wheel")) {
          return polkit.Result.YES;
        }
      });
    '';
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
  # An earlier version of this comment claimed the machine could not lock
  # itself out because its keyboard was `AT Translated Set 2 keyboard` on PS/2
  # and its touchpad `ELAN0524:00` on i2c, so nothing traversed USB. That is
  # true of the laptop and false of `matthiaspc`, which drives this same
  # closure: there the keyboard is a `Massdrop Inc. ALT Keyboard` sitting
  # BEHIND a `Massdrop Hub`, and the mouse a `Corsair NIGHTSWORD RGB`. Both
  # are USB, which is precisely the "one replug away from an unusable console"
  # case the old comment warned others about while asserting it did not apply
  # here.
  #
  # `presentDevicePolicy = "allow"` still grandfathers in whatever is attached
  # when the daemon starts, so a clean boot was never the exposure. The
  # exposure is everything after it: a replug, a hub power cycle, a KVM
  # switch, or any re-enumeration hits `implicitPolicyTarget = "block"` and
  # takes the keyboard with it.
  #
  # The `rules` below close that. They are the input chain and nothing else,
  # listed parent-first because a rule for a device behind a blocked hub
  # grants nothing — the hub has to come back before the keyboard hanging off
  # it can. Deliberately NOT a general "allow all HID": BadUSB attacks work by
  # claiming to be a keyboard, so allowing the class would surrender exactly
  # what USBGuard is here to hold. Everything else on this box — the audio
  # device, MSI Mystic Light, Bluetooth, any USB storage — stays subject to
  # the implicit block once re-enumerated, and gets approved through the
  # daemon (see IPCAllowedUsers) or gains a line here.
  services.usbguard = {
    enable = true;
    implicitPolicyTarget = "block";
    presentDevicePolicy = "allow";
    rules = ''
      allow id 1d6b:0002 # Linux xHCI root hub (USB 2.0) — the input chain hangs off this one
      allow id 1d6b:0003 # Linux xHCI root hub (USB 3.0)
      allow id 04d8:eec5 # Massdrop Hub — the ALT keyboard's parent; blocking it orphans the keyboard
      allow id 04d8:eed3 # Massdrop Inc. ALT Keyboard
      allow id 1b1c:1b5c # Corsair NIGHTSWORD RGB Gaming Mouse
    '';
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
