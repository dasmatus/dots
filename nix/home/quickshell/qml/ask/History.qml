// The conversation list, down the side of the pane.
//
// Its rows come from the `conversations` event, which is an ephemeral
// per-connection reply carrying seq null and conversation null. It is never
// persisted and never replayed, so this list is whatever the daemon last
// answered `op:"list"` with, not something the client accumulates.
//
// A thread with no title yet shows its first prompt is still missing rather
// than an id: `title` stays null until the first turn names it, and a uuid tells
// a reader nothing at all.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import ".."
import "../common"

ColumnLayout {
    id: root

    required property var conversations
    required property string current

    signal picked(string conversation)
    signal removed(string conversation)
    signal created

    spacing: 6

    RowLayout {
        Layout.fillWidth: true

        spacing: 6

        Text {
            Layout.fillWidth: true

            text: "Threads"
            color: Theme.muted

            font.family: Theme.fontUi
            font.pointSize: 9
            font.bold: true
            font.capitalization: Font.AllUppercase
        }

        Pill {
            interactive: true
            color: Theme.bgDarker

            onClicked: root.created()

            Text {
                text: "New"
                color: Theme.fg

                font.family: Theme.fontUi
                font.pointSize: 9
                font.bold: true
            }
        }
    }

    ListView {
        id: list

        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.minimumHeight: 0

        model: root.conversations
        spacing: 2

        clip: true
        reuseItems: true
        boundsBehavior: Flickable.StopAtBounds

        delegate: Rectangle {
            id: entry

            required property var modelData

            readonly property bool active: entry.modelData.id === root.current

            width: ListView.view.width
            height: label.implicitHeight + subtitle.implicitHeight + 12

            radius: Theme.askRadius
            color: entry.active ? Theme.selection : "transparent"

            Text {
                id: label

                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: remove.left
                anchors.topMargin: 6
                anchors.leftMargin: 8
                anchors.rightMargin: 4

                text: entry.modelData.title ?? "Untitled"
                textFormat: Text.PlainText
                color: entry.active ? Theme.fg : Theme.fgDark

                font.family: Theme.fontUi
                font.pointSize: 10

                elide: Text.ElideRight
            }

            Text {
                id: subtitle

                anchors.top: label.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: 8
                anchors.rightMargin: 8

                text: `${entry.modelData.backend} · ${entry.modelData.turns} turns`
                textFormat: Text.PlainText
                color: Theme.muted

                font.family: Theme.fontUi
                font.pointSize: 8

                elide: Text.ElideRight
            }

            MouseArea {
                anchors.fill: parent

                cursorShape: Qt.PointingHandCursor

                onClicked: root.picked(entry.modelData.id)
            }

            // Declared after the row's own MouseArea, so it sits above it and
            // deleting a thread does not also open it on the way past.
            //
            // Always drawn rather than revealed on hover: a reveal would have
            // to read the row MouseArea's containsMouse, and a nested
            // hoverEnabled MouseArea stops that hover reaching the parent, so
            // the affordance would vanish the moment the pointer arrived on it.
            Text {
                id: remove

                anchors.top: parent.top
                anchors.right: parent.right
                anchors.topMargin: 6
                anchors.rightMargin: 8

                text: "✕"
                color: hover.containsMouse ? Theme.red : Theme.muted

                font.family: Theme.fontUi
                font.pointSize: 9

                MouseArea {
                    id: hover

                    anchors.fill: parent
                    anchors.margins: -6

                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor

                    onClicked: root.removed(entry.modelData.id)
                }
            }
        }
    }
}
