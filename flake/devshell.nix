# devShells.${system} — the dev shell for hacking on the two Rust crates
# (installer-tui and wallpaper-tui): a plain Rust toolchain so
# `cargo fmt`/`cargo clippy`/`cargo test`/`cargo run` work locally without a
# system rust install. Both are pure TUIs with no native deps, so no
# pkg-config / webkit / gtk stack is needed here (the old Tauri dev shell
# carried it).
#
# The interactive shell is fish (not mkShell's default bash), loading a
# reproducible rebuild of the host's fish config (nix/home/fish.nix) so the
# dev shell feels like the machine: cat/ls/cd aliases, fish_greeting +
# fastfetch, zoxide (cd = z), starship prompt, and the claude-dev helper.
# Dropped from the host config on purpose:
#   - zellij auto-start: would wrap the dev shell in a multiplexer, which is
#     noise for `cargo` output; fish itself is the win over bash
#   - the `claude`/`codex` aliases: they call the host `ollama launch`
#     service wrapper, which is neither reproducible nor dev-relevant
# `--no-config` makes fish ignore ~/.config/fish (the home-manager symlink)
# so only the rebuilt config below is loaded; `--init-command` sources it
# before going interactive. The `case $- in *i*)` guard keeps
# `nix develop -c <cmd>` working under bash instead of being hijacked.
{
  pkgs,
  haskellPackages,
  abstracttui,
}:
let
  fishInit = pkgs.writeText "devshell-fish-init.fish" ''
    set -g fish_greeting
    fastfetch

    alias cat 'bat --paging=never'
    alias ls  'eza -lhi --git --icons always'
    alias cd  z

    ${pkgs.lib.getExe pkgs.zoxide} init fish | source
    ${pkgs.lib.getExe pkgs.starship} init fish | source

    function claude-dev
        set -l system_prompt "Always write tests, benchmarks, and documentation for any code you produce. When scripting is needed, prefer Python, TypeScript, or another scripting language over Bash — only use Bash as a last resort. When your task involves inspecting, testing, or automating a web application, use Playwright rather than curl or manual HTTP calls. Always use Bun instead of Node.js for running scripts, installing packages, and executing JavaScript or TypeScript. When writing TypeScript, use @types/bun for type definitions instead of @types/node. sudo is passwordless on this machine. When you need to ask the user a question or present options to choose from, always use the AskUserQuestion tool to display a dialog — never write out options as text and ask the user to type their choice."
        claude --dangerously-skip-permissions --append-system-prompt $system_prompt $argv
    end
  '';
in
{
  default = pkgs.mkShell {
    nativeBuildInputs = [
      pkgs.cargo
      pkgs.rustc
      pkgs.rustfmt
      pkgs.clippy
      # Fish dev-shell toolchain: the shell plus the binaries the rebuilt
      # config references (the aliases, and zoxide/starship init funcs that
      # call back into their binaries at runtime).
      pkgs.fish
      pkgs.bat
      pkgs.eza
      pkgs.zoxide
      pkgs.fastfetch
      pkgs.starship
    ];
    RUST_SRC_PATH = pkgs.rustPlatform.rustLibSrc;
    shellHook = ''
      # Switch to fish only for an interactive `nix develop`, detected by
      # the bash `i` flag in $-. In command mode (`nix develop -c <cmd>`,
      # where $- has no `i`) fall through so nix runs the given command
      # under bash as usual instead of being hijacked by exec.
      case $- in
        *i*) exec ${pkgs.lib.getExe pkgs.fish} -i -N -C "source ${fishInit}" ;;
      esac
    '';
  };

}
