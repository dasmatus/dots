// Recolors the Papirus-Dark icon theme's folder icons to the current
// wallpaper accent.
//
// Papirus does not encode folder colour as a hex to find-and-replace the
// way MoreWaita's Adwaita-blue family used to (see git history for that
// SVG rewrite, now gone): it ships one prebuilt SVG per named folder
// colour and points the plain icon name at one of them by symlink. So
// retint() no longer reads or rewrites any SVG bytes. It resolves the
// nearest colour NAME (Tint.nearestPapirusColor) and re-points symlinks in
// a thin theme that otherwise inherits everything else from the store's
// Papirus-Dark.
//
// Theme.papirusBase (a Papirus-Dark store path) is read-only, so this seeds
// $XDG_DATA_HOME/icons/Papirus-Tint by copying out just the
// Theme.papirusTintSizes <size>/places directories, rather than the whole
// theme. That's the same list tree.nix generates Theme.papirusTintIndex's
// own Directories key from, so the two cannot drift apart. Every other
// icon resolves through that index's Inherits=Papirus-Dark,Papirus,hicolor.
// `cp -aL`, not `cp -a`: Papirus-Dark/<size> is itself a symlink to
// ../Papirus/<size> (shared with the light variant), so a link-preserving
// copy would leave the seeded tree's places/ dangling the moment dst is
// treated as free-standing, and papirus-folders (below) explicitly skips
// symlinks when it scans for folder-<colour>-*.svg to retarget.
//
// The seed is guarded on a stamp file holding the source store path, not on
// `test -d`: a `test -d` guard is why the old MoreWaita-Tint tree was
// seeded exactly once and never re-checked afterwards. A Papirus version
// bump has to re-seed, and only comparing against the path actually seeded
// from (not just "does dst already exist") catches that.
//
// Recolouring goes through upstream's own papirus-folders rather than an
// open-coded symlink loop. Verified against a scratch copy under /tmp (not
// the live ~/.local/share/icons) before committing to it: `--theme <path>`
// accepts a bare directory, and Papirus-Tint's name is inferred from the
// path's own basename, so papirus-folders' DEFAULT_COLORS map, which is
// keyed by theme name, never comes into play, because it is only consulted
// by the revert/-D path, never by -C; `-C <colour> -o` symlinks both the
// `folder-<colour>` and `user-<colour>` prefixes across all five sizes in
// one pass; re-running with a different colour repoints the existing
// symlinks instead of failing. `-o` does not stop papirus-folders from
// touching its own config file: `config --new` unconditionally `rm -f`s
// `~/.config/papirus-folders/keep` before `-o`'s ONCE guard is even
// reached; only the following `--set`, which would recreate that file with
// `theme=... color=...`, is what `-o` actually skips (papirus-folders
// 220-232). So every retint() call still removes a stray keep file rather
// than leaving one behind. That's harmless, since nothing downstream of
// this file ever reads that config back.
//
// The rebuild branch of the seed stages into a sibling `$dst.new` and only
// `rm -rf`s the live `$dst` once that sibling is fully populated, right
// before the one `mv` that swaps it in. It never rewrites `$dst` in
// place. This is the one place in the pipeline that can destroy a
// previously working tree (a version bump means the stamp mismatches, so
// `$dst` gets rebuilt, not just created), so a `cp`/`mkdir` failure partway
// through must not be allowed to leave `$dst` half-overwritten or missing
// altogether; staging means the live tree is never in a worse state than
// "unchanged" until the very last, all-but-guaranteed-to-succeed step.
//
// Every step downstream of a failure is skipped, and retinted(), which
// Picker.qml treats as "the theme has been applied", never fires past
// one: see each Process's own onExited below for why.
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "tint.js" as Tint
import ".."

Item {
    id: root

    // XDG_DATA_HOME is set by home-manager's session environment in
    // practice, but a bare XDG-compliant session may not export it, so the
    // spec's own default is the fallback rather than an empty path.
    readonly property string dataHome: Quickshell.env("XDG_DATA_HOME") || (Quickshell.env("HOME") + "/.local/share")
    readonly property string dest: root.dataHome + "/icons/Papirus-Tint"

    // Fires once dconf has been told about the theme, so a caller (the
    // picker) can chain the next step without guessing how long a seed
    // plus symlink pass takes.
    signal retinted()

    function retint(accent) {
        const colorName = Tint.nearestPapirusColor(accent, Theme.papirusColors);

        // Every path (and the size list) travels in argv (positional
        // $1/$2/$3/$4), never interpolated into the script text, so none of
        // them can break the quoting no matter what a future store path or
        // XDG override happens to contain. See this file's own header for
        // why the guard, the copy and the staged rebuild are shaped the way
        // they are. `set -e` plus the EXIT trap is what makes the staging
        // actually safe: any failing step (a `mkdir`, a `cp`) aborts the
        // script immediately, the trap removes the half-built `$dst.new`
        // on the way out, and `$dst` itself is never touched until the
        // `rm -rf "$dst" && mv "$tmp" "$dst"` pair right at the end. By
        // that point, everything that could fail already has not.
        ensureTree.command = ["sh", "-c", `
set -e
src=$1; dst=$2; idx=$3; sizes=$4
if [ "$(cat "$dst/.dots-source" 2>/dev/null)" != "$src" ]; then
  tmp="$dst.new"
  trap 'rm -rf "$tmp"' EXIT
  rm -rf "$tmp"
  # $sizes is deliberately unquoted: it is "22x22 24x24 ..." (see
  # Theme.papirusTintSizes, tree.nix), and word-splitting on the shell's
  # default IFS is what turns that one string back into the size list this
  # loop iterates.
  for s in $sizes; do
    mkdir -p "$tmp/$s"
    cp -aL "$src/$s/places" "$tmp/$s/places"
  done
  cp "$idx" "$tmp/index.theme"
  chmod -R u+w "$tmp"
  printf '%s' "$src" > "$tmp/.dots-source"
  rm -rf "$dst"
  mv "$tmp" "$dst"
fi
`, "_", Theme.papirusBase, root.dest, Theme.papirusTintIndex, Theme.papirusTintSizes];
        // colorName is resolved once, up front, and baked into this
        // command now rather than threaded through onExited state: unlike
        // the old per-file SVG queue, nothing here needs data that only
        // exists after ensureTree has run.
        recolor.command = [Theme.papirusFolders, "--theme", root.dest, "-C", colorName, "-o"];
        ensureTree.running = true;
    }

    Process {
        id: ensureTree

        // qmllint disable signal-handler-parameters
        onExited: (exitCode, exitStatus) => {
            // A failed seed (source unreadable, disk full mid-copy, ...)
            // must not fall through to papirus-folders or dconf: the old
            // MoreWaita pipeline's unconditional dconf write was
            // defensible because its `test -d` guard meant the tree was
            // seeded once and never destroyed, so "the seed step ran" was
            // always true from the second retint() onward. This seed can
            // rebuild. Per the header above, it stages that rebuild rather
            // than doing it in place, but a caller still has no business
            // being told the theme changed when it didn't.
            if (exitCode !== 0)
                return;
            recolor.running = true;
        }
        // qmllint enable signal-handler-parameters
    }

    // The upstream tool that points a folder's plain icon name at its
    // colour-suffixed variant by symlink, e.g. folder.svg -> folder-<name>.svg
    // (and the same for user-<name>). See this file's header for why this is
    // upstream's own tool rather than an open-coded loop.
    Process {
        id: recolor

        // qmllint disable signal-handler-parameters
        onExited: (exitCode, exitStatus) => {
            // Same contract as ensureTree's own guard just above: a
            // papirus-folders failure (an unrecognised colour name, an
            // unwritable tree) means the folders were never actually
            // repointed, so dconf must not be told otherwise.
            if (exitCode !== 0)
                return;
            applyTheme.running = true;
        }
        // qmllint enable signal-handler-parameters
    }

    // Papirus-Tint follows the same on-disk icon-theme layout GNOME already
    // reads (index.theme and all); only the name and location differ from
    // the store's Papirus-Dark. So the switch is one write, no new theme
    // spec needed, and this Process itself never checks that the directory
    // named here exists. GNOME falls back to visually rendering whatever
    // it last found if it doesn't, and the write itself never errors
    // either way. It IS gated on the two Process steps above having both
    // succeeded, though (see their onExited handlers and the header
    // comment). That guard is about not lying to the caller, not about
    // dconf needing the directory to be there.
    //
    // dconf write, not gsettings set: this session has dconf on PATH (the
    // dconf.enable HM option, plus the NixOS module) but no gsettings
    // binary anywhere in either profile. glib's gsettings only exists as a
    // transitive build output nobody links into $PATH. dconf writes the
    // same key gsettings would through the schema, just spelled as a
    // GVariant string literal (the quotes inside the argument are part of
    // that literal, not shell quoting).
    Process {
        id: applyTheme

        command: ["dconf", "write", "/org/gnome/desktop/interface/icon-theme", "'Papirus-Tint'"]

        // qmllint disable signal-handler-parameters
        onExited: (exitCode, exitStatus) => {
            // retinted() means "the theme has been applied" to
            // Picker.qml. Closing out the same contract the two Process
            // handlers above start, it only fires once dconf has actually
            // recorded the change, not merely been asked to.
            if (exitCode === 0)
                root.retinted();
        }
        // qmllint enable signal-handler-parameters
    }
}
