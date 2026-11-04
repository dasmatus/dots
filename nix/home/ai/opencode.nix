# Native port of nix/home/ai/claude.nix to OpenCode. The shared
# infrastructure (the searxng-mcp stdio bridge, the pstack fetch) is written
# with identical arguments to claude.nix/codex.nix so both dedupe to one store
# path, the way their half of the comment in codex.nix explains; the
# OpenCode-specific settings translate to the opencode.json model:
# settings → ~/.config/opencode/opencode.json, context → global AGENTS.md,
# skills → ~/.config/opencode/skills/. Auto-discovery would find the repo's
# skill tree in .opencode/skills/ on a per-project basis only, so a global
# skills symlink is what makes the personal skills available to every
# project, matching how ~/.claude/skills works for Claude Code.
{
  pkgs,
  dots,
  lib,
  ...
}:
let
  # Stdio MCP bridge to the local SearXNG instance (nix/modules/services/searxng.nix).
  # Identical to the ones in claude.nix and codex.nix — a generic stdio MCP
  # server, so OpenCode consumes it the same way via settings.mcp below
  # (the schema's flat `mcp.<name>` variant of an mcp server entry).
  # OpenCode's built-in WebSearch is served provider-side and cannot be
  # re-pointed, so "SearXNG as default" works exactly like Claude Code's: an
  # MCP tool steered towards it via the global AGENTS.md context below.
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

        from mcp.server.mcpserver import MCPServer
        from mcp.types import ToolAnnotations

        SEARXNG = "http://127.0.0.1:8888"

        mcp = MCPServer("searxng")


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

  # The pstack plugin (github.com/cursor/plugins), poteto's rigorous
  # agent-workflow skills. Same fetch as codex.nix's `cursorPlugins`
  # (duplicated, not shared via specialArgs — identical args dedupe to one
  # store path). OpenCode's `skills` config key takes a list of additional
  # discovery folders, so pstack's `skills/` subtree rides in there.
  cursorPlugins = pkgs.fetchFromGitHub {
    owner = "cursor";
    repo = "plugins";
    rev = "60c641e4fad674784b30abcf9f8915dea39df38d";
    sha256 = "1983c5ivszcbrxyg35hv6zsrv99s42144vrpfk8qrsaaalpzy0n6";
  };

  # The superpowers skills library from its git source — the same rev the
  # Claude Code marketplace pins in ~/.claude/plugins/cache, so both harnesses
  # load the same bodies. OpenCode loads skills from a plain directory; the
  # repo's own .opencode/plugins/superpowers.js V2 plugin route is not used
  # not used because the skills are what is wanted, and a directory needs no
  # runtime fetch of a plugin package. rev pinned to obra/superpowers main
  # HEAD at adoption time; bump deliberately.
  superpowersSrc = pkgs.fetchFromGitHub {
    owner = "obra";
    repo = "superpowers";
    rev = "bb92a77741419a4ab5f06e711a283343f1ada0c3";
    sha256 = "sha256-UCVI+T7j1Xh1LDkrvnJduis7eHFqrizCyGTWAGW5d6U=";
  };

  # The claude-linux-computer marketplace, whose `skills/` holds the
  # desktop-control skills (find-and-click / interact / setup / status). Same
  # rev the Claude Code marketplace checkout pins; hash-determined so the
  # offline installer substitutes it without the fetcher cache. The bun-based
  # MCP server inside is NOT wired here: launching it needs bun + a plugin
  # checkout with node_modules, while the same desktop capability is served by
  # the natively packaged computer-use-linux MCP registered below.
  linuxComputerSrc = pkgs.fetchFromGitHub {
    owner = "Nige-l";
    repo = "claude-linux-computer";
    rev = "01776272c80647a40d99991f61f0fcb4196ea814";
    sha256 = "sha256-W6UDAySHLICJWydFUwydI7OGSDtgj7qetlnfGTz3U0o=";
  };

  # This repo's skills/ tree as a real store path — dots-skills.nix builds the
  # identical tree for the Claude Code and Claude desktop plugins, so this
  # callPackage dedupes to the one store path those two already use.
  # Unlike a bare ../../skills, a derivation output is an absolute store path:
  # the HM module asserts the skills value is a directory with
  # `builtins.readFileType`, and a flake-internal lazy path is not in the
  # eval context yet when it does (a bare path also failed evaluation with
  # Home Manager reading it relative to nix/ rather than nix/home/ai/).
  dotsSkills = pkgs.callPackage ../../packages/dots-skills.nix { };

  # `oc` — the front for OpenCode, the entry point a terminal reaches for
  # instead of the `opencode` binary. Two behaviours above the binary:
  #
  #   o Session resume. The front owns one session per directory: the id is
  #     remembered in XDG_STATE_HOME/opencode-front/<hash of $PWD>/session
  #     and every later call — the interactive TUI (`oc` bare) or a one-shot
  #     run (`oc "message"`, message on stdin works) — continues THAT
  #     session via `--session`. Not `--continue`: `opencode session list`
  #     in a directory also lists every other harness's threads (T3 Code
  #     sessions included), so the last session in the directory is not
  #     necessarily the front's. `oc -n` drops the memory and starts fresh.
  #
  #   o Model auto-switch. A one-shot run walks: the directory's last WORKING
  #     model first, then the configured chain. A model fails at the provider
  #     level (quota, auth, no route) when its stream never emits a
  #     `step_start` event — a failed `opencode run` can still exit 0, the
  #     error arrives as an error event — and the front then advances to the
  #     next model WITHIN the same session (`--session` is re-read per
  #     attempt), so the retry keeps all context. The winner is remembered
  #     and tried first next time. `-m provider/model` pins one model and
  #     skips the walk.
  #
  # The chain, first source that provides one wins: $OC_FRONT_MODELS (word
  # split), otherwise ~/.config/opencode/front-models (one model per line,
  # '#' comments), otherwise opencode's own default model (an empty chain
  # runs without --model at all).
  #
  # The script itself is scripts/oc, git-tracked and standalone-testable;
  # only the PATH prologue is stamped in here, pinning jq and coreutils so
  # the front does not depend on the user's shell PATH. OpenCode itself is
  # deliberately NOT pinned: it must resolve to whatever the profile wraps
  # or caps (nix/home/base/memory-limits.nix), not to a second unwrapped
  # copy. writeShellScriptBin rather than writeShellApplication keeps
  # shellcheck out of the build; the repo's other small helpers (dots-clone,
  # dots-hyprshot) made that same call.
  ocFront = pkgs.writeShellScriptBin "oc" (
    lib.strings.concatStrings [
      "PATH=${pkgs.jq}/bin:${pkgs.coreutils}/bin:\"$PATH\"\n"
      (builtins.readFile ../../../scripts/oc)
    ]
  );
in
{
  # Same toggle as programs.opencode below — the front without the harness
  # (or the harness without its front) would each be dead weight on PATH.
  home.packages = lib.optionals dots.ai.opencode [ ocFront ];

  # Gated on the installer "AI" screen toggle (options.dots.ai.opencode).
  programs.opencode = {
    enable = dots.ai.opencode;

    # ~/.config/opencode/AGENTS.md — global memory loaded in every project:
    # this is what makes the MCP tool the *default* rather than merely
    # available. Ported from codex.nix, minus nothing: OpenCode ships no
    # built-in web search either.
    context = ''
      # Web search
      Use the `searxng` MCP server's `web_search` tool (backed by the local
      SearXNG instance at http://127.0.0.1:8888) for all web searches.

      # Desktop control
      The `computer-use-linux` MCP server drives the real Linux desktop
      (Wayland-first): screenshots, AT-SPI semantic selectors, clicks,
      scrolls, keystrokes, and window targeting. Use it when asked to
      operate GUI apps. Runtime needs ydotoold + the AT-SPI bus + /dev/uinput
      group access; if a call fails, run `computer-use-linux doctor | jq
      .readiness` to see what's missing.
    '';

    # This repo's skills/ tree — the user's personal skills — as a directory
    # of one folder per skill. The HM module symlinks it to
    # ~/.config/opencode/skills/, which OpenCode discovers globally, so a
    # skill is available by its bare folder name in every project, unlike the
    # Claude Code plugin route that prefixes the name with `dots-skills:`.
    #
    # Dropping a new folder into skills/ still needs no Nix change: the whole
    # directory is symlinked, so new folders load automatically.
    skills = "${dotsSkills.plugin}/skills";

    settings = {
      # The stdio MCP bridge to the local SearXNG instance. The
      # desktop-control server is registered by
      # nix/home/ai/computer-use-linux.nix alongside its Claude Code and Codex
      # entries — OpenCode's local server entry is {type, command} +
      # {environment}, with command args folded into the command list.
      mcp.searxng = {
        type = "local";
        command = [ "${searxng-mcp}/bin/searxng-mcp" ];
      };

      # Additional skill discovery folders beyond the personal skills symlink
      # wired above. pstack, superpowers and the desktop-control skills come
      # as plain skills/ subtrees of their fetches; OpenCode answers to the
      # bare skill names, as with the symlink.
      skills = [
        "${cursorPlugins}/pstack/skills"
        "${superpowersSrc}/skills"
        "${linuxComputerSrc}/skills"
      ];
    };
  };
}
