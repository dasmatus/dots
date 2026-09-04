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

    // Sums the body's own implicit height rather than the column's, the same
    // way CodeBlock does, and for the same reason.
    //
    // A Flickable has NO implicit height. The body below is a fill-height
    // Flickable, so it contributes exactly 0 to column.implicitHeight, and a
    // card sized off that column measured the header alone: the path and the
    // +N/-N counts drew, and the diff itself was clipped to nothing. The
    // component rendered as a no-op and no test caught it, because nothing in
    // this suite can instantiate a component that reaches Theme.
    implicitHeight: Math.min(header.implicitHeight + body.implicitHeight + column.spacing + Theme.askGutter * 2, Theme.askCodeMaxHeight)

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
            id: header

            Layout.fillWidth: true

            spacing: Theme.askGutter

            Text {
                Layout.fillWidth: true

                text: root.path
                textFormat: Text.PlainText
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
