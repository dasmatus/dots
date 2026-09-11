// Row assembly for the dropdown a crumb click opens on PathBar.qml,
// mirroring commands.js's entryRows() one level up. Kept pure and split out
// for the same reason tabs.js is: CrumbMenu.qml reaches Quickshell.Io, which
// qmltestrunner cannot load, so the cap-and-remainder arithmetic and the row
// shape have to live somewhere a test can drive them with a plain array and
// no window. It is exercised here by tst_files_crumbmenu.qml.
.pragma library

.import "commands.js" as Commands
.import "icons.js" as Icons

// A crumb over `/nix/store` lists hundreds of thousands of entries, and
// nothing downstream of this paginates: CrumbMenu.qml's rows sit in a plain
// ColumnLayout sized to its own content, the same shape Menu.qml's rows use,
// with no ListView or Flickable to scroll. Rendering all of them would both
// stall the window building the popup and put most of it off the bottom of
// the screen; capping means the popup always fits.
function crumbEntries(entries, cap) {
    return entries.slice(0, cap);
}

// How many entries the cap left out, for the trailer row that says so
// rather than truncating silently.
function crumbRemainder(entries, cap) {
    return Math.max(0, entries.length - cap);
}

// The first row, always present: what a single crumb click used to do on
// its own before this dropdown existed, and still can, one row down. `path`
// travels as `subtitle` for a test to pin, even though this popup only ever
// renders `title`.
function openRow(path) {
    return { kind: "open", id: "open", title: "Open this folder", subtitle: path, glyph: Icons.FOLDER, colour: "accent" };
}

// The trailer row, present only once the cap actually bit. It carries no
// glyph: an icon here would claim to be another entry rather than a count of
// the ones left out.
function moreRow(remainder) {
    return { kind: "more", id: "more", title: `${remainder} more not shown`, subtitle: "", glyph: "", colour: "dim" };
}

// `entries` already arrives directories-first (parseListing's own sort), so
// the only ordering left to decide here is that the open-this-folder row
// leads and the remainder trailer, when there is one, trails.
//
// A shown entry's `index` (via Commands.entryRows) still lands on the right
// element of the full `entries` array: crumbEntries slices from the front,
// so a row's position inside that slice is the same index it already had
// before the cap was applied.
function crumbMenuRows(path, entries, cap) {
    const shown = crumbEntries(entries, cap);
    const remainder = crumbRemainder(entries, cap);

    const rows = [openRow(path)].concat(Commands.entryRows(shown));

    if (remainder > 0)
        rows.push(moreRow(remainder));

    return rows;
}
