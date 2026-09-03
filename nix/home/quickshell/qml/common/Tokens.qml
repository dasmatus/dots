// Resolves a palette token NAME to its colour, for the pure `.pragma
// library` modules that classify things but cannot import Theme.
// icons.js, places.js and commands.js all return "blue" or "accent"
// rather than a colour, and this is where that name becomes one.
//
// The table is built by reading every token explicitly. That is the whole
// point of the file: a binding written as `Theme[name]` with a variable
// key does not reliably register a dependency on the property it happens
// to land on, so a wallpaper change would repaint the surfaces that read
// `Theme.accent` directly and leave every dynamically-resolved icon on the
// old colour. Reading each property by name here means the binding depends
// on all of them, and `colourOf` is then a plain lookup on an object QML
// already knows how to invalidate.
//
// A singleton rather than a helper copied into each consumer: Pane, Menu,
// CommandLine and Sidebar all need it, and four copies of the same table
// is how one of them ends up missing a token nobody notices.
pragma Singleton

import QtQuick
import Quickshell
import ".."

Singleton {
    id: root

    readonly property var table: ({
            accent: Theme.accent,
            fg: Theme.fg,
            fgDark: Theme.fgDark,
            muted: Theme.muted,
            dim: Theme.dim,
            blue: Theme.blue,
            cyan: Theme.cyan,
            green: Theme.green,
            magenta: Theme.magenta,
            red: Theme.red,
            yellow: Theme.yellow,
            orange: Theme.orange
        })

    // An unknown name falls back to the foreground rather than throwing or
    // painting nothing. tst_files_icons.qml and tst_files_commands.qml both
    // assert every name those modules can emit is in the table, so a
    // fallback here means a token was added without its test.
    function colourOf(name: string): color {
        const found = root.table[name];
        return found !== undefined ? found : Theme.fg;
    }
}
