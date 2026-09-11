# NetworkManager with the wifi backend from nix/system/defaults.nix
# (settings.wifiBackend — "wpa_supplicant" or "iwd"). The retired Gentoo
# setup used iwd; the default here is wpa_supplicant. Flip via
# nix/system/defaults.nix to match the old Gentoo package.use (iwd) setup.
{
  settings,
  ...
}:
{
  networking.networkmanager = {
    enable = true;
    wifi.backend = settings.wifiBackend;
  };

  # Proton VPN (nix/home/proton/proton.nix): strict rp_filter drops the WireGuard
  # tunnel's return traffic on NixOS (nixpkgs#425431 — "connected" but 100%
  # packet loss). Loose is the wiki-recommended relaxation for fwmark-routed
  # WireGuard; settings.reversePathFilter defaults to "loose" — drop to false
  # in nix/system/defaults.nix if the app still reports servers unreachable.
  networking.firewall.checkReversePath = settings.reversePathFilter;

  # Phase B, ruling R6: copy the proven searxng-keygen directive set
  # (nix/modules/services/searxng.nix), adjusted for what THIS unit genuinely
  # needs, rather than inventing a bespoke set. NetworkManager's job — unlike
  # searx-keygen's one-shot offline write — is talking to the kernel's
  # networking stack and to hardware, so several of the searxng directives
  # would be a functional regression here, not a hardening win; each
  # omission below is deliberate and stated, not an oversight.
  #
  # Read the package's OWN vendored unit
  # (nixpkgs' networkmanager-1.58.0/etc/systemd/system/NetworkManager.service
  # in this pinned nixpkgs) before adding anything, because `systemd.packages`
  # ships that file verbatim and a drop-in only ever ADDS to or REPLACES
  # single-value directives on top of it — it already carries:
  #   CapabilityBoundingSet=CAP_NET_ADMIN CAP_DAC_OVERRIDE CAP_NET_RAW
  #     CAP_BPF CAP_NET_BIND_SERVICE CAP_SETGID CAP_SETUID CAP_SYS_MODULE
  #     CAP_AUDIT_WRITE CAP_KILL CAP_SYS_CHROOT
  #   PrivateTmp=true, ProtectClock=true, ProtectControlGroups=true,
  #   ProtectHome=read-only, ProtectKernelLogs=true, ProtectSystem=true,
  #   RestrictRealtime=true, RestrictSUIDSGID=true
  # That is why this repo's own drop-in below is short: most of the searxng
  # set is either already present upstream or actively wrong for this unit.
  #
  # NOT added, and why:
  #   - CapabilityBoundingSet: the brief measuring secureblue's own drop-in
  #     explicitly warns this unit must NOT get an empty
  #     CapabilityBoundingSet. Left untouched entirely rather than restated,
  #     because systemd ORs repeated CapabilityBoundingSet= assignments
  #     together (an empty one resets it, a non-empty one only adds) — the
  #     one safe way to avoid fighting that merge semantics is to not
  #     mention the key at all and keep the vendor unit's list authoritative.
  #   - ProtectSystem = "strict": upstream ships plain `true` (protects only
  #     /usr, /boot, /efi) rather than `strict` (which would also make /etc
  #     read-only). This machine's NetworkManager writes Wi-Fi profiles to
  #     /etc/NetworkManager/system-connections — the exact path
  #     impermanence.nix persists across the tmpfs-root wipe — so `strict`
  #     would break every "connect to a new network" and "forget network"
  #     action. Left at upstream's `true`.
  #   - ProtectKernelTunables: NetworkManager writes directly under
  #     /proc/sys/net/ipv4/conf/<iface>/* and
  #     /proc/sys/net/ipv6/conf/<iface>/* for per-interface behaviour
  #     (accept_ra, use_tempaddr, arp filtering, IPv4 forwarding for a
  #     hotspot) — this is routine NM operation, not an edge case, and
  #     ProtectKernelTunables makes exactly that path read-only regardless
  #     of capability.
  #   - ProtectKernelModules: the vendor unit grants CAP_SYS_MODULE on
  #     purpose (loading `tun`, ppp, or a VPN plugin's kernel module on
  #     demand); ProtectKernelModules blocks module loading outright
  #     regardless of capability, which would make that grant dead weight.
  #   - PrivateDevices: this is a laptop (form-factor.nix) with a hardware
  #     Wi-Fi/Bluetooth kill switch — NetworkManager needs `/dev/rfkill` to
  #     see it, and PrivateDevices hides every real device node behind a
  #     minimal API-only /dev.
  #   - NoNewPrivileges: not in the vendor unit either, and CAP_SETUID/
  #     CAP_SETGID plus the ppp integration (systemd.tmpfiles rule for
  #     /run/pppd/lock elsewhere in this module) suggest NetworkManager may
  #     still exec a setuid helper for some VPN plugin path; matching
  #     upstream's own omission here rather than guessing it is safe.
  #
  # ADDED:
  #   - RestrictAddressFamilies: absent upstream (no allowlist at all today).
  #     AF_UNIX for D-Bus/polkit, AF_INET/AF_INET6 for NM's own probing
  #     sockets, AF_NETLINK for rtnetlink/nl80211 (the mechanism NM's entire
  #     job runs on), AF_PACKET for the DHCP client's raw socket. This is
  #     the one directive secureblue's own measured NetworkManager drop-in
  #     is known to carry (per the task brief), reaching its documented
  #     2.9 `systemd-analyze security` score.
  #   - ProtectHome = true: tightens upstream's `read-only` to a full hide.
  #     NetworkManager (system service, not `nmcli`'s per-user config) never
  #     reads anything under /home.
  #   - RestrictNamespaces, LockPersonality, MemoryDenyWriteExecute: no
  #     known NetworkManager codepath needs a new namespace, an ABI
  #     personality switch, or a W^X violation; safe additions from the
  #     searxng set.
  systemd.services.NetworkManager.serviceConfig = {
    ProtectHome = true;
    RestrictNamespaces = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
      "AF_NETLINK"
      "AF_PACKET"
    ];
  };

  # Phase B, Part 4: chrony with NTS, porting secureblue's GrapheneOS-derived
  # config (measured off the live host, quoted verbatim in the task brief).
  # This replaces systemd-timesyncd, the NixOS default: `services.chrony`'s
  # own module (nixos/modules/services/networking/ntp/chrony.nix) already
  # does that step itself — `services.timesyncd.enable = mkForce false;` is
  # in its `config` block — so there is no separate "turn timesyncd off"
  # line to write here.
  #
  # `servers` + `serverOption` ("iburst", already the module default) +
  # `enableNTS = true` together reproduce the measured
  # `server <host> iburst nts` line for every entry, verified by reading the
  # module's own config-file template
  # (`"server " + server + " " + cfg.serverOption + optionalString
  # cfg.enableNTS " nts"`) rather than assumed.
  #
  # Everything else measured has no dedicated NixOS option and goes through
  # `extraConfig` verbatim, with two deliberate omissions from the literal
  # secureblue file:
  #   - `rtconutc`: already emitted automatically by the same template
  #     whenever `time.hardwareClockInLocalTime` is false (the NixOS
  #     default) — restating it in extraConfig would just duplicate the
  #     directive.
  #   - `rtcsync`: the module's own `enableRTCTrimming` (also on by default)
  #     does its own rtcfile/rtcautotrim-based RTC-drift tracking, which the
  #     module's option docs call more precise than `rtcsync`'s blind
  #     11-minute resync — and the two are mutually exclusive: an
  #     `assertions` entry in this exact module aborts the eval if
  #     `rtcsync` shows up in `extraConfig` while `enableRTCTrimming` is on.
  #     Kept the default (rtcfile tracking) rather than fighting it for a
  #     literal-match with secureblue; this is a deliberate divergence
  #     worth stating plainly, in the same spirit as the rp_filter/
  #     ptrace_scope table in the design spec.
  #
  # One more interaction worth recording rather than leaving implicit: the
  # module's own `enableMemoryLocking` option already defaults to `false`
  # specifically when `environment.memoryAllocator.provider` is
  # `"graphene-hardened"` or `"graphene-hardened-light"` — confirmed by
  # reading its `defaultText` inline above. Part 1 sets exactly
  # `"graphene-hardened"` in hardening.nix, so chronyd's `-m` (mlockall)
  # flag is already skipped with zero extra configuration here; nixpkgs
  # anticipated this exact allocator interaction before this repo needed it.
  services.chrony = {
    enable = true;
    servers = [
      "time.cloudflare.com"
      "ntppool1.time.nl"
      "nts.netnod.se"
      "ptbtime1.ptb.de"
      "time.dfm.dk"
    ];
    enableNTS = true;
    extraConfig = ''
      minsources 3
      authselectmode prefer
      cmdport 0
      noclientlog
      makestep 1.0 3
    '';
  };
}
