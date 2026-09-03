// Rows for the `:` command line and for the right-click menu, kept pure so
// tests/qml/tst_files_commands.qml can drive them with a fixed listing and
// no window.
//
// Copy and Move became yank and cut against a clipboard, then Paste. With
// the second pane gone there is no "the other side" to name as a
// destination, and a single-pane manager that cannot copy anywhere is
// worse than one that remembers what you picked. It is also the shape the
// `:` line already implies: two commands, a directory change between them,
// a third command.
//
// Glyph and colour travel on the row as data, and the caller resolves the
// colour name against Theme, the same split icons.js uses.
.pragma library

.import "icons.js" as Icons

var COPY = "\u{F018F}";
var CUT = "\u{F0190}";
var PASTE = "\u{F0192}";
var RENAME = "\u{F0CB6}";
var MKDIR = "\u{F0257}";
var TRASH = "\u{F0A79}";
var HIDDEN = "\u{F0208}";

// An action that needs a selection is not offered without one, rather than
// offered and silently doing nothing, which is what the old toolbar did.
// `clipboard` is what Paste would land, so Paste stays hidden until there
// is something to land.
function actionRows(selection, clipboard, showHidden) {
    const name = selection ? selection.name : "";
    const rows = [];

    if (selection) {
        rows.push({ kind: "action", id: "copy", title: "Copy", subtitle: name, glyph: COPY, colour: "green" });
        rows.push({ kind: "action", id: "cut", title: "Cut", subtitle: name, glyph: CUT, colour: "yellow" });
        rows.push({ kind: "action", id: "rename", title: "Rename", subtitle: name, glyph: RENAME, colour: "blue" });
    }

    if (clipboard)
        rows.push({ kind: "action", id: "paste", title: "Paste", subtitle: clipboard.name, glyph: PASTE, colour: "accent" });

    rows.push({ kind: "action", id: "mkdir", title: "New Folder", subtitle: "", glyph: MKDIR, colour: "accent" });

    if (selection)
        rows.push({ kind: "action", id: "trash", title: "Trash", subtitle: name, glyph: TRASH, colour: "red" });

    rows.push({
        kind: "action",
        id: "hidden",
        title: showHidden ? "Hide Dotfiles" : "Show Dotfiles",
        subtitle: "",
        glyph: HIDDEN,
        colour: "dim"
    });

    return rows;
}

function entryRows(entries) {
    return entries.map((entry, index) => ({
        kind: "entry",
        id: String(index),
        index: index,
        title: entry.name,
        subtitle: entry.isDir ? "folder" : "file",
        glyph: Icons.glyphFor(entry),
        colour: Icons.colourFor(entry)
    }));
}

// Providers.qml:208's own helper, repeated rather than imported: that file
// is the launcher's provider registry and pulling it in here would drag
// Quickshell, Hyprland and the whole ambient row set into a pure module.
function matches(haystack, needle) {
    return haystack.toLowerCase().includes(needle.toLowerCase());
}

// Prefix matches first, exactly as Launcher.qml sorts its own results, so
// typing "re" reaches Rename before anything merely containing "re".
function filtered(rows, query) {
    const needle = query.trim().toLowerCase();

    if (needle === "")
        return rows;

    return rows.filter(row => matches(row.title, needle)).sort((a, b) => {
        const aPrefix = a.title.toLowerCase().startsWith(needle) ? 0 : 1;
        const bPrefix = b.title.toLowerCase().startsWith(needle) ? 0 : 1;

        return aPrefix - bPrefix;
    });
}

// `:` and `/` are two lines, not one list with two kinds in it. vim splits
// them the same way and for the same reason: you already know whether you
// are naming a command or naming a file, so making the line ask you to
// disambiguate by typing is work the keystroke already did. It also stops
// a directory called "Copy" from outranking the Copy command.
function actionsFor(query, selection, clipboard, showHidden) {
    return filtered(actionRows(selection, clipboard, showHidden), query);
}

function entriesFor(query, entries) {
    return filtered(entryRows(entries), query);
}

// The right-click menu is the same action list with no filter and no
// entries: it is already pointing at something, so it does not need a way
// to choose one. Right-clicking bare pane background has no selection, so
// it collapses to the actions that need none.
function menuRows(selection, clipboard, showHidden) {
    return actionRows(selection, clipboard, showHidden);
}
