// One tool call: collapsed to a line, expanded to its arguments, its result
// and any diff it produced.
//
// AN INTERRUPTED TURN IS NOT A FAILED TURN, and this is the file that would get
// it wrong. When the user interrupts, the CLI still feeds the model a
// rejection, so a tool_result arrives with ok false on a turn the schema says
// did not error. Colouring on ok alone paints a red row on every interrupt.
//
// So the tone comes from ask.js's toolTone, which reads the turn's
// turn_end.stop as well as the result, and this file only maps a tone to a
// colour. "cancelled" is muted, not red: the user asked for it. The four tones
// are pending, ok, cancelled and error, and only the last is a failure.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import ".."

Item {
    id: root

    property var row: null
    property bool expanded: false

    signal decided(string request, string decision, string scope)

    readonly property string tone: root.row ? root.row.tone : "pending"

    // The one place a tone becomes a colour. Note what is missing: no branch
    // reads row.result.ok, because ok false means two different things and the
    // turn's stop is what separates them.
    readonly property color toneColor: {
        switch (root.tone) {
        case "ok":
            return Theme.green;
        case "error":
            return Theme.red;
        case "cancelled":
            return Theme.muted;
        default:
            return Theme.blue;
        }
    }

    readonly property string toneLabel: {
        switch (root.tone) {
        case "ok":
            return "done";
        case "error":
            return "failed";
        case "cancelled":
            return "cancelled";
        default:
            return "running";
        }
    }

    implicitHeight: column.implicitHeight

    ColumnLayout {
        id: column

        width: parent.width

        spacing: 6

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: headline.implicitHeight + 12

            radius: Theme.askRadius
            color: Theme.bgDark
            border.width: 1
            border.color: root.expanded ? root.toneColor : Theme.border

            RowLayout {
                id: headline

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Theme.askGutter
                anchors.rightMargin: Theme.askGutter

                spacing: 8

                Rectangle {
                    Layout.preferredWidth: 8
                    Layout.preferredHeight: 8

                    radius: 4
                    color: root.toneColor
                }

                Text {
                    text: root.row ? (root.row.displayName ?? root.row.name) : ""
                    textFormat: Text.PlainText
                    color: Theme.fg

                    font.family: Theme.fontUi
                    font.pointSize: 10
                    font.bold: true
                }

                Text {
                    Layout.fillWidth: true

                    text: root.row ? (root.row.summary ?? "") : ""
                    textFormat: Text.PlainText
                    color: Theme.muted

                    font.family: Theme.fontMono
                    font.pointSize: 9

                    elide: Text.ElideRight
                }

                Text {
                    text: root.toneLabel
                    color: root.toneColor

                    font.family: Theme.fontUi
                    font.pointSize: 9
                }
            }

            MouseArea {
                anchors.fill: parent

                cursorShape: Qt.PointingHandCursor

                onClicked: root.expanded = !root.expanded
            }
        }

        // An open permission prompt is never collapsed away. A prompt the user
        // cannot see is a turn that hangs with no visible cause.
        Approval {
            Layout.fillWidth: true

            visible: root.row !== null && root.row.permission !== null
            request: root.row ? root.row.permission : null

            onDecided: (decision, scope) => root.decided(root.row.permission.request, decision, scope)
        }

        Text {
            Layout.fillWidth: true

            visible: root.expanded && root.row !== null && root.row.input !== null
            text: root.row && root.row.input !== null ? JSON.stringify(root.row.input, null, 2) : ""
            textFormat: Text.PlainText
            color: Theme.fgDark

            font.family: Theme.fontMono
            font.pointSize: 9

            wrapMode: Text.Wrap
        }

        DiffView {
            Layout.fillWidth: true

            visible: root.row !== null && root.row.diff !== null
            path: root.row && root.row.diff ? root.row.diff.path : ""
            html: root.row && root.row.diff ? (root.row.diff.html ?? "") : ""
            newText: root.row && root.row.diff ? root.row.diff.newText : ""
            added: root.row && root.row.diff ? root.row.diff.added : 0
            removed: root.row && root.row.diff ? root.row.diff.removed : 0
        }

        Text {
            Layout.fillWidth: true

            visible: root.expanded && root.row !== null && root.row.result !== null
            text: root.row && root.row.result ? root.row.result.content + (root.row.result.truncated ? "\n[truncated]" : "") : ""
            textFormat: Text.PlainText
            color: root.tone === "error" ? Theme.red : Theme.fgDark

            font.family: Theme.fontMono
            font.pointSize: 9

            wrapMode: Text.Wrap
        }
    }
}
