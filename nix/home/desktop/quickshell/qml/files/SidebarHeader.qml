// A sidebar section title, one of Places, Bookmarks or Devices. Sidebar.qml
// used to hand-roll all three separately, which is how their margins could
// (and did) drift apart; factored here so a style or spacing change lands
// once.
import QtQuick
import QtQuick.Layouts
import ".."

Text {
    id: root

    required property string title
    // The first section needs no extra clearance above it: the column's
    // own edge margin already provides it. Every section after the first
    // needs a gap of its own to separate it from the list above.
    property bool first: false

    Layout.topMargin: root.first ? 0 : 10
    Layout.bottomMargin: 4

    text: root.title
    color: Theme.muted
    font.family: Theme.fontUi
    font.pixelSize: Theme.fontSize
    font.bold: true
}
