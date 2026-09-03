// The right-click menu. Same action list the `:` line offers, minus the
// filter and the directory entries: a menu is already pointing at
// something, so it needs no way to choose one.
//
// The popup mechanics — placement, clamping, the bottom-edge flip, the
// dismiss backdrop, openAt()/close() — live in PopupShell, extended here as
// the root rather than wrapped, the way the bar's pills extend Pill. This
// file keeps only what a right-click menu adds on top: the rows themselves,
// how tall they make the panel, and their hover highlight.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import "commands.js" as Commands
import "../common"
import ".."

PopupShell {
    id: root

    required property var selection
    required property var clipboard
    required property bool showHidden

    readonly property var rows: Commands.menuRows(root.selection, root.clipboard, root.showHidden)

    signal activated(var row)

    panelHeight: column.implicitHeight + Theme.filesPadding

    ColumnLayout {
        id: column

        anchors.fill: parent
        anchors.margins: Theme.filesPadding / 2
        spacing: 0

        Repeater {
            model: root.rows

            delegate: Rectangle {
                id: item

                required property var modelData

                Layout.fillWidth: true
                implicitHeight: Theme.filesRowHeight

                radius: Theme.filesRadius / 2
                color: itemArea.containsMouse ? Theme.accent : "transparent"

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    spacing: 0

                    Text {
                        Layout.preferredWidth: Theme.filesIconColumn

                        text: item.modelData.glyph
                        // icons.js and commands.js hand back a Theme
                        // property name, so the lookup is the property
                        // access rather than a switch in every consumer.
                        color: itemArea.containsMouse ? Theme.bg : Tokens.colourOf(item.modelData.colour)
                        font.family: Theme.fontUi
                        font.pixelSize: Theme.filesIconSize
                    }

                    Text {
                        Layout.fillWidth: true

                        text: item.modelData.title
                        color: itemArea.containsMouse ? Theme.bg : Theme.fg
                        font.family: Theme.fontUi
                        font.pixelSize: Theme.fontSize
                    }
                }

                MouseArea {
                    id: itemArea

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.close();
                        root.activated(item.modelData);
                    }
                }
            }
        }
    }
}
