// A thin accent line on one edge of its parent, for surfaces that mark
// state — the active tab, the selected drive, a focused field — without
// spending a full border on it. files/Tabs.qml drew this inline first, for
// its active tab's leading edge; Task 4 gives Field.qml's focus ring and
// five more call sites the same shape, so it lives here once instead of
// six times over.
//
// Only "left" and "top" are supported because those are the two edges the
// shell actually marks state on: left for a vertical run of tabs or a side
// list, top for a horizontal band.
import QtQuick
import ".."

Rectangle {
    id: root

    property string edge
    property bool active: false
    property color tint: Theme.accent
    property int thickness: Theme.chromeStripWidth

    anchors.top: parent.top
    anchors.left: parent.left
    anchors.bottom: root.edge === "left" ? parent.bottom : undefined
    anchors.right: root.edge === "top" ? parent.right : undefined

    width: root.edge === "left" ? root.thickness : undefined
    height: root.edge === "top" ? root.thickness : undefined

    visible: root.active
    color: root.tint
}
