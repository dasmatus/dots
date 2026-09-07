# Git identity, delivered as an agenix secret instead of a committed string.
#
# The secret's plaintext is a git config fragment, not a bare value:
#
#   [user]
#       name = Your Name
#       email = you@example.com
#
# because of *when* age runs. Decryption happens at home-manager activation,
# long after evaluation has finished, so the identity cannot be a Nix string —
# there is no point at which `user.name = <plaintext>` could be assigned. What
# git does support is reading another config file at runtime, so this module
# hands git an `[include] path` and git itself resolves the identity on every
# invocation. See secrets/secrets.nix for the recipient list and the rekeying
# workflow.
#
# The include is appended AFTER the generated config, so the fragment wins over
# anything set there. nix/home/shell/git.nix deliberately no longer sets
# user.name/user.email at all, rather than setting a placeholder for this to
# override: a placeholder that survived a failed decryption would author
# commits under a fake name, whereas an absent identity makes git refuse to
# commit. Failing closed is the point, and it is why the `hasSecret` guard
# below disables the module rather than substituting a default.
{
  config,
  lib,
  ...
}:
let
  secretFile = ../../../secrets/git-identity.age;

  # Whether the ciphertext has been created yet. It cannot be committed
  # pre-filled — an .age file is only meaningful once encrypted to a real
  # recipient key, and this repo ships none (secrets/secrets.nix carries a
  # placeholder public key deliberately, so a wrong recipient fails loudly).
  #
  # Without this guard a fresh clone would not merely lack an identity, it
  # would fail to EVALUATE: agenix's `file` option takes a path, and Nix errors
  # on a path that does not exist as soon as it is coerced. That would break
  # `nix flake check` and every home build for anyone who has not run
  # `agenix -e` yet — the same class of bare-checkout breakage that
  # nix/data/settings.nix's header describes and that this repo just finished
  # removing. So absence disables the module, and the activation warning below
  # is what surfaces it.
  hasSecret = builtins.pathExists secretFile;

  # Outside the Nix store, which is world-readable, and outside the config tree
  # that gets backed up or synced. ~/.local/state is user-owned and is where
  # home-manager already keeps per-user runtime state.
  identityPath = "${config.home.homeDirectory}/.local/state/agenix/git-identity";
in
lib.mkMerge [
  (lib.mkIf hasSecret {
    age.secrets.git-identity = {
      file = secretFile;
      path = identityPath;
      mode = "0400";
    };

    # `include`, not `includeIf`: this identity is unconditional — it is who
    # this user is on this machine, not a per-directory override. A conditional
    # include keyed on a path prefix would silently leave commits unauthored
    # anywhere outside that prefix.
    programs.git.includes = [ { path = identityPath; } ];
  })

  (lib.mkIf (!hasSecret) {
    # Not a hard failure: a machine can legitimately be set up before its
    # secrets are, and refusing to build would leave no way to install the very
    # tooling (`agenix`, the vault client) needed to create them. git itself
    # supplies the hard stop — with no user.email it refuses to commit.
    home.activation.gitIdentityMissing = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      warnEcho "no secrets/git-identity.age in this checkout — git has no identity and will refuse to commit."
      warnEcho "Create it with: nix run github:ryantm/agenix -- -e git-identity.age   (run from secrets/,"
      warnEcho "after replacing the placeholder recipient key in secrets/secrets.nix with your own)."
    '';
  })
]
