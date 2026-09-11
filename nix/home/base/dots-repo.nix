# First-login bootstrap: replaces the retired installer copy at /etc/dots
# (git history): clones the dots repo from Codeberg into
# ~/Dokumente/gitlab/personal/dots, flips its `origin` to SSH so later
# push/pull ride the vault SSH key (nix/home/apps/bitwarden.nix dots-keys), then
# symlinks the machine-specific install answers (settings.nix, facter.json)
# stashed by installer-tui at the configured state dir (options.dots.paths,
# default /var/lib/dots) into the clone, so rebuilds/autoUpgrade read the
# real hostname/user/hardware report instead of the committed placeholders.
# These are COPIES, not symlinks: a symlink here made an absolute path
# outside the flake an evaluation-time dependency, which pure eval refuses
# to follow. See the header of nix/data/settings.nix for the four things
# that broke. A copy is an ordinary in-tree file, so eval stays pure.
# The local path keeps its legacy "gitlab" segment. It's just a folder name
# now; the repo itself lives on codeberg.org/dasmatus/dots.
{
  pkgs,
  lib,
  dots,
  ...
}:

let
  # Anonymous-HTTPS for the first-login clone: the repo is public, so no
  # key material exists yet on a fresh machine. dots-keys flips origin to
  # sshUrl below once the vault SSH key is available.
  repoUrl = "https://codeberg.org/dasmatus/dots";
  sshUrl = "ssh://git@codeberg.org/dasmatus/dots";
  repoRel = "Dokumente/codeberg/personal/dots";
  # Configured relatives of the install-answer stash (options.dots.paths):
  # <stateDir>/<file> is copied over nix/data/<file> in the clone. Unlike the
  # symlink this replaces, a later edit in the stash is NOT picked up
  # automatically. Re-run this unit (or re-copy by hand) after e.g. a fresh
  # nixos-facter run. That is the deliberate trade for keeping eval pure.
  stateDir = dots.paths.stateDir;
  answerFiles = [
    dots.paths.settingsFile
    dots.paths.facterFile
  ];

  script = pkgs.writeShellScript "dots-clone" ''
    set -euo pipefail

    dest="$HOME/${repoRel}"
    mkdir -p "$(dirname "$dest")"

    cache_dir="$HOME/.cache"
    mkdir -p "$cache_dir"
    tmp="$(mktemp -d "$cache_dir/dots-clone.XXXXXX")"
    trap 'rm -rf "$tmp"' EXIT

    ${pkgs.git}/bin/git clone "${repoUrl}" "$tmp/repo"

    # An empty leftover dest is cleared so the rename below can land; a
    # non-empty one makes `mv -T` fail loudly instead of nesting the clone
    # inside it.
    rmdir "$dest" 2> /dev/null || true
    mv -T "$tmp/repo" "$dest"

    # The clone's default `origin` is the anonymous-HTTPS URL above. Flip
    # it to SSH so day-to-day push/pull use the vault key once dots-keys
    # unlocks rbw. `set-url` only records the URL. No connection is
    # attempted here, so this is safe before the SSH key exists.
    ${pkgs.git}/bin/git -C "$dest" remote set-url origin "${sshUrl}"

    # Restore the machine-specific install answers by copying them out of the
    # persisted stash (impermanence.nix bind-mounts /persist over
    # ${stateDir}) over the committed in-tree defaults. `install -m` both
    # replaces the destination and normalizes the mode, so the stash's
    # 0600-root facter.json lands readable by the eval that follows. That's
    # the permission failure that used to break `nix run .#iso-full` when
    # that path was reached through a symlink. `git update-index --skip-worktree`
    # then hides the resulting content change so the clone's tree stays clean
    # for autoUpgrade's git operations; `2>/dev/null || true` guards a
    # not-yet-indexed path.
    for f in ${lib.concatStringsSep " " answerFiles}; do
      if [ -e "${stateDir}/$f" ]; then
        install -m 0644 "${stateDir}/$f" "$dest/nix/data/$f"
        ${pkgs.git}/bin/git -C "$dest" update-index --skip-worktree "nix/data/$f" 2> /dev/null || true
      fi
    done
  '';
in
{
  systemd.user.services.dots-clone = {
    Unit = {
      Description = "Clone tokyonight-dots and restore installer-written settings";
      ConditionPathExists = "!%h/${repoRel}/.git";
      StartLimitIntervalSec = 600;
      StartLimitBurst = 5;
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${script}";
      # Network may not be up yet at first login; retry a handful of times.
      Restart = "on-failure";
      RestartSec = 30;

      # Only these two: this unit clones the repo into $HOME and chowns
      # flake.lock, so ProtectSystem/ProtectHome need a precise
      # ReadWritePaths naming the clone path. Real work is tracked
      # separately, not added here (see research-units.md §4 item 6).
      # These two are safe regardless: neither git nor the restore script
      # has a legitimate reason to gain privilege via a setuid/setgid
      # exec, or to create a new setuid/setgid file.
      NoNewPrivileges = true;
      RestrictSUIDSGID = true;
    };
    Install.WantedBy = [ "default.target" ];
  };
}
