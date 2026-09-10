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

  # Stdio MCP bridge to the local SearXNG instance (nix/modules/services/searxng.nix).
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
  # fetcher cache, the same reason nix/packages/aipage.nix uses a derivation. rev
  # pinned to backnotprop/pstack main HEAD at adoption time; bump
  # deliberately.
  pstackSrc = pkgs.fetchFromGitHub {
    owner = "backnotprop";
    repo = "pstack";
    rev = "18e0e908a13553b0e58d065ab26dbc9a972ec8ba";
    sha256 = "1nj8hrvakcpvbi89gvpcj1szr2yr6531w86npyx56msj6683c61m";
  };

  # dots-skills — this repo's skills/ tree as a plugin, plus the hook payloads
  # generated from it. Defined in nix/packages/dots-skills.nix rather than here because
  # nix/packages/claude-desktop.nix needs the identical tree: the desktop app reads
  # ~/.claude/skills on none of its surfaces, so the plugin is the only route
  # that reaches it.
  dotsSkills = pkgs.callPackage ../../packages/dots-skills.nix { };

  # Payload for the PostToolUse hook below. Auto-memory has no tool of its
  # own; it writes through the ordinary Write/Edit tools, so nothing marks
  # a memory write as done except the hook firing right after it. The
  # payload states a fact rather than an order. Claude Code's
  # prompt-injection defenses treat additionalContext phrased as an
  # imperative as a hijack attempt and show it to the user instead of
  # acting on it, so an order here would never reach the skill it exists
  # to trigger. builtins.toJSON keeps this string one Nix value away from
  # hand-escaped JSON.
  # Wording is deliberately factual with one borrowed word: "trigger" is
  # the primer's own vocabulary for a skill-matching condition, so stating
  # the match in those terms lets the fact self-identify as a trigger match
  # instead of leaving the model to infer the link on its own.
  memoryPrimer = pkgs.writeText "memory-primer.json" (
    builtins.toJSON {
      hookSpecificOutput = {
        hookEventName = "PostToolUse";
        additionalContext = "A memory file was just written. This matches the trigger condition of the dots-skills:unslopping-memory skill, which runs a prose-cleanup pass over memory files and enforces the CLAUDE.md line cap.";
      };
    }
  );

  # Decides, in a script this file controls, whether a Write/Edit call
  # touched an auto-memory file. See the long comment on `hooks.PostToolUse`
  # below for why that decision cannot live in the hook's own `if` field.
  # jq is the only runtimeInput, same "no hand-rolled JSON parsing" rule
  # `dotsMemoryHook` used to follow (git show b6582b8^) for its one flat
  # field; this payload has a field to descend into
  # (`.tool_input.file_path`) rather than a whole string to escape, so a
  # real parser earns its keep here where it did not there.
  memoryHookScript = pkgs.writeShellApplication {
    name = "claude-memory-hook";
    runtimeInputs = [ pkgs.jq ];
    text = ''
      # Claude Code hands a hook its event JSON on stdin, once. `// empty`
      # turns a missing or null field into the empty string rather than the
      # literal "null", and `2>/dev/null || true` swallows a parse failure
      # on a malformed or empty payload instead of tripping this script's
      # `set -e` (writeShellApplication's default) — either way file_path
      # ends up empty, and the case below already treats empty the same as
      # "not a memory file". Degrading to silence on anything unexpected
      # mirrors how `dotsMemoryHook` used to degrade to silence when its
      # database was down: a hook that stays quiet is recoverable, one that
      # errors is not.
      file_path=$(jq -r '.tool_input.file_path // empty' 2>/dev/null || true)

      # Auto-memory writes under ~/.claude/projects/<slug>/memory/, where
      # <slug> is the project path with every "/" turned into a "-" — an
      # arbitrary, unbounded number of path segments a permission-rule-style
      # single-segment "*" cannot span (see `hooks.PostToolUse` below for
      # the full story). A plain two-part substring test sidesteps segment
      # counting entirely: "somewhere under .claude" plus "through a
      # memory/ directory" is what auto-memory means regardless of how many
      # segments sit in between, and it keeps matching if
      # `autoMemoryDirectory` ever relocates the projects root, so long as
      # the relocated tree still keeps a `memory/` leaf the way Claude
      # Code's own docs show it would.
      case "$file_path" in
        *"/.claude/"*"/memory/"*)
          cat ${memoryPrimer}
          ;;
      esac

      exit 0
    '';
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

      # Memory entries
      A memory entry is a terse factual statement: what happened, what
      changed, what was decided. No adjectives, no summary prose, and
      nothing this file already says.
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

      # Guarantees dots-skills:unslopping-memory gets a chance to fire after
      # every memory write. A skill only runs when the model matches its own
      # description to the task in front of it, so without a nudge from
      # outside it may just never come up. Auto-memory has no tool of its
      # own; it writes through ordinary Write/Edit calls, which is why the
      # matcher below names those two instead of anything memory-specific
      # — that matcher is a cheap pre-filter on tool name and nothing more.
      #
      # The actual narrowing to memory files used to live in an `if` field
      # here, and that was wrong on three independent counts, so it moved
      # into `memoryHookScript` above instead:
      #   1. Permission-rule syntax matches a bare `*` within one path
      #      segment only; `**` is what spans directories. The real path
      #      (~/.claude/projects/<slug>/memory/<file>.md) has several
      #      segments before `memory`, which an unanchored `*/memory/*`
      #      can never bridge — contrast the `Edit(.claude/**)` /
      #      `Edit(/${config.home.homeDirectory}/.claude/**)` rules above,
      #      which both need `**` for exactly this reason.
      #   2. An unanchored pattern anchors to the project cwd, so
      #      `*/memory/*` could only ever match under the current project
      #      directory — never under ~/.claude/projects/ — which is why
      #      the rules above spell the home directory out instead of
      #      leaving it implicit.
      #   3. Decisively: Claude Code's permission docs say file rules are
      #      consulted for `Edit(path)` and `Read(path)` only, and that a
      #      `Write(path)` rule is accepted but never consulted. A brand
      #      new memory file's first write is a `Write` call, so the
      #      `Write(...)` half of the old `if` was dead on arrival even
      #      once the glob itself got fixed. That third point is what
      #      rules `if` out entirely rather than just needing a better
      #      glob: no permission-rule string can ever gate a `Write`, so
      #      the decision has to live somewhere `if` cannot reach. Do not
      #      "simplify" this back into an `if` clause — it would silently
      #      stop firing on every memory file's first write, which is the
      #      worst kind of broken: no error, no log, just a hook that
      #      never runs.
      #
      # See `memoryPrimer` above for why the payload states a fact instead
      # of giving an order, and `memoryHookScript` for how the file-path
      # match itself works now.
      hooks.PostToolUse = [
        {
          matcher = "Write|Edit";
          hooks = [
            {
              type = "command";
              command = "${memoryHookScript}/bin/claude-memory-hook";
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
        # via the profile list in nix/home/base/pkgs.nix: rust-analyzer, and clangd
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

      # Auto-memory back on. The Postgres-backed memory plugin that used to
      # own this job — a custom hook shelling out to psql, a schema of its
      # own, a service to keep running — is retired; Claude's built-in
      # ~/.claude/projects/*/memory read/write now carries session-to-session
      # continuity instead, with no extra service and nothing versioned here
      # to keep in sync with it.
      autoMemoryEnabled = true;
    };
  };

  # Beamenu plugin manifest: an "Ask Claude" one-shot prompt, a terminal
}
