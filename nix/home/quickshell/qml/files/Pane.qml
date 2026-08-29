// One directory's listing. `ls -1Ap --group-directories-first` runs as
// direct argv with no shell. Nothing on this path interpolates a path
// into a command string, so there is nothing here for a shell to need.
//
// `active` is owned by Files.qml, not by this file: only one side may be
// active at a time, and a property this file set on itself could not
// enforce that. A click anywhere in the pane asks the parent for focus via
// focusRequested() instead of claiming it directly.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "files.js" as FilesMath
import "operations.js" as Operations
import ".."

Rectangle {
    id: root

    required property string path
    required property bool active

    signal navigate(string path)
    signal focusRequested()

    property var entries: []
    property var selected: null

    color: Theme.bg
    border.width: root.active ? 2 : 0
    border.color: Theme.accent

    // A stale `selected` pointing at an entry the list no longer shows is
    // how a write operation can land on something the UI never highlighted:
    // navigating away (onPathChanged) drops it immediately, and every
    // completed listing (list()'s own async completion, below) drops it
    // again regardless of why list() ran — including a post-operation
    // refresh that Files.qml triggers with no path change at all.
    onPathChanged: {
        root.selected = null;
        root.list();
    }
    Component.onCompleted: root.list()

    function list(): void {
        lsProc.command = ["ls", "-1Ap", "--group-directories-first", "--", root.path];
        lsProc.running = true;
    }

    function activate(entry: var): void {
        const child = FilesMath.join(root.path, entry.name);

        if (entry.isDir) {
            root.navigate(child);
        } else {
            // Operations.openArgv, not an inline array literal: it has no
            // "--" and must never grow one — xdg-open's own argument loop
            // rejects it outright ("unexpected option '--'", exit 1),
            // confirmed against the exact binary this service resolves
            // from PATH, and broken that way once already by a "--" added
            // here in an earlier pass over this file. Being a pure
            // builder now means a test pins that shape directly. The
            // leading-dash exposure that earlier "--" was guarding
            // against is closed at its source instead: Files.qml's
            // setActivePath refuses a non-absolute root.path, so `child`
            // can never start with anything but "/".
            Quickshell.execDetached(Operations.openArgv(child));
        }
    }

    Process {
        id: lsProc

        stdout: StdioCollector {
            onStreamFinished: {
                root.selected = null;
                root.entries = FilesMath.parseListing(this.text);
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: root.active ? 2 : 0
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 8

            Text {
                text: "↑"
                color: Theme.fg
                font.family: Theme.fontUi

                MouseArea {
                    anchors.fill: parent
                    onClicked: {
                        root.focusRequested();
                        root.navigate(FilesMath.parentOf(root.path));
                    }
                }
            }

            Text {
                Layout.fillWidth: true
                text: root.path
                color: Theme.muted
                font.family: Theme.fontMono
                elide: Text.ElideMiddle
            }
        }

        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            model: root.entries

            delegate: Rectangle {
                id: row

                required property var modelData

                width: ListView.view.width
                height: 28
                color: root.selected === row.modelData ? Theme.bgDark : "transparent"

                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 12

                    text: (row.modelData.isDir ? "▸ " : "") + row.modelData.name
                    color: Theme.fg
                    font.family: Theme.fontUi
                }

                MouseArea {
                    anchors.fill: parent

                    onClicked: {
                        root.focusRequested();
                        root.selected = row.modelData;
                    }
                    onDoubleClicked: root.activate(row.modelData)
                }
            }
        }
    }
}
