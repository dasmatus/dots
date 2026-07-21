# Native port of nix/home/claude.nix to OpenAI Codex CLI. The shared
# infrastructure (the searxng-mcp stdio bridge, the ollama service) ports
# verbatim; the agent-specific settings are translated to Codex's config
# model — TOML written to ~/.codex/config.toml, AGENTS.md for global memory,
# and a Starlark rules file for the per-command allow-list (Claude's
# permissions.allow glob-list has no direct key equivalent here).
# Codex is Apache-2.0, so unlike claude-code it needs no unfree predicate
# in nix/modules/core.nix.
{ pkgs, lib, ... }:
let
  # Stdio MCP bridge to the local SearXNG instance (nix/modules/searxng.nix).
  # Identical to the one in claude.nix — a generic stdio MCP server, so Codex
  # consumes it the same way via settings.mcp_servers below. Claude Code's
  # built-in WebSearch has no Codex counterpart (Codex ships no built-in web
  # search), so "SearXNG as default" here means: expose it as an MCP tool and
  # steer towards it via the AGENTS.md context below. Python MCP SDK from
  # nixpkgs — no imperative npx fetch, and flake8 gates the script at build.
  # Results ride on searxng.nix's `search.formats = [... "json"]`.
  searxng-mcp =
    pkgs.writers.writePython3Bin "searxng-mcp"
      {
        libraries = [ pkgs.python3Packages.mcp ];
        flakeIgnore = [ "E501" ];
      }
      ''
        """Stdio MCP server exposing the local SearXNG instance as web_search."""
        import json
        import urllib.parse
        import urllib.request

        from mcp.server.fastmcp import FastMCP

        SEARXNG = "http://127.0.0.1:8888"

        mcp = FastMCP("searxng")


        @mcp.tool()
        def web_search(query: str, pageno: int = 1, time_range: str = "", categories: str = "") -> str:
            """Search the web through the local SearXNG metasearch instance.

            Prefer this tool for web searches. time_range narrows results to
            "day", "month" or "year" (empty = all time); categories is a
            comma-separated list of SearXNG categories such as general,
            images, news, it, science, files.
            """
            params = {"q": query, "format": "json", "pageno": str(pageno)}
            if time_range:
                params["time_range"] = time_range
            if categories:
                params["categories"] = categories
            req = urllib.request.Request(
                SEARXNG + "/search?" + urllib.parse.urlencode(params),
                headers={"User-Agent": "searxng-mcp"},
            )
            with urllib.request.urlopen(req, timeout=20) as resp:
                data = json.load(resp)
            lines = []
            answers = [a.get("answer", "") if isinstance(a, dict) else str(a) for a in data.get("answers", [])]
            if answers:
                lines.append("Answers: " + "; ".join(answers))
            for i, r in enumerate(data.get("results", [])[:12], 1):
                title = r.get("title", "")
                url = r.get("url", "")
                content = r.get("content", "")
                lines.append(f"{i}. {title}\n   {url}\n   {content}")
            if not lines:
                return "No results."
            return "\n".join(lines)


        mcp.run()
      '';
in
{
  # Shared with claude.nix: local model server for the fish `claude`/`ollama`
  # launch aliases and as an optional Codex model_provider.
  services.ollama.enable = true;

  programs.codex = {
    enable = true;

    # ~/.codex/AGENTS.md — global memory, loaded in every project: this is
    # what makes the MCP tool the *default* rather than merely available.
    # Codex ships no built-in web search, so there is no WebSearch fallback
    # clause (unlike claude.nix's CLAUDE.md).
    context = ''
      # Web search
      Use the `searxng` MCP server's `web_search` tool (backed by the local
      SearXNG instance at http://127.0.0.1:8888) for all web searches.
    '';

    settings = {
      # Codex analog of claude.nix's `model = "claude-fable-5[1m]"`. Codex
      # resolves model names against the configured provider (openai by
      # default); adjust to gpt-5.1 / a -codex variant / an ollama model as
      # needed. See https://learn.chatgpt.com/docs/config-file/config-reference.
      model = "gpt-5.5";

      # Port of claude.nix's `permissions.defaultMode = "auto"` + allow-list.
      # Codex has no per-command glob allow-list in config.toml; instead it
      # combines an approval policy, a sandbox mode, and Starlark rules
      # (programs.codex.rules below). `on-request` prompts only when a rule
      # doesn't auto-allow the command and the action needs sign-off — the
      # closest match to Claude's "auto-approve the allow-list, ask otherwise".
      approval_policy = "on-request";
      sandbox_mode = "workspace-write";

      mcp_servers.searxng = {
        command = "${searxng-mcp}/bin/searxng-mcp";
      };

      # Port of claude.nix's `tui = "fullscreen"`: Codex's alternate-screen
      # buffer is the fullscreen equivalent.
      tui.alternate_screen = "always";
      # Port of inputNeededNotifEnabled + agentPushNotifEnabled: surface
      # notifications, and only when the terminal is unfocused (so an active
      # session isn't spammed).
      tui.notifications = true;
      tui.notification_condition = "unfocused";
    };

    # Port of claude.nix's `permissions.allow` glob-list. Codex rules are
    # Starlark (see https://learn.chatgpt.com/docs/agent-configuration/rules);
    # `prefix_rule(pattern=[...], decision="allow")` auto-approves a command
    # whose argv starts with the given prefix, without prompting — the direct
    # equivalent of a `Bash(<cmd> *)` allow entry. The attribute name becomes
    # ~/.codex/rules/default.rules (the same file Codex itself writes to when
    # you approve a command in the TUI). Read permissions like
    # `Read(//home/matus/.cargo/bin/**)` have no entry here: Codex's
    # workspace-write sandbox already permits reads, so they're moot.
    rules.default = ''
      # git — covers claude.nix's `Bash(git init *)`, `git add *`, `git commit *`, `git *`.
      prefix_rule(
          pattern = ["git"],
          decision = "allow",
          justification = "Local git plumbing is safe to run without prompting.",
      )

      # mkosi — covers `Bash(mkosi *)`, `mkosi summary *`, and the sudo'd
      # `Bash(sudo mkosi summary)`.
      prefix_rule(
          pattern = ["mkosi"],
          decision = "allow",
          justification = "mkosi image builds and summaries are non-destructive.",
      )
      prefix_rule(
          pattern = ["sudo", "mkosi"],
          decision = "allow",
          justification = "mkosi summaries under sudo are non-destructive.",
      )

      # python3 — covers `Bash(python3 *)` and the `python3 -c ...` invocations.
      prefix_rule(
          pattern = ["python3"],
          decision = "allow",
          justification = "Ad-hoc python3 one-liners and scripts.",
      )

      # pacman -Ql / rustup which — package introspection only.
      prefix_rule(
          pattern = ["pacman", "-Ql"],
          decision = "allow",
          justification = "Querying installed package file lists is read-only.",
      )
      prefix_rule(
          pattern = ["rustup", "which"],
          decision = "allow",
          justification = "Resolving a rust toolchain path is read-only.",
      )

      # curl -s — covers the archlinux.org package-version lookup.
      prefix_rule(
          pattern = ["curl", "-s"],
          decision = "allow",
          justification = "Silent curl fetches for package metadata.",
      )

      # chmod +x — covers `Bash(chmod +x *)`.
      prefix_rule(
          pattern = ["chmod", "+x"],
          decision = "allow",
          justification = "Marking scripts executable is non-destructive.",
      )

      # bash -n — syntax-check only, covers the oci-sysupdate validation.
      prefix_rule(
          pattern = ["bash", "-n"],
          decision = "allow",
          justification = "bash -n only parses, it doesn't execute anything.",
      )

      # cargo vendor — covers `Bash(cargo vendor *)`.
      prefix_rule(
          pattern = ["cargo", "vendor"],
          decision = "allow",
          justification = "Vendoring crates into the tree is non-destructive.",
      )
    '';
  };
}
