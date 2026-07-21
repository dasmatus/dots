# System-level desktop. The whole block is conditionalized on
# settings.desktop == "hyprland" (nix/defaults.nix) — any other value (e.g.
# "none") skips it. The if-then-else mirrors the nvidia branch style in
# nix/hosts.nix. NOTE: the Home Manager side (nix/home/hyprland.nix + friends)
# is NOT gated — settings is not passed to home-manager (users.nix), so a
# non-"hyprland" value leaves the HM hyprland config importing regardless;
# wire that separately if a second desktop is ever added.
{
  lib,
  pkgs,
  settings,
  config,
  ...
}:
{
  # Require a FIDO2 key (PLUS the password) to unlock hyprlock, the ly display
  # manager, and the console login. Both factors are mandatory: a correct key
  # alone or a correct password alone is NOT enough. Recovery if the key is
  # lost: boot the LiveISO (`just iso`), nixos-enter, set this to false,
  # nixos-rebuild switch, reboot. Enroll keys with `just enroll-fido`.
  options.dots.fido.requireKey = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Require a FIDO2 key in addition to the password for hyprlock, ly, and console login (2FA). Turn off only for key-loss recovery via the LiveISO.";
  };

  config =
    if settings.desktop == "hyprland" then
      lib.mkMerge [
        {
          services.gnome.gnome-keyring.enable = true;
          # GUI frontend for gnome-keyring (also wires ssh askpass). This is a
          # NixOS option, not a home-manager one — it previously sat in
          # nix/home/hyprland.nix, where HM eval rejected it.
          programs.seahorse.enable = true;
          services.displayManager.ly.enable = true;
          programs.hyprland = {
            enable = true;
            withUWSM = true;
            xwayland.enable = true;
          };
          services.udisks2.enable = true;

          # ── Security key support (system level) ──────────────────────────
          # pcscd: required for smart-card / PIV / OpenPGP card access
          services.pcscd.enable = true;

          # udev rules: let non-root users talk to the key over USB
          services.udev.packages = with pkgs; [
            yubikey-personalization # YubiKey OTP / challenge-response
            libu2f-host # U2F HID
          ];

          # pamu2fcfg: enrolls a key into ~/.config/Yubico/u2f_keys (one line
          # per key — `just enroll-fido` runs it once per key). pam_u2f.so
          # itself is pulled into the PAM stack automatically by the u2fAuth
          # options below; this package only provides the enrollment CLI.
          environment.systemPackages = [ pkgs.pam_u2f ];

          # PAM U2F: wire the FIDO2 key into hyprlock, the ly display manager,
          # console login, and sudo. The authfile defaults to per-user
          # ~/.config/Yubico/u2f_keys, so enroll once per key with `just
          # enroll-fido` (two keys = two lines). The 2FA tightening below
          # (gated on dots.fido.requireKey, default true) makes the key AND
          # the password BOTH mandatory for hyprlock/ly/login. sudo stays
          # dormant while sudo-rs runs NOPASSWD for wheel (hardening.nix); it
          # only prompts if wheelNeedsPassword is flipped back to true.
          security.pam.services = {
            hyprlock.u2fAuth = true;
            ly.u2fAuth = true;
            login.u2fAuth = true;
            # Dormant while sudo-rs runs NOPASSWD for all wheel (hardening.nix);
            # only prompts if wheelNeedsPassword is flipped back to true.
            sudo.u2fAuth = true;
          };
          # Show a "Please touch the device" cue at every U2F prompt. NB:
          # hyprlock currently surfaces this as PAM_TEXT_INFO, not as the
          # visible prompt text (hyprlock issue #723), so the lockscreen still
          # reads "Password:" during the touch phase — tap the key first,
          # then type the password.
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

              # FIX: 3 = Ask (was 2 = Block). Lets BLE security keys prompt.
              DefaultWebBluetoothGuardSetting = 3;

              # WebUsbAskForUrls removed — having it set to only
              # grapheneos.org implicitly blocked WebUSB everywhere else,
              # including WebAuthn transports that rely on it.  With the
              # key gone, the default behaviour is "ask", which preserves
              # the security posture while letting keys work on any site.
              # WebUsbAskForUrls = [ … ];  ← deleted

              # FIX: 3 = Ask (was 2 = Block). Some keys (YubiKey OTP CCID)
              # expose a serial interface.
              DefaultSerialGuardSetting = 3;

              SyncDisabled = true;
              HttpsOnlyMode = "force_enabled";
              WebRtcIPHandling = "disable_non_proxied_udp";
            };

            etc."brave/policies/managed/search.json".text = builtins.toJSON {
              DefaultSearchProviderEnabled = true;
              DefaultSearchProviderName = "SearXNG";
              DefaultSearchProviderKeyword = "sx";
              DefaultSearchProviderSearchURL = "http://127.0.0.1:8888/search?q={searchTerms}";
              DefaultSearchProviderSuggestURL = "http://127.0.0.1:8888/autocompleter?q={searchTerms}";
            };

            etc."brave/policies/managed/extensions.json".text = builtins.toJSON {
              ExtensionInstallForcelist = [
                "nngceckbapebfimnlniiiahkandclblb;https://clients2.google.com/service/update2/crx"
                "fcoeoabgfenejglbffodgkkbkcdhcgfn;https://clients2.google.com/service/update2/crx"
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

          xdg.portal = {
            enable = true;
            # Both portal backends must be present in the system portal dir so
            # hyprland-portals.conf can dispatch Screenshot/ScreenCast to
            # hyprland and Settings/FileChooser to gtk.
            extraPortals = [
              pkgs.xdg-desktop-portal-hyprland
              pkgs.xdg-desktop-portal-gtk
            ];
          };

          programs.dconf.enable = true;
        }

        # ── 2FA tightening: FIDO2 key AND password both required ───────────
        # PAM stacks hyprlock/ly/login (useDefaultRules=true) as:
        #   [ pam_u2f.so (sufficient) → pam_unix.so (sufficient) → pam_deny.so (required) ]
        # Default = "key OR password" (either sufficient short-circuits before
        # the always-failing pam_deny). To make BOTH factors mandatory:
        #   1. pam_u2f.so → required: one global knob (security.pam.u2f.control
        #      overrides the option default "sufficient" cleanly — no mkForce).
        #   2. pam_unix.so → required: per service, mkForce (the auto-rule sets
        #      a plain "sufficient" definition that would otherwise conflict).
        #   3. pam_deny.so → DISABLED: it is `required` and ALWAYS returns
        #      PAM_AUTH_ERR — if left in, two preceding required successes still
        #      hit deny and the stack fails (total lockout). deny.enable is a
        #      plain override (the auto-rule never sets `enable`).
        # Verified via `nix eval` on this flake: u2f (order 10900) renders
        # before unix (order 11700), both `required`, no deny rule. sudo is
        # intentionally untouched (stays dormant while sudo-rs is NOPASSWD).
        (lib.mkIf config.dots.fido.requireKey {
          # u2f side: one global knob covers every service with u2fAuth=true
          # (hyprlock, ly, login, and the dormant sudo).
          security.pam.u2f.control = "required";
          # unix side + deny removal, per service.
          security.pam.services.hyprlock.rules.auth.unix.control = lib.mkForce "required";
          security.pam.services.ly.rules.auth.unix.control = lib.mkForce "required";
          security.pam.services.login.rules.auth.unix.control = lib.mkForce "required";
          security.pam.services.hyprlock.rules.auth.deny.enable = false;
          security.pam.services.ly.rules.auth.deny.enable = false;
          security.pam.services.login.rules.auth.deny.enable = false;
        })
      ]
    else
      { };
}
