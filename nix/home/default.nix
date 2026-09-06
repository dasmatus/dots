# home-manager profile aggregator — fully native modules; the raw files/
# dotfile tree is gone (git history). Every former dotfile is either a native
# module imported below (kitty.nix, zellij.nix, fastfetch.nix, fish.nix,
# claude.nix, hyprland.nix, quickshell/, nixvim.nix,
# librewolf.nix, dots-repo.nix) or was deliberately dropped (BetterDiscord —
# Vesktop covers it; gtk-2.0 filechooser state). GUI apps that used to be
# flatpaks live in pkgs.nix with their configs. The only generated
# raw text left is gtk-3.0/bookmarks (needs the real home directory
# interpolated).
# The X11-era stack (i3, polybar, picom, libinput-gestures, swaybg wallpaper
# exec, swayidle/swaylock, redshift) has been fully replaced by the Wayland
# modules imported below.
# The desktop shell is quickshell/: one QML tree where waybar, dunst, eww,
# rofi and beamenu used to be five programs with five theme paths.
{
  config,
  lib,
  pkgs,
  dots,
  ...
}:
{
  imports = [
    ./apps/kitty.nix
    ./shell/zellij.nix
    ./shell/fastfetch.nix
    ./shell/fish.nix
    ./ai/claude.nix
    ./ai/codex.nix
    ./ai/computer-use-linux.nix
    ./ai/edupage-mcp.nix
    ./apps/nixvim.nix
    ./base/dokumente.nix
    ./base/dots-repo.nix
    ./apps/brave.nix
    ./apps/junction.nix
    ./desktop/hyprland.nix
    ./desktop/session
    ./desktop/quickshell
    ./ai/claude-desktop.nix
    ./apps/librewolf.nix
    ./apps/settings-menu.nix
    ./shell/git.nix
    ./apps/bitwarden.nix
    ./proton/proton.nix
    ./proton/proton-drive.nix
    ./proton/proton-calendar.nix
    ./proton/proton-setup.nix
    ./base/pkgs.nix
    ./apps/zed.nix
    ./sandbox/machined.nix
    ./sandbox/wrap.nix
    ./sandbox/triage.nix
  ];
  home.stateVersion = "26.05";
  programs.home-manager.enable = true;

  # computer-use-linux MCP server + CLI, registered into every harness
  # present here (Claude Code + Codex). See nix/home/ai/computer-use-linux.nix.
  # Gated on at least one harness being enabled: the module's whole purpose is
  # to register an MCP server into a harness, so with both dots.ai.claude and
  # dots.ai.codex off it has nothing to serve and would only install a dead
  # CLI on PATH. (The per-harness mcpServers/mcp_servers assignments inside
  # the module are harmless when the parent harness is disabled — they're
  # silently dropped — but there's no point enabling the server at all then.)
  programs.computer-use-linux.enable = dots.ai.claude || dots.ai.codex;
  dconf.enable = true;
  dconf.settings."org/gnome/desktop/interface".color-scheme = "prefer-dark";
  dconf.settings = {
    "org/gnome/desktop/interface" = {
      accent-color = "red";
    };
    # Traffic-light order on the left — completes the GTK theme's macos
    # tweak (gtk.theme below); Brave's caption buttons read this key too.
    "org/gnome/desktop/wm/preferences" = {
      button-layout = "close,minimize,maximize:appmenu";
    };
    "org/gnome/desktop/input-sources" = {
      xkb-options = [ "ctrl:esc" ];
    };
  };
  qt = {
    enable = true;
    platformTheme.name = "qtct";
    style.name = "kvantum";
  };

  xdg.configFile = {
    "gtk-3.0/bookmarks".text = ''
      file://${config.home.homeDirectory}/Dokumente/gitlab
      file://${config.home.homeDirectory}/Dokumente/github
      file://${config.home.homeDirectory}/Dokumente/schule
      file://${config.home.homeDirectory}/Dokumente/blog
    '';

    # The gtk3/gtk4 modules would otherwise manage these two as read-only
    # symlinks into the store, same as gtk-3.0/bookmarks above. Quickshell's
    # own Gtk.qml (nix/home/desktop/quickshell/qml/wallpaper/Gtk.qml) needs to edit
    # gtk-icon-theme-name in place at wallpaper-pick time, and a write
    # through that symlink fails outright (EROFS) rather than reaching
    # anything — see that file's own header for the write(2)-level reason.
    # Disabling just these two paths here does not stop home-manager from
    # computing their rendered .text/.source (the gtk3/gtk4 modules still
    # compute both regardless of `enable`; only the symlink itself is
    # skipped) — the activation script below reuses that same source to
    # seed a real file the first time one is missing.
    "gtk-3.0/settings.ini".enable = false;
    "gtk-4.0/settings.ini".enable = false;
  };

  # Seeds gtk-3.0/settings.ini and gtk-4.0/settings.ini as plain, writable
  # files the first time either is missing, using the exact rendered
  # content the (now file-disabled, see xdg.configFile above) gtk3/gtk4
  # modules already compute from gtk.theme/gtk.iconTheme. "Missing" covers
  # both a first-ever switch and the one right after this option changed.
  #
  # Ordered after home-manager's own "linkGeneration" activation script
  # (modules/files.nix, cleanOldGen then linkNewGen), not merely after
  # writeBoundary: entryAfter [ "writeBoundary" ] alone would only make
  # this a *sibling* of linkGeneration, with no ordering between the two,
  # since linkGeneration is itself declared as entryAfter [ "writeBoundary" ]
  # (same file). Home-manager's dag gives siblings no guaranteed order. If
  # this seed ran first on the switch that turns management off, the old
  # generation's symlink would still be sitting at $dst3/$dst4 — `[ -f ]`
  # follows it to the still-existing store target, reads true, and skips
  # the install — and then linkGeneration's cleanOldGen would delete that
  # same symlink afterwards because the path stopped being managed,
  # leaving no settings.ini at all and GTK falling back to built-in
  # defaults. entryAfter [ "linkGeneration" ] (the same node home-manager's
  # own onFilesChange uses to run after the link/cleanup phase) guarantees
  # cleanOldGen has already removed that stale symlink before this runs,
  # so the guard below sees an honest picture of what's left at the path.
  #
  # What the -f guard actually finds there, post-reorder:
  #   - Nothing (the common case right after this feature lands): a stale
  #     home-manager symlink existed and cleanOldGen just removed it. -f
  #     is false, the seed installs the rendered content.
  #   - A plain regular file: either an earlier seed's output, or Gtk.qml's
  #     own tint already written (Gtk.qml replaces the destination with mv,
  #     which leaves a regular file, never a symlink). -f is true, the seed
  #     is skipped — required, see "seed-once" below, since this is the
  #     expected steady state after the very first wallpaper pick.
  #   - A dangling symlink unrelated to home-manager (foreign tool, manual
  #     edit, target since removed): -f is false because -f follows the
  #     link and finds nothing at the far end, so the seed runs. `install
  #     -Dm644` unlinks the dangling entry and creates a real file in its
  #     place rather than trying to write through the broken link (checked
  #     against a scratch dangling symlink before relying on it here), so
  #     no extra rm is needed for this case.
  #
  # Deliberately seed-once, not reasserted on every switch: Gtk.qml owns
  # this file from here on, rewriting gtk-icon-theme-name in place on every
  # wallpaper pick, and a switch that kept clobbering that back to the
  # declared default would erase a user's current tint every time they
  # rebuild for an unrelated reason. That is different from the dconf key
  # below (config.gtk.iconTheme's own dconf.settings write), which a switch
  # does still reset — dconf has no "someone else owns this file" file-
  # ownership mechanism to hand it off through, and the schema gap that
  # makes it inert on this machine is a separate, already-documented story.
  home.activation.gtkSettingsIniSeed = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    dst3=${lib.escapeShellArg "${config.xdg.configHome}/gtk-3.0/settings.ini"}
    dst4=${lib.escapeShellArg "${config.xdg.configHome}/gtk-4.0/settings.ini"}
    [ -f "$dst3" ] || run install -Dm644 ${config.xdg.configFile."gtk-3.0/settings.ini".source} "$dst3"
    [ -f "$dst4" ] || run install -Dm644 ${config.xdg.configFile."gtk-4.0/settings.ini".source} "$dst4"
  '';

  home.packages = with pkgs; [
    brightnessctl
    # Haskell toolchain — shared by Neovim (nixvim lsp.servers.hls) and Zed
    # (the `haskell` extension finds these on PATH) plus the shell. Installed
    # here rather than per-editor so all three see the identical binaries —
    # the editor-parity guarantee. haskell-language-server is the multi-GHC
    # WRAPPER; the default build ships the variant for the default ghc
    # (9.10.3 == Stackage LTS 24), so a stack project on LTS 24 works out of
    # the box. `stack` must be on PATH for the wrapper to probe the project's
    # GHC from stack.yaml. ghcup is NOT installable on NixOS (nixpkgs throws:
    # no compatible bindist), so this pure-nixpkgs route is the only
    # reproducible one. NB the multi-GHC override (supportedGhcVersions=[96 98
    # 910]) would cover older LTS too, but those per-GHC HLS builds are not in
    # the binary cache and build from source — too heavy for a frequently-
    # rebuilt dots repo + CI. For a stack project on an older LTS, add a
    # per-project flake devshell with the matching haskell.compiler.ghcXX +
    # haskell.packages.ghcXX.haskell-language-server; both editors pick it up
    # via `nix develop`/direnv. Versioned ghc attrs (ghc98/ghc910) are not
    # top-level — the default `ghc` (9.10.3) is what we install.
    haskell-language-server
    ghc
    stack
    cabal-install
    hlint
    fourmolu
  ];

  gtk = {
    enable = true;
    # adw-gtk3 (the libadwaita look for GTK3 apps), dark variant. The previous
    # tokyonight-gtk-theme was dropped from nixpkgs — it depended on
    # gtk-engine-murrine, which was removed upstream as unmaintained GTK 2.
    # The macOS traffic-light window buttons (close/min/max on the left) come
    # from the dconf `button-layout` key above, not from a theme-side tweak —
    # so nothing is lost dropping the tokyonight macos tweak variant.
    theme = {
      name = "adw-gtk3-dark";
      package = pkgs.adw-gtk3;
    };
    # Since stateVersion 26.05 gtk4 no longer inherits the shared gtk.theme
    # default; without this no gtk-4.0/gtk.css @import is emitted and
    # libadwaita apps silently stay Adwaita.
    gtk4.theme = config.gtk.theme;
    # The old TUI's accent tint (@imports of a runtime-state gtkN.css that
    # its tint.rs regenerated on every wallpaper change) is gone with the
    # crate — Picker.qml and Rotation.qml only carry the icon
    # theme (Icons.qml) and the bar's own accent (tint/current.json) so far.
    # GTK stays plain adw-gtk3-dark, not pointed at a file nothing writes
    # anymore, until a later plan ports the GTK/Kvantum/rofi tint writers too.
    # Papirus-Dark is the variant whose icons are all light-toned, which is
    # what suits adw-gtk3-dark above and the org/gnome/desktop/interface
    # color-scheme = "prefer-dark" dconf key. This value is not what the
    # desktop runs most of the time, though: the shell's wallpaper pipeline
    # points the running icon theme at a generated Papirus-Tint. It does
    # that two ways — Icons.qml's dconf write of
    # org/gnome/desktop/interface/icon-theme, and Gtk.qml's own write of
    # gtk-icon-theme-name straight into gtk-3.0/settings.ini and
    # gtk-4.0/settings.ini. Only the second one currently does anything on
    # this machine: gsettings-desktop-schemas is not installed, so the dconf
    # key has no schema to be resolved through and GTK never sees it,
    # falling back to settings.ini instead — the dconf write is kept anyway
    # because it costs nothing and becomes the live mechanism the day that
    # package is installed. What this iconTheme attribute actually governs,
    # then, is the settings.ini fallback: xdg.configFile below turns off
    # home-manager's normal management of those same two settings.ini
    # paths, and a one-time activation seed renders this value into them as
    # a plain file, so Gtk.qml has somewhere writable to edit afterward
    # rather than a read-only store symlink. Unlike the dconf key, that seed
    # is not re-applied on every `home-manager switch` — see the activation
    # script below for why — so this value in practice only ever surfaces
    # before the very first wallpaper pick on a given machine, not "until
    # the next pick" after every rebuild. This attribute also puts the
    # Papirus package in the profile, which is what makes Papirus-Tint's
    # Inherits=Papirus-Dark,Papirus,hicolor resolvable at all — so it is a
    # hard dependency of the tint theme, not a cosmetic default.
    iconTheme = {
      name = "Papirus-Dark";
      package = pkgs.papirus-icon-theme;
    };
  };
  programs.starship.enable = true;
}
