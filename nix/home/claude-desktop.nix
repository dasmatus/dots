# Claude Desktop for Linux (beta). Chat, Cowork and Claude Code in one app.
#
# The derivation is nix/claude-desktop.nix, built at the flake level and handed
# in via extraSpecialArgs like settingsMenu. It repackages upstream's
# .deb because that is the only channel they publish: the documented install is
# an apt repository (https://code.claude.com/docs/en/desktop-linux), which has
# no NixOS analogue, so the package is pinned by digest and bumped by hand.
#
# The app does not self-update on Linux even when installed the documented way,
# so nothing is lost by pinning; see the bump recipe in nix/claude-desktop.nix.
{
  claudeDesktop,
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.claude-desktop;
in
{
  options.programs.claude-desktop = {
    enable = lib.mkEnableOption "the Claude desktop app" // {
      default = true;
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ claudeDesktop ];

    # The app stores its session in the Secret Service, which on this machine
    # is gnome-keyring (pulled in by the GNOME session; also what Proton Mail
    # Bridge uses, see proton.nix). Without one running, sign-in does not
    # persist across restarts.
    #
    # Sign-in itself is interactive and cannot be declared: launch it once and
    # log in with the claude.ai account.

    # Give the app the same skills the terminal CLI gets. It reads
    # ~/.claude/skills on none of its surfaces (see the passthru comment in
    # nix/claude-desktop.nix for why, and why no wrapper variable can change
    # that), so the only route in is its own local-plugin registry.
    #
    # An activation script rather than home.file, for two reasons. The plugin
    # directory has to be real: the loader resolves its realpath and refuses
    # anything landing outside the registry root, so a store symlink is
    # dropped with "Skipping plugin with invalid path". And the registry is
    # keyed by the signed-in account and org UUIDs, which are discovered by
    # globbing rather than spelled out — writing personal account identifiers
    # into a repo that gets published is not worth the two saved lines, and
    # globbing additionally survives signing in as a different account.
    #
    # Unverified where it matters: on a machine that has never installed a
    # desktop plugin, neither registry file exists, so the shape written below
    # is read off the loader rather than observed. If the app ignores the
    # entry, install any plugin once through its own UI, diff what it wrote,
    # and match it.
    home.activation.claudeDesktopSkills = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      # home-manager splices every activation entry into one bash script,
      # so `exit` here would abort the run before linkGeneration links
      # ~/.config. Skip the loop instead of leaving the script.
      sessions="$HOME/.config/Claude/local-agent-mode-sessions"
      if [ -d "$sessions" ]; then
        for org in "$sessions"/*/*/; do
          # skills-plugin/ is the cloud-synced skill cache, which nests the same
          # two UUIDs the other way round and is not a session root.
          case "$org" in *"/skills-plugin/"*) continue ;; esac
          [ -d "$org" ] || continue

          plugins="$org/cowork_plugins"
          reg="$plugins/installed_plugins.json"
          set="$org/cowork_settings.json"

          run mkdir -p "$plugins/dots-skills"
          run cp -r --no-preserve=mode ${claudeDesktop.skillsPlugin}/. "$plugins/dots-skills"/

          # Both registry files are the app's own mutable state — it rewrites
          # them whenever a plugin is installed or toggled — so they are merged
          # into rather than owned. A read-only store symlink here would make
          # the app's next write fail.
          [ -f "$reg" ] || echo '{"plugins":{}}' > "$reg"
          [ -f "$set" ] || echo '{}' > "$set"

          run ${lib.getExe pkgs.jq} \
            --arg p "$plugins/dots-skills" \
            '.plugins["dots-skills@local-desktop-app-uploads"] =
               [{ installPath: $p, scope: "user", installedAt: (now * 1000 | floor) }]' \
            "$reg" > "$reg.tmp" && run mv "$reg.tmp" "$reg"

          run ${lib.getExe pkgs.jq} \
            '.enabledPlugins["dots-skills@local-desktop-app-uploads"] = true' \
            "$set" > "$set.tmp" && run mv "$set.tmp" "$set"
        done
      fi
    '';
  };
}
