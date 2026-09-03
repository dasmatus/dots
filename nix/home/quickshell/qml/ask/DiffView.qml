// A file edit, as a unified diff.
//
// The daemon always produces the diff event; the CLI emits none of its own. It
// builds one from the tool result's structuredPatch when that is non-empty, and
// reshapes it from the tool arguments otherwise. Either way `html` arrives
// pre-rendered by render.rs, so this file paints and does not diff.
//
// When html is null the fallback is the counted lines plus the new text, which
// is honest about what it has rather than pretending to a diff it was not
// given. old_text and new_text are always present, so a later phase can build a
// client-side fallback here without the schema changing.
//
// Raw providers emit no diff at all: in provider mode there are no file tools
// to diff. A tool row with no diff simply does not instantiate this.
import QtQuick
import QtQuick.Layouts
import ".."

Rectangle {
    id: root

    property string path: ""
    property string html: ""
    property string newText: ""
    property int added: 0
    property int removed: 0

    readonly property bool rendered: root.html !== ""

    implicitHeight: Math.min(column.implicitHeight + Theme.askGutter * 2, Theme.askCodeMaxHeight)

    radius: Theme.askRadius
    color: Theme.bgDarker
    border.width: 1
    border.color: Theme.border

    ColumnLayout {
        id: column

        anchors.fill: parent
        anchors.margins: Theme.askGutter

        spacing: 6

        RowLayout {
            Layout.fillWidth: true

            spacing: Theme.askGutter

            Text {
                Layout.fillWidth: true

                text: root.path
                color: Theme.fgDark

                font.family: Theme.fontMono
                font.pointSize: 9

                // The tail of a path is what identifies the file; the head is
                // the part every path in one checkout shares.
                elide: Text.ElideLeft
            }

            Text {
                text: `+${root.added}`
                color: Theme.green

                font.family: Theme.fontMono
                font.pointSize: 9
                font.bold: true
            }

            Text {
                text: `-${root.removed}`
                color: Theme.red

                font.family: Theme.fontMono
                font.pointSize: 9
                font.bold: true
            }
        }

        Flickable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 0

            contentWidth: body.implicitWidth
            contentHeight: body.implicitHeight
            clip: true

            Text {
                id: body

                text: root.rendered ? root.html : root.newText
                textFormat: root.rendered ? Text.RichText : Text.PlainText
                color: Theme.fg

                font.family: Theme.fontMono
                font.pointSize: 10

                wrapMode: Text.NoWrap
            }
        }
    }
}
