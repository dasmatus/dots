# packages.${system} — the dots-installer Rust TUI, the in-flake aipage dists,
# Claude Desktop, the shell's QML tree and the two LiveISO images.
{
  pkgs,
  aipagePackages,
  pkgsClaude,
  ...
}:
self: {
  # Claude Desktop for Linux (beta) — repackaged from Anthropic's .deb, which
  # is the only distribution channel upstream offers. See nix/claude-desktop.nix.
  claude-desktop = pkgsClaude.callPackage ../nix/claude-desktop.nix { };
  dots-installer = pkgs.rustPlatform.buildRustPackage {
    pname = "dots-installer";
    version = "0.1.0";
    src = ../rust/installer-tui;
    cargoLock.lockFile = ../rust/installer-tui/Cargo.lock;
  };
  settings = pkgs.rustPlatform.buildRustPackage {
    pname = "settings";
    version = "0.1.0";
    src = ../rust/settings-global;
    cargoLock.lockFile = ../rust/settings-global/Cargo.lock;
    # The crate is named global-settings, so `nix run .#settings` needs the
    # binary spelled out.
    meta.mainProgram = "global-settings";
  };
  # hyprmon — the declarative multi-monitor auto-detection daemon. Built at
  # the flake level for the same reason `settings` above is (cache key
  # sharing, `nix build .#hyprmon`); nix/home/hyprmon.nix wraps the store path
  # and wires the systemd user service.
  hyprmon = pkgs.rustPlatform.buildRustPackage {
    pname = "hyprmon";
    version = "0.1.0";
    src = ../rust/hyprmon;
    cargoLock.lockFile = ../rust/hyprmon/Cargo.lock;
    # The launcher entry's icon (nix/home/hyprmon.nix names it `hyprmon`,
    # unqualified). It ships here rather than as a home file because the
    # launcher resolves an `Icon=` name through the icon themes on
    # XDG_DATA_DIRS, and hicolor in the profile is what puts it there — the
    # same lookup the GNOME app grid makes. Named as a Nix path rather than a
    # relative one: cargoInstallHook does not run with the unpacked source as
    # its cwd.
    postInstall = ''
      install -Dm444 ${../rust/hyprmon/hyprmon.svg} \
        "$out/share/icons/hicolor/scalable/apps/hyprmon.svg"
    '';
    meta.mainProgram = "hyprmon";
  };
  # quickshell-config — the shell's QML tree with Palette.qml generated from
  # nix/palette.json. nix/home/quickshell/default.nix builds the same thing
  # with the real state directory; this one exists so `nix run .#nix-lint` has
  # something to point qmllint at, and so a broken palette fails the flake
  # rather than the next login. The stateHome here only reaches a FileView
  # path string, so a placeholder is enough to lint against.
  quickshell-config = import ../nix/home/quickshell/tree.nix {
    inherit pkgs;
    stateHome = "/var/empty/.local/state";
    # The real cheatsheet, not an empty stub: linting a tree whose data files
    # are all empty would not exercise the delegates that read them.
    keybinds = import ../nix/home/keybinds.nix;
  };

  # AIPage dists (codeberg.org/dasmatus/aipage), built from a pinned fetchGit
  # source — see nix/aipage.nix. Consumed by the LibreWolf and Brave home
  # modules via specialArgs, and embedded in both ISOs so the installer
  # substitutes them from the ISO store (offline-capable).
  aipage-firefox = aipagePackages.firefox;
  aipage-chrome = aipagePackages.chrome;
  iso = self.nixosConfigurations.live-iso.config.system.build.isoImage;
  iso-full = self.nixosConfigurations.live-iso-full.config.system.build.isoImage;
}
