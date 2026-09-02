// Pure directory-listing helpers for Pane.qml. Split out so
// tests/qml/tst_files.qml can drive them with captured listing output and
// no Process, filesystem or compositor anywhere near the test.
//
// The listing comes from `find -printf`, not `ls`. A row needs a size and
// an mtime beside the name, and `ls -l` only exposes those inside a
// column layout that has to be re-parsed out of padded, locale-formatted
// text. `-printf` names the fields it emits, so this file splits on tabs
// instead of guessing where `ls` put a column this time.
//
// One line per entry is the format's contract, and a name containing a raw
// newline or tab byte defeats it: the captured text is indistinguishable
// from two entries, or from an extra field, by the time it reaches this
// file. Nothing downstream trusts `name` as a shell token either way —
// join() below and Pane.qml's argv both carry it as plain string data,
// never through a shell — so that split is a display artifact on an
// astronomically rare filename, not a parsing crash or an injection.
//
// Sorting lives here rather than in the `find` call because `find` has no
// equivalent of `ls --group-directories-first`, and a comparator in this
// file is one a test can drive directly.
.pragma library

// `%Y`, not `%y`: it reports the type after following a symlink, so a link
// to a directory sorts and behaves as the directory it points at, which is
// what `ls -p`'s trailing slash used to convey.
var LISTING_FORMAT = "%Y\\t%s\\t%T@\\t%f\\n";

function listingArgv(path) {
    return ["find", path, "-maxdepth", "1", "-mindepth", "1", "-printf", "%Y\t%s\t%T@\t%f\n"];
}

// A line is type, size in bytes, mtime as an epoch float, then the
// basename. The name is joined back rather than indexed so a name that
// itself contains a tab loses only its own display, not the whole listing.
function parseListing(text) {
    return sortEntries(text.split("\n").filter(line => line !== "").map(raw => {
        const parts = raw.split("\t");
        if (parts.length < 4)
            return null;

        return {
            name: parts.slice(3).join("\t"),
            isDir: parts[0] === "d",
            size: parseInt(parts[1], 10),
            mtime: parseFloat(parts[2])
        };
    }).filter(entry => entry !== null));
}

// Directories first, then case-insensitive by name. localeCompare rather
// than a bare `<` so "Öffentlich" lands beside "O" instead of after "Z",
// which is what a byte comparison does to this tree's German home.
function sortEntries(entries) {
    return entries.slice().sort((a, b) => {
        if (a.isDir !== b.isDir)
            return a.isDir ? -1 : 1;

        return a.name.localeCompare(b.name, undefined, { sensitivity: "base" });
    });
}

// Powers of 1024 with one decimal above the kilobyte, which is what every
// file manager this replaces shows. A directory has no meaningful size of
// its own here — `find` reports the size of the directory inode, not of
// its contents — so it gets a dash rather than a misleading 4.0 KB.
function formatSize(entry) {
    if (entry.isDir)
        return "—";

    const units = ["B", "KB", "MB", "GB", "TB"];
    let size = entry.size;
    let unit = 0;

    while (size >= 1024 && unit < units.length - 1) {
        size /= 1024;
        unit += 1;
    }

    return unit === 0 ? `${size} B` : `${size.toFixed(1)} ${units[unit]}`;
}

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

// `now` is a parameter rather than a Date.now() call so a test can pin the
// boundary between the two formats instead of skipping it.
//
// Recent entries show a time and old ones show a year, for the same reason
// `ls -l` does: the day and month alone are ambiguous across years, and the
// clock time stops mattering once something is months old.
function formatTime(entry, now) {
    const when = new Date(entry.mtime * 1000);
    const day = when.getDate();
    const month = MONTHS[when.getMonth()];

    if (now - entry.mtime * 1000 > 182 * 24 * 60 * 60 * 1000)
        return `${day} ${month} ${when.getFullYear()}`;

    const hours = String(when.getHours()).padStart(2, "0");
    const minutes = String(when.getMinutes()).padStart(2, "0");
    return `${day} ${month} ${hours}:${minutes}`;
}

// The Unix convention, not an attribute: a leading dot is all that marks a
// file hidden. `find` has no equivalent of `ls`'s -A, so the filtering
// happens here, which also means the pane can toggle it without re-running
// the listing.
function isHidden(entry) {
    return entry.name.startsWith(".");
}

function visibleEntries(entries, showHidden) {
    return showHidden ? entries : entries.filter(entry => !isHidden(entry));
}

function join(dir, name) {
    return dir.replace(/\/$/, "") + "/" + name;
}

// The path split into the segments a breadcrumb bar clicks through, each
// carrying the absolute path that reaching it would open. Root leads every
// list and is the only crumb whose label is not a directory name.
//
// Built here rather than in the bar so a test can drive it: the arithmetic
// that matters is that crumb N's path is the first N components joined,
// which is easy to get wrong by one slash and invisible until a click
// lands somewhere unexpected.
function crumbsFor(path) {
    const crumbs = [{ label: "/", path: "/" }];

    if (path === "/")
        return crumbs;

    let walked = "";

    for (const part of path.split("/")) {
        if (part === "")
            continue;

        walked = `${walked}/${part}`;
        crumbs.push({ label: part, path: walked });
    }

    return crumbs;
}

function parentOf(path) {
    if (path === "/")
        return "/";

    const cut = path.lastIndexOf("/");
    return cut <= 0 ? "/" : path.slice(0, cut);
}
