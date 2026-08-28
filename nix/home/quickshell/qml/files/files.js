// Pure directory-listing helpers for Pane.qml. Split out so
// tests/qml/tst_files.qml can drive them with captured `ls -1Ap` output
// and no Process, filesystem or compositor anywhere near the test.
//
// One line per entry is `ls`'s own contract, not a choice made here, and a
// name that itself contains a raw newline byte defeats it: the captured
// text is indistinguishable from two separate entries by the time it
// reaches this file, and splitting on "\n" reads it as exactly that.
// Nothing downstream trusts `name` as a shell token either way, join()
// below and Pane.qml's argv both carry it as plain string data, never
// through a shell, so that split is a display artifact on an
// astronomically rare filename, not a parsing crash or an injection.
.pragma library

// `-p` marks a directory with a trailing slash; this is the only place
// that convention is interpreted, so Pane.qml's own entries carry a plain
// isDir boolean instead.
function parseListing(text) {
    return text.split("\n").filter(line => line !== "").map(raw => {
        const isDir = raw.endsWith("/");
        return { name: isDir ? raw.slice(0, -1) : raw, isDir: isDir };
    });
}

function join(dir, name) {
    return dir.replace(/\/$/, "") + "/" + name;
}

function parentOf(path) {
    if (path === "/")
        return "/";

    const cut = path.lastIndexOf("/");
    return cut <= 0 ? "/" : path.slice(0, cut);
}
