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
  lib,
  dots,
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
      obsidian
      omnix
      # flathub tracked the fresh branch; plain `libreoffice` = still/LTS
      libreoffice-still
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
      ghc
    ])
    ++ [ haveno ]
    # Newelle's only purpose here is the ollama cloud chat front-end (the
    # dconf custom_command below), so gate the package on the same
    # dots.ai.ollama toggle — with ollama off there's no backend to talk to
    # and Newelle would dead-launch with broken LLM settings.
    ++ lib.optional dots.ai.ollama pkgs.newelle;

  # Newelle → ollama cloud model: the custom_command LLM handler feeds the
  # chat history ({0}, shell-quoted JSON) to `ollama run kimi-k3:cloud`, so
  # answers come from the ollama.com cloud model (requires `ollama signin` +
  # `ollama pull kimi-k3:cloud`) — no per-key API billing. The instruction
  # and JSON are merged into one stdin prompt via `printf '%s\n%s\n'`
  # (unlike `echo`, printf won't mangle JSON `\n` escapes under /bin/sh);
  # `ollama run` reads piped stdin as the prompt, generates once, and
  # streams stdout, matching streaming = true. welcome-screen-shown skips
  # the first-run provider wizard; suggestion = "" disables the extra
  # per-message suggestion invocations (they'd burn ollama credits).
  # NB: home-manager rewrites llm-settings wholesale on switch — handler
  # tweaks made in the app UI don't survive a rebuild.
  #
  # Gated on dots.ai.ollama: the command needs the ollama client + cloud
  # account, so with ollama off Newelle keeps its upstream LLM defaults. No
  # longer touches claude-code, so the old finalPackage-eval guard is gone.
  dconf.settings."io/github/qwersyk/Newelle" = lib.mkIf dots.ai.ollama {
    language-model = "custom_command";
    welcome-screen-shown = true;
    llm-settings = builtins.toJSON {
      custom_command = {
        streaming = true;
        command = "printf '%s\\n%s\\n' 'stdin is the chat history as a JSON list of objects with User and Message fields. Answer the last User message. Output only the reply text, no preamble.' {0} | ${lib.getExe pkgs.ollama} run kimi-k3:cloud";
        suggestion = "";
      };
    };
  };
}
