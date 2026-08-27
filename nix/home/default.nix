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
  pkgs,
  dots,
  ...
}:
{
  imports = [
    ./kitty.nix
    ./zellij.nix
    ./fastfetch.nix
    ./fish.nix
    ./claude.nix
    ./codex.nix
    ./computer-use-linux.nix
    ./edupage-mcp.nix
    ./nixvim.nix
    ./dokumente.nix
    ./dots-repo.nix
    ./brave.nix
    ./junction.nix
    ./hyprland.nix
    ./quickshell
    ./claude-desktop.nix
    ./librewolf.nix
    ./settings-menu.nix
    ./git.nix
    ./bitwarden.nix
    ./proton.nix
    ./pkgs.nix
    ./zed.nix
  ];
  home.stateVersion = "26.05";
  programs.home-manager.enable = true;

  # computer-use-linux MCP server + CLI, registered into every harness
  # present here (Claude Code + Codex). See nix/home/computer-use-linux.nix.
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
  };

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
    iconTheme = {
      name = "MoreWaita";
      package = pkgs.morewaita-icon-theme;
    };
  };
  programs.starship.enable = true;
}
