# Ex-flatpak GUI apps as native Home Manager packages (nix/modules/flatpak.nix
# is gone — git history). GNOME core apps went back to services.gnome.core-apps
# (nix/modules/desktop.nix); LibreWolf is managed by programs.librewolf
# (librewolf.nix). Attrs verified against the pinned nixpkgs rev.
#
# Dropped in the migration:
#   - com.github.tchx84.Flatseal — flatpak permission manager, obsolete
#   - org.virt_manager.virt-manager — already native system-wide
#     (programs.virt-manager, nix/modules/virtualisation.nix)
#   - io.github.mpobaschnig.Vaults — removed from nixpkgs 2026-07 over the
#     fuse2 deprecation; gocryptfs/cryfs CLIs remain available if needed
#   - com.ktechpit.torrhunt, io.github.justinrdonnelly.bouncer,
#     io.gitlab.persiangolf.voicegen — Flathub-only, not in nixpkgs; would
#     need out-of-tree packaging to keep
{
  pkgs,
  config,
  lib,
  ...
}:
let
  # Haveno ships no nixpkgs package; wrap the release AppImage (type 2).
  # The sha256 is cross-checked against the release's 1.8.0-reto.hashes
  # file, exactly like the retired flatpak bundle pin was.
  haveno = pkgs.appimageTools.wrapType2 {
    pname = "haveno";
    version = "1.8.0-reto";
    src = pkgs.fetchurl {
      url = "https://github.com/retoaccess1/haveno-reto/releases/download/v1.8.0-reto/haveno-v1.8.0-linux-x86_64.AppImage";
      hash = "sha256-znLY75hNv2C6HMlxoB+65e0UfJvHK7opVl0pEYmhbUw=";
    };
    # jpackage bundle: private JRE + JavaFX natives dlopen GTK/X11/audio libs
    extraPkgs =
      p: with p; [
        glib
        gtk3
        nss
        nspr
        at-spi2-core
        at-spi2-atk
        cairo
        pango
        gdk-pixbuf
        mesa
        libxkbcommon
        wayland
        alsa-lib
        cups
        fontconfig
        freetype
        zlib
        libx11
        libxext
        libxrender
        libxtst
        libxi
      ];
  };
in
{
  home.packages =
    (with pkgs; [
      # GNOME-adjacent tools (ex flathub-verified)
      dconf-editor
      gnome-extension-manager
      gnome-firmware
      # apps (ex flathub-verified)
      vesktop
      carburetor
      mpv
      newelle
      obsidian
      # Stremio — the official `stremio-linux-shell` Rust+GTK4 client (the
      # old Qt5 `stremio` was dropped from nixpkgs 2026-02-11 over its
      # EOL Qt5 WebEngine). Unfree only via the bundled server.js — see the
      # allowUnfreePredicate entry in nix/modules/core.nix. Addons (e.g.
      # Eclipsia, manifest https://eclipsia.sudolocal.qzz.io/manifest.json)
      # are subscribed via Stremio's UI and persist in ~/.local/share, not here.
      stremio-linux-shell
      # flathub tracked the fresh branch; plain `libreoffice` = still/LTS
      libreoffice-fresh
      # plain `onionshare` is the CLI-only build
      onionshare-gui
      # torbrowser-launcher was never packaged; nixpkgs builds the browser
      tor-browser
      keepassxc
      simplex-chat-desktop
      transmission_4-gtk
      bleachbit
      pika-backup
      prismlauncher
      signal-desktop
      refine
      scrot
      imagemagick
    ])
    ++ [ haveno ];

  # Newelle → Claude Code: the custom_command LLM handler pipes the chat
  # history ({0}, shell-quoted JSON) to `claude -p`, so answers come from the
  # Max subscription instead of a separate API key. welcome-screen-shown
  # skips the first-run provider wizard; suggestion = "" disables the extra
  # per-message suggestion invocations (they'd burn plan usage).
  # NB: home-manager rewrites llm-settings wholesale on switch — handler
  # tweaks made in the app UI don't survive a rebuild.
  #
  # Gated on programs.claude-code.enable (== dots.ai.claude): the HM
  # claude-code module only assigns `finalPackage` under `mkIf cfg.enable`,
  # so reading it here unconditionally trips "programs.claude-code.finalPackage
  # was accessed but has no value defined" the moment the installer AI toggle
  # is flipped off. When claude is disabled there is no `claude -p` to pipe
  # to, so Newelle keeps its upstream LLM defaults rather than pointing at a
  # missing binary.
  dconf.settings."io/github/qwersyk/Newelle" = lib.mkIf config.programs.claude-code.enable {
    language-model = "custom_command";
    welcome-screen-shown = true;
    llm-settings = builtins.toJSON {
      custom_command = {
        streaming = true;
        command = "echo {0} | ${lib.getExe config.programs.claude-code.finalPackage} -p 'stdin is the chat history as a JSON list of objects with User and Message fields. Answer the last User message. Output only the reply text, no preamble.'";
        suggestion = "";
      };
    };
  };
}
