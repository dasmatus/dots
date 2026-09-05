// A centred glyph and message for a content column with nothing to show —
// a search that matched no row, or a nav page this task ships as a stub for
// a later one to fill in. One visual for both, since both are the same
// shape ("there is nothing here, and here is why") and a second one drawn
// per caller would just be this file copied with the words changed.
import QtQuick
import QtQuick.Layouts
import ".."

ColumnLayout {
    id: root

    property string glyph: "\u{F02FC}"
    property string message: ""

    anchors.centerIn: parent
    spacing: 8

    Text {
        Layout.alignment: Qt.AlignHCenter

        text: root.glyph
        color: Theme.dim

        font.family: Theme.fontUi
        font.pointSize: Theme.settingsTitleFontSize
    }

    Text {
        Layout.alignment: Qt.AlignHCenter

        text: root.message
        color: Theme.muted
        horizontalAlignment: Text.AlignHCenter

        font.family: Theme.fontUi
        font.pointSize: Theme.settingsRowDescFontSize
    }
}
