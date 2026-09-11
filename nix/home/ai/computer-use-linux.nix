# Home-manager module for the computer-use-linux desktop-control MCP server
# + CLI (github.com/agent-sh/computer-use-linux). The prebuilt release binary
# is packaged in ./computer-use-linux-pkg.nix (autoPatchelf'd to Nix-store
# glibc). Enabling this module installs the CLI on PATH and registers it as
# a stdio MCP server in every harness present in this dots config: Claude
# Code (programs.claude-code.mcpServers) and Codex
# (programs.codex.settings.mcp_servers). To wire a new harness, add another
# `config.programs.<harness>...` assignment below; the build is shared.
#
# Registration is the *wiring* only. Actually driving the desktop needs
# system services: ydotoold (input injection), the AT-SPI session bus
# (accessibility tree), xdg-desktop-portal (screenshots), and a udev rule
# giving the `input` group access to /dev/uinput. Those are NixOS system
# modules and live outside home-manager; run `computer-use-linux doctor` (or
# `doctor | jq .readiness`) to see what's missing on this box.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.computer-use-linux;

  # Single shared build of the prebuilt binary; the PATH entry and both
  # harness registrations reference this one store path.
  defaultPackage = pkgs.callPackage ./computer-use-linux-pkg.nix { };

  # The stdio MCP server is `computer-use-linux mcp`; both harnesses spawn it
  # identically (JSON-RPC over stdio, rmcp 2024-11-05).
  mcpArgs = [ "mcp" ];
in
{
  options.programs.computer-use-linux = {
    enable = lib.mkEnableOption "the computer-use-linux desktop-control MCP server and CLI, registered in every harness present in this config";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      defaultText = lib.literalExpression "pkgs.callPackage ./computer-use-linux-pkg.nix {}";
      description = ''
        The computer-use-linux derivation to install on PATH and register
        as an MCP server. Defaults to the prebuilt v0.4.1 release binary
        wrapped with autoPatchelfHook; override to build from source or pin
        a different version.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # CLI on PATH so `computer-use-linux doctor|setup|screenshot|...` are
    # usable directly. Registrations below use the absolute store path so
    # harnesses don't depend on PATH at spawn time.
    home.packages = [ cfg.package ];

    # Claude Code: programs.claude-code.mcpServers, written to ~/.claude.json.
    programs.claude-code.mcpServers.computer-use-linux = {
      type = "stdio";
      command = "${cfg.package}/bin/computer-use-linux";
      args = mcpArgs;
    };

    # OpenAI Codex CLI: programs.codex.settings.mcp_servers, written to
    # ~/.codex/config.toml. Merges with the searxng entry declared in codex.nix.
    programs.codex.settings.mcp_servers.computer-use-linux = {
      command = "${cfg.package}/bin/computer-use-linux";
      args = mcpArgs;
    };
  };
}
