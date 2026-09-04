# Proton Drive two-way sync, scoped by document type rather than by directory.
#
# rclone is the sync engine, not proton-cli. nixpkgs' `proton-cli`
# (roman-16/proton-cli, wired up in proton-calendar.nix) exposes `drive items`
# verbs copy/delete/download/info/list/move/rename/revisions/trash/upload —
# all per-file, with no sync, mount or bisync anywhere in the command tree.
# rclone's `protondrive` backend plus `bisync` is the only thing in nixpkgs
# that keeps two trees reconciled, so Drive is rclone's job and proton-cli is
# left to the calendar.
#
# The requested scope was "everywhere that could hold documents and
# presentations". Measured on this machine that is emphatically not a
# directory list: 66 of the 68 real office documents sit under
# ~/Dokumente/schule, while a naive whole-of-~/Dokumente sweep also picks up
# the git checkouts in codeberg/github/gitlab — including ~15 copies of this
# repo under .claude/worktrees, each carrying the same 30 planning .md files.
# So the pairing is root x extension filter: sync every root a document could
# land in, but only files that actually are documents. A new .odp dropped
# anywhere in scope is picked up on the next run with no config change, and
# the 4.8 GB of ISOs and tarballs in ~/Downloads never moves.
#
# Verified against the live tree with `rclone ls --filter-from`: the filter
# selects 66 files / 42 MiB, all under ~/Dokumente/schule, and zero files
# that git tracks. The other four roots match nothing today and exist so a
# document dropped on the desktop tomorrow is picked up without an edit here.
#
# ---------------------------------------------------------------------------
# Why the remote is NOT declared with home-manager's `programs.rclone`
#
# It would be the obvious move — that module even has a `secrets` option that
# keeps passwords out of the Nix store. It is also actively wrong here, and
# would break login every boot.
#
# rclone's protondrive backend is stateful. After a successful SRP login it
# writes the session back into rclone.conf itself — backend/protondrive.go
# setConfigMap() m.Set()s client_uid, client_access_token, client_refresh_token
# and client_salted_key_pass, and authHandler() re-persists them on every
# token refresh. Those four keys are what let later runs skip the 2FA prompt.
#
# home-manager's module publishes the config with `mv -f "$stagingPath"
# "$configPath"` from rclone-config.service, which is WantedBy default.target
# — so it re-renders rclone.conf from the Nix store at every activation AND
# every boot. Declaring the remote there would therefore delete the cached
# session on a schedule, and each recovery needs a fresh 2FA code, which no
# timer can supply. rclone must own its own config file, so it does.
#
# The one-time setup is correspondingly imperative:
#
#   rclone config create protondrive protondrive \
#     username you@proton.me password 'account-password' 2fa 123456
#
# Nothing else is needed afterwards: no password lives in the Nix store, in
# this repo, or in /var/lib/dots, because after that first login the cached
# tokens in ~/.config/rclone/rclone.conf are the credential. If the session
# is ever invalidated (password change, revoked session), re-run the same
# command with a fresh code.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Roots are keyed by the Drive folder they map to. Each pair gets its own
  # bisync state, so a conflict or a forced resync in one never disturbs the
  # others. German XDG names (this is a de_DE session, see user-dirs.dirs)
  # are spelled out rather than derived, because xdg.userDirs is not enabled
  # in this profile and the names would otherwise be English defaults.
  roots = {
    Dokumente = "${config.home.homeDirectory}/Dokumente";
    Schreibtisch = "${config.home.homeDirectory}/Schreibtisch";
    Downloads = "${config.home.homeDirectory}/Downloads";
    Vorlagen = "${config.home.homeDirectory}/Vorlagen";
    Oeffentlich = "${config.home.homeDirectory}/Öffentlich";
  };

  # Extensions that count as "a document or a presentation", plus the notes
  # and spreadsheet formats that travel with them. Case-insensitive: rclone
  # patterns are case-sensitive by default, and the scanned tree held both
  # .docx and .PDF, so each glob is written with a brace alternation.
  documentGlobs = [
    "odt"
    "ott"
    "doc"
    "docx"
    "rtf" # word processing
    "odp"
    "otp"
    "ppt"
    "pptx" # presentations
    "ods"
    "xls"
    "xlsx"
    "csv" # spreadsheets
    "pdf"
    "epub"
    "djvu" # fixed layout
    "tex"
    "bib" # LaTeX sources
    # NB no "md"/"org": measured against the real tree they matched 549 files
    # (repo READMEs, CLAUDE.md, mdbook sources, blog drafts) against 68 actual
    # documents. Markdown here is source, not a document.
  ];

  caseInsensitiveGlob =
    ext:
    "+ *.{"
    + lib.concatStringsSep "," [
      (lib.toLower ext)
      (lib.toUpper ext)
    ]
    + "}";

  # Directory exclusions come first: rclone filter files are first-match-wins,
  # so a `- .git/**` line only wins if nothing above it already matched. The
  # .claude and .superpowers entries are what keep the worktree copies of this
  # repo's planning docs (30 .md files x ~15 worktrees) out of Drive.
  filtersFile = pkgs.writeText "proton-drive-filters.txt" (
    lib.concatStringsSep "\n" (
      [
        "# Directories that must never sync, whatever they contain."
        "- .git/**"
        "- .jj/**"
        "- .svn/**"
        "- node_modules/**"
        "- .direnv/**"
        "- .devenv/**"
        "- target/**"
        "- result/**"
        "- .cache/**"
        "- .venv/**"
        "- __pycache__/**"
        "- .claude/**"
        "- .superpowers/**"
        "- .Trash-*/**"
        "- .stversions/**"
        ""
        "# Forge checkouts under ~/Dokumente. These are code, not documents,"
        "# and two-way sync into a live working tree is how you corrupt one."
        "# Anchored with a leading / so only the ~/Dokumente roots match, not"
        "# a stray directory of the same name elsewhere. Add a root here when"
        "# you clone another forge; blog/, schule/, incubator/ and iso/ stay"
        "# in scope. Without these three, a .csv and an .xlsx vendored inside"
        "# a cloned third-party repo were the only files that leaked."
        "- /codeberg/**"
        "- /github/**"
        "- /gitlab/**"
        ""
        "# Everything below is an allow-list of document formats."
      ]
      ++ map caseInsensitiveGlob documentGlobs
      ++ [
        ""
        "# Anything the allow-list did not claim stays local."
        "- **"
      ]
    )
  );

  # A per-pair sentinel, not an rclone-side check, decides whether this run
  # needs --resync. bisync refuses to run without prior state (and also after
  # the filters file changes, since it hashes it), and the recovery for both
  # is the same first-run reconcile. Keying the sentinel on the filters file's
  # store path means editing documentGlobs above automatically triggers
  # exactly one resync per pair rather than a permanent hard failure at every
  # wake-up.
  syncStateDir = "${config.xdg.stateHome}/proton-drive";
  filtersTag = builtins.substring 0 12 (baseNameOf filtersFile);

  mkBisyncScript =
    name: localPath:
    pkgs.writeShellApplication {
      name = "proton-drive-bisync-${lib.toLower name}";
      runtimeInputs = [
        pkgs.rclone
        pkgs.coreutils
      ];
      text = ''
        local_path=${lib.escapeShellArg localPath}
        remote_path=${lib.escapeShellArg "protondrive:${name}"}
        sentinel=${lib.escapeShellArg "${syncStateDir}/${name}.${filtersTag}"}

        # A root that does not exist yet is not an error: the XDG dirs are
        # created lazily by the desktop, and an absent ~/Vorlagen should skip
        # rather than fail the whole timer.
        if [ ! -d "$local_path" ]; then
          echo "proton-drive: $local_path does not exist, skipping" >&2
          exit 0
        fi

        # No remote configured yet means the one-time `rclone config create`
        # in this file's header has not been run. Say so once and exit clean,
        # rather than failing every 15 minutes with an opaque backend error.
        if ! rclone listremotes | grep -qx 'protondrive:'; then
          echo "proton-drive: no 'protondrive' remote configured; see nix/home/proton/proton-drive.nix" >&2
          exit 0
        fi

        mkdir -p ${lib.escapeShellArg syncStateDir}

        # --conflict-resolve newer: when the same document changed on both
        # sides between runs, the later edit wins instead of bisync parking
        # both copies as .conflict1/.conflict2 files the user must merge by
        # hand. --max-delete 25 is the blast-radius cap: a genuine mass
        # deletion aborts the run and asks for a human, which is what we want
        # when the alternative is silently emptying a Drive folder.
        common_args=(
          --filters-file ${lib.escapeShellArg filtersFile}
          --conflict-resolve newer
          --max-delete 25
          --resilient
          --recover
          --create-empty-src-dirs
        )

        if [ ! -e "$sentinel" ]; then
          echo "proton-drive: first run for ${name}, performing --resync" >&2
          # --resync-mode newer rather than the path1 default: on a first
          # reconcile neither side is authoritative, and preferring the newer
          # copy avoids a stale local file overwriting a fresher Drive one.
          rclone bisync "$local_path" "$remote_path" \
            "''${common_args[@]}" --resync --resync-mode newer
          touch "$sentinel"
        else
          rclone bisync "$local_path" "$remote_path" "''${common_args[@]}"
        fi
      '';
    };
in
{
  home.packages = [ pkgs.rclone ];

  systemd.user.services = lib.mapAttrs' (
    name: localPath:
    lib.nameValuePair "proton-drive-${lib.toLower name}" {
      Unit = {
        Description = "Proton Drive two-way sync for ${name}";
        After = [ "network-online.target" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = lib.getExe (mkBisyncScript name localPath);
        # Sync is background work behind whatever the user is actually doing.
        IOSchedulingClass = "idle";
        Nice = 10;
      };
    }
  ) roots;

  systemd.user.timers = lib.mapAttrs' (
    name: _:
    lib.nameValuePair "proton-drive-${lib.toLower name}" {
      Unit.Description = "Schedule Proton Drive sync for ${name}";
      Timer = {
        # A randomised delay so a laptop resuming from suspend does not fire
        # all five pairs into the same second and trip Proton's rate limits.
        OnBootSec = "3m";
        OnUnitActiveSec = "15m";
        RandomizedDelaySec = "2m";
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    }
  ) roots;
}
