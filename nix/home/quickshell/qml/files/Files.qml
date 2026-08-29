// The file manager's outer shell, now two Panes: leftPath/rightPath persist
// independently, and activeSide says which one write operations (added
// later in this plan) act on. Devices.requestOpen and openPath both target
// whichever side is active, through setActivePath, the same single
// entrypoint Plan 1 established, extended rather than replaced.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "files.js" as FilesMath
import "operations.js" as Operations
import "../services"
import ".."

Scope {
    id: root

    property string leftPath: Quickshell.env("HOME")
    property string rightPath: Quickshell.env("HOME")
    property string activeSide: "left"

    readonly property var activePane: root.activeSide === "left" ? leftPane : rightPane
    readonly property var otherPane: root.activeSide === "left" ? rightPane : leftPane

    property string promptMode: ""
    property string promptText: ""
    // Captured by Operations.beginPrompt() when a rename/mkdir/trash-confirm
    // prompt opens, and the only thing confirmPrompt() resolves an argv
    // from — never the live activePane/selected, which can point somewhere
    // else entirely by the time the user presses Enter. See beginPrompt's
    // own comment in operations.js for why.
    property var promptSnapshot: null

    // Set by opRunner's onExited below when a write operation's exit code
    // is non-zero, so a refused gio trash or an mv/mkdir failure has
    // somewhere to surface instead of the panes just quietly re-listing as
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

    // Every in-tree caller already passes an absolute path — a mountpoint
    // from Devices, or a child built through FilesMath.join from an
    // already-absolute pane path — except `qs ipc call files openPath`,
    // which hands over an arbitrary string with no shape guarantee at
    // all. leftPath/rightPath end up unescaped in every Pane's `ls` argv
    // and, for a non-directory hit, in `xdg-open`'s — `ls` tolerates a
    // leading "-" via its own "--", but `xdg-open` does not accept "--"
    // at all (confirmed against the binary this service resolves from
    // PATH), so a relative-looking path handed to it would be read as an
    // option, not a path. Rejecting outright rather than coercing (e.g.
    // prefixing "./"): a malformed IPC call should do nothing, not land
    // somewhere the caller did not ask for.
    function setActivePath(path: string): void {
        if (!path.startsWith("/"))
            return;

        if (root.activeSide === "left")
            root.leftPath = path;
        else
            root.rightPath = path;
    }

    function copySelected(): void {
        const pane = root.activePane;
        if (!pane.selected)
            return;

        root.runOperation(Operations.copyArgv(FilesMath.join(pane.path, pane.selected.name), root.otherPane.path));
    }

    function moveSelected(): void {
        const pane = root.activePane;
        if (!pane.selected)
            return;

        root.runOperation(Operations.moveArgv(FilesMath.join(pane.path, pane.selected.name), root.otherPane.path));
    }

    function runOperation(argv: var): void {
        root.lastError = "";
        const runner = opRunner.createObject(root, { command: argv });
        runner.running = true;
    }

    function beginRename(): void {
        if (!root.activePane.selected)
            return;

        root.promptSnapshot = Operations.beginPrompt("rename", root.activePane.path, root.activePane.selected.name);
        root.promptMode = "rename";
        root.promptText = root.activePane.selected.name;
    }

    // Every mode this file ever puts into a snapshot, so confirmPrompt()
    // below can tell "isValidEntryName rejected something" apart from
    // "there was never a valid snapshot to resolve" without duplicating
    // operations.js's own mode dispatch.
    readonly property var promptModes: ["rename", "mkdir", "trash-confirm"]

    // Resolves strictly from promptSnapshot (captured when the prompt
    // opened) plus the live promptText, never from activePane/selected —
    // see promptSnapshot's own comment above for why. resolvePromptArgv
    // returns null either because isValidEntryName rejected a name (the
    // typed text for rename/mkdir, or the snapshot's own name for
    // trash-confirm) or because the snapshot itself is falsy or carries a
    // mode none of beginRename/beginMkdir/trashSelected ever produces — a
    // should-never-happen case kept generic rather than blamed on a name,
    // since no name was involved. Either way the prompt closes, so nothing
    // is left stuck on screen.
    function confirmPrompt(): void {
        const argv = Operations.resolvePromptArgv(root.promptSnapshot, root.promptText);
        if (argv)
            root.runOperation(argv);
        else if (root.promptSnapshot && root.promptModes.includes(root.promptSnapshot.mode))
            root.lastError = "Invalid name: cannot be empty or whitespace-only, contain \"/\" or a newline, or be \"..\"";
        else
            root.lastError = "Nothing to confirm";

        root.promptMode = "";
        root.promptSnapshot = null;
    }

    function cancelPrompt(): void {
        root.promptMode = "";
        root.promptSnapshot = null;
    }

    function beginMkdir(): void {
        root.promptSnapshot = Operations.beginPrompt("mkdir", root.activePane.path, null);
        root.promptMode = "mkdir";
        root.promptText = "";
    }

    // Trash is the one operation here that destroys data by itself, rather
    // than merely relocating it within reach of the two panes, so it is the
    // one operation gated on a confirmation rather than firing straight off
    // the toolbar click. Reuses promptMode's state machine rather than a
    // second one: promptText carries the selected entry's name for the
    // confirm label below, never as editable input — the rename/mkdir
    // TextInput stays hidden for this mode, a separate Text shows instead.
    function trashSelected(): void {
        if (!root.activePane.selected)
            return;

        root.promptSnapshot = Operations.beginPrompt("trash-confirm", root.activePane.path, root.activePane.selected.name);
        root.promptMode = "trash-confirm";
        root.promptText = root.activePane.selected.name;
    }

    Component {
        id: opRunner

        Process {
            // qmllint disable signal-handler-parameters
            onExited: (exitCode, exitStatus) => {
                root.lastError = exitCode === 0 ? "" : ("\"" + this.command.join(" ") + "\" failed (exit " + exitCode + ")");
                leftPane.list();
                rightPane.list();
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

        visible: false
        implicitWidth: 1200
        implicitHeight: 600

        ColumnLayout {
            anchors.fill: parent
            spacing: 0

            RowLayout {
                Layout.fillWidth: true
                Layout.margins: 4
                spacing: 12

                Text {
                    text: "Copy →"
                    color: Theme.fg
                    font.family: Theme.fontUi

                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.copySelected()
                    }
                }

                Text {
                    text: "Move →"
                    color: Theme.fg
                    font.family: Theme.fontUi

                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.moveSelected()
                    }
                }

                Text {
                    text: "Rename"
                    color: Theme.fg
                    font.family: Theme.fontUi

                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.beginRename()
                    }
                }

                Text {
                    text: "New Folder"
                    color: Theme.fg
                    font.family: Theme.fontUi

                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.beginMkdir()
                    }
                }

                Text {
                    text: "Trash"
                    color: Theme.red
                    font.family: Theme.fontUi

                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.trashSelected()
                    }
                }

                TextInput {
                    Layout.preferredWidth: 200
                    visible: root.promptMode === "rename" || root.promptMode === "mkdir"
                    text: root.promptText
                    color: Theme.fg
                    font.family: Theme.fontUi

                    onTextChanged: root.promptText = text
                    onVisibleChanged: if (visible) forceActiveFocus()

                    Keys.onReturnPressed: root.confirmPrompt()
                    Keys.onEscapePressed: root.cancelPrompt()
                }

                // Trash needs no free-text entry, only a yes/no, so it gets
                // its own label rather than sharing the TextInput above —
                // that field's own text is bound to promptText and would let
                // the confirm turn into an accidental rename.
                Text {
                    visible: root.promptMode === "trash-confirm"
                    text: "Trash \"" + root.promptText + "\"? Enter / Esc"
                    color: Theme.red
                    font.family: Theme.fontUi

                    onVisibleChanged: if (visible) forceActiveFocus()

                    Keys.onReturnPressed: root.confirmPrompt()
                    Keys.onEscapePressed: root.cancelPrompt()
                }
            }

            // A failed mv/cp/mkdir/gio only shows up here: the panes below
            // re-list unconditionally on every operation exit, success or
            // not, since a partial failure still needs whatever DID change
            // reflected. Without this a refused gio trash (e.g. across a
            // filesystem boundary it won't cross) looked identical to a
            // trash that actually happened.
            RowLayout {
                Layout.fillWidth: true
                Layout.margins: 4
                visible: root.lastError !== ""

                Text {
                    Layout.fillWidth: true
                    text: root.lastError
                    color: Theme.red
                    font.family: Theme.fontUi
                    elide: Text.ElideRight
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 0

                Sidebar {
                    Layout.fillHeight: true
                    Layout.preferredWidth: 200
                }

                Pane {
                    id: leftPane

                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    path: root.leftPath
                    active: root.activeSide === "left"
                    onNavigate: (path) => root.leftPath = path
                    onFocusRequested: root.activeSide = "left"
                }

                Pane {
                    id: rightPane

                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    path: root.rightPath
                    active: root.activeSide === "right"
                    onNavigate: (path) => root.rightPath = path
                    onFocusRequested: root.activeSide = "right"
                }
            }
        }
    }
}
