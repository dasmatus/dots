// The shell's rounded-capsule primitive: a Rectangle holding a row of
// content. Started as the bar's own, every module there is one of these,
// and now the launcher's filter pill bar builds on it too, which is why it
// lives in common/ rather than bar/.
//
// waybar drew these with `border-radius: 9999px` on every module, which is CSS
// for "as round as it gets". A Rectangle radius is a real number of pixels, so
// half the height is the honest way to write the same shape, and it stays right
// if the bar height ever changes.
//
// Sizing is intrinsic: a pill asks for the width its content needs plus
// padding, so the bar never hardcodes a module's width and a longer clock
// format cannot clip itself.
//
// The internal Row and MouseArea are assigned through `data` rather than
// written as plain children. `content` aliases the default property onto the
// Row, so anything declared as an ordinary child here would be routed into the
// Row it is trying to define.
import QtQuick
import ".."

Rectangle {
    id: root

    default property alias content: layout.data

    property int horizontalPadding: Theme.barPillPadding
    property bool interactive: false

    signal clicked
    signal middleClicked

    // Width follows the content; height does not. waybar gave every module a
    // 4px vertical margin inside a 30px bar, so the capsules were a uniform
    // 22px however tall their text happened to be. Letting each pill size to
    // its own glyphs instead would leave the battery and the clock disagreeing
    // by a pixel or two, which reads as a wobbling bar.
    implicitWidth: layout.implicitWidth + root.horizontalPadding * 2
    implicitHeight: Theme.barHeight - 8

    radius: height / 2
    color: Theme.bgDark

    data: [
        Row {
            id: layout

            anchors.centerIn: parent
            spacing: 6
        },
        MouseArea {
            anchors.fill: parent

            enabled: root.interactive
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
            cursorShape: root.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor

            onClicked: (mouse) => {
                if (mouse.button === Qt.MiddleButton) {
                    root.middleClicked();
                } else {
                    root.clicked();
                }
            }
        }
    ]
}
