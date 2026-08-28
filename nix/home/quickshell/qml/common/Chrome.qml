// The two things every popup surface besides the launcher used to hand-roll
// for itself: an accent heading top-left and a footer bar naming the keys
// that work on that surface. Panel already owns the border, the fill and the
// click-swallowing MouseArea; this only wraps it with the parts that
// differed surface to surface purely because nothing collected them in one
// place before.
import QtQuick
import QtQuick.Layouts
import ".."

Item {
    id: root

    property string title: ""
    property var hints: []
    property int padding: 0

    default property alias content: body.data

    // Lets a caller size itself off a real number instead of a guessed
    // constant meant to cover whatever the header and footer cost: a
    // ColumnLayout's own implicitHeight already sums a hidden footer as
    // zero, so this needs no separate visibility bookkeeping.
    implicitHeight: shell.implicitHeight + root.padding * 2

    Panel {
        id: panel

        anchors.fill: parent
        padding: root.padding

        ColumnLayout {
            id: shell

            anchors.fill: parent

            spacing: 10

            Text {
                text: root.title
                color: Theme.accent

                font.family: Theme.fontUi
                font.pointSize: 14
                font.bold: true
            }

            // A real Layout, not a bare Item, so a caller's top-level
            // content can use Layout.fillWidth/fillHeight the ordinary way
            // instead of having to know this needs anchors.fill instead.
            ColumnLayout {
                id: body

                Layout.fillWidth: true
                Layout.fillHeight: true
                // Without this, a real ColumnLayout's default minimum
                // height (its implicitHeight) refuses to shrink body below
                // its natural size, so a caller squeezed by its own
                // `parent.height - 80` cap overflows instead of
                // compressing the way the old bare Item silently did.
                Layout.minimumHeight: 0
            }

            Text {
                Layout.fillWidth: true

                // Theme has no dim-foreground token (see tree.nix's generated
                // properties) — opacity on the shared foreground keeps the
                // hint bar off nix/palette.json rather than adding one for a
                // single label.
                text: root.hints.map(h => `${h.key} ${h.label}`).join("   ·   ")
                color: Theme.fg
                opacity: 0.6
                visible: root.hints.length > 0

                font.family: Theme.fontUi
                font.pointSize: 9

                elide: Text.ElideRight
            }
        }
    }
}
