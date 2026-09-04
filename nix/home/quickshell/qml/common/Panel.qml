// The rounded surface both the launcher and the settings form draw their
// content on. What actually differs between the two — placement, size,
// focus handling, the click-outside-to-dismiss `PanelWindow` around it — stays
// in each caller; this is only the chrome that was byte-for-byte the same in
// both: the Theme.bg + Theme.alphaPanel fill, and the MouseArea that
// swallows a click before it reaches the dismiss handler behind the panel.
//
// `padding` is a property rather than a fixed inset because the two callers
// disagree on it (24 for a form with breathing room, 4 for a list that wants
// the space): the field says so out loud instead of a magic number hiding
// again in each caller.
import QtQuick
import ".."

Rectangle {
    id: root

    property int padding: 0

    default property alias content: contentArea.data

    radius: Theme.launcherRadius
    color: Qt.alpha(Theme.bg, parseInt(Theme.alphaPanel, 16) / 255)

    // Sits below `contentArea` in stacking order, so it only catches clicks
    // that land on bare panel background — a real control still gets its own
    // click first.
    MouseArea {
        anchors.fill: parent
    }

    Item {
        id: contentArea

        anchors.fill: parent
        anchors.margins: root.padding
    }
}
