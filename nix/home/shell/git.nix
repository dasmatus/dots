# Git commit signing and transport. The identity (user.name / user.email) is
# deliberately NOT set here: it is an agenix secret included at runtime by
# nix/home/secrets/identity.nix. It used to come from the installer-collected
# dots.gitName / dots.gitEmail, which meant a real name and address sat in
# plaintext in a public repo and in the world-readable Nix store. Setting no
# identity at all — rather than a placeholder for the include to override —
# makes git refuse to commit when the secret is missing instead of authoring
# commits under a fake name. Signing is SSH-format
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
  ...
}:
{
  programs.git = {
    enable = true;
    package = pkgs.git.override { withLibsecret = true; };
    settings = {
      # name/email intentionally absent — see the header. They arrive through
      # the `[include]` that nix/home/secrets/identity.nix appends.
      user = {
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
