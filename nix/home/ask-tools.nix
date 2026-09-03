# Two helpers the ask pane needs that are not the daemon itself.
#
# `dots-ask-index` builds the pane's file index. The pane is user-wide
# rather than scoped to one checkout, so "what is in my nixos config" has
# to resolve a path before any backend sees it, and walking $HOME per
# question is too slow to do inline.
#
# `dots-ask-offline` answers a question about one file with no account and
# no network, using the ollama already on this box. The pane's default
# backend is the claude CLI, which needs a live session; when there is not
# one, because the subscription lapsed or a spend limit tripped, this is
# what still works.
#
# Neither carries a hardcoded list of what to skip or which model to run.
# The indexer walks once, measures where the files actually are, and prunes
# the heaviest directories itself against a budget derived from free disk.
# The offline helper reads how much memory is free right now, asks ollama
# what is installed and how big those models really are, and picks the
# largest that fits; if none fits it probes each candidate's real download
# size before committing to a pull. A table written in here would be stale
# within a release and wrong on a machine with different memory.
#
# These live in Nix rather than scripts/ because neither python3 nor jq is
# on this machine's PATH, so a standalone script fails partway through with
# a bare "command not found" after doing the expensive part.
# writeShellApplication supplies the dependencies through runtimeInputs and
# runs shellcheck over the text, which is how nix/home/edupage-mcp.nix
# already does it.
#
# The two python programs sit in their own files rather than inline. A
# heredoc inside a Nix indented string has its leading whitespace stripped
# by Nix's own de-indentation, which is exactly the whitespace python needs.
#
# The toggles arrive as the `dots` module argument, not through `config`.
# nix/modules/users.nix hands the NixOS-side projection to home-manager via
# extraSpecialArgs, the way nix/home/ask.nix and nix/home/edupage-mcp.nix read
# it. `config.dots` resolves in this scope too, which is the trap: nix/home/
# session declares options.dots.session, so the wrong spelling fails with
# "attribute 'ai' missing" and reads like the installer answers are broken
# rather than like the wrong `dots` was read.
{
  dots,
  lib,
  pkgs,
  ...
}:
let
  cfg = dots.ai;
  # Same gate as the pane. The offline helper works without an account, but
  # it is part of the pane rather than a general tool, so it follows it.
  enabled = cfg.claude || cfg.codex || cfg.ollama;

  indexPy = ./ask-index.py;
  ollamaPy = ./ask-ollama.py;

  index = pkgs.writeShellApplication {
    name = "dots-ask-index";
    runtimeInputs = with pkgs; [
      fd
      python3
      coreutils
      gawk
    ];
    text = ''
      DATA_HOME=''${XDG_DATA_HOME:-$HOME/.local/share}
      INDEX_DIR=''${DOTS_ASK_INDEX_DIR:-$DATA_HOME/dots-ask/index}
      INDEX="$INDEX_DIR/files.ndjson"
      META="$INDEX_DIR/meta.json"
      ROOT=''${DOTS_ASK_INDEX_ROOT:-$HOME}

      case "''${1:-}" in
        --stats)
          test -f "$INDEX" || { echo "no index at $INDEX" >&2; exit 1; }
          echo "index:   $INDEX"
          echo "entries: $(wc -l <"$INDEX")"
          echo "size:    $(du -h "$INDEX" | cut -f1)"
          exit 0
          ;;
        --explain)
          test -f "$META" || { echo "no meta at $META" >&2; exit 1; }
          cat "$META"
          exit 0
          ;;
        "") ;;
        *) echo "usage: dots-ask-index [--stats|--explain]" >&2; exit 2 ;;
      esac

      mkdir -p "$INDEX_DIR"

      # Budget the index against the filesystem it lives on rather than a
      # number picked in advance. One percent of free space at roughly 200
      # bytes a line is generous for a path index, clamped so a nearly full
      # disk still gets something usable and a huge one does not invite an
      # unbounded walk.
      free_kb=$(df -Pk "$INDEX_DIR" | awk 'NR==2 {print $4}')
      budget=$(( free_kb * 1024 / 100 / 200 ))
      test "$budget" -ge 20000 || budget=20000
      test "$budget" -le 2000000 || budget=2000000

      tmp=$(mktemp "$INDEX_DIR/.files.XXXXXX")
      trap 'rm -f "$tmp" "$tmp.meta"' EXIT

      # fd already honours .gitignore and .ignore, so a repo's own build
      # output is skipped without naming it here. What is left to decide is
      # the unignored bulk: caches, vendored trees, browser profiles. That
      # decision is made from counts, in ask-index.py, not from a list.
      fd --type f --hidden --absolute-path --print0 . "$ROOT" \
        | python3 ${indexPy} "$budget" "$ROOT" "$tmp.meta" >"$tmp"

      # One rename so a reader never sees a half-written index. The daemon
      # reads without locking, on the assumption that it sees either the
      # old file whole or the new one whole.
      mv "$tmp.meta" "$META"
      mv "$tmp" "$INDEX"
      trap - EXIT

      python3 ${indexPy} --summary "$META"
    '';
  };

  offline = pkgs.writeShellApplication {
    name = "dots-ask-offline";
    runtimeInputs = with pkgs; [
      ollama
      curl
      python3
      coreutils
      gawk
    ];
    text = ''
      CONFIG_HOME=''${XDG_CONFIG_HOME:-$HOME/.config}
      CONFIG=''${DOTS_ASK_OFFLINE_CONFIG:-$CONFIG_HOME/dots-ask/offline-models}
      HOST=''${OLLAMA_HOST:-http://127.0.0.1:11434}

      # How much of free memory a model may claim. The rest carries the
      # compositor, the shell and whatever the question is about. Two
      # thirds is where a 16 GB laptop still runs a browser while
      # answering.
      FRACTION=''${DOTS_ASK_OFFLINE_FRACTION:-66}

      mem_avail_kb() { awk '/^MemAvailable:/ {print $2}' /proc/meminfo; }
      mem_total_kb() { awk '/^MemTotal:/ {print $2}' /proc/meminfo; }

      # Try each vendor's tool and take the first that answers. A machine
      # with no discrete GPU reports nothing, which is correct rather than
      # an error.
      vram_bytes() {
        if command -v nvidia-smi >/dev/null 2>&1; then
          nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
            | awk 'NR==1 {print $1 * 1048576; f=1} END {if (!f) print 0}'
        elif command -v rocm-smi >/dev/null 2>&1; then
          rocm-smi --showmeminfo vram --csv 2>/dev/null \
            | awk -F, 'NR==2 {print $2; f=1} END {if (!f) print 0}'
        else
          echo 0
        fi
      }

      budget_bytes() {
        ram=$(( $(mem_avail_kb) * 1024 * FRACTION / 100 ))
        vram=$(vram_bytes)
        # A model that fits entirely in VRAM does not contend with the
        # desktop for RAM, so the larger of the two is the honest ceiling.
        if test "$vram" -gt "$ram"; then echo "$vram"; else echo "$ram"; fi
      }

      human() { numfmt --to=iec --suffix=B "$1"; }

      # Ask ollama what is installed and how big each one really is, rather
      # than carrying a table that drifts on every model update.
      local_models() {
        curl -sf --max-time 5 "$HOST/api/tags" 2>/dev/null \
          | python3 ${ollamaPy} tags
      }

      assess() {
        echo "cpu:     $(nproc) cores"
        echo "memory:  $(human $(( $(mem_total_kb) * 1024 ))) total, $(human $(( $(mem_avail_kb) * 1024 ))) free now"
        v=$(vram_bytes)
        if test "$v" -gt 0; then echo "vram:    $(human "$v")"; else echo "vram:    none detected"; fi
        echo "budget:  $(human "$(budget_bytes)") for a model"
        echo "disk:    $(df -Ph "$HOME" | awk 'NR==2 {print $4}') free on \$HOME"
        if curl -sf --max-time 2 "$HOST/api/tags" >/dev/null 2>&1; then
          echo "ollama:  reachable at $HOST"
        else
          echo "ollama:  NOT reachable at $HOST"
        fi
        echo
        echo "installed models, largest first:"
        b=$(budget_bytes)
        while read -r size name; do
          test -n "$name" || continue
          if test "$size" -le "$b"; then fit="fits"; else fit="too big"; fi
          printf '  %-24s %-10s %s\n' "$name" "$(human "$size")" "$fit"
        done < <(local_models)
      }

      # Seed the candidate list from the families already installed, so the
      # suggestions match what this user already trusts. Written once, then
      # it belongs to the user. Keeping it in a config file rather than in
      # this module is the point: a tag list in Nix would be stale within a
      # release, and would need a rebuild to change.
      seed_config() {
        mkdir -p "$(dirname "$CONFIG")"
        {
          echo "# Candidates for dots-ask-offline, one per line, tried in order."
          echo "# Each one's real download size is probed before any pull, and"
          echo "# the first that fits the measured budget wins. Edit freely."
          local_models | awk '{print $2}' | sed 's/:.*//' | sort -u \
            | while read -r fam; do
                test -n "$fam" && echo "# already installed: $fam"
              done
          echo "qwen3:1.7b"
          echo "llama3.2:3b"
          echo "gemma3:1b"
        } >"$CONFIG"
      }

      # Ask the registry how big a model is WITHOUT downloading it, by
      # reading the manifest the pull stream reports before any layer moves.
      probe_size() {
        curl -sf --max-time 30 -X POST "$HOST/api/pull" \
          -d "{\"model\":\"$1\",\"stream\":true}" 2>/dev/null \
          | python3 ${ollamaPy} pull-size
      }

      pick_model() {
        b=$(budget_bytes)
        # Prefer something already on disk. Pulling when a usable model is
        # already here wastes bandwidth and disk for no gain.
        while read -r size name; do
          if test -n "$name" && test "$size" -le "$b"; then
            echo "$name"
            return 0
          fi
        done < <(local_models)

        test -f "$CONFIG" || seed_config

        while read -r cand; do
          case "$cand" in ""|\#*) continue ;; esac
          if ! probed=$(probe_size "$cand"); then
            echo "could not size $cand, skipping" >&2
            continue
          fi
          if test "$probed" -le "$b"; then
            echo "pulling $cand at $(human "$probed"), within $(human "$b")" >&2
            ollama pull "$cand" >&2
            echo "$cand"
            return 0
          fi
          echo "$cand needs $(human "$probed"), over the $(human "$b") budget" >&2
        done <"$CONFIG"
        return 1
      }

      case "''${1:-}" in
        --assess|"") assess; exit 0 ;;
        --pick)
          pick_model || { echo "nothing fits the measured budget; edit $CONFIG" >&2; exit 1; }
          exit 0
          ;;
      esac

      FILE=$1
      QUESTION=''${2:-Summarise this file. Say what it is for and what stands out.}
      test -f "$FILE" || { echo "not a file: $FILE" >&2; exit 1; }

      model=$(pick_model) || { echo "nothing fits the measured budget; edit $CONFIG" >&2; exit 1; }

      # Size the excerpt against the budget rather than a fixed number of
      # bytes. Roughly four bytes a token, and a small model's context is
      # the binding limit long before the file is.
      excerpt=$(( $(budget_bytes) / 4096 ))
      test "$excerpt" -ge 4000 || excerpt=4000
      test "$excerpt" -le 120000 || excerpt=120000

      actual=$(stat -c %s "$FILE")
      body=$(head -c "$excerpt" "$FILE")
      note=""
      if test "$actual" -gt "$excerpt"; then
        note="[truncated: first $excerpt of $actual bytes]"
      fi

      echo "model: $model" >&2
      ollama run "$model" "$(printf '%s\n' \
        "Answer a question about one file on this machine. Answer only from" \
        "the content shown. If the answer is not in it, say so rather than" \
        "guessing." \
        "" \
        "File: $FILE" \
        "" \
        "--- begin ---" \
        "$body" \
        "--- end ---" \
        "$note" \
        "" \
        "Question: $QUESTION")"
    '';
  };
in
{
  config = lib.mkIf enabled {
    home.packages = [
      index
      offline
    ];

    # Rebuild the index on a timer rather than at every login. A walk of
    # $HOME is cheap with fd but not free, and an index a day stale still
    # resolves the paths people ask about. Persistent so a machine that was
    # off at the scheduled time catches up rather than waiting a full day.
    systemd.user.services.dots-ask-index = {
      Unit.Description = "Rebuild the ask pane's file index";
      Service = {
        Type = "oneshot";
        ExecStart = lib.getExe index;
        Nice = 10;
        IOSchedulingClass = "idle";
      };
    };

    systemd.user.timers.dots-ask-index = {
      Unit.Description = "Rebuild the ask pane's file index daily";
      Timer = {
        OnCalendar = "daily";
        Persistent = true;
        RandomizedDelaySec = "30m";
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
