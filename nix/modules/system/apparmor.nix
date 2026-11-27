# AppArmor enabled in complain mode. Profiles stay loaded for visibility but do
# not block applications.
{
  lib,
  ...
}:
{
  security.apparmor = {
    enable = true;
    # Keep per-app profiles from nixpkgs/defaults in complain mode.
    policies = lib.mkForce { };
  };
  security.apparmor.killUnconfinedConfinables = false;
}
