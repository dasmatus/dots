// Recolors the Papirus-Dark icon theme's folder icons to the current
// wallpaper accent.
//
// Papirus does not encode folder colour as a hex to find-and-replace the
// way MoreWaita's Adwaita-blue family used to (see git history — that SVG
// rewrite is gone): it ships one prebuilt SVG per named folder colour and
// points the plain icon name at one of them by symlink. So retint() no
// longer reads or rewrites any SVG bytes — it resolves the nearest colour
// NAME (Tint.nearestPapirusColor) and re-points symlinks in a thin theme
// that otherwise inherits everything else from the store's Papirus-Dark.
//
// Theme.papirusBase (a Papirus-Dark store path) is read-only, so this seeds
// $XDG_DATA_HOME/icons/Papirus-Tint by copying out just the five
// <size>/places directories — the ones Theme.papirusTintIndex's own
// Directories key declares — rather than the whole theme; every other icon
// resolves through that index's Inherits=Papirus-Dark,Papirus,hicolor.
// `cp -aL`, not `cp -a`: Papirus-Dark/<size> is itself a symlink to
// ../Papirus/<size> (shared with the light variant), so a link-preserving
// copy would leave the seeded tree's places/ dangling the moment dst is
// treated as free-standing, and papirus-folders (below) explicitly skips
// symlinks when it scans for folder-<colour>-*.svg to retarget.
//
// The seed is guarded on a stamp file holding the source store path, not on
// `test -d`: a `test -d` guard is why the old MoreWaita-Tint tree was
// seeded exactly once and never re-checked afterwards — a Papirus version
// bump has to re-seed, and only comparing against the path actually seeded
// from (not just "does dst already exist") catches that.
//
// Recolouring goes through upstream's own papirus-folders rather than an
// open-coded symlink loop. Verified against a scratch copy under /tmp (not
// the live ~/.local/share/icons) before committing to it: `--theme <path>`
// accepts a bare directory — Papirus-Tint's name is inferred from the
// path's own basename, so papirus-folders' DEFAULT_COLORS map, which is
// keyed by theme name, never comes into play, because it is only consulted
// by the revert/-D path, never by -C; `-C <colour> -o` symlinks both the
// `folder-<colour>` and `user-<colour>` prefixes across all five sizes in
// one pass; re-running with a different colour repoints the existing
// symlinks instead of failing; and `-o` skips writing papirus-folders' own
// persistent config file, so nothing is left behind outside the theme
// directory itself.
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

        // Every path travels in argv (positional $1/$2/$3), never
        // interpolated into the script text, so none of them can break the
        // quoting no matter what a future store path or XDG override
        // happens to contain — see this file's own header for why the
        // guard and the copy are shaped the way they are.
        ensureTree.command = ["sh", "-c", 'src=$1; dst=$2; idx=$3; if [ "$(cat "$dst/.dots-source" 2>/dev/null)" != "$src" ]; then rm -rf "$dst" && for s in 22x22 24x24 32x32 48x48 64x64; do mkdir -p "$dst/$s" && cp -aL "$src/$s/places" "$dst/$s/places" || exit 1; done && cp "$idx" "$dst/index.theme" && chmod -R u+w "$dst" && printf "%s" "$src" > "$dst/.dots-source"; fi', "_", Theme.papirusBase, root.dest, Theme.papirusTintIndex];
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
            applyTheme.running = true;
        }
        // qmllint enable signal-handler-parameters
    }

    // Papirus-Tint follows the same on-disk icon-theme layout GNOME already
    // reads (index.theme and all); only the name and location differ from
    // the store's Papirus-Dark. So the switch is one write, no new theme
    // spec needed. It stays a no-op if the directory named here is missing
    // — GNOME falls back to visually rendering whatever it last found, the
    // write itself never errors — so this runs unconditionally rather than
    // guarding on retint() having run first.
    //
    // dconf write, not gsettings set: this session has dconf on PATH (the
    // dconf.enable HM option, plus the NixOS module) but no gsettings
    // binary anywhere in either profile — glib's gsettings only exists as a
    // transitive build output nobody links into $PATH. dconf writes the
    // same key gsettings would through the schema, just spelled as a
    // GVariant string literal (the quotes inside the argument are part of
    // that literal, not shell quoting).
    Process {
        id: applyTheme

        command: ["dconf", "write", "/org/gnome/desktop/interface/icon-theme", "'Papirus-Tint'"]

        // qmllint disable signal-handler-parameters
        onExited: (exitCode, exitStatus) => {
            root.retinted();
        }
        // qmllint enable signal-handler-parameters
    }
}
