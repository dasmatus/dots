"""Stat, prune and encode the ask pane's file index.

Reads NUL-separated absolute paths on stdin, writes one JSON object per
line to stdout, and writes a meta file recording what it pruned.

The pruning decision lives here rather than in a list of directory names
because a hand-written exclude list goes stale the moment a toolchain
starts caching somewhere new. This walks once, counts where the files
actually are, and drops the heaviest directories until the result fits the
budget its caller measured from free disk.

Shell cannot do this part: a path may hold a quote or a backslash, and one
malformed line would break the daemon's whole-file parse.

Usage, from nix/home/ask-tools.nix:
    fd ... --print0 | python3 ask-index.py BUDGET ROOT META_PATH
    python3 ask-index.py --summary META_PATH
"""

import json
import os
import sys
from collections import Counter

# Files are bucketed by their directory at this depth. Deeper would prune a
# single project rather than a category, which is not a call this should
# make on someone's behalf.
KEY_DEPTH = 3


def summarise(meta_path):
    """Print the human-readable result of a previous run."""
    with open(meta_path) as fh:
        meta = json.load(fh)
    print(
        "indexed %d of %d files under %s"
        % (meta["entries"], meta["seen"], meta["root"])
    )
    if meta["unreadable"]:
        print("skipped %d unreadable" % meta["unreadable"])
    for pruned in meta["pruned"]:
        print(
            "pruned %s (%d files, over the %d budget)"
            % (pruned["dir"], pruned["files"], meta["budget"])
        )


def bucket(path, root):
    """Return the directory key a path is counted against."""
    parts = os.path.relpath(path, root).split(os.sep)[:KEY_DEPTH]
    return os.sep.join(parts[:-1]) if len(parts) > 1 else ""


def main():
    if sys.argv[1] == "--summary":
        summarise(sys.argv[2])
        return

    budget, root, meta_path = int(sys.argv[1]), sys.argv[2], sys.argv[3]

    entries = []
    per_key = Counter()
    unreadable = 0

    for raw in sys.stdin.buffer.read().split(b"\0"):
        if not raw:
            continue
        try:
            stat = os.stat(raw)
        except OSError:
            # Vanished between the walk and the stat, or not statable by
            # this user. Neither is worth failing the whole index over.
            unreadable += 1
            continue
        path = os.fsdecode(raw)
        key = bucket(path, root)
        entries.append((path, stat.st_size, int(stat.st_mtime), key))
        per_key[key] += 1

    # Over budget: drop whole directories worst first until it fits.
    # Dropping the heaviest keeps a cache from crowding out a documents
    # tree; dropping at random would not.
    pruned = []
    remaining = len(entries)
    if remaining > budget:
        for key, count in per_key.most_common():
            if remaining <= budget:
                break
            # Never prune the root bucket. Files directly in the home
            # directory are the most likely to be asked about.
            if key == "":
                continue
            pruned.append({"dir": key, "files": count})
            remaining -= count

    dropped = {entry["dir"] for entry in pruned}
    written = 0
    out = sys.stdout
    for path, size, mtime, key in entries:
        if key in dropped:
            continue
        ext = os.path.splitext(path)[1]
        out.write(
            json.dumps(
                {
                    "path": path,
                    "name": os.path.basename(path),
                    "ext": ext[1:].lower(),
                    "size": size,
                    "mtime": mtime,
                },
                ensure_ascii=False,
            )
            + "\n"
        )
        written += 1

    with open(meta_path, "w") as fh:
        json.dump(
            {
                "entries": written,
                "seen": len(entries),
                "unreadable": unreadable,
                "budget": budget,
                "root": root,
                "pruned": pruned,
                "note": (
                    "pruned directories were chosen by file count at this "
                    "run, not from a list in the source"
                ),
            },
            fh,
            indent=2,
        )


if __name__ == "__main__":
    main()
