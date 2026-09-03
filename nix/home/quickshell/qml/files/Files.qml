// The file manager's outer shell: a tab strip, a places sidebar, one pane,
// and a `:` command line along the bottom.
//
// One pane, not two. The two-pane Norton Commander layout is what made
// Copy and Move mean "to the other side"; with a single pane they became a
// clipboard instead — yank or cut, change directory, paste. That is also
// the shape the command line already implies: a command, a navigation, a
// second command.
//
// A tab is one directory, and switching tabs swaps the pane's path.
// nixvim.nix runs bufferline in `mode = "tabs"`, so the strip is modelled
// on tabs rather than buffers. The live path stays on this object rather
// than inside the tabs array, because the Pane binds to it directly and a
// binding into `tabs[activeTab].path` would not re-evaluate when only the
// array element changed; `displayTabs` folds the live path back in for the
// strip to draw.
//
// The toolbar this file used to carry is gone. Its actions live in the
// command line and in the right-click menu, both built from commands.js,
// so the two surfaces cannot drift apart.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "files.js" as FilesMath
import "history.js" as HistoryMath
import "operations.js" as Operations
import "tabs.js" as TabsMath
import "../services"
import ".."

Scope {
    id: root

    property var tabs: [TabsMath.newTab(Quickshell.env("HOME"))]
    property int activeTab: 0
    property string path: Quickshell.env("HOME")

    // The active tab's own history. Each tab keeps its own, the way a
    // browser tab does, so Back never walks out of the directory tree you
    // were reading into one another tab happened to visit.
    property var history: HistoryMath.initial(Quickshell.env("HOME"))

    // Dotfiles are hidden until asked for, the way every graphical file
    // manager defaults, rather than the `ls -A` the listing used to run.
    property bool showHidden: false

    // What Copy or Cut picked up: the directory it came from, the name
    // inside it, and which builder Paste should use. Holding the directory
    // and name separately rather than a joined path is what lets Paste go
    // back through Operations.resolveSelectionArgv, which is the function
    // that rejects a name trying to escape its directory.
    property var clipboard: null

    // The strip draws from this, not from `tabs`: the active tab's path
    // only exists on `path` until something makes it switch away.
    readonly property var displayTabs: root.tabs.map((tab, index) => index === root.activeTab ? {
                path: root.path,
                history: root.history
            } : tab)

    property string promptMode: ""
    property string promptText: ""
    // Captured by Operations.beginPrompt() when a rename/mkdir/trash-confirm
    // prompt opens, and the only thing confirmPrompt() resolves an argv
    // from — never the live selection, which can point somewhere else
    // entirely by the time the user presses Enter. See beginPrompt's own
    // comment in operations.js for why.
    property var promptSnapshot: null

    // `/` searches the whole tree below the current directory, not just the
    // listing on screen. The walk runs in `find` and lands here; until it
    // does, and whenever the query is empty, the line falls back to the
    // directory already in memory so it is never blank while typing.
    property var searchResults: []
    readonly property string searchQuery: root.promptMode === "search" ? cmdline.query.trim() : ""
    readonly property var searchEntries: root.searchQuery === "" ? pane.entries : root.searchResults

    // A cap, not a page: a search for "e" under a home directory matches
    // tens of thousands of paths, and no one scrolls past the first screen
    // of a fuzzy search. The count of what was dropped is worth showing.
    readonly property int searchCap: 200
    property int searchFound: 0

    // Set by opRunner's onExited below when a write operation's exit code
    // is non-zero, so a refused gio trash or an mv/mkdir failure has
    // somewhere to surface instead of the pane just quietly re-listing as
    // if nothing happened. Cleared at the start of the next operation.
    property string lastError: ""

    function open(): void {
        window.visible = true;
    }

    function close(): void {
        window.visible = false;
    }

    function toggle(): void {
        window.visible = !window.visible;
    }

    function loadTab(tab: var): void {
        root.path = tab.path;
        root.history = tab.history;
    }

    function switchTab(index: int): void {
        if (index === root.activeTab)
            return;

        root.tabs = root.displayTabs;
        root.activeTab = TabsMath.clampIndex(index, root.tabs.length);
        root.loadTab(root.tabs[root.activeTab]);
    }

    function addTab(): void {
        const opened = TabsMath.opened(root.displayTabs, root.path);
        root.tabs = opened;
        root.activeTab = opened.length - 1;
        root.loadTab(opened[root.activeTab]);
    }

    function closeTab(index: int): void {
        const snapshot = root.displayTabs;
        const next = TabsMath.closed(snapshot, index);

        if (next.length === snapshot.length)
            return;

        const landing = TabsMath.indexAfterClose(snapshot, index, root.activeTab);
        root.tabs = next;
        root.activeTab = TabsMath.clampIndex(landing, next.length);
        root.loadTab(next[root.activeTab]);
    }

    // Back and Forward move the cursor without pushing, which is what keeps
    // Forward reachable after a Back. Every other navigation goes through
    // setActivePath and pushes, discarding whatever was ahead.
    function goBack(): void {
        if (!HistoryMath.canBack(root.history))
            return;

        root.history = HistoryMath.back(root.history);
        root.path = HistoryMath.currentOf(root.history);
    }

    function goForward(): void {
        if (!HistoryMath.canForward(root.history))
            return;

        root.history = HistoryMath.forward(root.history);
        root.path = HistoryMath.currentOf(root.history);
    }

    // Every in-tree caller already passes an absolute path — a mountpoint
    // from Devices, an XDG directory from places.js, or a child built
    // through FilesMath.join from an already-absolute pane path — except
    // `qs ipc call files openPath`, which hands over an arbitrary string
    // with no shape guarantee at all. `path` ends up unescaped in the
    // Pane's listing argv and, for a non-directory hit, in `xdg-open`'s,
    // which does not accept "--" at all (confirmed against the binary this
    // service resolves from PATH), so a relative-looking path handed to it
    // would be read as an option, not a path. Rejecting outright rather
    // than coercing: a malformed IPC call should do nothing, not land
    // somewhere the caller did not ask for. Operations.isAbsolutePath is
    // pure, so this specific guard is unit-tested with no live Files.qml
    // anywhere near the test.
    function setActivePath(newPath: string): void {
        if (!Operations.isAbsolutePath(newPath))
            return;

        root.history = HistoryMath.pushed(root.history, newPath);
        root.path = newPath;
    }

    function runOperation(argv: var): void {
        root.lastError = "";
        const runner = opRunner.createObject(root, {
            command: argv
        });
        runner.running = true;
    }

    // Copy and Cut only remember. Nothing runs until Paste, which is what
    // makes the pair usable in one pane: the directory you are standing in
    // when you pick is not the one you are standing in when you drop.
    function yank(mode: string): void {
        if (!pane.selected)
            return;

        root.clipboard = {
            dir: root.path,
            name: pane.selected.name,
            mode: mode
        };
    }

    // Goes back through resolveSelectionArgv rather than joining a path
    // here, so a clipboard entry whose name would escape its directory is
    // refused by the same check Copy and Move always used.
    function paste(): void {
        if (!root.clipboard)
            return;

        const argv = Operations.resolveSelectionArgv(root.clipboard.mode, root.clipboard.dir, root.clipboard.name, root.path);

        if (!argv) {
            root.lastError = Operations.escapesDirectoryMessage();
            return;
        }

        root.runOperation(argv);

        // A cut is spent once it lands; a copy stays, so the same file can
        // be dropped into several directories without picking it up again.
        if (root.clipboard.mode === "move")
            root.clipboard = null;
    }

    function beginRename(): void {
        if (!pane.selected)
            return;

        root.promptSnapshot = Operations.beginPrompt("rename", root.path, pane.selected.name);
        root.promptMode = "rename";
        root.promptText = pane.selected.name;
        cmdline.beginPrompt(root.promptText);
    }

    // Resolves strictly from promptSnapshot (captured when the prompt
    // opened) plus the live promptText, never from the live selection —
    // see promptSnapshot's own comment above for why. On rejection,
    // Operations.promptErrorMessage picks a naming-specific message for a
    // mode that actually validates a name and a generic one for a falsy
    // snapshot or an unrecognised mode, neither of which has a name to
    // blame — that choice is pure and lives in operations.js, testable
    // with no live prompt, rather than duplicated as QML here. Either way
    // the prompt closes, so nothing is left stuck on screen.
    function confirmPrompt(): void {
        const argv = Operations.resolvePromptArgv(root.promptSnapshot, root.promptText);
        if (argv)
            root.runOperation(argv);
        else
            root.lastError = Operations.promptErrorMessage(root.promptSnapshot);

        root.closeCmdline();
    }

    function beginMkdir(): void {
        root.promptSnapshot = Operations.beginPrompt("mkdir", root.path, null);
        root.promptMode = "mkdir";
        root.promptText = "";
        cmdline.beginPrompt("");
    }

    // Trash is the one operation here that destroys data by itself, rather
    // than merely relocating it, so it is the one gated on a confirmation.
    // Reuses promptMode's state machine rather than a second one:
    // promptText carries the selected entry's name for the confirm label,
    // never as editable input.
    function trashSelected(): void {
        if (!pane.selected)
            return;

        root.promptSnapshot = Operations.beginPrompt("trash-confirm", root.path, pane.selected.name);
        root.promptMode = "trash-confirm";
        root.promptText = pane.selected.name;
        cmdline.query = root.promptText;
    }

    // "command" for `:` and "search" for `/`. Two lines rather than one
    // list holding both kinds, the way vim splits them: the keystroke has
    // already said whether you are naming a command or naming a file.
    function openCmdline(mode: string): void {
        root.promptSnapshot = null;
        root.promptMode = mode;
        cmdline.clear();
    }

    function closeCmdline(): void {
        root.promptMode = "";
        root.promptSnapshot = null;
        cmdline.clear();
        catcher.forceActiveFocus();
    }

    // One dispatcher for both surfaces, so the `:` line and the right-click
    // menu cannot grow different ideas of what "Trash" does.
    function runRow(row: var): void {
        if (row.kind === "entry") {
            // searchEntries, not pane.entries: in search mode the rows come
            // from the recursive walk, and their names are paths relative to
            // the current directory. pane.activate joins against that same
            // directory, so a hit three levels down opens correctly without
            // a second join here.
            const entry = root.searchEntries[row.index];
            root.closeCmdline();

            if (entry)
                pane.activate(entry);

            return;
        }

        switch (row.id) {
        case "copy":
            root.closeCmdline();
            root.yank("copy");
            break;
        case "cut":
            root.closeCmdline();
            root.yank("move");
            break;
        case "paste":
            root.closeCmdline();
            root.paste();
            break;
        case "rename":
            root.beginRename();
            break;
        case "mkdir":
            root.beginMkdir();
            break;
        case "trash":
            root.trashSelected();
            break;
        case "hidden":
            root.closeCmdline();
            root.showHidden = !root.showHidden;
            break;
        }
    }

    // Debounced rather than fired per keystroke: a recursive walk of a home
    // directory costs far more than the keystroke that started it, and
    // typing "report" would otherwise launch six of them and race their
    // results back in whatever order they finished.
    Timer {
        id: searchDebounce

        interval: 180
        onTriggered: root.runSearch()
    }

    onSearchQueryChanged: {
        if (root.searchQuery === "") {
            searchDebounce.stop();
            searchProc.running = false;
            root.searchResults = [];
            root.searchFound = 0;
            return;
        }

        searchDebounce.restart();
    }

    function runSearch(): void {
        // Killing the previous walk before starting the next is what stops
        // a slow search for "r" from delivering its results on top of a
        // finished search for "report".
        searchProc.running = false;
        searchProc.command = FilesMath.searchArgv(root.path, root.searchQuery, root.showHidden);
        searchProc.running = true;
    }

    Process {
        id: searchProc

        stdout: StdioCollector {
            onStreamFinished: {
                const hits = FilesMath.parseListing(this.text);
                root.searchFound = hits.length;
                root.searchResults = hits.slice(0, root.searchCap);
            }
        }
    }

    Component {
        id: opRunner

        Process {
            // qmllint disable signal-handler-parameters
            onExited: (exitCode, exitStatus) => {
                root.lastError = exitCode === 0 ? "" : ("\"" + this.command.join(" ") + "\" failed (exit " + exitCode + ")");
                pane.list();
                destroy();
            }
            // qmllint enable signal-handler-parameters
        }
    }

    Connections {
        target: Devices

        function onRequestOpen(path) {
            root.setActivePath(path);
            root.open();
        }
    }

    IpcHandler {
        target: "files"

        function open(): void {
            root.open();
        }

        function close(): void {
            root.close();
        }

        function toggle(): void {
            root.toggle();
        }

        function openPath(path: string): void {
            root.setActivePath(path);
            root.open();
        }
    }

    FloatingWindow {
        id: window

        // ProxyWindowBase's own clear colour defaults to Qt::white, so
        // every child painted straight on the window reads on white
        // without this.
        color: Theme.bg

        visible: false
        implicitWidth: 1100
        implicitHeight: 700

        FocusScope {
            id: keys

            anchors.fill: parent
            focus: true

            // `:` opens the command line, the way it opens vim's. Every
            // other key falls through, so nothing here has to know about
            // the pane's own handling.
            //
            // This lives on its own item with `focus` BOUND to the closed
            // state rather than on the FocusScope with an imperative
            // forceActiveFocus() on close. A FocusScope routes key events
            // to whichever child it last focused, and the command line's
            // TextInput takes that focus imperatively when it opens; on
            // close the TextInput goes invisible but stays the scope's
            // focused child, so key events went to an item that could not
            // receive them and a second `:` did nothing. A binding
            // reclaims focus the moment promptMode goes back to "".
            Item {
                id: catcher

                anchors.fill: parent
                focus: root.promptMode === ""

                // `gg` is the one two-key sequence here, so it gets one
                // flag rather than a general pending-count machine. Any
                // other key clears it, which is what stops `g` then `j`
                // from jumping to the top a keystroke later.
                property bool pendingG: false

                Keys.onPressed: (event) => {
                    const wasPendingG = catcher.pendingG;
                    catcher.pendingG = false;
                    event.accepted = true;

                    if (event.text === ":") {
                        root.openCmdline("command");
                        return;
                    }

                    if (event.text === "/") {
                        root.openCmdline("search");
                        return;
                    }

                    switch (event.key) {
                    case Qt.Key_J:
                    case Qt.Key_Down:
                        pane.moveSelection(1);
                        return;
                    case Qt.Key_K:
                    case Qt.Key_Up:
                        pane.moveSelection(-1);
                        return;
                    // h leaves the directory and l enters the selection,
                    // which is the same left-is-out, right-is-in the
                    // arrows have.
                    case Qt.Key_H:
                    case Qt.Key_Left:
                        root.setActivePath(FilesMath.parentOf(root.path));
                        return;
                    case Qt.Key_L:
                    case Qt.Key_Right:
                    case Qt.Key_Return:
                    case Qt.Key_Enter:
                        pane.activateSelected();
                        return;
                    case Qt.Key_G:
                        // Shift+G is the bottom; a bare g arms the pair.
                        if (event.modifiers & Qt.ShiftModifier)
                            pane.selectIndex(pane.entries.length - 1);
                        else if (wasPendingG)
                            pane.selectIndex(0);
                        else
                            catcher.pendingG = true;

                        return;
                    }

                    event.accepted = false;
                }
            }

            ColumnLayout {
                anchors.fill: parent
                spacing: 0

                Tabs {
                    Layout.fillWidth: true

                    tabs: root.displayTabs
                    activeIndex: root.activeTab

                    onSelected: (index) => root.switchTab(index)
                    onClosed: (index) => root.closeTab(index)
                    onAdded: root.addTab()
                }

                // Spans the window rather than sitting inside the pane: it
                // describes the tab, and the sidebar changes it too.
                PathBar {
                    Layout.fillWidth: true

                    path: root.path
                    canBack: HistoryMath.canBack(root.history)
                    canForward: HistoryMath.canForward(root.history)

                    onNavigate: (path) => root.setActivePath(path)
                    onBack: root.goBack()
                    onForward: root.goForward()
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.margins: Theme.filesPadding

                    spacing: Theme.filesGutter

                    Sidebar {
                        Layout.fillHeight: true
                        Layout.preferredWidth: Theme.filesSidebarWidth

                        onRequested: (path) => root.setActivePath(path)
                    }

                    Pane {
                        id: pane

                        Layout.fillWidth: true
                        Layout.fillHeight: true

                        path: root.path
                        active: true
                        showHidden: root.showHidden

                        onNavigate: (path) => root.setActivePath(path)
                        onContextRequested: (x, y) => menu.openAt(x, y)
                    }
                }

                // A failed mv/cp/mkdir/gio only shows up here: the pane
                // re-lists unconditionally on every operation exit, success
                // or not, since a partial failure still needs whatever DID
                // change reflected. Without this a refused gio trash (e.g.
                // across a filesystem boundary it won't cross) looked
                // identical to a trash that actually happened.
                Rectangle {
                    Layout.fillWidth: true
                    Layout.leftMargin: Theme.filesPadding
                    Layout.rightMargin: Theme.filesPadding
                    Layout.bottomMargin: Theme.filesPadding

                    implicitHeight: Theme.filesRowHeight
                    radius: Theme.filesRadius / 2
                    color: Theme.bgDark
                    visible: root.lastError !== ""

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        spacing: 8

                        Text {
                            text: "\u{F0026}"
                            color: Theme.red
                            font.family: Theme.fontUi
                            font.pixelSize: Theme.filesIconSize
                        }

                        Text {
                            Layout.fillWidth: true
                            text: root.lastError
                            color: Theme.red
                            font.family: Theme.fontMono
                            font.pixelSize: Theme.fontSize
                            elide: Text.ElideRight
                        }
                    }
                }

                CommandLine {
                    id: cmdline

                    Layout.fillWidth: true

                    mode: root.promptMode
                    entries: root.searchEntries
                    selection: pane.selected
                    clipboard: root.clipboard
                    showHidden: root.showHidden

                    onActivated: (row) => root.runRow(row)
                    onSubmitted: (text) => {
                        root.promptText = text;
                        root.confirmPrompt();
                    }
                    onCancelled: root.closeCmdline()
                }
            }

            // Mounted on the window rather than inside the pane, so a menu
            // opened near an edge can overhang the pane it came from.
            Menu {
                id: menu

                selection: pane.selected
                clipboard: root.clipboard
                showHidden: root.showHidden

                onActivated: (row) => root.runRow(row)
                onDismissed: catcher.forceActiveFocus()
            }
        }
    }
}
