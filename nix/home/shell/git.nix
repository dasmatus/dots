# Git identity + SSH commit signing. The identity (user.name / user.email)
# comes from the installer-collected dots.gitName / dots.gitEmail (written
# into nix/data/settings.nix by rust/installer-tui, bridged to options.dots.* by
# nix/modules/dots.nix, and passed into HM via nix/modules/system/users.nix
# extraSpecialArgs). Signing is SSH-format
# against the public half of the Bitwarden-vault SSH key: dots-keys
# (bitwarden.nix) exports ~/.ssh/id_ed25519.pub, and with a .pub-only
# signingkey git's ssh-keygen -Y sign pulls the private key from the rbw
# agent — it never exists on disk. Transport auth is SSH-only too: the
# same vault key pushes to Codeberg over ssh://git@codeberg.org/dasmatus/dots
# (dots-repo.nix flips the dots clone's origin to SSH after the
# first-login clone; dots-keys keeps it there). No HTTPS credential
# helper and no forge CLI — the repo is public, so the bootstrap clone is
# anonymous HTTPS and everything after is SSH.
{
  config,
  pkgs,
  dots,
  ...
}:
{
  programs.git = {
    enable = true;
    package = pkgs.git.override { withLibsecret = true; };
    settings = {
      user = {
        name = dots.gitName;
        email = dots.gitEmail;
        # Absolute path — git does not tilde-expand signingkey.
        signingkey = "${config.home.homeDirectory}/.ssh/id_ed25519.pub";
      };
      credential.helper = "libsecret";
      gpg.format = "ssh";
      # Written by dots-keys; lets `git log --show-signature` verify locally.
      gpg.ssh.allowedSignersFile = "${config.xdg.configHome}/git/allowed_signers";
      commit.gpgsign = true;
      tag.gpgsign = true;
    };
  };
}
