# Install-time parameters. The LiveISO installer (installer-tui) overwrites this
# file on the target before running `nixos-install`; the committed defaults only
# exist so the flake evaluates green without an installer run.
{
  username = "matus";
  hostname = "tokyonight";
  disks = [ "/dev/nvme0n1" ];
  swapSize = "32G";
  gitName = "Matus Mastena";
  gitEmail = "Shadiness9530@proton.me";
}
