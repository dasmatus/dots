// Argv builders for the write operations Files.qml's toolbar drives. Every
// one ends "--" before the path, the coreutils/gio convention that stops
// a name starting with "-" being parsed as a flag, and every path is its
// own array element, never concatenated into a shell string, because
// nothing on this path ever runs through sh -c.
.pragma library

function copyArgv(src, dst) {
    return ["cp", "-r", "--", src, dst];
}

function moveArgv(src, dst) {
    return ["mv", "--", src, dst];
}

function renameArgv(oldPath, newPath) {
    return ["mv", "--", oldPath, newPath];
}

function mkdirArgv(path) {
    return ["mkdir", "--", path];
}

function trashArgv(path) {
    return ["gio", "trash", "--", path];
}
