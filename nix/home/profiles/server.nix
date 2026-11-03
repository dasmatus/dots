# Server home-manager profile: the CLI-only half of this repo's home config,
# for VPSes and headless boxes. Companions to profiles/portable.nix (the
# foreign-desktop half, flake/home.nix's default) and profiles/session.nix
# (the desktop-session half — gnome/hyprland/sway by dots.desktop.environment,
# NixOS-only): same modules, minus everything that
# assumes a graphical session.
#
# The line here is the same *runtime coupling* rule the other two profiles
# state: what a server cannot run is not installed. Concretely dropped vs the
# portable profile:
#
#   - desktop/session + quickshell + the per-DE compositor modules (the
#     graphical answer to "what is on the screen" — a headless box has none)
#   - kitty, zed, brave, librewolf, junction, settings-menu, bitwarden
#     (GUI apps; `zed` and `bitwarden` double as CLI programs, but a server
#     edits with nixvim below and the vault-key workflow bitwarden.nix enables
#     (rbw, dots-keys) needs a desktop secret service to unlock against)
#   - flatpaks, gnome-extensions, gnome-backgrounds, the dconf/GTK/qt theme
#     stack (no compositor means no widget to theme)
#   - proton apps (proximity drive/calendar — desktop sync clients)
#   - computer-use-linux, edupage-mcp, triage-assist (MCP servers built around
#     a screen, a school portal and a desktop triage queue)
#   - dokumente (the Documents tree) and dots-repo's first-login bootstrap
#     unit: a server's checkout is placed by the deploy app that carries this
#     profile there — it clones the repo into $HOME before the first switch,
#     so the deferred clone service would only race it (dots-repo's
#     `ConditionPathExists = "!…/dots"` makes a full remote checkout look
#     work that needs doing, and the unit would then clone the committed
#     default settings.nix *over* a real one)
#
# Kept, deliberately unchanged: the shell stack (fish/zellij/fastfetch/git +
# the agenix git identity), nixvim as the editor, starship, the language
# toolchains (imported from nix/home/base/toolchains.nix), memory-limits (it
# defines `_module.args.wrapCapped`, which the AI-harness wrappers below
# consume, and its runtime checks degrade to plain exec on a box with no
# systemd user manager), and Claude Code + Codex + OpenCode as the CLI AI
# harnesses.
#
# The git credential helper in shell/git.nix is `libsecret`; on a headless
# box there is no secret service to ask. Nothing here reaches that code path
# in normal use — transport auth is SSH (see that file's header) — and when
# the helper is invoked (an HTTPS credential prompt), git treats a helper
# that answers nothing as "no credentials" and fails the fetch plainly, which
# is exactly what the transport would fail with anyway on a box that never
# made an HTTPS forge call.
{
  pkgs,
  ...
}:
{
  imports = [
    ./../shell/fish.nix
    ./../shell/zellij.nix
    ./../shell/fastfetch.nix
    ./../shell/git.nix
    # The git identity that git.nix deliberately does not set — same import
    # as the portable profile, so the agenix payload decrypts on a server with
    # zero per-host setup beyond the age key at the identity path. Requires
    # agenix's home-manager module: flake/home.nix supplies it for every
    # profile it builds.
    ./../secrets/identity.nix
    ./../apps/nixvim.nix
    ./../base/toolchains.nix
    # Supplies `_module.args.wrapCapped` for the AI modules below. Its own
    # drop-ins/slices are desktop-shaped but inert here; see the file's
    # wrapper for the on-box check that decides rather than assume.
    ./../base/memory-limits.nix
    ./../ai/claude.nix
    ./../ai/codex.nix
    ./../ai/opencode.nix
  ];

  home.stateVersion = "26.05";
  programs.home-manager.enable = true;
  programs.starship.enable = true;

  # fish.nix's aliases (cat → bat, ls → eza) name these; they are declared in
  # nix/modules/system/core.nix on a NixOS host, which a server profile has no
  # access to — so they are trimmed and put in the profile itself.
  home.packages = with pkgs; [
    bat
    eza
  ];
}
