// Argv builders for the write operations Files.qml's toolbar drives. Every
// coreutils/gio one (copyArgv/moveArgv/renameArgv/mkdirArgv/trashArgv)
// ends "--" before the path, the convention that stops a name starting
// with "-" being parsed as a flag, and every path is its own array
// element, never concatenated into a shell string, because nothing on
// this path ever runs through sh -c. openArgv is the one exception to
// the "--" rule, deliberately — see its own comment for why.
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

// Whether `name` could resolve to somewhere other than a real, distinct
// entry inside the directory it gets joined against — the only property
// that matters for a name nobody typed, e.g. an existing entry's name off
// a real `ls` listing. `join` is `dir + "/" + name`, so an empty name or
// "." both resolve to `dir` itself (join(dir, "") is "dir/", join(dir,
// ".") is "dir/."), and a name with "/" or exactly ".." can point outside
// `dir` entirely — those four are checked here, nothing more, and nothing
// less: an empty snapshot.name used to pass this function (neither ".."
// nor containing "/"), so a trash-confirm on one resolved to trashing the
// pane's own directory, exit 0, silently. `typeof name !== "string"`
// comes first so a non-string (a future caller's mistake, not anything
// trashSelected() produces today) is rejected rather than reaching
// `.includes` and throwing — this function has to stay total, since a
// throw here would skip confirmPrompt()'s own cleanup and leave a prompt
// stuck open exactly the way a live-selection read used to.
function escapesDirectory(name) {
    return typeof name !== "string" || name === "" || name === "." || name === ".." || name.includes("/");
}

// A rename's new name and a new folder's name are free text the user
// typed, unlike an existing entry's name, which is a fact about the disk
// (see escapesDirectory above, used for that case instead, and which
// already rejects an empty name on its own). Beyond escapesDirectory's
// four properties, a name about to be CREATED gets two more rules a name
// that already exists does not need, because both are about picking a
// bad name rather than escaping anywhere: a whitespace-only (but
// non-empty) name mints a directory literally named " ", which is legal
// but not what anyone meant to type, and a name carrying a newline byte
// is syntactically valid but files.js's parseListing splits `ls -1Ap`
// output on "\n", so minting one turns into two phantom rows the next
// time either pane lists this directory. A real file already named " "
// or containing a tab predates this dialog and lists, copies and moves
// just fine; only creating a new one that way is refused.
function isValidEntryName(name) {
    if (escapesDirectory(name))
        return false;

    return name.trim() !== "" && !name.includes("\n");
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

    // snapshot.name is a rename's SOURCE half, an existing entry's name
    // off a real ls listing exactly like trash-confirm's below — not
    // promptText, the DESTINATION the user is typing and already checked
    // by isValidEntryName. Round 4 closed this exact hole for
    // trash-confirm and missed it here: beginPrompt("rename", dir,
    // "../.ssh/id_ed25519") resolved renameArgv straight onto a path
    // outside dir, with nothing anywhere checking snapshot.name. Same fix,
    // same reason, so escapesDirectory rather than isValidEntryName: see
    // escapesDirectory's own comment and trash-confirm's comment below for
    // why a name off a listing gets the disk-fact check, not the
    // create-time one — a file already named " " or holding a tab must
    // stay renameable.
    if (snapshot.mode === "rename") {
        if (escapesDirectory(snapshot.name) || !isValidEntryName(promptText))
            return null;

        return renameArgv(FilesMath.join(snapshot.dirPath, snapshot.name), FilesMath.join(snapshot.dirPath, promptText));
    }

    if (snapshot.mode === "mkdir") {
        if (!isValidEntryName(promptText))
            return null;

        return mkdirArgv(FilesMath.join(snapshot.dirPath, promptText));
    }

    // snapshot.name here always comes off a real ls listing today (via
    // trashSelected(), and parseListing never emits an empty or "."
    // entry), which is exactly why this checks escapesDirectory rather
    // than isValidEntryName: a file already named " ", "  " or a literal
    // tab is a real, existing, trashable file, and rejecting it for being
    // "blank" applied a create-time hygiene rule to a name nobody typed —
    // the trash button was refusing files copy, move and rename all left
    // alone. beginPrompt takes name as a plain argument with no shape
    // guarantee of its own regardless, so the escape check stays:
    // beginPrompt("trash-confirm", dir, "../../etc/passwd") resolved to a
    // traversal, and beginPrompt("trash-confirm", dir, "") resolved to
    // trashing dir itself, until escapesDirectory covered both.
    if (snapshot.mode === "trash-confirm") {
        if (escapesDirectory(snapshot.name))
            return null;

        return trashArgv(FilesMath.join(snapshot.dirPath, snapshot.name));
    }

    return null;
}

// copySelected()/moveSelected() build their source the same way
// resolvePromptArgv builds rename's and trash-confirm's: FilesMath.join()
// against pane.selected.name, an existing entry's name off the same
// parseListing() ls -1Ap output those two read theirs from. Neither call
// site validated it at all until now — not escapesDirectory, not
// isValidEntryName — so a selected entry named "..", or one join() would
// resolve outside pane.path some other way, went straight into copyArgv/
// moveArgv with nothing in between. Pulled out of Files.qml into a pure
// function for the same reason resolvePromptArgv is one: Files.qml
// instantiates Quickshell.Io, which qmltestrunner cannot load here, so any
// check written inline there is a check no test in this suite can reach.
// mode picks the builder; escapesDirectory rejection returns null the same
// way an unrecognised resolvePromptArgv mode does, leaving the decision of
// what to show the user to the caller.
function resolveSelectionArgv(mode, srcDirPath, name, dstDirPath) {
    if (escapesDirectory(name))
        return null;

    const src = FilesMath.join(srcDirPath, name);

    if (mode === "copy")
        return copyArgv(src, dstDirPath);

    if (mode === "move")
        return moveArgv(src, dstDirPath);

    return null;
}

// The three modes this file ever puts into a beginPrompt() snapshot.
const PROMPT_MODES = ["rename", "mkdir", "trash-confirm"];

function isKnownPromptMode(mode) {
    return PROMPT_MODES.includes(mode);
}

// The message for a name that only ever fails escapesDirectory's four
// checks (a non-string, the empty string, "." or ".." exactly, or a name
// containing "/"), never isValidEntryName's extra CREATE-time rules —
// shared by promptErrorMessage's trash-confirm branch below and
// copySelected()/moveSelected() in Files.qml, the three places a name off
// a real listing can get rejected. It does have to name the empty string:
// escapesDirectory("") is true, and an earlier wording here named only
// "/", ".." and "." and dropped the empty-string rejection along with the
// two hygiene rules that legitimately don't apply, leaving a user who
// typed nothing looking at a reason that was not the reason. Non-string
// stays unnamed regardless — nothing off a real listing is ever anything
// but a string, so only a future caller's bug reaches it, not a person
// this message is written for.
function escapesDirectoryMessage() {
    return "Invalid name: cannot be empty, contain \"/\", or be \"..\" or \".\"";
}

// Which lastError text a failed confirmPrompt() should show, given the
// snapshot resolvePromptArgv() just rejected. Pulled out of Files.qml so
// it is testable without a live prompt: a generic message for a falsy
// snapshot or an unrecognised mode, neither of which has a name to blame,
// and otherwise a naming-specific message scoped to what that mode can
// actually reject — trash-confirm, and now rename's source half, only
// ever fail escapesDirectory, never isValidEntryName's extra CREATE-time
// rules, so this message must not claim a blank or newline name would be
// refused when trash-confirm accepts both.
function promptErrorMessage(snapshot) {
    if (!snapshot || !isKnownPromptMode(snapshot.mode))
        return "Nothing to confirm";

    if (snapshot.mode === "trash-confirm")
        return escapesDirectoryMessage();

    return "Invalid name: cannot be empty or whitespace-only, contain \"/\" or a newline, or be \"..\" or \".\"";
}

// Pane.qml's activate() opens a non-directory hit through this. A pure
// builder rather than an inline array literal so a test can pin its exact
// shape: xdg-open's own argument loop rejects "--" outright and exits 1
// ("unexpected option '--'"), unlike every coreutils/gio command every
// other builder in this file targets, so this one must never grow one —
// confirmed against the binary this service resolves from PATH, and
// broken that way once already by a "--" added here in an earlier pass
// over this file.
function openArgv(path) {
    return ["xdg-open", path];
}

// Whether `path` is safe to become Files.qml's leftPath/rightPath:
// absolute, so it can never reach an option parser as a bare "-foo" the
// way a relative-looking string could. Every in-tree caller (a device
// mountpoint, a child built through FilesMath.join from an already-
// absolute pane path) already only ever passes one; `qs ipc call files
// openPath` is the one caller with no shape guarantee at all, and this is
// the single choke point between that call and every argv root.path
// eventually reaches (Pane.qml's ls, and openArgv above for a
// non-directory hit).
function isAbsolutePath(path) {
    return typeof path === "string" && path.startsWith("/");
}
