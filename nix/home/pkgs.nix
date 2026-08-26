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
  # The AppImage's own contents, unpacked. `wrapType2` uses this internally to
  # build the FHS root but discards everything outside the entrypoint, so the
  # desktop entry and icon it ships are otherwise thrown away — see
  # extraInstallCommands below.
  havenoSrc = pkgs.fetchurl {
    url = "https://github.com/retoaccess1/haveno-reto/releases/download/v1.8.0-reto/haveno-v1.8.0-linux-x86_64.AppImage";
    hash = "sha256-znLY75hNv2C6HMlxoB+65e0UfJvHK7opVl0pEYmhbUw=";
  };
  havenoContents = pkgs.appimageTools.extract {
    pname = "haveno";
    version = "1.8.0-reto";
    src = havenoSrc;
  };

  # Haveno ships no nixpkgs package; wrap the release AppImage (type 2).
  # The sha256 is cross-checked against the release's 1.8.0-reto.hashes
  # file, exactly like the retired flatpak bundle pin was.
  haveno = pkgs.appimageTools.wrapType2 {
    pname = "haveno";
    version = "1.8.0-reto";
    src = havenoSrc;

    # `wrapType2` on its own installs a binary and nothing else — its output
    # is exactly bin/haveno — so Haveno was invisible to anything that finds
    # applications by scanning share/applications: the app grid, xdg-open,
    # and beamenu's `apps` provider alike. Lifting the AppImage's own entry
    # and icon out fixes all three at once, which is why this is a packaging
    # fix rather than a launcher entry.
    #
    # The shipped Exec is
    #   Exec=sh -c "PATH=\"\$HOME/.local/bin:\$PATH\"; bin/Haveno %u"
    # — a path relative to the AppImage root, which means nothing once the
    # entry is read from the profile. The whole line is replaced rather than
    # patched piecewise, since none of it survives: the wrapper on PATH
    # already sets up the FHS environment that prelude was standing in for.
    #
    # `Icon=exchange.haveno.Haveno` is a bare name, so the icon goes to
    # hicolor where a theme lookup will find it. Both copies are unconditional
    # on purpose: if a version bump stops shipping either file, this should
    # fail the build rather than quietly produce an entry that cannot launch
    # or an app with no icon.
    extraInstallCommands = ''
      install -Dm444 ${havenoContents}/exchange.haveno.Haveno.desktop \
        "$out/share/applications/exchange.haveno.Haveno.desktop"
      sed -i 's|^Exec=.*|Exec=haveno %u|' \
        "$out/share/applications/exchange.haveno.Haveno.desktop"
      install -Dm444 ${havenoContents}/exchange.haveno.Haveno.svg \
        "$out/share/icons/hicolor/scalable/apps/exchange.haveno.Haveno.svg"
    '';
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
      rustc
      clippy
      cargo-expand
      rust-analyzer
      cargo
      clang
      # clangd, clang-format and clang-tidy. Kept next to clang so the two
      # majors move together; a clangd ahead of the driver parses flags the
      # driver never emits. This is also what puts clangd on PATH for the
      # clangd-lsp plugin in nix/home/claude.nix, which spawns it by bare name.
      clang-tools
      stack
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
  # ── Launcher entries for the packages above ────────────────────────────
  #
  # Two kinds of gap are closed here, and they need different answers.
  #
  # Eleven of these packages ship no `.desktop` file at all (om, magick, the
  # rust and haskell and c toolchains, scrot), so beamenu's `apps` provider —
  # which reads share/applications and nothing else — cannot see them. Their
  # entries are the `toolchain` plugin below.
  #
  # The rest do ship desktop entries and already launch. What a launcher adds
  # for those is not another way to start them, it is reaching *into* them
  # through the interface they already expose: fwupd's CLI, Pika's on-disk
  # config, mpv's IPC socket. Only surfaces verified present on this machine
  # are wired; the notes say what was rejected and why, so the next person
  # does not re-litigate it.
  #
  # Every command here is parameterless, hence every plugin here is ambient:
  # a keyworded provider is handed the query with its prefix stripped, but an
  # ambient one is handed the whole root query, so a `{query}` command in an
  # ambient plugin would receive whatever the user typed to *find* the row.
  # The two that do take an argument (`rs`, `mpv`) are keyworded for exactly
  # that reason.

  # Pika Backup's own window answers "did it run?" only after it opens and
  # mounts. The same answer is already sitting in two JSON files it writes,
  # so the launcher can give it in a keystroke. Reading them found both
  # repositories two months stale, which is the whole argument for the row.
  #
  # `start-backup` over its D-Bus GActions is deliberately absent: it kicks
  # off a real borg run against removable media, and the marshalling for it
  # is the one part of that interface this has not verified.

  # The eleven packages with no desktop entry. A version readout is a thin
  # thing on its own, which is why these are grouped one row per language
  # rather than one row per binary: "what is my Rust toolchain" is a question
  # someone actually asks, "what version is cargo-expand" is not.
  #
  # `exec` is execvp'd directly by the canvas — no shell — so anything with a
  # `;` or a pipe goes through `bash -lc`, the same form nix/home/claude.nix
  # uses. The pane renders stderr as well as stdout, so a tool that reports
  # its version on the wrong stream still shows up.

  # Keyworded, because unlike everything above it consumes what follows it.
  # `rs E0382` renders the long-form explanation in the pane — the one piece
  # of the Rust toolchain that is genuinely launcher-shaped.

  # Also keyworded, and the one entry here that beats its desktop file
  # outright: `umpv` appends to the playlist of the player that is already
  # running instead of starting a rival process, and mpv.desktop cannot.
  # yt-dlp is on the wrapped mpv's PATH, so a pasted stream URL resolves.
  # A cold start also creates the IPC socket the two actions talk to.

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
