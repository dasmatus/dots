# NetworkManager with the iwd wifi backend — matches the retired Gentoo
# networkmanager package.use (iwd) setup (git history).
{ ... }:
{
  networking.networkmanager = {
    enable = true;
    wifi.backend = "wpa_supplicant";
  };
}
