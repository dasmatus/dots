// The sidebar's fixed places: Home plus whichever XDG user directories
// this login actually has.
//
// Parsed from $XDG_CONFIG_HOME/user-dirs.dirs rather than hardcoded, for
// two reasons. The names are localised — this login's Desktop is
// "Schreibtisch" and its Public is "Öffentlich" — so an English literal
// would point at directories that do not exist. And a user who moved or
// deleted one should not get a sidebar row leading nowhere.
//
// Pure, so tests/qml/tst_files_places.qml drives it with captured file
// contents and no filesystem.
.pragma library

// The order the sidebar lists them in, which is by how often they get
// opened rather than the order xdg-user-dirs happens to write them.
// A key absent from the file is simply skipped.
var ORDER = [
    { key: "XDG_DOCUMENTS_DIR", label: "Documents", glyph: "\u{F09EE}", colour: "blue" },
    { key: "XDG_DOWNLOAD_DIR", label: "Downloads", glyph: "\u{F01DA}", colour: "green" },
    { key: "XDG_PICTURES_DIR", label: "Pictures", glyph: "\u{F02E9}", colour: "magenta" },
    { key: "XDG_MUSIC_DIR", label: "Music", glyph: "\u{F075A}", colour: "cyan" },
    { key: "XDG_VIDEOS_DIR", label: "Videos", glyph: "\u{F0567}", colour: "cyan" },
    { key: "XDG_DESKTOP_DIR", label: "Desktop", glyph: "\u{F0379}", colour: "yellow" },
    { key: "XDG_PUBLICSHARE_DIR", label: "Public", glyph: "\u{F0496}", colour: "orange" },
    { key: "XDG_TEMPLATES_DIR", label: "Templates", glyph: "\u{F0227}", colour: "dim" }
];

// Lines look like `XDG_MUSIC_DIR="$HOME/Musik"`, with `#` comments and
// blank lines mixed in. The value is shell-quoted and usually relative to
// $HOME through a literal `$HOME`, which is expanded here rather than by a
// shell, since nothing in this file manager runs one.
function parseUserDirs(text, home) {
    const dirs = {};

    for (const raw of text.split("\n")) {
        const line = raw.trim();
        if (line === "" || line.startsWith("#"))
            continue;

        const eq = line.indexOf("=");
        if (eq <= 0)
            continue;

        const key = line.slice(0, eq).trim();
        let value = line.slice(eq + 1).trim();

        if (value.length >= 2 && value.startsWith("\"") && value.endsWith("\""))
            value = value.slice(1, -1);

        if (value.startsWith("$HOME"))
            value = home + value.slice("$HOME".length);

        // A key pointing back at $HOME itself is xdg-user-dirs' way of
        // saying the directory is disabled. Home already has its own row.
        if (value === "" || value === home)
            continue;

        dirs[key] = value;
    }

    return dirs;
}

// GTK's bookmarks file, one `file:///path` per line with an optional
// display label after a space. Read rather than invented so this sidebar
// shows the same bookmarks every other GTK file manager does.
//
// Read-only on purpose: nix/home/default.nix declares the file through
// `xdg.configFile."gtk-3.0/bookmarks".text`, so the path is a symlink into
// the nix store and a write would fail. A new bookmark is a home-manager
// edit, which is also what makes it survive a reinstall.
//
// Only `file://` lines are kept. GTK writes `smb://` and `sftp://` entries
// into the same file, and nothing here can open one: the pane lists with
// `find`, which needs a local path.
var BOOKMARK_SCHEME = "file://";

function decodePath(encoded) {
    try {
        return decodeURIComponent(encoded);
    } catch (error) {
        // A stray percent that is not an escape makes decodeURIComponent
        // throw. The raw line is still a usable path far more often than
        // not, so the bookmark degrades rather than taking the list with it.
        return encoded;
    }
}

function parseBookmarks(text) {
    const bookmarks = [];

    for (const raw of text.split("\n")) {
        const line = raw.trim();
        if (!line.startsWith(BOOKMARK_SCHEME))
            continue;

        const body = line.slice(BOOKMARK_SCHEME.length);
        const space = body.indexOf(" ");

        const encoded = space < 0 ? body : body.slice(0, space);
        const label = space < 0 ? "" : body.slice(space + 1).trim();
        const path = decodePath(encoded);

        if (path === "" || !path.startsWith("/"))
            continue;

        bookmarks.push({
            label: label !== "" ? label : basename(path),
            path: path,
            glyph: "\u{F00C0}",
            colour: "yellow"
        });
    }

    return bookmarks;
}

function basename(path) {
    if (path === "/")
        return "/";

    const trimmed = path.replace(/\/$/, "");
    const cut = trimmed.lastIndexOf("/");
    return cut < 0 ? trimmed : trimmed.slice(cut + 1);
}

function placesFor(text, home) {
    const dirs = parseUserDirs(text, home);
    const places = [{ label: "Home", path: home, glyph: "\u{F02DC}", colour: "accent" }];

    for (const entry of ORDER) {
        if (dirs[entry.key])
            places.push({ label: entry.label, path: dirs[entry.key], glyph: entry.glyph, colour: entry.colour });
    }

    return places;
}
