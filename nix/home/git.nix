# Git identity, SSH commit signing, and HTTPS auth. Signing is SSH-format
# against the public half of the Bitwarden-vault SSH key: dots-keys
# (bitwarden.nix) exports ~/.ssh/id_ed25519.pub, and with a .pub-only
# signingkey git's ssh-keygen -Y sign pulls the private key from the rbw
# agent — it never exists on disk. HTTPS auth goes through glab's
# credential helper (replacing the former libsecret helper outright, so a
# stale keyring PAT cannot shadow it); glab only answers for its
# configured GitLab hosts, and other hosts use SSH via the same agent.
{
  config,
  pkgs,
  ...
}:
{
  programs.git = {
    enable = true;
    package = pkgs.git.override { withLibsecret = true; };
    config = {
      user = {
        name = "Matus Mastena";
        email = "Shadiness9530@proton.me";
        # Absolute path — git does not tilde-expand signingkey.
        signingkey = "${config.home.homeDirectory}/.ssh/id_ed25519.pub";
      };
      gpg.format = "ssh";
      # Written by dots-keys; lets `git log --show-signature` verify locally.
      gpg.ssh.allowedSignersFile = "${config.xdg.configHome}/git/allowed_signers";
      commit.gpgsign = true;
      tag.gpgsign = true;
      credential.helper = "libsecret";
    };
  };
}
