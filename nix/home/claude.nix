# Native port of files/claude/settings.json (deleted — see git history).
# ccbar used to be an imperative `cargo install ccbar` (~/.cargo/bin); it is
# now built from its crates.io release below and wired into the statusline,
# and goes on PATH so the 5-hour/weekly limits can be polled directly.
{
  config,
  pkgs,
  lib,
  dots,
  claudeDesktop,
  inputs,
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
        from mcp.types import ToolAnnotations

        SEARXNG = "http://127.0.0.1:8888"

        mcp = FastMCP("searxng")


        # readOnlyHint defaults to false — "this tool may change state" — and plan mode
        # denies any MCP tool that says so, whatever the allow-list holds. Read-only is
        # necessary but not sufficient there: a matching permissions.allow entry is the
        # other half.
        @mcp.tool(annotations=ToolAnnotations(readOnlyHint=True, destructiveHint=False, openWorldHint=True))
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
  # `.claude-plugin/plugin.json`. Among the skills are
  # typescript-best-practices, which skills/writing-good-web routes .ts work
  # to, and unslop, which dodging-cdb and writing-good-rs both call. Those
  # references make this pin load-bearing, not merely convenient.
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

  # dots-memory: the Postgres-backed memory plugin. Design:
  # docs/superpowers/specs/2026-08-26-postgres-memory-plugin-design.md.
  # The hook shells out to psql itself, rather than trusting the MCP
  # server, so a dead cluster degrades the plugin to silence instead of a
  # failed SessionStart/Stop: any psql failure means no stdout at all, and
  # the script always exits 0. `basename` is done with pure parameter
  # expansion (not the coreutils binary) so `postgresql_18` can stay the
  # only runtimeInput.
  dotsMemoryHook = pkgs.writeShellApplication {
    name = "dots-memory-hook";
    runtimeInputs = [ pkgs.postgresql_18 ];
    text = ''
      # Escapes backslashes, double quotes and newlines for one JSON
      # string literal. No jq dependency for a single field.
      json_escape() {
        local s=$1
        s=''${s//\\/\\\\}
        s=''${s//\"/\\\"}
        s=''${s//$'\n'/\\n}
        printf '%s' "$s"
      }

      event="''${1:-}"
      project_dir="''${CLAUDE_PROJECT_DIR:-$PWD}"
      scope="''${project_dir##*/}"

      case "$event" in
        session-start)
          if digest="$(psql -X -d matus -Atc \
              "select agentmem.digest('$scope', 40, 6000)" 2>/dev/null)"; then
            printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' \
              "$(json_escape "$digest")"
          fi
          ;;
        stop)
          printf '{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"nothing durable was recorded this session; if something was learned, call remember"}}\n'
          ;;
      esac
      exit 0
    '';
  };

  # The checked-in tree under plugins/dots-memory/ stays diffable; this
  # runCommand only adds `bin/` store symlinks on top, so `.mcp.json` and
  # `hooks/hooks.json` can name `''${CLAUDE_PLUGIN_ROOT}/bin/<name>`
  # without ever spelling out a store path. The plugin's own
  # .claude-plugin/plugin.json suppresses Home Manager's synthesized
  # manifest. `dots-memory-mcp` is plan 3's crate
  # (rust/dots-memory-mcp); this derivation only symlinks the built
  # binary in, it does not build it.
  dotsMemoryPlugin = pkgs.runCommand "dots-memory-plugin" { } ''
    cp -r ${../../plugins/dots-memory} $out
    chmod -R u+w $out
    mkdir -p $out/bin
    ln -s ${inputs.self.packages.x86_64-linux.dots-memory-mcp}/bin/dots-memory-mcp \
      $out/bin/dots-memory-mcp
    ln -s ${dotsMemoryHook}/bin/dots-memory-hook $out/bin/dots-memory-hook
    test -e $out/.claude-plugin/plugin.json
    test -e $out/.mcp.json
  '';

  # dots-skills — this repo's skills/ tree as a plugin, plus the hook payloads
  # generated from it. Defined in nix/dots-skills.nix rather than here because
  # nix/claude-desktop.nix needs the identical tree: the desktop app reads
  # ~/.claude/skills on none of its surfaces, so the plugin is the only route
  # that reaches it.
  dotsSkills = pkgs.callPackage ../dots-skills.nix { };
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

    # dots-memory — see `dotsMemoryPlugin` above. Ships its own
    # .claude-plugin/plugin.json, so no manifest is synthesized here
    # either. Not in `settings.enabledPlugins`: that key names
    # `<plugin>@<marketplace>` pairs for marketplace-sourced plugins, and
    # this one is loaded straight from the store like pstack above.
    plugins.dots-memory = "${dotsMemoryPlugin}";

    # dots-skills — see `dotsSkills` above. This replaces the bare
    # `skills = ../../skills` wiring rather than sitting beside it. Both routes
    # land in ~/.claude/skills/, but the plugin's copies answer to
    # `dots-skills:<name>` and the bare copies to `<name>`; the listing dedups
    # by resolved name, and two different names dedup to nothing. Keeping both
    # would double the listing without doubling the capability, and Home
    # Manager cannot catch it — its only assertion is that skill directory
    # names must not collide with plugin directory names, and `dots-skills`
    # collides with none of them.
    #
    # Dropping a new folder into skills/ still needs no Nix change: the
    # manifest deliberately omits a `skills` key, which is what keeps the
    # folder auto-loaded rather than shadowed by an explicit list.
    plugins.dots-skills = "${dotsSkills.plugin}";

    # ~/.claude/CLAUDE.md — global memory, loaded in every project: this is
    # what makes the MCP tool the *default* rather than merely available.
    #
    # The `mcp__plugin_hm_` prefix on the tool name is not decoration. The
    # module folds `mcpServers` above into a synthesized personal plugin whose
    # manifest name is the short `hm`, and the MCP tool prefix is built from
    # that manifest name, so the bare `mcp__searxng__web_search` this used to
    # say named a tool that does not exist. An agent that tries it gets
    # nothing and silently falls back to the built-in WebSearch — the exact
    # behaviour this block exists to prevent.
    #
    # Reaches general-purpose subagents but not Explore or Plan, which are
    # built with CLAUDE.md stripped. The SubagentStart hook below is the only
    # channel that reaches those two.
    context = ''
      # Web search
      Default to the `searxng` MCP tool (`mcp__plugin_hm_searxng__web_search`, backed
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
          # SearXNG is the default web search for every session (see the
          # `context` block below), so this tool fires constantly, and one GET
          # against a loopback instance is not worth a prompt. Plan mode needs
          # both halves: the readOnlyHint annotation above clears its read-only
          # gate, and this rule is what then approves the call.
          "mcp__plugin_hm_searxng__web_search"
          # The auto-mode-setup skill drafts auto-mode config and needs to
          # create files under the project's .claude/ and ~/.claude/ without
          # prompting. NB: ~/.claude/settings.json itself is HM-managed, so
          # a switch reverts any edits the skill makes there.
          "Skill(auto-mode-setup)"
          # The primer tells every subagent to call these skills, and a
          # subagent has nobody to answer a permission prompt: a prompt it
          # cannot answer is a denial, which turns the mandate into a silent
          # no-op. Pre-allowing the namespace is what keeps the hook from
          # being advice a subagent is structurally unable to take.
          "Skill(dots-skills:*)"
          "Edit(.claude/**)"
          "Edit(/${config.home.homeDirectory}/.claude/**)"
        ];
        defaultMode = "auto";
      };

      # Claude Code lifecycle hooks (settings.json "hooks", distinct from
      # the HM module's hooks/ script directory). Two events, one payload,
      # both generated by `dotsSkills.primer` above.
      #
      # SessionStart is the old wiring widened. It used to cat a single
      # SKILL.md, which primed the top-level session with dodging-cdb and
      # left every other skill to self-trigger off a description the model
      # may or may not have matched against. It now emits the generated
      # index as well, so a fresh session starts holding one trigger line
      # per skill and a standing instruction to call the Skill tool on a
      # match.
      #
      # SubagentStart is the reason any of this exists. A subagent is built
      # with a fresh message array rather than a copy of its parent's
      # transcript, so SessionStart output never reaches it and it fires
      # this event instead. Both hooks emit JSON rather than bare text
      # deliberately: bare stdout becomes a hook_success attachment, which
      # a session folds into context and a subagent does not, so a plain
      # cat here would fire, log a clean exit, and change nothing about
      # what the subagent does. Only hookSpecificOutput/additionalContext
      # lands. No matcher, so it covers every agent type including Explore
      # and Plan — the two built-ins that have CLAUDE.md stripped from
      # their context and so cannot be reached any other way.
      hooks.SessionStart = [
        {
          hooks = [
            {
              type = "command";
              command = "cat ${dotsSkills.primer}/session-start.json";
            }
          ];
        }
      ];
      hooks.SubagentStart = [
        {
          hooks = [
            {
              type = "command";
              command = "cat ${dotsSkills.primer}/subagent-start.json";
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
        # The official LSP plugins carry no code: each is just an `lspServers`
        # block in the marketplace manifest naming a binary Claude Code spawns
        # itself, so the server has to reach PATH on its own. Both do,
        # via the profile list in nix/home/pkgs.nix: rust-analyzer, and clangd
        # out of clang-tools, next to the clang c-compiler-preference insists on.
        "clangd-lsp@claude-plugins-official" = true;
        "rust-analyzer-lsp@claude-plugins-official" = true;
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

      # What `/model opus` writes, so a fresh session starts on Opus 5
      # instead of asking. ~/.claude/settings.json is a store symlink, so
      # the slash command's own write cannot stick, so this is the only
      # place the default survives a `home-manager switch`.
      model = "opus";

      # Turn off auto-memory. Claude then neither reads nor writes
      # ~/.claude/projects/*/memory, so nothing about a session leaks into
      # the next one behind the user's back. Project context comes from
      # CLAUDE.md and the skills above, which are versioned here.
      autoMemoryEnabled = false;
    };
  };

  # Beamenu plugin manifest: an "Ask Claude" one-shot prompt, a terminal
}
