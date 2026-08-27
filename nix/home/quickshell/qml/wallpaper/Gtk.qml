// Regenerates the GTK 3/4 accent-override stylesheets for the current
// wallpaper accent, tint.rs's gtk_css targets — cheap text, so every pick
// rewrites both unconditionally, the same "always regenerate" call
// apply_tint_ctx made for gtk (unlike Kvantum/icons, which it only redid on
// an actual accent change).
//
// Written under Theme.tintStateDir, not into ~/.config/gtk-3.0 or
// gtk-4.0: nothing reads an @import of these files yet — home.nix's own
// gtk.theme still pins plain adw-gtk3-dark, and wiring the @import is its
// own later change, not this one. This only has to make sure the files
// exist and stay current so that later wiring is a one-line home-manager
// change instead of also needing a shell-side rewrite too.
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import "tint.js" as Tint
import ".."

Item {
    id: root

    function write(accent, accentDark, accentLight) {
        // mkdir -p inline rather than depending on Picker's own tint-state
        // mkdir having already run first: each Process here is independent,
        // so an unwritable or missing tint dir fails only this write,
        // whichever of the two happens to run first.
        gtk3.command = ["sh", "-c", 'mkdir -p "$(dirname "$2")" && printf \'%s\' "$1" > "$2"', "_", Tint.gtkCss(accent, accentDark, accentLight, 3), Theme.tintStateDir + "/gtk3.css"];
        gtk3.running = true;

        gtk4.command = ["sh", "-c", 'mkdir -p "$(dirname "$2")" && printf \'%s\' "$1" > "$2"', "_", Tint.gtkCss(accent, accentDark, accentLight, 4), Theme.tintStateDir + "/gtk4.css"];
        gtk4.running = true;
    }

    Process {
        id: gtk3
    }

    Process {
        id: gtk4
    }
}
