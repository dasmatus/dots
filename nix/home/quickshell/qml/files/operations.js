// Argv builders for the write operations Files.qml's toolbar drives. Every
// one ends "--" before the path, the coreutils/gio convention that stops
// a name starting with "-" being parsed as a flag, and every path is its
// own array element, never concatenated into a shell string, because
// nothing on this path ever runs through sh -c.
.pragma library
.import "files.js" as FilesMath

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

// A rename's new name and a new folder's name are free text the user
// typed, unlike every other argument on this path, which comes straight
// off a real `ls` listing. A blank (empty or whitespace-only) name joins
// to the parent directory itself (mkdir -- $dir, not a new one at all,
// or a directory literally named " ", which is legal but not what anyone
// meant to type); a name carrying "/" or a ".." segment escapes the
// directory the prompt was opened in, which a rename or mkdir dialog must
// never be able to do; a name carrying a newline byte is syntactically a
// valid filename on Linux, but files.js's parseListing splits `ls -1Ap`
// output on "\n", so minting one turns into two phantom rows the next
// time either pane lists this directory. None of these are optional —
// resolvePromptArgv below also runs this over a name that never came from
// typed text at all, so it has to reject everything that could go wrong
// with an arbitrary string, not just what a keyboard is likely to produce.
function isValidEntryName(name) {
    if (name.trim() === "" || name === "..")
        return false;

    return !name.includes("/") && !name.includes("\n");
}

// Captures what a pending rename/mkdir/trash-confirm needs to resolve its
// argv, at the moment the prompt opens rather than at the moment it
// confirms. Files.qml used to read root.activePane.selected live inside
// confirmPrompt(), which let a click onto a different row, or into the
// other pane entirely, land between the prompt opening and Enter being
// pressed — the operation then ran against whatever was selected by
// confirm time, not what the dialog showed, and if that pane had nothing
// selected the live read threw before the prompt state even reset. `name`
// is the selected entry's name for rename/trash-confirm, null for mkdir,
// which has no selected entry, only a parent directory to create inside.
function beginPrompt(mode, dirPath, name) {
    return { mode: mode, dirPath: dirPath, name: name };
}

// Resolves a beginPrompt() snapshot plus the live prompt text into the
// argv to run, or null if the mode is unrecognised or (rename/mkdir only)
// the typed name fails isValidEntryName. promptText is the one piece of
// prompt state legitimately read live here: it is the field the user is
// actively typing into, not something that changes out from under them
// the way the active pane's selection can.
function resolvePromptArgv(snapshot, promptText) {
    if (!snapshot)
        return null;

    if (snapshot.mode === "rename") {
        if (!isValidEntryName(promptText))
            return null;

        return renameArgv(FilesMath.join(snapshot.dirPath, snapshot.name), FilesMath.join(snapshot.dirPath, promptText));
    }

    if (snapshot.mode === "mkdir") {
        if (!isValidEntryName(promptText))
            return null;

        return mkdirArgv(FilesMath.join(snapshot.dirPath, promptText));
    }

    // snapshot.name here always comes off a real ls listing today (via
    // trashSelected()), and a POSIX filename cannot itself contain "/", so
    // this validates something unreachable through the running UI. It
    // stays anyway: beginPrompt takes name as a plain argument with no
    // shape guarantee of its own, so the only thing that made this branch
    // safe before was every caller's discipline, not this function's own
    // contract. beginPrompt("trash-confirm", dir, "../../etc/passwd")
    // resolved to a traversal until this check existed.
    if (snapshot.mode === "trash-confirm") {
        if (!isValidEntryName(snapshot.name))
            return null;

        return trashArgv(FilesMath.join(snapshot.dirPath, snapshot.name));
    }

    return null;
}
