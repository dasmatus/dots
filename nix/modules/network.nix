# NetworkManager with the iwd wifi backend — parity with the Gentoo
# networkmanager package.use (iwd) in installer/hostconfig.py.
{ ... }:
{
  networking.networkmanager = {
    enable = true;
    wifi.backend = "iwd";
  };
}
