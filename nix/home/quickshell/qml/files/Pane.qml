// One directory's listing. `ls -1Ap --group-directories-first` runs as
// direct argv with no shell. Nothing on this path interpolates a path
// into a command string, so there is nothing here for a shell to need.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "files.js" as FilesMath
import ".."

Item {
    id: root

    required property string path

    signal navigate(string path)

    property var entries: []

    onPathChanged: root.list()
    Component.onCompleted: root.list()

    function list(): void {
        lsProc.command = ["ls", "-1Ap", "--group-directories-first", root.path];
        lsProc.running = true;
    }

    function activate(entry: var): void {
        const child = FilesMath.join(root.path, entry.name);

        if (entry.isDir) {
            root.navigate(child);
        } else {
            Quickshell.execDetached(["xdg-open", child]);
        }
    }

    Process {
        id: lsProc

        stdout: StdioCollector {
            onStreamFinished: root.entries = FilesMath.parseListing(this.text)
        }
    }

    ColumnLayout {
        anchors.fill: parent
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
                    onClicked: root.navigate(FilesMath.parentOf(root.path))
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
                color: "transparent"

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
                    onClicked: root.activate(row.modelData)
                }
            }
        }
    }
}
