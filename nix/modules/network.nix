# NetworkManager with the wifi backend from nix/defaults.nix
# (settings.wifiBackend — "wpa_supplicant" or "iwd"). The retired Gentoo
# setup used iwd; the default here is wpa_supplicant. Flip via
# nix/defaults.nix to match the old Gentoo package.use (iwd) setup.
{
  settings,
  ...
}:
{
  networking.networkmanager = {
    enable = true;
    wifi.backend = settings.wifiBackend;
  };

  # Proton VPN (nix/home/proton.nix): strict rp_filter drops the WireGuard
  # tunnel's return traffic on NixOS (nixpkgs#425431 — "connected" but 100%
  # packet loss). Loose is the wiki-recommended relaxation for fwmark-routed
  # WireGuard; settings.reversePathFilter defaults to "loose" — drop to false
  # in nix/defaults.nix if the app still reports servers unreachable.
  networking.firewall.checkReversePath = settings.reversePathFilter;
}
