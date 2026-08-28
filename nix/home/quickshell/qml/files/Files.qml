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

    function open(): void {
        window.visible = true;
    }

    function close(): void {
        window.visible = false;
    }

    function toggle(): void {
        window.visible = !window.visible;
    }

    function setActivePath(path: string): void {
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
        const runner = opRunner.createObject(root, { command: argv });
        runner.running = true;
    }

    function beginRename(): void {
        if (!root.activePane.selected)
            return;

        root.promptMode = "rename";
        root.promptText = root.activePane.selected.name;
    }

    function confirmPrompt(): void {
        if (root.promptMode === "rename") {
            const oldPath = FilesMath.join(root.activePane.path, root.activePane.selected.name);
            const newPath = FilesMath.join(root.activePane.path, root.promptText);
            root.runOperation(Operations.renameArgv(oldPath, newPath));
        }

        root.promptMode = "";
    }

    function cancelPrompt(): void {
        root.promptMode = "";
    }

    Component {
        id: opRunner

        Process {
            // qmllint disable signal-handler-parameters
            onExited: (exitCode, exitStatus) => {
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

                TextInput {
                    Layout.preferredWidth: 200
                    visible: root.promptMode !== ""
                    text: root.promptText
                    color: Theme.fg
                    font.family: Theme.fontUi

                    onTextChanged: root.promptText = text
                    onVisibleChanged: if (visible) forceActiveFocus()

                    Keys.onReturnPressed: root.confirmPrompt()
                    Keys.onEscapePressed: root.cancelPrompt()
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
