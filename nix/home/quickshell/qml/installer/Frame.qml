// The chrome every wizard page shares: a centered title over its own
// content, an inline error line, and a footer hint naming the keys that work
// on that page. Factored out once eight screens needed the same three-part
// layout, so a new screen only supplies what actually differs.
//
// `activated` re-exposes the StackView attachment (`StackView.onActivated`)
// under a plain signal so screens never need `import QtQuick.Controls`
// themselves just to grab keyboard focus back after a push/replace — only
// this file needs to know StackView exists.
import QtQuick
import QtQuick.Controls
import ".."

Item {
    id: root

    required property string title
    property string hint: ""
    property string error: ""

    default property alias content: contentArea.data

    signal activated()

    StackView.onActivated: root.activated()

    anchors.fill: parent

    Rectangle {
        anchors.fill: parent
        color: Theme.bg
    }

    Column {
        anchors.centerIn: parent

        width: Math.min(720, parent.width - 160)
        spacing: 20

        Text {
            width: parent.width

            text: root.title
            color: Theme.accent

            font.family: Theme.fontUi
            font.pixelSize: Theme.fontSize * 2
            font.bold: true
        }

        Item {
            id: contentArea

            width: parent.width
            height: childrenRect.height
        }

        Text {
            width: parent.width

            visible: root.error.length > 0
            text: root.error
            color: Theme.red
            wrapMode: Text.WordWrap

            font.family: Theme.fontUi
            font.pixelSize: Theme.fontSize
        }

        Text {
            width: parent.width

            visible: root.hint.length > 0
            text: root.hint
            color: Theme.muted
            wrapMode: Text.WordWrap

            font.family: Theme.fontUi
            font.pixelSize: Theme.fontSize * 0.85
        }
    }
}
