# packages.${system} — the dots-installer Rust TUI, the in-flake aipage dists,
# Claude Desktop, the shell's QML tree and the two LiveISO images.
{
  pkgs,
  aipagePackages,
  pkgsClaude,
  inputs,
  ...
}:
self: {
  # The home-manager CLI, taken from THIS flake's home-manager input rather
  # than from nixpkgs. `nix run .#home-switch` (flake/apps.nix) drives it to
  # apply homeConfigurations on a non-NixOS host, where there is usually no
  # `home-manager` on PATH at all — and where a nixpkgs-provided one could be
  # a different version than the config in flake/home.nix was evaluated
  # against, which is exactly the mismatch that produces activation errors
  # about unknown options.
  hm-cli = inputs.home-manager.packages.${pkgs.stdenv.hostPlatform.system}.home-manager;
  # Claude Desktop for Linux (beta) — repackaged from Anthropic's .deb, which
  # is the only distribution channel upstream offers. See nix/packages/claude-desktop.nix.
  claude-desktop = pkgsClaude.callPackage ../nix/packages/claude-desktop.nix { };
  # Betterbird, a Thunderbird fork, for its StatusNotifierItem tray icon.
  # nixpkgs dropped its own betterbird for want of a maintainer, but upstream
  # still ships a linux-x86_64 release tarball every ESR cycle, so this
  # repackages that the way nixpkgs' own thunderbird-bin repackages Mozilla's.
  # See nix/packages/betterbird.nix.
  betterbird = pkgs.callPackage ../nix/packages/betterbird.nix { };

  # ChromaLeon, the wallpaper-accent GNOME Shell extension. Built here rather
  # than taken from pkgs.gnomeExtensions because that generator fetches a
  # prebuilt e.g.o zip with no rev or patch seam, and this one carries a patch.
  # See nix/packages/chromaleon.nix.
  chromaleon = pkgs.callPackage ../nix/packages/chromaleon.nix { };
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
  # quickshell-config — the shell's QML tree with Palette.qml generated from
  # nix/data/palette.json. nix/home/desktop/quickshell/default.nix builds the same thing
  # with the real state directory; this one exists so `nix run .#nix-lint` has
  # something to point qmllint at, and so a broken palette fails the flake
  # rather than the next login. The stateHome here only reaches a FileView
  # path string, so a placeholder is enough to lint against.
  quickshell-config = import ../nix/home/desktop/quickshell/tree.nix {
    inherit pkgs;
    stateHome = "/var/empty/.local/state";
    cacheHome = "/var/empty/.cache";
    # The real cheatsheet, not an empty stub: linting a tree whose data files
    # are all empty would not exercise the delegates that read them.
    keybinds = import ../nix/home/desktop/keybinds.nix;
  };

  # AIPage dists (codeberg.org/dasmatus/aipage), built from a pinned fetchGit
  # source — see nix/packages/aipage.nix. Consumed by the LibreWolf and Brave home
  # modules via specialArgs, and embedded in both ISOs so the installer
  # substitutes them from the ISO store (offline-capable).
  aipage-firefox = aipagePackages.firefox;
  aipage-chrome = aipagePackages.chrome;

  iso = self.nixosConfigurations.live-iso.config.system.build.isoImage;
  iso-full = self.nixosConfigurations.live-iso-full.config.system.build.isoImage;

  # Exposed so `nix run .#nix-lint` can force the primer generator to run and
  # trip its build-time asserts, not because anyone installs this directly.
  # See nix/packages/dots-skills.nix.
  dots-skills-primer = (pkgs.callPackage ../nix/packages/dots-skills.nix { }).primer;

  # dots-secreport — salvaged out of dots-sandbox (see git history) when
  # the bespoke per-app sandbox was retired for Flatpak + AppArmor:
  # report.rs (the privacy/hardware-security dashboard collector behind
  # qml/settings/pages/security.qml) and triage.rs (the AppArmor denial
  # classifier, given the CLI subcommand it never had) had nothing to do
  # with launching apps and outlived the crate they were born in.
  #
  # doCheck stays false, matching every other in-tree crate here
  # (installer-tui, settings-global): the real `cargo test` run lives in
  # `nix run .#nix-lint`, which is where its fmt/clippy/test line now runs
  # too. Unlike the old dots-sandbox crate's own doCheck note (see git
  # history), this crate has no forward-looking reason to stay that way (no
  # real namespace/process spawn the Nix build sandbox would refuse) — it is
  # simply consistency with the rest of the file rather than a real
  # restriction.
  dots-secreport = pkgs.rustPlatform.buildRustPackage {
    pname = "dots-secreport";
    version = "0.1.0";
    src = ../rust/dots-secreport;
    cargoLock.lockFile = ../rust/dots-secreport/Cargo.lock;
    doCheck = false;
    meta.mainProgram = "dots-secreport";
  };
}
