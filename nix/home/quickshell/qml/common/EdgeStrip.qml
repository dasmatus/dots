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

    // Six of the eight call sites give the parent a corner radius
    // (files/Pane.qml, common/Field.qml, installer/Ai.qml and
    // DiskSelect.qml, monitors/Arrange.qml, wallpaper/Picker.qml); QtQuick
    // never clips a child to a Rectangle's rounded shape, so a strip
    // anchored flush to both ends of an edge painted a square corner past
    // the curve. Insetting the cross-axis anchors by the parent's own
    // radius keeps the strip inside the flat run between the two corners
    // instead of trying to round the strip's own ends to match — the strip
    // is usually only a couple of px thick, thinner than most of these
    // radii, and Qt Quick clamps a Rectangle's radius to half its shorter
    // side, so a rounded strip end would not trace the same curve as the
    // parent anyway.
    //
    // `parent` is statically just an Item to qmllint, which is why the read
    // below needs the disable: every real call site's parent is a
    // Rectangle, but files/Tabs.qml's square tab delegate has one with
    // radius 0, and tst_edge_strip.qml's older hosts are plain Items with
    // no radius property at all — both read as absent/0 and fall through
    // the `|| 0`, so this changes nothing for either.
    // qmllint disable missing-property
    readonly property real cornerInset: (root.parent && root.parent.radius) || 0

    anchors.top: parent.top
    anchors.left: parent.left
    anchors.bottom: root.edge === "left" ? parent.bottom : undefined
    anchors.right: root.edge === "top" ? parent.right : undefined
    anchors.topMargin: root.edge === "left" ? root.cornerInset : 0
    anchors.bottomMargin: root.edge === "left" ? root.cornerInset : 0
    anchors.leftMargin: root.edge === "top" ? root.cornerInset : 0
    anchors.rightMargin: root.edge === "top" ? root.cornerInset : 0

    width: root.edge === "left" ? root.thickness : undefined
    height: root.edge === "top" ? root.thickness : undefined

    visible: root.active
    color: root.tint
}
