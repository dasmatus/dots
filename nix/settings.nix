# Install-time parameters. The LiveISO installer (installer-tui) overwrites this
# file on the target before running `nixos-install`; the committed defaults only
# exist so the flake evaluates green without an installer run.
{
  username = "matus";
  hostname = "tokyonight";
  disk = "/dev/nvme0n1";
  swapSize = "32G";
}
