# System-level desktop services shared by all three DEs (GNOME, Hyprland,
# Sway). Everything here is unconditional — no `if` on the DE choice. Each
# per-DE module (gnome.nix, hyprland.nix, sway.nix) adds only what is unique
# to its compositor.
#
# Split out of the former desktop.nix monolith so a second DE can be added
# without duplicating pipewire/fonts/portals/PAM/flatpak/Brave-policies.
{
  lib,
  pkgs,
  config,
  ...
}:
{
  # Require a FIDO2 key (PLUS the password) to unlock the screen locker, the
  # display manager, and the console login. When true, both factors are
  # mandatory: a correct key alone or a correct password alone is NOT enough.
  # When false (the default), `pam_u2f.so` is `sufficient` — a correct key
  # touch alone short-circuits the PAM stack before `pam_unix.so`/`pam_deny.so`,
  # so the key unlocks without the password (the password still works as a
  # fallback via the `sufficient` pam_unix.so). Recovery if the key is lost:
  # boot the LiveISO (`nix run .#iso`), nixos-enter, flip this back, rebuild,
  # reboot. Enroll keys with `nix run .#enroll-fido`.
  options.dots.fido.requireKey = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "When true, require a FIDO2 key AND the password (2FA) for the screen locker, display manager, and console login. When false (default), the key alone is sufficient — touching it unlocks without the password, the password remains a fallback. Turn on only when you want mandatory 2FA; flip back via the LiveISO for key-loss recovery.";
  };

  config = lib.mkMerge [
    {
      services.gnome.gnome-keyring.enable = true;
      # GUI frontend for gnome-keyring (also wires ssh askpass). This is a
      # NixOS option, not a home-manager one.
      programs.seahorse.enable = true;

      services.udisks2.enable = true;

      # Nothing added for exfat or vfat: both are already in
      # /proc/filesystems on this machine and udisks mounts them through
      # the kernel driver without running fsck. ntfs is different.
      # udisks lists "ntfs" in its SupportedFilesystems D-Bus property,
      # but it ships no mount.ntfs of its own, so that property is not
      # proof the kernel can actually mount one.
      boot.supportedFilesystems.ntfs = true;

      # UPower backs the Quickshell bar's battery module. waybar read
      # /sys/class/power_supply itself and so needed nothing here, which is
      # why this was never enabled; Quickshell talks to
      # org.freedesktop.UPower over D-Bus instead, and without the service
      # the name is not activatable and the battery silently never appears.
      # The daemon also supplies charge state and time-to-empty, which
      # sysfs only offers as raw counters to be reassembled by hand.
      services.upower.enable = true;

      # ── Security key support (system level) ──────────────────────────
      # pcscd: required for smart-card / PIV / OpenPGP card access
      services.pcscd.enable = true;

      # udev rules: let non-root users talk to the key over USB
      services.udev.packages = with pkgs; [
        yubikey-personalization # YubiKey OTP / challenge-response
        libu2f-host # U2F HID
      ];

      # pamu2fcfg: enrolls a key into ~/.config/Yubico/u2f_keys (one line
      # per key — `nix run .#enroll-fido` runs it once per key). pam_u2f.so
      # itself is pulled into the PAM stack automatically by the u2fAuth
      # options below; this package only provides the enrollment CLI.
      environment.systemPackages = [ pkgs.pam_u2f ];

      # PAM U2F: wire the FIDO2 key into the screen locker, display manager,
      # console login, and sudo. The authfile defaults to per-user
      # ~/.config/Yubico/u2f_keys, so enroll once per key with `nix run
      # .#enroll-fido` (two keys = two lines). The 2FA tightening below
      # (gated on dots.fido.requireKey, default false) makes the key AND
      # the password BOTH mandatory for the locker/DM/login. sudo stays
      # dormant while sudo-rs runs NOPASSWD for wheel (hardening.nix); it
      # only prompts if wheelNeedsPassword is flipped back to true.
      security.pam.services = {
        login.u2fAuth = true;
        # Dormant while sudo-rs runs NOPASSWD for all wheel (hardening.nix);
        # only prompts if wheelNeedsPassword is flipped back to true.
        sudo.u2fAuth = true;
      };
      # Show a "Please touch the device" cue at every U2F prompt.
      security.pam.u2f.settings.cue = true;

      environment = {
        etc."brave/policies/managed/hardening.json".text = builtins.toJSON {
          BraveRewardsDisabled = true;
          BraveWalletDisabled = true;
          BraveVPNDisabled = true;
          TorDisabled = true;
          BraveAIChatEnabled = false;
          BraveNewsDisabled = true;
          BraveTalkDisabled = true;
          BravePlaylistEnabled = false;
          BraveSpeedreaderEnabled = false;
          BraveWaybackMachineEnabled = false;
          BraveWebDiscoveryEnabled = false;
          BraveP3AEnabled = false;
          BraveStatsPingEnabled = false;
          BlockThirdPartyCookies = true;
          PasswordManagerEnabled = false;
          SafeBrowsingProtectionLevel = 0;
          SafeBrowsingExtendedReportingEnabled = false;
          MetricsReportingEnabled = false;
          CloudReportingEnabled = false;
          AutofillAddressEnabled = false;
          AutofillCreditCardEnabled = false;
          BackgroundModeEnabled = false;
          NetworkPredictionOptions = 2;
          DnsOverHttpsMode = "secure";
          DnsOverHttpsTemplates = "https://family.dns.mullvad.net/dns-query";

          # 3 = Ask (was 2 = Block). Lets BLE security keys prompt.
          DefaultWebBluetoothGuardSetting = 3;

          # 3 = Ask (was 2 = Block). Some keys (YubiKey OTP CCID)
          # expose a serial interface.
          DefaultSerialGuardSetting = 3;

          SyncDisabled = true;
          HttpsOnlyMode = "force_enabled";
          WebRtcIPHandling = "disable_non_proxied_udp";
        };

        etc."brave/policies/managed/search.json".text = builtins.toJSON {
          DefaultSearchProviderEnabled = true;
          # DuckDuckGo, not the local SearXNG. The SearXNG URLs only
          # resolve where nix/modules/services/searxng.nix is actually
          # running; pointed at a host without it, every search in the
          # address bar fails with connection-refused and there is no
          # fallback, because a DefaultSearchProvider* policy set is
          # mandatory rather than advisory. A public provider is the only
          # value that is correct on both this repo's NixOS host and a
          # foreign machine applying the same policy set.
          DefaultSearchProviderName = "DuckDuckGo";
          DefaultSearchProviderKeyword = "ddg";
          DefaultSearchProviderSearchURL = "https://duckduckgo.com/?q={searchTerms}";
          DefaultSearchProviderSuggestURL = "https://duckduckgo.com/ac/?q={searchTerms}&type=list";
        };

        etc."brave/policies/managed/extensions.json".text = builtins.toJSON {
          ExtensionInstallForcelist = [
            "nngceckbapebfimnlniiiahkandclblb;https://clients2.google.com/service/update2/crx"
            "nomnklagbgmgghhjidfhnoelnjfndfpd;https://clients2.google.com/service/update2/crx"
            "cebifddlogbjhoibpjobhlamopmlpckl;https://clients2.google.com/service/update2/crx"
            "febipmhaonfflclkijaehmhnacjilggf;https://clients2.google.com/service/update2/crx"
            "mnjggcdmjocbbbhaepdhchncahnbgone;https://clients2.google.com/service/update2/crx"
          ];
        };
      };

      services.pipewire = {
        enable = true;
        alsa.enable = true;
        pulse.enable = true;
      };
      security.rtkit.enable = true;

      fonts.packages = with pkgs; [
        nerd-fonts.lilex
        nerd-fonts.agave
        noto-fonts-color-emoji
      ];
      fonts.fontconfig.defaultFonts.monospace = [ "Lilex Nerd Font" ];

      # The SYSTEM-level half of Flatpak (nixpkgs' own
      # nixos/modules/services/desktops/flatpak.nix — the plain
      # `services.flatpak.enable`, not nix-flatpak's declarative
      # packages/overrides, which stay on the home-manager side; see
      # nix/home/base/flatpaks.nix's header for why). Installing Flathub refs
      # into the USER installation without this one line still works —
      # flatpak run resolves them fine — but their exports/share never
      # joins the system XDG_DATA_DIRS, so a Flatpak's own icons, mime
      # associations and D-Bus service files are invisible to anything that
      # only ever looks at the system search path.
      services.flatpak.enable = true;

      programs.dconf.enable = true;
    }

    # ── U2F sufficiency vs 2FA tightening ──────────────────────────────
    # PAM stacks the locker/DM/login (useDefaultRules=true) as:
    #   [ pam_u2f.so (sufficient) → pam_unix.so (sufficient) → pam_deny.so (required) ]
    # Default (requireKey=false): `pam_u2f.so` is `sufficient`, so a
    # correct key touch short-circuits the stack before pam_unix.so and
    # the always-failing pam_deny.so — the key ALONE unlocks, no password
    # needed. A wrong/missing touch falls through to pam_unix.so (also
    # `sufficient`), so the password still works as a fallback. Either
    # path reaches the end only on failure, where pam_deny.so (required)
    # finalizes the rejection.
    #
    # requireKey=true flips to mandatory 2FA (key AND password):
    #   1. pam_u2f.so → required: one global knob (security.pam.u2f.control
    #      overrides the option default "sufficient" cleanly — no mkForce).
    #   2. pam_unix.so → required: per service, mkForce (the auto-rule sets
    #      a plain "sufficient" definition that would otherwise conflict).
    #   3. pam_deny.so → DISABLED: it is `required` and ALWAYS returns
    #      PAM_AUTH_ERR — if left in, two preceding required successes still
    #      hit deny and the stack fails (total lockout). deny.enable is a
    #      plain override (the auto-rule never sets `enable`).
    (lib.mkIf config.dots.fido.requireKey {
      # u2f side: one global knob covers every service with u2fAuth=true.
      security.pam.u2f.control = "required";
      # unix side + deny removal, per service. The per-DE modules add
      # their own locker's PAM service name to this list.
      security.pam.services.login.rules.auth.unix.control = lib.mkForce "required";
      security.pam.services.login.rules.auth.deny.enable = false;
    })
  ];
}
