// Stands in for common/Tokens.qml, which is a Quickshell Singleton and so
// out of qmltestrunner's reach for the same reason the sibling Theme.qml
// stub exists. The real one resolves a palette token NAME to a colour by
// reading every Theme property explicitly; the shape a caller sees is one
// function, and that is all this reproduces.
//
// Symlinking the real file instead does not work and does not fail loudly:
// the engine resolves the type to an object with no colourOf on it, and the
// only sign is a "Property 'colourOf' of object Tokens is not a function"
// warning from whichever delegate happened to draw. Which token maps to
// which colour is tst_files_icons.qml's and tst_files_commands.qml's
// question anyway, not this stub's.
pragma Singleton
import QtQuick
import ".."

QtObject {
    id: root

    readonly property var table: ({
            accent: Theme.accent,
            fg: Theme.fg,
            muted: Theme.muted,
            red: Theme.red
        })

    function colourOf(name: string): color {
        const found = root.table[name];
        return found !== undefined ? found : Theme.fg;
    }
}
