# agenix recipient list, read by the `agenix` CLI ONLY (`agenix -e`, `-r`),
# never by the flake. `nix flake show` will not evaluate this file and nothing
# imports it; it exists so `agenix` knows which public keys each .age file
# under this directory must be encrypted to.
#
# Why the git identity is in here at all: nix/home/shell/git.nix needs a
# user.name/user.email, and this is a public repo. The identity used to sit in
# nix/data/settings.nix as plaintext, which put a real name and address in
# every clone and in the world-readable Nix store. agenix keeps the ciphertext
# in git and decrypts it at *activation* time to a file outside the store.
#
# That timing is the whole design constraint. age decrypts during activation,
# not during evaluation, so a decrypted value can never become a Nix string.
# `user.name = <secret>` is impossible by construction. nix/home/secrets/identity.nix
# therefore does not try: it points git's own `[include] path` at the
# decrypted file and lets git read the identity at runtime. Nothing about the
# identity is ever an eval-time input, which is also why removing it from
# settings.nix did not reintroduce the impurity that file's header describes.
#
# To add a recipient (a second machine, or a rotated key): append its public
# key below, then re-encrypt everything to the new set with
#   nix run github:ryantm/agenix -- -r -i ~/.ssh/id_ed25519
# run from this directory. `-r` rekeys in place; it needs an identity that is
# ALREADY a recipient, so never drop your only key in the same commit that
# adds its replacement.
let
  # The Bitwarden-vault SSH key's public half, exported to ~/.ssh/id_ed25519.pub
  # by `dots-keys` (nix/home/apps/bitwarden.nix). Reusing it as the age
  # recipient rather than minting a separate age identity is deliberate: it is
  # already the key that signs commits and authenticates the Codeberg remote,
  # its private half never touches disk (ssh-keygen -Y pulls it from the rbw
  # agent), and age speaks ssh-ed25519 natively. One key to hold, one to
  # rotate.
  #
  # REPLACE THIS with the real public key before the first `agenix -e`. The
  # placeholder is not a valid recipient and age will refuse it, which is the
  # intended failure. A silently-wrong recipient would produce a file only
  # the wrong key can open.
  matus = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDcBIqNnSREQ6lFWulDaZUUnGI7MPmE831Gpg1mOwF45";
in
{
  "git-identity.age".publicKeys = [ matus ];
}
