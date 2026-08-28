// Recolors the MoreWaita icon theme to the current wallpaper accent.
//
// tint.rs walked the Nix-store MoreWaita tree in place. That tree
// (Theme.moreWaitaBase, baked in by tree.nix) is read-only, so this instead
// `cp -r`s it once into $XDG_DATA_HOME/icons/MoreWaita-Tint, then
// `chmod -R u+w` — the same step tree.nix's own runCommand needs and for the
// same reason: a copy out of the store inherits the store's unwritable mode
// bits verbatim, so a plain `cp -r` here would hand back a tree this file
// can't then write into.
//
// Every retint() re-reads the 240 blue-bearing SVGs from that pristine base
// rather than from whatever the last retint left in the destination:
// recolorIconText's regex only matches the six original Adwaita blues, so
// recoloring an already-recolored file would match nothing and the icon
// theme would freeze on the first accent it was ever given.
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
    readonly property string dest: root.dataHome + "/icons/MoreWaita-Tint"

    property string pendingAccent: ""
    property var pendingFiles: []
    property string pendingSrc: ""

    // Fires once gsettings has been told about the theme, so a caller (the
    // picker) can chain the next step without guessing how long a 240-file
    // rewrite takes.
    signal retinted()

    function retint(accent) {
        root.pendingAccent = accent;
        // Both paths travel in argv (positional $1/$2), not interpolated into
        // the script text, so neither can break the quoting no matter what a
        // future store path or XDG override happens to contain.
        ensureTree.command = ["sh", "-c", 'test -d "$2" || { cp -r "$1" "$2" && chmod -R u+w "$2"; }', "_", Theme.moreWaitaBase, root.dest];
        ensureTree.running = true;
    }

    Process {
        id: ensureTree

        // qmllint disable signal-handler-parameters
        onExited: (exitCode, exitStatus) => {
            listBlues.running = true;
        }
        // qmllint enable signal-handler-parameters
    }

    // -Z null-terminates the match list: SVG filenames never contain a
    // newline in practice, but nothing here needs to assume that. -i matches
    // the plan's own workload check (`grep -rlic`), which is
    // case-insensitive; tint.rs's SVGs are all lowercase hex, but a future
    // upstream release is not this file's business to assume about.
    Process {
        id: listBlues

        command: ["grep", "-rliZ", "-E", Tint.ADWAITA_BLUE_HEXES.join("|"), Theme.moreWaitaBase]

        stdout: StdioCollector {
            onStreamFinished: {
                root.pendingFiles = this.text.length === 0 ? [] : this.text.split("\0").filter(p => p.length > 0);
                root.rewriteNext();
            }
        }
    }

    // One file at a time rather than 240 processes in flight: a wallpaper
    // pick is not a hot path, and a queue drained by chained onExited
    // handlers needs no dynamic object creation to stay correct.
    function rewriteNext() {
        if (root.pendingFiles.length === 0) {
            applyTheme.running = true;
            return;
        }

        root.pendingSrc = root.pendingFiles[0];
        root.pendingFiles = root.pendingFiles.slice(1);
        readSvg.command = ["cat", root.pendingSrc];
        readSvg.running = true;
    }

    Process {
        id: readSvg

        stdout: StdioCollector {
            onStreamFinished: {
                const recolored = Tint.recolorIconText(this.text, root.pendingAccent);
                const rel = root.pendingSrc.slice(Theme.moreWaitaBase.length);
                writeSvg.command = ["sh", "-c", "printf '%s' \"$1\" > \"$2\"", "_", recolored, root.dest + rel];
                writeSvg.running = true;
            }
        }
    }

    Process {
        id: writeSvg

        // qmllint disable signal-handler-parameters
        onExited: (exitCode, exitStatus) => {
            root.rewriteNext();
        }
        // qmllint enable signal-handler-parameters
    }

    // MoreWaita-Tint follows the same on-disk icon-theme layout GNOME
    // already reads (index.theme and all); only the name and location
    // differ from the store's MoreWaita. So the switch is one write, no new
    // theme spec needed. It stays a no-op if the directory named here is
    // missing — GNOME falls back to visually rendering whatever it last
    // found, the write itself never errors — so this runs unconditionally
    // rather than guarding on retint() having run first.
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

        command: ["dconf", "write", "/org/gnome/desktop/interface/icon-theme", "'MoreWaita-Tint'"]

        // qmllint disable signal-handler-parameters
        onExited: (exitCode, exitStatus) => {
            root.retinted();
        }
        // qmllint enable signal-handler-parameters
    }
}
