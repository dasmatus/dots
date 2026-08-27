// Recolors the Catppuccin Kvantum (Qt) theme to the current wallpaper
// accent — tint.rs's tint_kvantum_tree + recolor_kvantum_text +
// select_kvantum, ported the way Icons.qml ports the icon side: the
// Nix-store base ships read-only, so this cp -r's it into a writable copy
// before touching it.
//
// Kvantum finds a theme by directory name matching both its .kvconfig and
// its .svg (`<X>/<X>.kvconfig`, `<X>/<X>.svg`) — not by content — so the
// base theme's own files (catppuccin-frappe-blue.kvconfig/.svg) are
// renamed to WallpaperTint.* as part of the same copy step, before
// recolorKvantumText ever runs on them.
//
// Every retint() re-copies from the pristine store base rather than
// recoloring whatever the last retint left in the destination, for the
// same reason Icons.qml's own header gives for MoreWaita:
// recolorKvantumText only matches the three original
// Catppuccin-Frappe-Blue hexes, so recoloring an already-recolored file
// would match nothing.
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "tint.js" as Tint
import ".."

Item {
    id: root

    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")
    readonly property string dest: root.configHome + "/Kvantum/WallpaperTint"
    readonly property string selectFile: root.configHome + "/Kvantum/kvantum.kvconfig"
    // Theme.kvantumBase is always a Nix store path, so it never ends in
    // "/" — the segment after the last "/" is always the theme's own file
    // base name (e.g. "catppuccin-frappe-blue").
    readonly property string baseName: Theme.kvantumBase.slice(Theme.kvantumBase.lastIndexOf("/") + 1)

    property string pendingAccent: ""
    property string pendingDark: ""
    property string pendingLight: ""

    function retint(accent, accentDark, accentLight) {
        root.pendingAccent = accent;
        root.pendingDark = accentDark;
        root.pendingLight = accentLight;

        // Every path travels in argv, not interpolated into the script
        // text (see Icons.qml's own ensureTree for why). `test -d` failing
        // — a missing or unreadable kvantumBase — short-circuits the whole
        // `&&` chain before anything is written: this target is skipped,
        // nothing downstream of this Process ever runs, and no other tint
        // target is affected.
        ensureTree.command = ["sh", "-c", 'test -d "$1" && mkdir -p "$(dirname "$2")" && rm -rf "$2" && cp -r "$1" "$2" && chmod -R u+w "$2" && mv "$2/$3.kvconfig" "$2/WallpaperTint.kvconfig" && mv "$2/$3.svg" "$2/WallpaperTint.svg"', "_", Theme.kvantumBase, root.dest, root.baseName];
        ensureTree.running = true;
    }

    Process {
        id: ensureTree

        // qmllint disable signal-handler-parameters
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0)
                return;
            readKvconfig.running = true;
        }
        // qmllint enable signal-handler-parameters
    }

    // Read via a spawned `cat` (as Icons.qml's own readSvg does), not
    // FileView.text(): only the WRITE side needs to move off argv below,
    // and a Process's stdout has no size limit the way its own argv does.
    Process {
        id: readKvconfig

        command: ["cat", root.dest + "/WallpaperTint.kvconfig"]

        stdout: StdioCollector {
            onStreamFinished: {
                kvconfigWriter.path = root.dest + "/WallpaperTint.kvconfig";
                kvconfigWriter.setText(Tint.recolorKvantumText(this.text, root.pendingAccent, root.pendingDark, root.pendingLight));
            }
        }
    }

    // Written through FileView, not a spawned `sh -c printf '%s' "$1"` the
    // way Icons.qml's per-icon writeSvg is: that puts the whole recolored
    // file in a single argv entry, which is fine for a ~1KB icon SVG but
    // silently fails to even spawn for the Kvantum theme's ~150KB SVG —
    // found by diffing this file's own output against the expected accent
    // and finding the pristine, un-recolored bytes still there with no error
    // surfaced anywhere but a QProcess "Process failed to start" log line.
    FileView {
        id: kvconfigWriter

        onSaved: {
            readSvg.running = true;
        }
    }

    Process {
        id: readSvg

        command: ["cat", root.dest + "/WallpaperTint.svg"]

        stdout: StdioCollector {
            onStreamFinished: {
                svgWriter.path = root.dest + "/WallpaperTint.svg";
                svgWriter.setText(Tint.recolorKvantumText(this.text, root.pendingAccent, root.pendingDark, root.pendingLight));
            }
        }
    }

    FileView {
        id: svgWriter

        onSaved: {
            selectTheme.running = true;
        }
    }

    // Points Kvantum at the freshly-tinted theme. Only takes effect for an
    // app started afterward — same live-reload limitation Icons.qml's
    // dconf write has — so this runs unconditionally rather than guarding
    // on retint() having run first.
    Process {
        id: selectTheme

        command: ["sh", "-c", 'mkdir -p "$(dirname "$1")" && printf "[General]\\ntheme=WallpaperTint\\n" > "$1"', "_", root.selectFile]
    }
}
