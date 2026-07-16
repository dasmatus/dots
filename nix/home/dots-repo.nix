# First-login bootstrap — replaces the retired installer copy at /etc/dots
# (git history): clones the tokyonight-dots repo into
# ~/Dokumente/gitlab/personal/dots, then restores the machine-specific
# install answers (settings.nix, facter.json) stashed by installer-tui at
# /var/lib/dots, so rebuilds/autoUpgrade keep the real hostname/user/hardware
# report instead of the committed placeholders.
{ pkgs, ... }:

let
  repoUrl = "https://gitlab.com/tentypekmatus/tokyonight-dots";
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
