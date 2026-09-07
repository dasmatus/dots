# Portable home-manager profile — the half of this repo's home config that
# depends on nothing but a Linux user account. It is what
# `homeConfigurations` (flake/home.nix) installs on a non-NixOS host, and it
# is imported unchanged by nix/home/default.nix so the NixOS build sees the
# identical set.
#
# The split line is *runtime coupling*, not module cleanliness. Nothing in
# nix/home reads `osConfig` — the whole tree already takes its inputs through
# specialArgs (`dots`, `settings`) rather than the system config — so every
# module here evaluates standalone. What the session half needs and this half
# does not is a machine built to run it: a Hyprland seat for the compositor
# and shell, and nix/modules/system/sandbox-host.nix's microvm host for the
# `dots-sandbox run` wrappers to launch into. Both are NixOS-only, and a
# wrapper whose sandbox host is absent fails at app-launch time rather than at
# eval, which is exactly the failure worth keeping off a foreign host.
#
# See nix/home/profiles/session.nix for that other half.
{
  config,
  lib,
  pkgs,
  dots,
  ...
}:
{
  imports = [
    ./../apps/kitty.nix
    ./../shell/zellij.nix
    ./../shell/fastfetch.nix
    ./../shell/fish.nix
    ./../shell/git.nix
    # The git identity that git.nix deliberately does not set. Imported here
    # rather than from each entry point so the two builds cannot drift into
    # one having an identity and the other not. Requires agenix's
    # home-manager module, which flake/home.nix and
    # nix/modules/system/users.nix each supply on their side.
    ./../secrets/identity.nix
    ./../ai/claude.nix
    ./../ai/codex.nix
    ./../ai/computer-use-linux.nix
    ./../ai/edupage-mcp.nix
    ./../ai/claude-desktop.nix
    ./../apps/nixvim.nix
    ./../apps/brave.nix
    ./../apps/junction.nix
    ./../apps/librewolf.nix
    ./../apps/settings-menu.nix
    ./../apps/bitwarden.nix
    ./../apps/zed.nix
    ./../base/dokumente.nix
    ./../base/dots-repo.nix
    ./../base/pkgs.nix
    ./../base/flatpaks.nix
    ./../base/gnome-extensions.nix
    ./../base/gnome-backgrounds.nix
    ./../proton/proton.nix
    ./../proton/proton-drive.nix
    ./../proton/proton-calendar.nix
    ./../proton/proton-setup.nix
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

  # The Haskell toolchain (haskell-language-server, ghc, stack, cabal-install,
  # hlint, fourmolu) used to be listed right here. It is declared in
  # flake/languages.nix now and installed by nix/home/base/pkgs.nix, which
  # this profile already imports — so the packages this profile puts in the
  # user's PATH are unchanged, and the editor-parity guarantee (Neovim's
  # nixvim lsp.servers.hls and Zed's `haskell` extension both finding the
  # identical binaries by bare name) holds exactly as before. It moved
  # because `ghc` and `stack` were also listed in nix/home/base/pkgs.nix, so
  # two files were declaring one toolchain, and a third — flake/devenv.nix —
  # was declaring the Rust one separately for the dev shell. All three notes
  # that mattered survive in flake/languages.nix: why ghcup is not an option
  # on NixOS, why the plain (not multi-GHC-override) HLS build is the one to
  # install, and what to do for a stack project on an older LTS.
  home.packages = with pkgs; [
    brightnessctl
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
