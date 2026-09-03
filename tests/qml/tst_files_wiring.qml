// Reachability tests for the file manager's window and its focus handover,
// in the idiom tst_launcher_wiring.qml established: qmltestrunner cannot
// instantiate Files.qml — it reaches FloatingWindow, IpcHandler, Process and
// Quickshell.env, all of which tests/README.md rules out — so these read the
// shipped source as text.
//
// Both assertions here are about a bug that produced no error of any kind.
//
// The window one: closing the file manager with SUPER+Q, the bind every
// other window on the desktop answers to, left it unable to open ever again.
// `qs ipc call files open` returned success, the log stayed clean, and no
// window mapped. Quickshell's setter compares the requested visibility
// against a desired-state flag that a compositor-initiated close never
// cleared, so `visible = true` matched it, early-returned, and dropped the
// write. Answering the window's own `closed` signal is what clears it, and
// it has to happen there rather than defensively inside open(): the four
// callers — open(), toggle(), openPath() and Devices' requestOpen — all go
// through the same setter, and only the signal knows a close happened.
//
// The focus one: `catcher` holds focus while the command line is closed, and
// CommandLine's TextInput holds it while the line is open. Both halves are
// bindings on the mode, and each is dead without the other — a catcher that
// took focus imperatively would keep it while the line was up and swallow
// everything typed there. tst_files_cmdline_focus.qml drives the CommandLine
// half against real key events; this pins the half that lives in a file no
// test can instantiate.
//
// Checked against comment-stripped source, because the prose in Files.qml
// discusses `onClosed`, `window.visible` and `catcher`'s binding by name
// while explaining why they are shaped this way, and an unstripped scan
// would let a comment stand in for the code it describes — the failure
// sourcescan.js's own header records having been bitten by once already.
import QtQuick
import QtTest
import "sourcescan.js" as Scan

TestCase {
    name: "FilesWiring"

    function readSource(relPath) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl(relPath), false);
        xhr.send();
        compare(xhr.status, 200, relPath + " must be readable (needs QML_XHR_ALLOW_FILE_READ=1)");
        return Scan.stripComments(xhr.responseText);
    }

    function filesSource() {
        return readSource("../../nix/home/quickshell/qml/files/Files.qml");
    }

    function commandLineSource() {
        return readSource("../../nix/home/quickshell/qml/files/CommandLine.qml");
    }

    // The whole of the reopen fix. Without it the window opens exactly once
    // per shell lifetime and every later open is a silent no-op.
    function test_a_compositor_close_resets_the_windows_visibility() {
        const block = Scan.blockAfter(filesSource(), "FloatingWindow {");
        verify(block !== "", "Files.qml must define a FloatingWindow");

        // The window's own properties, cut off at its first child. The Tabs
        // strip inside it carries an onClosed of its own — a tab being
        // closed, nothing to do with the window — and scanning the whole
        // block would let that one answer for this assertion.
        const properties = block.slice(0, block.indexOf("FocusScope {"));
        verify(properties !== "", "the window must still contain the FocusScope that holds its content");

        const handler = properties.indexOf("onClosed:");
        verify(handler !== -1, "the window must answer its own closed signal — a compositor close otherwise leaves the visibility setter armed and every later open() is dropped");

        const line = properties.slice(handler, properties.indexOf("\n", handler));
        verify(line.indexOf("visible = false") !== -1, "onClosed must clear the visibility flag; anything else leaves the reopen broken");
    }

    // toggle() reads the same property the close desynced, so it has to be
    // covered by the same reset rather than by a second mechanism.
    function test_every_entry_point_opens_through_the_windows_visible_property() {
        const src = filesSource();

        verify(Scan.blockAfter(src, "function open(): void {").indexOf("window.visible = true") !== -1, "open() must set the window's own visible property");
        verify(Scan.blockAfter(src, "function toggle(): void {").indexOf("window.visible") !== -1, "toggle() must go through the same property, so the closed-signal reset covers it too");
    }

    // A binding, not a forceActiveFocus() in a close handler. The comment on
    // `catcher` records why: the TextInput stays its FocusScope's focused
    // child after being hidden, so a second `:` reached an item that could
    // not receive it until the binding started reclaiming focus instead.
    function test_the_pane_catcher_holds_focus_by_binding_on_the_closed_state() {
        const src = filesSource();
        const at = src.indexOf("id: catcher");
        verify(at !== -1, "Files.qml must define the catcher item that receives keys while the command line is closed");

        // Its own declaration block, not the whole file: `focus:` appears on
        // the enclosing FocusScope too, and matching that one would pass
        // while catcher had no binding at all.
        const declaration = src.slice(at, src.indexOf("Keys.onPressed", at));
        verify(declaration.indexOf('focus: root.promptMode === ""') !== -1, "catcher's focus must be bound to the closed state, not taken imperatively");
    }

    // The other half. These two bindings and the confirm item's are mutually
    // exclusive by construction, which is what makes exactly one of them
    // hold focus in every mode.
    function test_the_command_line_holds_focus_by_binding_on_the_open_state() {
        const src = commandLineSource();

        verify(src.indexOf('focus: root.mode !== "" && !root.confirming') !== -1, "the command line's field must bind its focus to the mode");
        verify(src.indexOf("forceActiveFocus") === -1, "taking focus imperatively is what clear() used to undo one statement later — the `:` and `/` lines came up focusing nothing at all");
        verify(src.indexOf("input.focus = false") === -1, "and releasing it imperatively is the other half of that pair");
    }

    // The index only covers $HOME, and the fallback is what a first boot
    // searches through: dots-files-index has not run yet, grep cannot read
    // the file, and without this `/` would report that the machine contains
    // nothing. It is also the path that outlives the index entirely, in
    // /etc or on a mounted stick, so it is the one most likely to rot
    // unnoticed — nothing about a working index would ever exercise it.
    function test_a_search_falls_back_to_the_live_walk_without_an_index() {
        const src = filesSource();

        const chooser = Scan.blockAfter(src, "function runSearch(): void {");
        verify(chooser.indexOf("Index.withinHome") !== -1, "runSearch must ask whether the current directory is one the index covers");
        verify(chooser.indexOf("runLiveSearch") !== -1, "and walk live when it is not");

        const fallback = Scan.blockAfter(src, "function runLiveSearch(): void {");
        verify(fallback.indexOf("FilesMath.searchArgv") !== -1, "the fallback must still build the find argv files.js already tests");

        // grep's exit 2 is the only signal that the file is missing at all.
        // Reading it off `indexed` matters as much: a live walk that found
        // nothing must not be mistaken for a missing index and retried
        // forever.
        const exited = Scan.blockAfter(src, "onExited: (exitCode, exitStatus) => {");
        verify(exited.indexOf("Index.indexUnavailable") !== -1, "a missing index must be told apart from a search that matched nothing");
        verify(exited.indexOf("searchProc.indexed") !== -1, "and only an indexed run may fall back, or the fallback retries itself");
    }

    // A global search returns hits from directories the pane is not in, so
    // opening one through the pane's own path would open a file of the same
    // name in the wrong place, or nothing at all.
    function test_a_search_hit_opens_through_its_own_directory() {
        verify(Scan.blockAfter(filesSource(), "if (row.kind === \"entry\") {").indexOf("pane.activateAt(") !== -1, "an activated search row must open against the directory index.js attached to it");
    }
}
