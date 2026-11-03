# Native port of nix/home/ai/claude.nix to OpenCode. The shared
# infrastructure (the searxng-mcp stdio bridge, the pstack fetch) is written
# with identical arguments to claude.nix/codex.nix so all three instances
# dedupe to one store path, the way their half of the comment in codex.nix
# explains; the OpenCode-specific settings translate to the opencode.json
# model: settings → ~/.config/opencode/opencode.json, context → global
# AGENTS.md, skills → ~/.config/opencode/skills/. Auto-discovery would find
# the repo's skill tree in .opencode/skills/ on a per-project basis only, so
# a global skills symlink is what makes the personal skills available to
# every project, matching how ~/.claude/skills works for Claude Code.
{
  pkgs,
  dots,
  ...
}:
let
  # Stdio MCP bridge to the local SearXNG instance (nix/modules/services/searxng.nix).
  # Identical to the ones in claude.nix and codex.nix — a generic stdio MCP
  # server, so OpenCode consumes it the same way via settings.mcp below.
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
  # repo's own .opencode/plugins/superpowers.js V2 plugin route is not used,
  # because the skills are what is wanted and a directory needs no runtime
  # fetch of a plugin package. rev pinned to obra/superpowers main
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

  # `oc` — the front for OpenCode, the script the left terminal runs instead
  # of the `opencode` binary. Two above-the-binary behaviours:
  #
  #   o Resume. A front call in a directory continues THE session that front
  #     owns there, straight from `--session <id>` stored in one state file
  #     per directory hash (XDG state home, oc-front/). Not `--continue` from
  #     the front's side — `opencode session list` in a directory also lists
  #     every other harness's threads (T3 Code sessions included) while the
  #     front only wants its own, so the id is remembered rather than looked
  #     up. In TUI mode the same file decides between `--session` and a
  #     fallback `--continue` (the last session in the directory, whoever's
  #     it is), because there TUI flags are all the front has.
  #
  #   o Auto-switch. A run walks a model chain: the directory's last WORKING
  #     model first, then the chain order. A model fails at the provider
  #     level (quota, auth, takeover routing) when its stream never emitted a
  #     step_start — a failed run can still exit 0, the error arrives as an
  #     error event — and then the front advances to the next model WITHIN
  #     the same session, so retry costs nothing in context. The winner is
  #     remembered as the next run's head model. `-m provider/model` pins the
  #     choice and skips the walk.
  #
  # The chain itself comes from $OC_FRONT_MODELS (space separated), else
  # ~/.config/opencode/front-models (one per line, '#' comments), else the
  # baked DEFAULT_CHAIN below the order the auth list suggests:
  # opencode-go was configured for the T3 Code harness, console-anthropic
  # ("OpenCode Console" auth) is the fast fallback, `opencode` (Zen) rides
  # last. Only jq is worth a store path in the script; sha256sum, mktemp, cksum
  # and friends come from coreutils off the standard PATH.
  ocFront = pkgs.writeShellScriptBin "oc" ''
    # oc — front for opencode: resumes the front's session for this directory
    # and walks a model chain when the provider fails.
    set -euo pipefail

    jq() { "${pkgs.jq}/bin/jq" "$@"; }

    usage() {
      cat <<'EOF'
    oc  — front for opencode

      oc [message...]    one-shot run; with no message the TUI opens instead
      -n | --new         drop the stored front session and start fresh
      -m | --model ID    pin provider/model (e.g. opencode-go/glm-5.3-flash);
                         skips the auto-switch walk
      -c | --plain       exec opencode with the remaining arguments as-is
      -h | --help        this text

    The front keeps one session per directory under
    ''${XDG_STATE_HOME:-~/.local/state}/oc-front/<hash of $PWD> — the session
    is resumed automatically on every later call. A message can arrive as
    arguments or on stdin. Model chain: $OC_FRONT_MODELS, then
    ~/.config/opencode/front-models (one model per line, # comments), then
    the baked default — the last working model in a directory is always
    tried first.
    EOF
    }

    hash=$("${pkgs.coreutils}/bin/sha256sum" - <<< "$(pwd -P)" | "${pkgs.coreutils}/bin/cut" -d' ' -f1)
    root=''${OC_FRONT_STATE:-''${XDG_STATE_HOME:-$HOME/.local/state}/oc-front}
    state="$root/$hash"
    "${pkgs.coreutils}/bin/mkdir" -p "$state"

    pin=''
    fresh=0
    plain=0
    message=()
    while [ $# -gt 0 ]; do
      case $1 in
        -n|--new) fresh=1 ;;
        -m|--model)
          if [ $# -lt 2 ]; then echo "oc: $1 needs an argument" >&2; exit 2; fi
          pin=$2; shift ;;
        --model=*) pin=''${1#--model=} ;;
        -c|--plain) plain=1 ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) echo "oc: unknown flag ''$1 (see oc --help)" >&2; exit 2 ;;
        *) message+=("$1") ;;
      esac
      shift
    done
    while [ $# -gt 0 ]; do message+=("$1"); shift; done

    if [ ! -t 0 ]; then
      body="$(cat)" || true
      if [ -n "$body" ]; then message+=("$body"); fi
    fi

    if [ "$plain" -eq 1 ]; then
      exec opencode "''${message[@]}"
    fi

    if [ ''${#message[@]} -eq 0 ]; then
      if [ ! -t 0 ]; then
        echo 'oc: no message on stdin (is this a TUI call? use a real message, `oc --help`)' >&2
        exit 2
      fi
      if [ "$fresh" -eq 1 ]; then
        "${pkgs.coreutils}/bin/rm" -f "$state/session" "$state/model"
      fi
      if [ -s "$state/session" ]; then
        exec opencode --session "$(cat "$state/session")"
      fi
      exec opencode --continue
    fi

    if [ "$fresh" -eq 1 ]; then
      "${pkgs.coreutils}/bin/rm" -f "$state/session"
    fi

    # The chain. The pinned model collapses it to a single step; otherwise the
    # directory's stored working model is tried head-of-line before the rest.
    chain=''${OC_FRONT_MODELS:-"''+DEFAULT_CHAIN+''"}
    chain_file=''${OC_FRONT_MODELS_FILE:-$HOME/.config/opencode/front-models}
    if [ -z "$pin" ] && [ -f "$chain_file" ]; then
      chain="$(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$chain_file" | grep . || true)"
    fi
    if [ -z "$pin" ] && [ -s "$state/model" ]; then
      first="$(cat "$state/model")"
      rest=''
      for m in $chain; do
        [ "$m" != "$first" ] && rest="$rest $m" || true
      done
      chain="$first$rest"
    fi
    if [ -n "$pin" ]; then chain=$pin; fi

    # Runs one model against the message. Writes its stream to
    # $state/last-attempt.json; exits 0 with the reply text on stdout when the
    # model actually steered a turn.
    attempt() {
      local model=$1
      shift
      local out code
      out="$(mktemp "$state/attempt.XXXXXX.json")"
      local args=(run --format json)
      if [ -s "$state/session" ]; then args+=(--session "$(cat "$state/session")"); fi
      if [ -n "$model" ]; then args+=(--model "$model"); fi

      opencode "''${args[@]}" "$@" >"$out" 2>"$state/last-stderr.log"
      code=$?

      # A provider failure can exit 0 — the error arrives as an event — so the
      # real qualifier is that a step actually happened. The session id rides
      # every event; remembering it even on the failure path is what keeps the
      # whole walk inside one front session.
      if [ "$code" -eq 0 ] && grep -q '"type":"step_start"' "$out"; then
        jq -r '.sessionID // empty' "$out" | head -n1 > "$state/session.new"
        if [ -s "$state/session.new" ]; then
          mv "$state/session.new" "$state/session"
        else
          "${pkgs.coreutils}/bin/rm" -f "$state/session.new"
          return 1   # ...hmm, no: should this be a failure? see below
        fi
        if [ -n "$model" ]; then printf %s "$model" > "$state/model"; fi
        jq -r 'select(.type == "text") | .part.text // empty' "$out"
        "${pkgs.coreutils}/bin/rm" -f "$out"
        return 0
      fi
      jq -r '.sessionID // empty' "$out" | head -n1 > "$state/session.new"
      [ -s "$state/session.new" ] && mv "$state/session.new" "$state/session" || true
      rm -f "$state/session.new"
      jq -r 'select(.type == "error") | (.error.message // .part.text // empty)' "$out" |
        head -n1 > "$state/last-error.txt" || true
      mv "$out" "$state/last-attempt.json"
      return 1
    }

    status=1
    for model in $chain; do
      if attempt "$model" "''${message[@]}"; then
        status=0
        break
      fi
      echo "oc: $(''${model:-(default model)}) failed; trying the next model" >&2
    done
    # shellcheck disable=SC2181
    if [ "$status" -ne 0 ]; then
      echo 'oc: every model in the chain failed. Last error (see ~/.local/state/oc-front/):' >&2
      cat "$state/last-error.txt" >&2
    fi
    exit "$status"
  '';
in
{
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
