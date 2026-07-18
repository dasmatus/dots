# agenix: encrypted secrets committed to this public repo, decrypted at
# activation with the machine's SSH host key. First (and so far only)
# secret: the GitLab PAT that dots-keys (nix/home/bitwarden.nix) feeds to
# glab — with it, git-over-HTTPS auth works on a fresh machine before
# Bitwarden is ever unlocked; without it, dots-keys falls back to the
# vault item. This deliberately stays smaller than a full sops/agenix
# rollout: one host identity, one rules file, secrets opt-in per file.
#
# Nothing here generates host keys by default — services.openssh is off in
# this config — so a oneshot creates the ed25519 host key on first boot.
# Chicken-and-egg on a brand-new machine: the key appears on the first
# boot, but agenix decrypts during *activation*, so secrets materialize
# from the second activation onward (any nixos-rebuild switch or reboot).
# dots-keys tolerates the gap via its vault fallback.
#
# Adding/rekeying a secret (agenix CLI is in systemPackages):
#   1. cat /etc/ssh/ssh_host_ed25519_key.pub  → paste into
#      secrets/secrets.nix (per-machine; append, don't replace, to keep
#      old machines able to decrypt).
#   2. cd secrets && agenix -e gitlab-pat.age  (paste the PAT, one line)
#   3. git add secrets/gitlab-pat.age  — flake eval only sees tracked
#      files, and the age.secrets guard below keys off exactly that.
{
  config,
  lib,
  pkgs,
  inputs,
  settings,
  ...
}:
{
  environment.systemPackages = [
    inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
  ];

  age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  age.secrets = lib.mkIf (builtins.pathExists ../../secrets/gitlab-pat.age) {
    gitlab-pat = {
      file = ../../secrets/gitlab-pat.age;
      owner = settings.username;
    };
  };

  systemd.services.ssh-host-key = {
    description = "Generate the ed25519 SSH host key (agenix identity)";
    wantedBy = [ "multi-user.target" ];
    unitConfig.ConditionPathExists = "!/etc/ssh/ssh_host_ed25519_key";
    serviceConfig.Type = "oneshot";
    path = [ pkgs.openssh ];
    script = ''
      mkdir -p /etc/ssh
      ssh-keygen -t ed25519 -N "" -C ${config.networking.hostName} \
        -f /etc/ssh/ssh_host_ed25519_key
    '';
  };
}
