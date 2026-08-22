# Native port of files/claude/settings.json (deleted — see git history).
# ccbar used to be an imperative `cargo install ccbar` (~/.cargo/bin); it is
# now built from its crates.io release below and wired into the statusline,
# and goes on PATH so the 5-hour/weekly limits can be polled directly.
{
  config,
  pkgs,
  lib,
  dots,
  ...
}:
let
  # Claude Code statusline with 5-hour and 7-day (weekly) rate-limit bars.
  # Hashes verified by building against the pinned nixpkgs; pure-Rust deps
  # (serde, serde_json, toml, ureq/rustls), no native libraries.
  ccbar = pkgs.rustPlatform.buildRustPackage rec {
    pname = "ccbar";
    version = "0.3.0";
    src = pkgs.fetchCrate {
      inherit pname version;
      hash = "sha256-1FMxK/DfbLQAn4qG+gwvUUsELQpxHCIGlgZq4Of89uE=";
    };
    cargoHash = "sha256-GM0ofr1uPrF2/5keE/4TZXiXg+wodJefTBhzYHOvTCs=";
    meta = {
      description = "Fast, configurable statusline for Claude Code";
      homepage = "https://github.com/Saturate/ccbar";
      license = lib.licenses.mit;
      mainProgram = "ccbar";
    };
  };

  # Stdio MCP bridge to the local SearXNG instance (nix/modules/searxng.nix).
  # Claude Code's built-in WebSearch is served Anthropic-side and cannot be
  # re-pointed, so "SearXNG as default" means: expose it as an MCP tool and
  # steer towards it via the global context below. Python MCP SDK from
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

  # The pstack plugin (github.com/cursor/plugins) — poteto's rigorous
  # agent-workflow skills + subagents. The upstream repo is a Cursor
  # `.cursor-plugin/` marketplace, which Claude Code does not read; but a
  # plugin manifest is optional in Claude Code — it auto-discovers a
  # `skills/` and `agents/` subdir at the plugin root and derives the name
  # from the directory — so pointing `programs.claude-code.plugins.pstack`
  # straight at the fetched `pstack/` dir works with no third-party
  # `.claude-plugin/` shim fork. fetchFromGitHub (not builtins.fetchGit) so
  # the output path is hash-determined and the offline installer can
  # substitute it without the fetcher cache — the same reason nix/aipage.nix
  # uses a derivation. rev pinned to the cursor/plugins main HEAD at adoption
  # time; bump deliberately with `nix flake update`-style intent.
  cursorPlugins = pkgs.fetchFromGitHub {
    owner = "cursor";
    repo = "plugins";
    rev = "60c641e4fad674784b30abcf9f8915dea39df38d";
    sha256 = "1983c5ivszcbrxyg35hv6zsrv99s42144vrpfk8qrsaaalpzy0n6";
  };
in
{
  home.packages = [ ccbar ];
  # Gated on the installer "AI" screen toggle (options.dots.ai.claude, written
  # into settings.nix as aiClaude and bridged by nix/modules/dots.nix).
  programs.claude-code = {
    enable = dots.ai.claude;

    mcpServers.searxng = {
      type = "stdio";
      command = "${searxng-mcp}/bin/searxng-mcp";
    };

    # pstack — see `cursorPlugins` above. A personal plugin: the HM module
    # symlinks it into ~/.claude/skills/pstack and synthesizes a
    # .claude-plugin/plugin.json (pstack ships only a .cursor-plugin/ one,
    # which Claude Code ignores), exposing its skills + subagents. Distinct
    # from the marketplace plugins in settings.enabledPlugins below; the two
    # mechanisms coexist.
    plugins.pstack = "${cursorPlugins}/pstack";

    # ~/.claude/CLAUDE.md — global memory, loaded in every project: this is
    # what makes the MCP tool the *default* rather than merely available.
    context = ''
      # Web search
      Default to the `searxng` MCP tool (`mcp__searxng__web_search`, backed
      by the local SearXNG instance at http://127.0.0.1:8888) for all web
      searches. Fall back to the built-in WebSearch tool only when the local
      instance is unreachable.

      # Desktop control
      The `computer-use-linux` MCP server drives the real Linux desktop
      (Wayland-first): screenshots, AT-SPI semantic selectors, clicks,
      scrolls, keystrokes, and window targeting across compositors. Use it
      when asked to operate GUI apps. It needs ydotoold + the AT-SPI bus +
      /dev/uinput group access at runtime; if a tool call fails, run
      `computer-use-linux doctor | jq .readiness` to see what's missing.
    '';
    settings = {
      ultracode = true;
      permissions = {
        allow = [
          "Bash(git init *)"
          "Bash(git add *)"
          "Bash(git commit *)"
          "Bash(git *)"
          "Bash(sudo mkosi summary)"
          "Bash(mkosi summary *)"
          "Bash(mkosi *)"
          "Bash(python3 -c \"import importlib.metadata; print\\(importlib.metadata.version\\('mkosi'\\)\\)\")"
          "Bash(python3 -c ' *)"
          "Bash(python3 *)"
          "Bash(pacman -Ql rust)"
          "Bash(rustup which *)"
          "Read(//home/matus/.cargo/bin/**)"
          "Bash(curl -s \"https://archlinux.org/packages/extra/x86_64/rust/\")"
          "Bash(chmod +x *)"
          "Bash(bash -n /var/home/matus/Dokumente/schule/demo-maturitna-praca/mkosi.extra/usr/local/sbin/oci-sysupdate)"
          "Bash(cargo vendor *)"
          # The auto-mode-setup skill drafts auto-mode config and needs to
          # create files under the project's .claude/ and ~/.claude/ without
          # prompting. NB: ~/.claude/settings.json itself is HM-managed, so
          # a switch reverts any edits the skill makes there.
          "Skill(auto-mode-setup)"
          "Edit(.claude/**)"
          "Edit(/${config.home.homeDirectory}/.claude/**)"
        ];
        defaultMode = "auto";
      };

      disableClaudeAiConnectors = true;

      statusLine = {
        type = "command";
        command = lib.getExe ccbar;
        refreshInterval = 1;
      };

      enabledPlugins = {
        "superpowers@claude-plugins-official" = true;
        "explanatory-output-style@claude-plugins-official" = true;
        "learning-output-style@claude-plugins-official" = false;
        "clangd-lsp@claude-plugins-official" = true;
        "linux-computer@claude-linux-computer" = true;
      };

      extraKnownMarketplaces = {
        "claude-linux-computer" = {
          source = {
            source = "git";
            url = "https://github.com/Nige-l/claude-linux-computer.git";
          };
        };
      };

      skipWorkflowUsageWarning = true;
      theme = "dark";
      tui = "fullscreen";
      disableAgentView = true;
      remoteControlAtStartup = true;
      inputNeededNotifEnabled = true;
      agentPushNotifEnabled = true;

      model = "claude-fable-5[1m]";
    };
  };

  # Beamenu plugin manifest: an "Ask Claude" one-shot prompt, a terminal
  # drop-in, and a usage readout. `programs.beamenu.plugins` lands via a
  # parallel task on the same plan — this worktree was cut before it (and
  # before the claude-desktop packaging, hence `icon = null` below), so gate
  # visibility with lib.mkIf the same way the rest of this file gates on
  # dots.ai.claude: eval stays inert here and picks the block up once both
  # land on merge.
  programs.beamenu.plugins = lib.mkIf dots.ai.claude {
    claude = {
      name = "claude";
      title = "Claude Code";
      # nix/claude-desktop.nix and its `claudeDesktop` specialArg (which
      # would give a hicolor icon store path) aren't present in this
      # worktree — it was branched before that packaging landed.
      icon = null;
      keyword = "cl";
      commands = [
        {
          id = "ask";
          title = "Ask Claude";
          description = "Prompt Claude Code";
          mode = "view";
          ui = "log";
          # stream-json emits one event per assistant content block plus a
          # final result line; keep only the readable text (thinking/system
          # /tool-use events are launcher noise) — `{query}` is substituted
          # by beamenu itself.
          exec = [
            "bash"
            "-lc"
            ''
              claude -p "{query}" --output-format stream-json --verbose | ${lib.getExe pkgs.jq} -r '
                if .type == "assistant" then
                  (.message.content[]? | select(.type == "text") | .text)
                elif .type == "result" then
                  .result
                else
                  empty
                end
              '
            ''
          ];
        }
        {
          id = "shell";
          title = "Claude in terminal";
          mode = "terminal";
          exec = [ "claude" ];
        }
        {
          id = "usage";
          title = "Claude usage";
          description = "5h and weekly limits";
          mode = "view";
          ui = "log";
          # ccbar only renders whatever JSON lands on its stdin (src/main.rs
          # — no fetching of its own); its rate-limit block reads
          # rate_limits.{five_hour,seven_day}.used_percentage (src/status.rs
          # RateWindow, confirmed against the built crates.io source).
          # resets_at is an epoch int in that struct and is left out here:
          # the only source for it is prose ("resets Aug 22, 7:10pm
          # (Europe/London)"), not safe to machine-parse. The percentages
          # come from Claude Code's own built-in `/usage` slash command,
          # which is a free local computation (verified live: total_cost_usd
          # 0, zero tokens) rather than a real model call.
          exec = [
            "bash"
            "-lc"
            ''
              out=$(claude -p "/usage" --output-format json | ${lib.getExe pkgs.jq} -r .result)
              five=$(printf '%s' "$out" | grep -oP 'Current session: \K[0-9]+')
              week=$(printf '%s' "$out" | grep -oP 'Current week \(all models\): \K[0-9]+')
              ${lib.getExe pkgs.jq} -n --argjson five "''${five:-0}" --argjson week "''${week:-0}" \
                '{rate_limits: {five_hour: {used_percentage: $five}, seven_day: {used_percentage: $week}}}' \
                | ${lib.getExe ccbar}
            ''
          ];
        }
      ];
    };
  };
}
