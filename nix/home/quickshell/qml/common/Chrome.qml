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

    Panel {
        id: panel

        anchors.fill: parent
        padding: root.padding

        ColumnLayout {
            anchors.fill: parent

            spacing: 10

            Text {
                text: root.title
                color: Theme.accent

                font.family: Theme.fontUi
                font.pointSize: 14
                font.bold: true
            }

            Item {
                id: body

                Layout.fillWidth: true
                Layout.fillHeight: true
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
