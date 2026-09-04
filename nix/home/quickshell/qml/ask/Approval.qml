// The permission prompt: allow once, allow always, or deny.
//
// Deny by default is the rule the daemon enforces and this is its face. Nothing
// runs without a decision a person made or a rule a person wrote earlier, so
// there is no default button and no timeout that picks one.
//
// The three buttons map onto op:"permission" as decision plus scope. "Allow
// once" is allow/once and dies with the call. "Always" is allow/forever and is
// the only one policy.rs writes to disk, keyed by backend, tool, argument
// pattern and the conversation's cwd, so an approval granted in one checkout
// does not carry into another. Deny sends a reason back, which the CLI hands
// the model verbatim as an error tool_result.
//
// The session scope the schema also carries has no button. Three choices is
// already the most a prompt can ask for without being read past, and "until
// this conversation ends" is the one a person can least predict the reach of.
//
// A withdrawn prompt never gets here: ask.js clears the row's permission on
// withdrawn true, and on an interrupt, so this only ever renders a request the
// daemon is still waiting on.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import ".."
import "../common"

Rectangle {
    id: root

    property var request: null

    signal decided(string decision, string scope)

    implicitHeight: column.implicitHeight + Theme.askGutter * 2

    radius: Theme.askRadius
    color: Theme.bgDark
    border.width: 1
    border.color: Theme.yellow

    ColumnLayout {
        id: column

        anchors.fill: parent
        anchors.margins: Theme.askGutter

        spacing: 8

        Text {
            Layout.fillWidth: true

            text: root.request ? `${root.request.displayName ?? root.request.name} wants to run` : ""
            textFormat: Text.PlainText
            color: Theme.yellow

            font.family: Theme.fontUi
            font.pointSize: 10
            font.bold: true

            elide: Text.ElideRight
        }

        Text {
            Layout.fillWidth: true

            text: root.request ? (root.request.description ?? JSON.stringify(root.request.input ?? {})) : ""
            textFormat: Text.PlainText
            color: Theme.fgDark

            font.family: Theme.fontMono
            font.pointSize: 9

            wrapMode: Text.Wrap
            maximumLineCount: 4
            elide: Text.ElideRight
        }

        RowLayout {
            Layout.fillWidth: true

            spacing: 6

            Pill {
                interactive: true
                color: Theme.green

                onClicked: root.decided("allow", "once")

                Text {
                    text: "Allow once"
                    color: Theme.bg

                    font.family: Theme.fontUi
                    font.pointSize: 9
                    font.bold: true
                }
            }

            Pill {
                interactive: true
                color: Theme.blue

                onClicked: root.decided("allow", "forever")

                Text {
                    text: "Always"
                    color: Theme.bg

                    font.family: Theme.fontUi
                    font.pointSize: 9
                    font.bold: true
                }
            }

            Pill {
                interactive: true
                color: Theme.red

                onClicked: root.decided("deny", "once")

                Text {
                    text: "Deny"
                    color: Theme.bg

                    font.family: Theme.fontUi
                    font.pointSize: 9
                    font.bold: true
                }
            }

            Item {
                Layout.fillWidth: true
            }
        }
    }
}
