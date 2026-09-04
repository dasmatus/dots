"""Read ollama's HTTP API for dots-ask-offline.

Two questions the shell cannot answer without a JSON parser, and neither
jq nor python is on this machine's PATH by default, which is why this
arrives through writeShellApplication's runtimeInputs.

    tags        list installed models as "SIZE NAME", largest first
    pull-size   print a model's real download size without downloading it

`pull-size` is the interesting one. /api/pull streams a manifest and
reports total bytes before any layer moves, so the stream can be read for
that number and then dropped. That is what lets the caller refuse a model
that would not fit before spending the bandwidth, rather than carrying a
table of sizes that drifts on every model release.

Usage, from nix/home/ask-tools.nix:
    curl -sf "$HOST/api/tags" | python3 ask-ollama.py tags
    curl -sf -X POST "$HOST/api/pull" -d ... | python3 ask-ollama.py pull-size
"""

import json
import sys


def tags():
    """Print installed models as "SIZE NAME", largest first."""
    try:
        data = json.load(sys.stdin)
    except (ValueError, OSError):
        # No ollama, or nothing installed. An empty list is the honest
        # answer; the caller decides whether that is fatal.
        return
    rows = (
        (model.get("size", 0), model.get("name", ""))
        for model in data.get("models", [])
    )
    for size, name in sorted(rows, reverse=True):
        if name:
            print(size, name)


def pull_size():
    """Print the first total-bytes figure the pull stream reports."""
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if message.get("error"):
            # An unknown tag, or a registry that refused. Exit non-zero so
            # the caller moves to the next candidate instead of treating
            # silence as a size of zero.
            sys.exit(1)
        total = message.get("total")
        if total:
            print(total)
            return
    # The stream ended without ever reporting a total.
    sys.exit(1)


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: ask-ollama.py {tags|pull-size}")
    if sys.argv[1] == "tags":
        tags()
    elif sys.argv[1] == "pull-size":
        pull_size()
    else:
        sys.exit("unknown subcommand: %s" % sys.argv[1])


if __name__ == "__main__":
    main()
