# NetworkManager with the iwd wifi backend — matches the retired Gentoo
# networkmanager package.use (iwd) setup (git history).
{ ... }:
{
  networking.networkmanager = {
    enable = true;
    wifi.backend = "wpa_supplicant";
  };

  # Proton VPN (nix/home/proton.nix): strict rp_filter drops the WireGuard
  # tunnel's return traffic on NixOS (nixpkgs#425431 — "connected" but 100%
  # packet loss). Loose is the wiki-recommended relaxation for fwmark-routed
  # WireGuard; drop to false if the app still reports servers unreachable.
  networking.firewall.checkReversePath = "loose";
}
