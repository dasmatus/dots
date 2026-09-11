# Machine-specific install answers. Merged *over* nix/system/defaults.nix by
# flake/lib.nix, so anything absent here falls back to that file:
#   settings = (import ../nix/system/defaults.nix) // (import ../nix/data/settings.nix);
#
# This is a REAL, tracked, in-tree file and must stay one. It used to be a
# committed symlink to /var/lib/dots/settings.nix (the installer-written
# stash), which made the absolute path a hard *evaluation-time* dependency of
# every flake output touching nixosConfigurations. That cost: pure eval
# refused to follow it ("access to absolute path ... is forbidden in pure
# evaluation mode"), so `nix flake check` could not run on a bare checkout at
# all, `nix run .#iso` needed --impure, `iso-full` failed outright on the
# stash's 0600-root facter.json, and CI had to materialize a throwaway stub
# before any nix call. Keeping the answers in-tree removes all four.
#
# gitName/gitEmail are deliberately absent: the git identity moved to an
# agenix secret (secrets/secrets.nix, nix/home/secrets/identity.nix) so a
# public repo does not carry a real name and address, and so it never lands in
# the world-readable Nix store. rust/installer-tui still collects and writes
# them (config.rs::settings_nix). That is harmless, since nothing reads them
# now.
#
# rust/installer-tui writes these same keys (config.rs::settings_nix) into the
# stash at install time; nix/home/base/dots-repo.nix then COPIES the stash over
# this file in the clone (a copy, not a symlink, which is what keeps eval
# pure) and marks it --skip-worktree so the clone's tree stays clean.
{
  username = "matus";
  hostname = "secureblue";
  disks = [ "/dev/nvme0n1" ];
  swapSize = "32G";
  aiClaude = true;
  aiCodex = true;
  aiOllama = true;
}
