# The dev shell for hacking on this repo's Rust crates (installer-tui,
# settings-global, dots-sandbox, dots-memory-*), as a devenv module.
#
# This replaces the hand-rolled `pkgs.mkShell` that used to live in
# flake/devshell.nix. What the move buys, concretely:
#   - the `languages.*` modules (flake/languages.nix) supply
#     cargo/rustc/rustfmt/clippy AND set RUST_SRC_PATH themselves, so
#     rust-analyzer resolves std without the manual binding the old shell
#     carried.
#   - `scripts` become real executables on PATH, discoverable via
#     `devenv info`, instead of fish functions that only existed inside an
#     interactive shell.
#   - `git-hooks` wires the same fmt/clippy gates CI runs, at commit time.
# It is still exposed as `devShells.default`, so `nix develop` and direnv's
# `use flake` keep working unchanged; devenv is the implementation, not a new
# entry point.
#
# None of these crates need webkit / gtk (the retired Tauri shell did), so that
# stack is deliberately absent. pkg-config is present, but only because
# devenv's own top-level and its `languages.c` module install it — nothing
# here asks for it.
#
# The interactive shell is fish, not bash, loading a reproducible rebuild of
# the host's fish config (nix/home/shell/fish.nix) so the dev shell feels like
# the machine: cat/ls/cd aliases, fish_greeting + fastfetch, zoxide (cd = z)
# and starship. Dropped from the host config on purpose:
#   - zellij auto-start: would wrap the dev shell in a multiplexer, which is
#     noise for `cargo` output; fish itself is the win over bash.
#   - the `claude`/`codex` aliases: they call the host `ollama launch` service
#     wrapper, which is neither reproducible nor dev-relevant.
{ pkgs, lib, ... }:
let
  # devenv needs to know the checkout root: it puts `.devenv/` state there and
  # installs the git hooks below into that repo. It normally discovers this
  # from the environment, which pure flake evaluation does not provide — so
  # under `nix flake check` (and any plain `nix develop`) the module system
  # aborts on devenv's own assertion, "devenv was not able to determine the
  # current directory".
  #
  # Upstream's answer is `nix develop --no-pure-eval`, and that stays the
  # documented way to ENTER this shell — `builtins.getEnv` returns the real
  # directory there, so the value below is correct and the hooks install where
  # they belong.
  #
  # The fallback exists for the other caller: `nix flake check` evaluates every
  # devShell, always purely, and has no interest in entering this one. In that
  # evaluation getEnv yields "" and this substitutes a placeholder, which is
  # enough to satisfy the assertion and let the shell's DERIVATION be checked.
  # A shell built from that evaluation would write its state to a path that
  # does not exist — which is exactly right for a shell nobody enters, and is
  # why the placeholder is an obviously-bogus name rather than something like
  # "." that might half-work and quietly scatter state.
  devenvRoot = builtins.getEnv "PWD";

  fishInit = pkgs.writeText "devshell-fish-init.fish" ''
    set -g fish_greeting
    fastfetch

    alias cat 'bat --paging=never'
    alias ls  'eza -lhi --git --icons always'
    alias cd  z

    ${lib.getExe pkgs.zoxide} init fish | source
    ${lib.getExe pkgs.starship} init fish | source
  '';
in
{
  devenv.root = if devenvRoot != "" then devenvRoot else "/devenv-root-unavailable-in-pure-eval";

  # The toolchains — Rust, C/C++ and Haskell — come from flake/languages.nix,
  # the single devenv module nix/home/base/pkgs.nix also installs into the user
  # profile. The Rust half of it replaces what the old mkShell listed by hand
  # (cargo, rustc, rustfmt, clippy plus RUST_SRC_PATH); the other two are here
  # because the profile and the dev shell now share one declaration, not
  # because these crates need a Haskell compiler.
  imports = [ ./languages.nix ];

  # The binaries the rebuilt fish config above calls back into at runtime (the
  # aliases, and the zoxide/starship init functions).
  packages = [
    pkgs.fish
    pkgs.bat
    pkgs.eza
    pkgs.zoxide
    pkgs.fastfetch
    pkgs.starship
  ];

  # Was a fish function in the old shell, so it existed only after the exec
  # below and only interactively. As a devenv script it is an ordinary
  # executable: `nix develop -c claude-dev …` works, and so does calling it
  # from another script.
  scripts.claude-dev.exec = ''
    exec claude --dangerously-skip-permissions --append-system-prompt \
      "Always write tests, benchmarks, and documentation for any code you produce. When scripting is needed, prefer Python, TypeScript, or another scripting language over Bash — only use Bash as a last resort. When your task involves inspecting, testing, or automating a web application, use Playwright rather than curl or manual HTTP calls. Always use Bun instead of Node.js for running scripts, installing packages, and executing JavaScript or TypeScript. When writing TypeScript, use @types/bun for type definitions instead of @types/node. Escalate with run0, not sudo — run0 goes through systemd and polkit instead of a setuid binary, and is passwordless for wheel on this machine. sudo-rs still works as a fallback if run0 is unavailable. When you need to ask the user a question or present options to choose from, always use the AskUserQuestion tool to display a dialog — never write out options as text and ask the user to type their choice." \
      "$@"
  '';

  # The same gates CI runs (.forgejo/workflows/ci.yml), moved to commit time so
  # a `cargo fmt` miss is caught before it is pushed rather than after. Scoped
  # to the Rust tree: `rust/` is where these tools apply, and running clippy
  # over a commit that only touches Nix or QML would be pure latency.
  git-hooks.hooks = {
    rustfmt.enable = true;
    clippy.enable = true;
    # nixfmt-rfc-style is what `formatter` in flake.nix uses (pkgs.nixfmt-tree
    # wraps it), so the hook and `nix fmt` cannot disagree.
    nixfmt-rfc-style.enable = true;
  };

  # Switch to fish only for an interactive `nix develop`, detected by the bash
  # `i` flag in $-. In command mode (`nix develop -c <cmd>`, where $- has no
  # `i`) fall through so nix runs the given command under bash as usual
  # instead of being hijacked by the exec.
  #
  # `-N` (--no-config) makes fish ignore ~/.config/fish (the home-manager
  # symlink) so only the rebuilt config above is loaded; `-C` sources it
  # before going interactive.
  enterShell = ''
    case $- in
      *i*) exec ${lib.getExe pkgs.fish} -i -N -C "source ${fishInit}" ;;
    esac
  '';
}
