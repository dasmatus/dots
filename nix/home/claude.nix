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

  # The pstack plugin, fetched from its canonical upstream
  # (github.com/backnotprop/pstack) rather than the cursor/plugins
  # marketplace mirror it used to ride in. The repo keeps `skills/` and
  # `agents/` at its root with only a `.cursor-plugin/` manifest, which
  # Claude Code does not read; a plugin manifest is optional though, so the
  # HM module auto-discovers both subdirs and synthesizes the
  # `.claude-plugin/plugin.json`. Among the skills is
  # typescript-best-practices, which skills/writing-good-code routes web
  # work to, so this pin is load-bearing for that umbrella skill.
  # fetchFromGitHub (not builtins.fetchGit) so the output path is
  # hash-determined and the offline installer can substitute it without the
  # fetcher cache, the same reason nix/aipage.nix uses a derivation. rev
  # pinned to backnotprop/pstack main HEAD at adoption time; bump
  # deliberately.
  pstackSrc = pkgs.fetchFromGitHub {
    owner = "backnotprop";
    repo = "pstack";
    rev = "18e0e908a13553b0e58d065ab26dbc9a972ec8ba";
    sha256 = "1nj8hrvakcpvbi89gvpcj1szr2yr6531w86npyx56msj6683c61m";
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

    # pstack — see `pstackSrc` above. A personal plugin: the HM module
    # symlinks it into ~/.claude/skills/pstack and synthesizes a
    # .claude-plugin/plugin.json (pstack ships only a .cursor-plugin/ one,
    # which Claude Code ignores), exposing its skills + subagents. Distinct
    # from the marketplace plugins in settings.enabledPlugins below; the two
    # mechanisms coexist.
    plugins.pstack = "${pstackSrc}";

    # Personal skills from this repo's skills/ tree (one folder per skill,
    # each holding a SKILL.md). The module symlinks the whole directory into
    # ~/.claude/skills/, so dropping a new skill folder into skills/ needs no
    # Nix change. Each skill self-triggers off its frontmatter description;
    # dodging-cdb is additionally injected at session start via the
    # SessionStart hook in settings below, because Claude Code has no native
    # "run this skill at startup" mechanism.
    skills = ../../skills;

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

      # Claude Code lifecycle hooks (settings.json "hooks", distinct from
      # the HM module's hooks/ script directory). A SessionStart hook's
      # stdout is added to the session context, so cat-ing dodging-cdb's
      # SKILL.md from its store path primes every fresh session with it
      # before any git push happens. That is the closest thing to "run this
      # skill at startup". The path interpolation pins the file into the
      # store, so the hook can never dangle even if the repo checkout moves.
      hooks.SessionStart = [
        {
          hooks = [
            {
              type = "command";
              command = "cat ${../../skills/dodging-cdb/SKILL.md}";
            }
          ];
        }
      ];

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
}
