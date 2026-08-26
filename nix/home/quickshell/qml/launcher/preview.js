// Pure mapping from a filesystem path to what the preview pane draws.
//
// Split out of PreviewPane.qml for the same reason bar/battery.js is split out
// of Battery.qml: tests/qml/tst_preview.qml can reach arithmetic, but not a
// component that inherits from Quickshell types and reads Theme.
//
// beamenu did all of this in a sidecar process, because reading a 40 MB image
// on the launcher's own thread would have frozen the keyboard. QML gives that
// away for nothing — Image decodes asynchronously and Process is already
// non-blocking — so the pane is a delegate here rather than a second program.
.pragma library

// fd prints directories with a trailing slash and files without one, so the
// kind is already in the string by the time a row is built. Nothing here
// stats the filesystem; the shell command below does that once, off-thread.
const IMAGE_EXTENSIONS = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "avif", "ico"];

// Read bounded and listed bounded. A preview is a glance, and `head` refusing
// to read the other 39 MB is the whole reason this stays responsive.
const BODY_BYTES = 65536;
const BODY_LINES = 200;

// The path is NOT in here. It arrives as "$1" and the kind as "$2", so a file
// named `; rm -rf ~` is an argument rather than a command. Building this
// string by interpolation would be the one bug in this file that mattered.
const SCRIPT = 'p="$1"; kind="$2";'
    + ' if [ -d "$p" ]; then'
    + ' n=$(ls -A -- "$p" 2>/dev/null | wc -l);'
    + ' m=$(stat -c %Y -- "$p" 2>/dev/null || echo 0);'
    + ' printf "META 0 %s %s\\n" "$m" "$n";'
    + ' ls -Ap -- "$p" 2>/dev/null | head -n ' + BODY_LINES + ';'
    + ' else'
    + ' s=$(stat -c %s -- "$p" 2>/dev/null || echo 0);'
    + ' m=$(stat -c %Y -- "$p" 2>/dev/null || echo 0);'
    + ' printf "META %s %s 0\\n" "$s" "$m";'
    + ' if [ "$kind" != "image" ]; then'
    + ' head -c ' + BODY_BYTES + ' -- "$p" 2>/dev/null | head -n ' + BODY_LINES + ';'
    + ' fi;'
    + ' fi';

function isDirectory(path) {
    return path.endsWith("/");
}

function extensionOf(path) {
    const name = displayName(path);
    const dot = name.lastIndexOf(".");

    // `<= 0` rather than `< 0`: a leading dot is a hidden file, not an
    // extension, so .bashrc previews as text instead of as nothing.
    return dot <= 0 ? "" : name.slice(dot + 1).toLowerCase();
}

function kindOf(path) {
    if (isDirectory(path))
        return "directory";

    return IMAGE_EXTENSIONS.indexOf(extensionOf(path)) === -1 ? "text" : "image";
}

function displayName(path) {
    const trimmed = isDirectory(path) ? path.slice(0, -1) : path;
    return trimmed.slice(trimmed.lastIndexOf("/") + 1);
}

function displayParent(path, home) {
    const trimmed = isDirectory(path) ? path.slice(0, -1) : path;
    const cut = trimmed.lastIndexOf("/");
    const parent = cut <= 0 ? "/" : trimmed.slice(0, cut);

    if (!home)
        return parent;

    // The `home + "/"` half of this is what stops /home/matusek rendering as
    // ~ek. A plain startsWith would call any sibling of home a child of it.
    if (parent === home)
        return "~";

    return parent.startsWith(home + "/") ? "~" + parent.slice(home.length) : parent;
}

// Image.source wants a URL, and a URL is not a path: a filename may legally
// contain a space, a #, or a ?, each of which means something else once it is
// in a URL. Encoding per segment keeps the separators as separators.
function fileUrl(path) {
    const trimmed = isDirectory(path) ? path.slice(0, -1) : path;
    return "file://" + trimmed.split("/").map(encodeURIComponent).join("/");
}

function formatSize(bytes) {
    if (bytes < 1024)
        return bytes + " B";

    const units = ["KB", "MB", "GB", "TB"];
    let value = bytes / 1024;
    let unit = 0;

    while (value >= 1024 && unit < units.length - 1) {
        value /= 1024;
        unit++;
    }

    // One decimal below 10, none above: "1.5 KB" is worth the character and
    // "5.2 MB" past two digits is noise on a line this small.
    const rounded = value >= 10 ? Math.round(value) : Math.round(value * 10) / 10;
    return rounded + " " + units[unit];
}

function previewCommand(path, kind) {
    return ["sh", "-c", SCRIPT, "sh", path, kind];
}

// A NUL byte is the cheap, boring test every pager uses, and it is right far
// more often than sniffing magic numbers would be.
function isBinary(text) {
    return text.indexOf("\u0000") !== -1;
}

function parseMeta(line) {
    const parts = line.split(" ");

    if (parts[0] !== "META")
        return { bytes: 0, modified: 0, entries: 0 };

    return {
        bytes: parseInt(parts[1], 10) || 0,
        modified: parseInt(parts[2], 10) || 0,
        entries: parseInt(parts[3], 10) || 0
    };
}

// The command prints its metadata on the first line and the body after it, so
// one process answers both questions and the pane never shows a size that
// belongs to the previous row.
function splitOutput(text) {
    const newline = text.indexOf("\n");

    if (newline === -1)
        return { meta: parseMeta(text), body: "" };

    return {
        meta: parseMeta(text.slice(0, newline)),
        body: text.slice(newline + 1)
    };
}
