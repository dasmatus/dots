# Desktop: GNOME (GDM/Wayland) + Hyprland, pipewire, fonts and themes.
# GNOME core apps are delivered as verified flatpaks (nix/modules/flatpak.nix);
# only the apps without a Flathub presence stay native below.
{ pkgs, ... }:
{
  services = {
    displayManager.gdm.enable = true;
    desktopManager.gnome.enable = true;
    gnome = {
      core-apps.enable = false;
      core-developer-tools.enable = false;
      games.enable = false;
      # nautilus previews; core-apps-gated upstream, so re-enable explicitly
      sushi.enable = true;
    };
  };
  environment = {
    systemPackages =
      # core-apps replacements with no (verified) Flathub equivalent
      (with pkgs; [
        nautilus
        gnome-console
        gnome-system-monitor
        gnome-tecla
        yelp
      ])
      ++ (with pkgs.gnomeExtensions; [
        blur-my-shell
        dash-to-dock
        user-themes
        appindicator
        screentospace
        tiling-assistant
      ]);

    # System-wide Brave enterprise policies — inlined from the retired
    # files/brave/policies tree (git history); same /etc/brave/policies/managed
    # layout. Stays system-level: Chromium on Linux has no per-user managed
    # policies, so this cannot live in Home Manager.
    etc."brave/policies/managed/hardening.json".text = builtins.toJSON {
      BraveWalletDisabled = true;
      BraveRewardsDisabled = true;
      BraveNewsDisabled = true;
      BraveAIChatEnabled = false;
      PasswordManagerEnabled = false;
      SafeBrowsingEnabled = false;
      SafeBrowsingExtendedReportingEnabled = false;
      MetricsReportingEnabled = false;
      CloudReportingEnabled = false;
      DeviceMetricsReportingEnabled = false;
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
      WebRtcIPHandlingPolicy = "disable_non_proxied_udp";
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
  programs.gnome-disks.enable = true;
  programs.seahorse.enable = true;
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
