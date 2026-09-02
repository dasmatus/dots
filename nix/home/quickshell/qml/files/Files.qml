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
import "operations.js" as Operations
import "tabs.js" as TabsMath
import "../services"
import ".."

Scope {
    id: root

    property var tabs: [TabsMath.newTab(Quickshell.env("HOME"))]
    property int activeTab: 0
    property string path: Quickshell.env("HOME")

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
                path: root.path
            } : tab)

    property string promptMode: ""
    property string promptText: ""
    // Captured by Operations.beginPrompt() when a rename/mkdir/trash-confirm
    // prompt opens, and the only thing confirmPrompt() resolves an argv
    // from — never the live selection, which can point somewhere else
    // entirely by the time the user presses Enter. See beginPrompt's own
    // comment in operations.js for why.
    property var promptSnapshot: null

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

    function switchTab(index: int): void {
        if (index === root.activeTab)
            return;

        root.tabs = root.displayTabs;
        root.activeTab = TabsMath.clampIndex(index, root.tabs.length);
        root.path = root.tabs[root.activeTab].path;
    }

    function addTab(): void {
        const opened = TabsMath.opened(root.displayTabs, root.path);
        root.tabs = opened;
        root.activeTab = opened.length - 1;
        root.path = opened[root.activeTab].path;
    }

    function closeTab(index: int): void {
        const snapshot = root.displayTabs;
        const next = TabsMath.closed(snapshot, index);

        if (next.length === snapshot.length)
            return;

        const landing = TabsMath.indexAfterClose(snapshot, index, root.activeTab);
        root.tabs = next;
        root.activeTab = TabsMath.clampIndex(landing, next.length);
        root.path = next[root.activeTab].path;
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

    function openCmdline(): void {
        root.promptSnapshot = null;
        root.promptMode = "command";
        cmdline.clear();
    }

    function closeCmdline(): void {
        root.promptMode = "";
        root.promptSnapshot = null;
        cmdline.clear();
        keys.forceActiveFocus();
    }

    // One dispatcher for both surfaces, so the `:` line and the right-click
    // menu cannot grow different ideas of what "Trash" does.
    function runRow(row: var): void {
        if (row.kind === "entry") {
            const entry = pane.entries[row.index];
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
            Keys.onPressed: (event) => {
                if (root.promptMode === "" && event.text === ":") {
                    root.openCmdline();
                    event.accepted = true;
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

                        onNavigate: (path) => root.path = path
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
                    entries: pane.entries
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
                onDismissed: keys.forceActiveFocus()
            }
        }
    }
}
