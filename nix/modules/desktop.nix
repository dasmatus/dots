# System-level desktop. The whole block is conditionalized on
# settings.desktop == "hyprland" (nix/defaults.nix) — any other value (e.g.
# "none") skips it. The if-then-else mirrors the nvidia branch style in
# nix/hosts.nix. NOTE: the Home Manager side (nix/home/hyprland.nix + friends)
# is NOT gated — settings is not passed to home-manager (users.nix), so a
# non-"hyprland" value leaves the HM hyprland config importing regardless;
# wire that separately if a second desktop is ever added.
{
  pkgs,
  settings,
  ...
}:
{
  config =
    if settings.desktop == "hyprland" then
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

        # PAM U2F: allow the security key to unlock hyprlock
        security.pam.services.hyprlock = {
          u2fAuth = true;
        };

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
          extraPortals = [ pkgs.xdg-desktop-portal-hyprland ];
        };

        programs.dconf.enable = true;
      }
    else
      { };
}
