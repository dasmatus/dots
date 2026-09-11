# Zed (https://zed.dev), the GUI code editor that replaces VSCodium
# (nix/home/vscode.nix, removed). Wired to launch on SUPER+Z from
# nix/home/desktop/hyprland.nix, and surfaced in the keybind cheatsheet
# (nix/home/desktop/keybinds.nix).
#
# HM module namespace is `programs.zed-editor` (NOT `programs.zed`, there is
# no `programs.zed` at the locked home-manager rev 39411a8e). The nixpkgs
# package is `zed-editor` and its binary is `zeditor` (meta.mainProgram), which
# is what the Hyprland SUPER+Z bind execs. `defaultEditor` is deliberately left
# false: nixvim (nix/home/apps/nixvim.nix) already owns EDITOR/VISUAL as the TUI
# default, and enabling zed-editor.defaultEditor would collide on the same
# home.sessionVariables. Zed is the GUI editor only, launched via the wm bind.
#
# Feature parity with the prior VSCodium extension set + the nixvim LSP bar:
#   - enkia.tokyo-night  → `tokyo-night` Zed extension + theme "Tokyo Night"
#                          (the plain variant == Neovim tokyonight "night")
#   - vscode-neovim      → Zed's BUILT-IN `vim_mode` (no extension)
#   - continue.continue  → Zed's NATIVE Agent panel (Anthropic + ollama); no
#                          Continue extension, since native covers it
#   - fill-labs.dependi  → `deps-language-server` Zed extension (Cargo.toml
#                          version inlays + outdated/yanked diagnostics)
#   - rust-analyzer      → Zed built-in LSP (not an extension)
# Plus nixvim LSP parity: clangd, nil, lua-language-server, ansible, pyright,
# ruff, typescript-language-server, gopls, bash-language-server,
# yaml-language-server, json-language-server, vscode-css-language-server,
# vscode-html-language-server, marksman, texlab, docker-language-server,
# dockerfile-language-server. taplo (TOML) and vimls have no Zed equivalent
# today. See the gaps noted inline.
{
  config,
  pkgs,
  lib,
  dots,
  ...
}:
{
  # Zed is a FLATPAK now (dev.zed.Zed, declared in
  # nix/home/base/flatpaks.nix). `package = null` is the home-manager
  # firefox/zed-family idiom for "manage the configuration, install nothing":
  # the module keeps rendering settings.json / keymap.json exactly as before,
  # and the editor itself comes from Flathub.
  #
  # The rendered files still land in ~/.config/zed, which is NOT where a
  # sandboxed Zed looks. See the `.var/app` symlink at the bottom of this
  # file for how the two are joined, and nix/home/base/flatpaks.nix for the
  # filesystem grant that makes the symlink resolve inside the sandbox.
  programs.zed-editor = {
    enable = true;
    package = null;

    # Extensions are NOT installed by Nix. The module emits
    # `auto_install_extensions = { <id> = true; }` into settings.json, so Zed
    # fetches them from its marketplace on startup (needs network). ids are the
    # short marketplace names (https://zed.dev/extensions/<id>), verified
    # against the live marketplace. Each LSP-bearing extension only *registers*
    # its language-server id + tree-sitter grammar; the server binary itself
    # comes from extraPackages below (or Zed core for built-ins).
    extensions = [
      # theme + UI
      "tokyo-night" # Tokyo Night / Storm / Light color themes
      "material-icon-theme" # file-tree/tab icons (closest to nvim-web-devicons)

      # language servers + grammars not in Zed core
      "nix" # nil + nixd + Nix tree-sitter
      "lua" # lua-language-server + Lua grammar
      "ansible" # ansible-language-server + YAML/Jinja grammars
      "html" # vscode-html-language-server
      "marksman" # marksman (Markdown LSP)
      "latex" # texlab + LaTeX/BibTeX grammars
      "docker-compose" # docker-language-server (compose + Dockerfile)
      "dockerfile" # dockerfile-language-server
      "haskell" # hls (Haskell language server) + Haskell/Cabal grammars

      # Rust crate dependency review (replaces VSCodium's Dependi)
      "deps-language-server"
    ];

    # Written to ~/.config/zed/settings.json (jq-merged with manual edits by
    # default via mutableUserSettings=true, so in-app setting tweaks survive a
    # rebuild, and static Nix values win on conflict). The `// lib.optionalAttrs`
    # tail (not `lib.mkIf` inside the literal) gates the ollama block: mkIf is a
    # definition-level merge marker the module system only unwraps at a
    # definition's top value, so nesting it inside this freeform JSON attrset
    # would serialize as {_type,condition,content} garbage. optionalAttrs is a
    # plain function, so the key is cleanly absent when dots.ai.ollama is off.
    userSettings = {
      # --- Neovim parity: theme, icons, font, vim mode ---
      # Tokyo Night plain variant == Neovim tokyonight style "night". Object
      # form so it tracks the dark/light system preference (the host is dark).
      theme = {
        mode = "dark";
        dark = "Tokyo Night";
        light = "Tokyo Night Light";
      };
      # Zed's UI icons are SVG-based (no Nerd-Font-glyph port of
      # nvim-web-devicons exists); Material Icon Theme is the closest file-type
      # coverage. The buffer font below still renders Nerd Font glyphs in-buffer.
      icon_theme = "Material Icon Theme";
      # Match nixvim guifont "Lilex Nerd Font:style=Bold:h14" (Lilex Nerd Font
      # is installed system-wide via nix/modules/desktop/desktop.nix nerd-fonts.lilex).
      buffer_font_family = "Lilex Nerd Font";
      buffer_font_size = 14;
      buffer_font_weight = 700;
      terminal.font_family = "Lilex Nerd Font";
      # Built-in vim mode replaces VSCodium's vscode-neovim extension.
      vim_mode = true;

      # Privacy: Zed phones home by default; the rest of the dots stack is
      # telemetry-light, so opt out of both metrics and diagnostic reports.
      telemetry = {
        metrics = false;
        diagnostics = false;
      };

      # Format on save globally; per-language entries below refine the
      # formatter choice. "on" == always; "modifications_if_available" would
      # only touch changed lines.
      format_on_save = "on";

      # Per-server LSP overrides (the Zed equivalent of nixvim's lsp.servers
      # options / lspconfig setup). `initialization_options` are sent at LSP
      # initialize (need a restart); `settings` are runtime-adjustable.
      lsp = {
        # rust-analyzer is built-in and enabled by default for Rust; just nudge
        # it to run clippy (parity with the repo's rust toolchain lint stance).
        rust-analyzer.initialization_options.check.command = "clippy";
        # nil reads its formatter from initialization_options; point it at
        # nixfmt so `formatter = "language_server"` below formats Nix via nil.
        nil.initialization_options.formatting.command = [ "nixfmt" ];
        # Haskell: the `haskell` extension registers the `hls` server and reads
        # lsp.hls.binary, falling back to haskell-language-server-wrapper on
        # PATH. Point it at the wrapper explicitly (it probes stack.yaml /
        # cabal.project and dispatches to haskell-language-server-<ghc>), and
        # the wrapper + fourmolu come from home.packages (nix/home/default.nix),
        # shared with Neovim so both editors dispatch identically.
        hls.binary = {
          path = "haskell-language-server-wrapper";
          arguments = [ "lsp" ];
        };
      };

      # Per-language config. `language_servers` is an array of ids: a bare id
      # enables a server, `!id` disables it, and the sentinel `"..."` (always
      # last) keeps Zed's other defaults for that language. Only languages where
      # we change the default server set or set a formatter are listed.
      # Built-in-default languages (Rust, C, C++, Go, Bash, YAML, JSON, CSS, JS,
      # TS) keep Zed's defaults unless a formatter is set here.
      languages = {
        # Nix: nil (parity with nixvim nil_ls), nixd disabled, nixfmt via nil.
        Nix = {
          language_servers = [
            "nil"
            "!nixd"
            "..."
          ];
          formatter = "language_server";
          format_on_save = "on";
        };

        # Python: pyright + ruff (parity with nixvim pyright/ruff). Zed's
        # default is basedpyright; explicitly select pyright and disable the
        # alternatives so the server set matches Neovim. ruff formats/fixes.
        Python = {
          language_servers = [
            "pyright"
            "ruff"
            "!basedpyright"
            "!ty"
            "!pyrefly"
            "!pylsp"
            "..."
          ];
          formatter = {
            language_server.name = "ruff";
          };
          format_on_save = "on";
        };

        # Rust: rust-analyzer (built-in) runs rustfmt internally.
        Rust = {
          formatter = "language_server";
          format_on_save = "on";
        };

        # C / C++: clangd (built-in) for LSP; clang-format for formatting.
        # {buffer_path} is interpolated to the file's path so clang-format
        # picks up the nearest .clang-format config.
        C = {
          formatter = {
            external = {
              command = "clang-format";
              arguments = [ "--assume-filename={buffer_path}" ];
            };
          };
          format_on_save = "on";
        };
        "C++" = {
          formatter = {
            external = {
              command = "clang-format";
              arguments = [ "--assume-filename={buffer_path}" ];
            };
          };
          format_on_save = "on";
        };

        # Lua: lua-language-server (from the `lua` extension) + stylua.
        Lua = {
          language_servers = [
            "lua-language-server"
            "..."
          ];
          formatter = {
            external = {
              command = "stylua";
              arguments = [
                "--stdin-filepath"
                "{buffer_path}"
                "-"
              ];
            };
          };
          format_on_save = "on";
        };

        # Haskell: hls (from the `haskell` extension) + fourmolu formatter.
        # fourmolu reads the buffer on stdin; --stdin-input-path lets it infer
        # the module name from {buffer_path} (the absolute path Zed substitutes).
        # hls needs the project buildable for full diagnostics. Run
        # `stack build` / `cabal build` once first so it can resolve the graph.
        Haskell = {
          language_servers = [
            "hls"
            "..."
          ];
          formatter = {
            external = {
              command = "fourmolu";
              arguments = [
                "--stdin-input-path"
                "{buffer_path}"
              ];
            };
          };
          format_on_save = "on";
        };

        # Ansible: ansible-language-server (from the `ansible` extension).
        Ansible.language_servers = [
          "ansible"
          "..."
        ];

        # HTML: vscode-html-language-server (from the `html` extension) +
        # prettier (Zed's built-in prettier runner, no external binary needed).
        HTML = {
          language_servers = [
            "vscode-html-language-server"
            "..."
          ];
          formatter = "prettier";
          format_on_save = "on";
        };

        # Markdown: marksman (from the `marksman` extension) + prettier.
        Markdown = {
          language_servers = [
            "marksman"
            "..."
          ];
          formatter = "prettier";
          format_on_save = "on";
        };

        # LaTeX: texlab (from the `latex` extension). Zed's default.json already
        # pre-sets this once the extension is installed; set it explicitly so
        # it's on regardless of default churn.
        LaTeX = {
          language_servers = [
            "texlab"
            "..."
          ];
          formatter = "language_server";
          format_on_save = "on";
        };

        # Docker: dockerfile-language-server for Dockerfile,
        # docker-language-server for compose. Both come from extensions.
        Dockerfile.language_servers = [
          "dockerfile-language-server"
          "..."
        ];
        "Docker Compose".language_servers = [
          "docker-language-server"
          "..."
        ];

        # Web languages: Zed's built-in servers stay (typescript-language-
        # server, json-language-server, vscode-css-language-server, bash-
        # language-server, yaml-language-server); only the formatter is set to
        # the built-in prettier runner for parity with nixvim's prettier.
        JSON = {
          formatter = "prettier";
          format_on_save = "on";
        };
        JSONC = {
          formatter = "prettier";
          format_on_save = "on";
        };
        YAML = {
          formatter = "prettier";
          format_on_save = "on";
        };
        CSS = {
          formatter = "prettier";
          format_on_save = "on";
        };
        SCSS = {
          formatter = "prettier";
          format_on_save = "on";
        };
        JavaScript = {
          formatter = "prettier";
          format_on_save = "on";
        };
        TypeScript = {
          formatter = "prettier";
          format_on_save = "on";
        };
      };

    }
    // lib.optionalAttrs dots.ai.ollama {
      # Native Agent panel (replaces VSCodium's Continue extension).
      # Anthropic Claude is built-in, and the API key is read from
      # ANTHROPIC_API_KEY or set via the UI (stored in the system keychain,
      # never in settings.json), so no static config is needed for it.
      # Ollama (local) only needs an api_url and is gated on the same
      # dots.ai.ollama toggle the rest of the repo uses (e.g. Newelle in
      # pkgs.nix), and with ollama off there's no backend, so the whole
      # language_models key is absent rather than left empty.
      language_models.ollama.api_url = "http://localhost:11434";
    };
  };

  # The LSP servers and formatters that used to be
  # `programs.zed-editor.extraPackages`. That option wraps the zed binary in a
  # symlinkJoin to put them on Zed's PATH, and it asserts a non-null
  # `package`, so it is unavailable the moment Zed stops being installed by
  # Nix. They move to the profile instead.
  #
  # Be clear about what that does and does not buy. On PATH they serve the
  # shell and Neovim (nixvim.nix pins the same set, which is the "works in
  # both editors" guarantee). Zed itself is sandboxed now, and a flatpak does
  # NOT inherit the profile PATH, so reaching these from inside it needs both
  # the /nix/store grant in nix/home/base/flatpaks.nix and Zed being told
  # where they are. Treat editor-side language support in the flatpak as
  # something to verify per language server, not as something this list
  # guarantees the way it used to.
  #
  # clang-tools (clang-format) and rustfmt are NOT here any more, and their
  # absence is not a regression: both are inside the language toolchains
  # nix/home/base/pkgs.nix installs from flake/languages.nix, so they are on
  # PATH exactly as before. Listing them a second time would in fact break the
  # build, since home-manager's profile is a buildEnv that refuses collisions,
  # and
  # a bare `pkgs.rustfmt` beside the toolchain's own is two store paths
  # claiming bin/rustfmt.
  #
  # What stays is the Nix and Lua tooling, which is not part of any toolchain
  # declared there: devenv's `languages.nix` installs nixd, and this config
  # deliberately disables nixd in favour of nil (see the `lsp` block above).
  home.packages = with pkgs; [
    nil # Nix LSP (the `nix` extension registers it; binary lives here)
    nixfmt # Nix formatter (nil's formatting.command + external fallback)
    stylua # Lua formatter
  ];

  # Join home-manager's ~/.config/zed to the per-app root the flatpak reads as
  # $XDG_CONFIG_HOME. mkOutOfStoreSymlink (not a plain store symlink) because
  # the target must stay a live path into $HOME that Zed can also write to,
  # since a store symlink would be read-only and Zed rewrites settings.json itself
  # when a setting is changed in the UI.
  home.file.".var/app/dev.zed.Zed/config/zed".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/.config/zed";
}
