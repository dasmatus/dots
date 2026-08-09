# Rewrite of files/fish (deleted — see git history). Changes vs the original:
#   - the tty1 `exec startx` block is gone: GDM (nix/modules/desktop.nix)
#     owns session startup now, and startx is X11-only
#   - fastfetch replaces neofetch (removed from nixpkgs; fastfetch.nix owns
#     the config)
#   - starship init comes from programs.starship
#   - linuxbrew/bun/dotnet/Antigravity PATH cruft dropped (host-specific,
#     none of it exists on NixOS), along with conf.d/rustup.fish and the
#     vendored completions/bun.fish (neither tool is declared here)
#   - fish_variables dropped: its only content was BROWSER=brave-browser-stable,
#     a stale pre-migration value (Brave is back via brave.nix, but LibreWolf
#     stays the main browser); home.sessionVariables.BROWSER is the native
#     replacement if one is ever wanted
#   - functions/claude-dev.fish is ported verbatim below
{ settings, ... }:
{
  programs.zoxide = {
    enable = true;
    enableFishIntegration = true;
  };
  programs.fish = {
    enable = true;

    interactiveShellInit = ''
      set -g fish_greeting
      fastfetch
    '';

    shellAliases = {
      cat = "bat --paging=never";
      ls = "eza -lhi --git --icons always";
      cd = "z";
      claude =
        if settings.aiClaude && settings.aiOllama then
          "ollama launch claude"
        else
          "echo 'claude and ollama not enabled'";
      codex =
        if settings.aiCodex && settings.aiOllama then
          "ollama launch codex -- --dangerously-bypass-approvals-and-sandbox"
        else
          "echo 'codex and ollama not enabled'";
    };

    functions.claude-dev = ''
      set -l system_prompt "Always write tests, benchmarks, and documentation for any code you produce. When scripting is needed, prefer Python, TypeScript, or another scripting language over Bash — only use Bash as a last resort. When your task involves inspecting, testing, or automating a web application, use Playwright rather than curl or manual HTTP calls. Always use Bun instead of Node.js for running scripts, installing packages, and executing JavaScript or TypeScript. When writing TypeScript, use @types/bun for type definitions instead of @types/node. sudo is passwordless on this machine. When you need to ask the user a question or present options to choose from, always use the AskUserQuestion tool to display a dialog — never write out options as text and ask the user to type their choice."
      claude --dangerously-skip-permissions --append-system-prompt $system_prompt $argv
    '';
  };
}
