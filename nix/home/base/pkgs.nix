# The packages that CANNOT be flatpaks, plus Haveno's AppImage wrapper.
#
# This file used to be the landing site of a flatpaks-to-nixpkgs migration —
# "ex-flatpak GUI apps as native Home Manager packages". That direction is
# reversed: every GUI app here is a Flathub ref again, declared in
# nix/home/base/flatpaks.nix, and this file keeps only what Flathub has no
# answer for. See that file's header for why (the portable profile targets a
# Fedora Atomic host where Flatpak is the delivery mechanism, and a flatpak
# brings its own sandbox on a host with no microvm host to launch into).
#
# What is left, and why each one stays:
#
#   - Command-line tools and language toolchains. Flatpak packages
#     applications with desktop entries, not `cargo` and `ghc`; a flatpak'd
#     compiler could not see the project it is asked to build. These are also
#     what nix/home/apps/{nixvim,zed}.nix and the AI harnesses expect to find
#     on PATH by bare name. The toolchains themselves are no longer LISTED
#     here — they come from flake/languages.nix, the one devenv module
#     `nix develop` builds its shell from; see `toolchains` below.
#   - networkmanagerapplet — a session tray daemon, not an app.
#   - haveno — no Flathub package exists (exchange.haveno.Haveno is 404,
#     checked against the Flathub API). Upstream ships a signed AppImage,
#     wrapped below.
#
# The three GUI exceptions that stay native for the same "no Flathub package"
# reason are documented where they live: kitty (nix/home/apps/kitty.nix),
# claude-desktop (nix/home/ai/claude-desktop.nix) and Haveno here.
{
  pkgs,
  lib,
  dots,
  inputs,
  ...
}:
let
  # The language toolchains, evaluated out of the SAME devenv module
  # flake/devenv.nix imports — see flake/languages.nix for what is in it and
  # why. `mkConfig` runs devenv's module system and stops there; it does not
  # build a shell, so nothing about `devenv.root`, the git hooks or
  # `enterShell` is involved, and none of that file's assertions are forced.
  #
  # `pkgs` is this evaluation's own instance (the system one on NixOS via
  # `useGlobalPkgs`, flake/home.nix's on a foreign host), not the flake's, so
  # the toolchains are built from the same nixpkgs as everything else in the
  # profile rather than a second instance that merely happens to agree.
  #
  # `config.packages` is devenv's public list of what the environment puts on
  # PATH — but it is not only OUR packages: devenv's own top-level adds
  # pkg-config unconditionally, and `processes` resolves a process manager
  # (process-compose) whether or not anything declares a process. Those belong
  # to `devenv up`, not to a user profile, so the baseline is evaluated once
  # with no modules and subtracted, leaving exactly what flake/languages.nix
  # contributed. Doing it by subtraction rather than by an exclusion list
  # means a future devenv that adds something else to its baseline does not
  # quietly grow the profile.
  #
  # (The baseline eval is module-system only — no derivations are built for it
  # — and `subtractLists` compares derivations by output path, so this is a
  # cheap set difference, not a rebuild.)
  toolchains = inputs.devenv.lib.mkConfig {
    inherit pkgs inputs;
    modules = [ ../../../flake/languages.nix ];
  };
  devenvBaseline = inputs.devenv.lib.mkConfig {
    inherit pkgs inputs;
    modules = [ ];
  };

  # One derivation rather than splicing `toolchains.packages` straight into
  # `home.packages`, for one concrete reason: devenv's language modules
  # deliberately list overlapping packages (clang-tools comes from both
  # `languages.c` and `languages.cplusplus`, clang from `cplusplus` and from
  # the Rust linker driver), which costs nothing on a shell's PATH but is a
  # hard error in home-manager's profile buildEnv, which does not ignore
  # collisions. devenv builds its own profile with `ignoreCollisions` for the
  # same reason; this is that, under a name that says where it came from.
  #
  # NB the join is how the profile is assembled, not a layer anything has to
  # know about: an editor or script looking for `clangd` still finds
  # ~/.nix-profile/bin/clangd exactly as before.
  languageToolchains = pkgs.buildEnv {
    name = "dots-language-toolchains";
    paths = lib.subtractLists devenvBaseline.packages toolchains.packages;
    ignoreCollisions = true;
  };
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
      # CLI tools. `omnix` and `scrot` have no desktop entry between them;
      # `magick` is called by scripts, not clicked.
      omnix
      scrot
      imagemagick
      # nix/home/desktop/session/actions.nix's nm-applet daemon has run at session
      # start since forever, but nothing in this repo ever packaged it, so
      # the network tray icon has silently never actually appeared.
      networkmanagerapplet

      # The Nerd Font this config's terminal and prompt already assume. It was
      # never installed: nix/home/apps/kitty.nix asks for `font_family LilexNF`
      # and nix/home/shell/fastfetch.nix's keys are Nerd Font private-use
      # glyphs, but no font package existed anywhere in the tree, so
      # `fc-list | grep -ci nerd` answered 0 and every one of those glyphs
      # rendered as tofu.
      #
      # This is what flake/home.nix's `fonts.fontconfig.enable` is FOR — that
      # option only points fontconfig at the home profile's share/fonts, and
      # on a foreign host with nothing in it there was nothing to find. On
      # NixOS the same package reaches fontconfig through
      # nix/modules/system/core.nix's `fonts.packages`, so it belongs in this
      # shared file rather than beside the enable.
      #
      # Only the one family, not the whole nerd-fonts set: nixpkgs split that
      # attribute up precisely so a profile does not carry ~3 GB to get one
      # typeface, and LilexNF is the only face this repo names.
      nerd-fonts.lilex
    ])
    ++ [
      # Rust, C/C++ and Haskell. This one entry is what the hand-written list
      # of ghc / rustc / clippy / cargo-expand / rust-analyzer / cargo /
      # clang / clang-tools / stack used to be, and it also absorbs the
      # separate Haskell list that lived in nix/home/profiles/portable.nix.
      # clang-tools is still inside it: a clangd ahead of the driver parses
      # flags the driver never emits, so the two majors move together, and
      # this is what puts clangd on PATH for the clangd-lsp plugin in
      # nix/home/ai/claude.nix, which spawns it by bare name.
      languageToolchains
      haveno
    ];
  # Newelle is a flatpak now (io.github.qwersyk.Newelle, gated on the same
  # dots.ai.ollama toggle in nix/home/base/flatpaks.nix). Its dconf settings
  # stay here, below, because dconf is host state rather than app state — a
  # flatpak reads the same dconf database through the settings portal, so the
  # keys land where the app looks for them either way.

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
  # `;` or a pipe goes through `bash -lc`, the same form nix/home/ai/claude.nix
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
