# First-login bootstrap — replaces the retired installer copy at /etc/dots
# (git history): clones the dots repo from Codeberg into
# ~/Dokumente/gitlab/personal/dots, flips its `origin` to SSH so later
# push/pull ride the vault SSH key (nix/home/bitwarden.nix dots-keys), then
# restores the machine-specific install answers (settings.nix, facter.json)
# stashed by installer-tui at /var/lib/dots, so rebuilds/autoUpgrade keep
# the real hostname/user/hardware report instead of the committed
# placeholders. The local path keeps its legacy "gitlab" segment — it's just
# a folder name now; the repo itself lives on codeberg.org/dasmatus/dots.
{ pkgs, ... }:

let
  # Anonymous-HTTPS for the first-login clone: the repo is public, so no
  # key material exists yet on a fresh machine. dots-keys flips origin to
  # sshUrl below once the vault SSH key is available.
  repoUrl = "https://codeberg.org/dasmatus/dots";
  sshUrl = "ssh://git@codeberg.org/dasmatus/dots";
  repoRel = "Dokumente/gitlab/personal/dots";

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
    # unlocks rbw. `set-url` only records the URL — no connection is
    # attempted here, so this is safe before the SSH key exists.
    ${pkgs.git}/bin/git -C "$dest" remote set-url origin "${sshUrl}"

    for f in settings.nix facter.json; do
      if [ -f "/var/lib/dots/$f" ]; then
        cp "/var/lib/dots/$f" "$dest/nix/$f"
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
    };
    Install.WantedBy = [ "default.target" ];
  };
}
