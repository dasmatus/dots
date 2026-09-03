// The mechanics shared by every popup that opens at a point and closes on
// an outside click: files/Menu.qml's right-click menu today, and a
// path-segment dropdown due to land beside it. Both want the same panel —
// clamped inside the parent, flipped above the anchor point when there is
// no room to open downward — and the same way of closing, so this holds
// that half and leaves the row content, and how tall it ends up, to the
// caller: `content` and `panelHeight` do for a popup what `Panel.qml`'s own
// `content` and the caller-computed `height` do for a fixed-position one.
//
// The `MouseArea` behind the panel is the part worth explaining: the click
// that dismisses a popup almost always lands somewhere else entirely — on
// the pane row a right-click menu was opened over, in Menu.qml's case.
// Without a full-size area behind the panel catching that click first, it
// would fall through to whatever the popup was covering, and closing the
// menu would also re-fire the row underneath it.
import QtQuick
import ".."

Item {
    id: root

    property real anchorX: 0
    property real anchorY: 0
    property int panelWidth: Theme.filesMenuWidth
    property real panelHeight: 0

    default property alias content: panel.data

    signal dismissed()

    visible: false
    anchors.fill: parent

    function openAt(x: real, y: real): void {
        root.anchorX = x;
        root.anchorY = y;
        root.visible = true;
    }

    function close(): void {
        root.visible = false;
    }

    // Swallows the click that dismisses the popup so it does not also land
    // on whatever sits under the cursor.
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: {
            root.close();
            root.dismissed();
        }
    }

    Rectangle {
        id: panel

        x: Math.max(0, Math.min(root.anchorX, root.width - width))
        y: root.anchorY + height > root.height ? Math.max(0, root.anchorY - height) : root.anchorY

        implicitWidth: root.panelWidth
        implicitHeight: root.panelHeight

        radius: Theme.filesRadius
        color: Theme.bgDark
        border.width: 1
        border.color: Theme.border
    }
}
