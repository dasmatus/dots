# The file manager's `/` used to walk $HOME on every debounced keystroke.
# This builds that walk once, ahead of time, so the search reads a file
# instead of a filesystem.
#
# Measured on this tree, 299569 entries under $HOME: the live walk cost
# 0.24s per query with dotfiles pruned and 0.89s with them shown, against
# 0.00-0.11s for a grep over the index. Building it costs 1.47s.
#
# The output is byte-for-byte the format files/files.js's searchArgv
# already emitted — `%Y\t%s\t%T@\t%P` — because files/index.js hands it
# straight to the same parseListing. Changing the format here silently
# breaks the reader, so it is pinned by tests/qml/tst_files_index.qml.
#
# `%Y` and not `%y`, for the reason files.js gives: it reports the type
# after following a symlink, so a link to a directory is indexed as the
# directory it points at and opens by navigating rather than by xdg-open.
# It costs a stat per entry, which is most of the 1.47s, and that stat is
# also what makes the size and mtime columns free.
{
  pkgs,
  lib,
  config,
  ...
}:

let
  indexDir = "${config.xdg.cacheHome}/dots-shell/files";

  # Two files from one walk. Pruning dotfiles is what separates the 0.24s
  # live walk from the 0.89s one, and deriving the pruned copy here costs
  # 0.05s, so the query never pays for the distinction at all.
  #
  # Both are staged under .new and renamed into place. A reader opening
  # the file mid-build would otherwise see a truncated index and quietly
  # return half a search; rename within one directory is atomic, so it
  # sees either the old index or the new one.
  #
  # The emptiness guard is what stops a `find` that died early from
  # replacing a good index with a stub. Exiting non-zero leaves the
  # previous index in place and puts the failure in the journal.
  builder = pkgs.writeShellScript "dots-files-index" ''
    set -euo pipefail

    # 0600. The index is a full inventory of the user's home directory,
    # and there is no reason for any other account to read it.
    umask 077

    dir=${lib.escapeShellArg indexDir}
    mkdir -p "$dir"

    # `|| true` because find exits non-zero on any unreadable directory,
    # which is a normal state for a home directory, not a failed walk.
    ${pkgs.findutils}/bin/find "$HOME" -mindepth 1 \
      -printf '%Y\t%s\t%T@\t%P\n' > "$dir/all.tsv.new" 2> /dev/null || true

    if [ ! -s "$dir/all.tsv.new" ]; then
      echo "dots-files-index: walk produced nothing, keeping the old index" >&2
      rm -f "$dir/all.tsv.new"
      exit 1
    fi

    # Drops every path with a dot segment in it, which is what
    # `find ( -name '.*' -prune )` did and what files.js's isHidden means
    # by hidden. Verified against that find: both keep 92604 of this
    # tree's 299569 entries.
    #
    # The tab in the pattern is load-bearing and is why it is built here
    # rather than written inline. The path is the line's fourth field, so
    # a name beginning with a dot is preceded by the separator and not by
    # the start of the line: the obvious `(^|/)\.` matches none of them,
    # keeps every top-level dotfile, and leaves visible.tsv a copy of
    # all.tsv. It did exactly that until it was diffed against find.
    tab="$(printf '\t')"

    # Exits 1 when it prints nothing, which for a home directory made
    # entirely of dotfiles is a correct answer rather than an error.
    ${pkgs.gnugrep}/bin/grep -v -E "($tab|/)\\." \
      "$dir/all.tsv.new" > "$dir/visible.tsv.new" || true

    mv -f "$dir/all.tsv.new" "$dir/all.tsv"
    mv -f "$dir/visible.tsv.new" "$dir/visible.tsv"
  '';
in
{
  # WantedBy the shell rather than the session: the index exists only to
  # serve the file manager, so it is built when the thing that reads it
  # starts, and not on a login that never opens one.
  #
  # Nice and idle I/O because this competes with everything else a login
  # is doing. A cold walk of a home directory is I/O bound, and being
  # second in that queue costs the user nothing — the search falls back to
  # a live walk until the index lands.
  systemd.user.services.dots-files-index = {
    Unit = {
      Description = "Index $HOME for the file manager's search";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${builder}";
      Nice = 19;
      IOSchedulingClass = "idle";
    };
    Install = {
      WantedBy = [ "quickshell.service" ];
    };
  };

  # OnUnitActiveSec alone, with no OnBootSec, so the first build is the
  # one the shell's own startup triggers and the timer only ever schedules
  # the refresh after it. A timer that has never seen its unit active does
  # not elapse, which is exactly the wanted behaviour on a session with no
  # shell in it.
  systemd.user.timers.dots-files-index = {
    Unit = {
      Description = "Rebuild the file manager's index";
      PartOf = [ "graphical-session.target" ];
    };
    Timer = {
      OnUnitActiveSec = "10min";
    };
    Install = {
      WantedBy = [ "graphical-session.target" ];
    };
  };
}
