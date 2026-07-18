# Desktop: GNOME (GDM/Wayland) + Hyprland, pipewire, fonts and themes.
# Since the flatpak migration the GNOME core apps come from
# services.gnome.core-apps below; hand-picked GUI apps live per-user in
# Home Manager (nix/home/pkgs.nix).
{ pkgs, ... }:
{
  services = {
    displayManager.gdm.enable = true;
    desktopManager.gnome.enable = true;
    gnome = {
      # also brings sushi, gnome-disks and seahorse; gnome-software stays
      # out because it is gated on services.flatpak.enable upstream
      core-apps.enable = true;
      core-developer-tools.enable = false;
      games.enable = false;
      # rbw's built-in SSH agent (nix/home/bitwarden.nix) is the only SSH
      # agent here: gnome-keyring otherwise pulls in gcr-ssh-agent, whose
      # socket unit runs `systemctl --user set-environment SSH_AUTH_SOCK`
      # at login and would clobber the rbw socket. gnome-keyring itself
      # stays — Secret Service for glab's keyring token and proton bridge.
      gcr-ssh-agent.enable = false;
    };
  };
  environment = {
    # core-apps ships Epiphany; browsing is covered per-user by Brave and
    # LibreWolf (nix/home), so drop it from the set instead of disabling
    # core-apps wholesale.
    gnome.excludePackages = [ pkgs.epiphany ];
    systemPackages = (
      with pkgs.gnomeExtensions;
      [
        blur-my-shell
        dash-to-dock
        user-themes
        appindicator
        screentospace
        tiling-assistant
      ]
    );

    # System-wide Brave enterprise policies — inlined from the retired
    # files/brave/policies tree (git history); same /etc/brave/policies/managed
    # layout. Stays system-level: Chromium on Linux has no per-user managed
    # policies, so this cannot live in Home Manager (the browser itself is
    # per-user: programs.brave, nix/home/brave.nix).
    etc."brave/policies/managed/hardening.json".text = builtins.toJSON {
      # Brave Origin, declaratively: these are the per-feature policies the
      # brave://settings Origin "Upgrade" toggle flips internally (see the
      # Group Policy support doc + brave-core's Origin policy manager); the
      # standalone brave-origin flavor isn't packaged in nixpkgs.
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

      PasswordManagerEnabled = false;
      # SafeBrowsingEnabled is deprecated since Chrome 83 and ignored once
      # the ProtectionLevel policy is set; 0 = no Safe Browsing.
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
      DefaultWebBluetoothGuardSetting = 2;
      DefaultWebUsbGuardSetting = 2;
      WebUsbAskForUrls = [ "https://grapheneos.org" ];
      DefaultSerialGuardSetting = 2;
      BrowserSignin = 0;
      SyncDisabled = true;
      HttpsOnlyMode = "force_enabled";
      # Chromium's policy is WebRtcIPHandling — the "…Policy"-suffixed
      # spelling the old tree used is the extension-API pref name and was
      # never a managed policy, i.e. it silently did nothing.
      WebRtcIPHandling = "disable_non_proxied_udp";
    };
    # Default search: the local SearXNG instance (nix/modules/searxng.nix).
    # Tor Browser is deliberately left alone — its stock engine set is part
    # of the anti-fingerprinting story, and a localhost engine would leak
    # local state into the Tor profile.
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
  programs.hyprland.enable = true;
  # hyprlock (home-manager) can only unlock with a system PAM service
  security.pam.services.hyprlock = { };

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
    extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
    config.common.default = "gtk";
  };

  # hyprland.conf applies themes via gsettings.
  programs.dconf.enable = true;
}
