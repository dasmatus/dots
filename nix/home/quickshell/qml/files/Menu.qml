// The right-click menu. Same action list the `:` line offers, minus the
// filter and the directory entries: a menu is already pointing at
// something, so it needs no way to choose one.
//
// Positioned by the caller in window coordinates and clamped here rather
// than there, because only this file knows how tall it ended up once the
// row count is known. Right-clicking near the bottom edge flips it above
// the cursor instead of letting it hang off the window.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import "commands.js" as Commands
import "../common"
import ".."

Item {
    id: root

    required property var selection
    required property var clipboard
    required property bool showHidden

    property real anchorX: 0
    property real anchorY: 0

    readonly property var rows: Commands.menuRows(root.selection, root.clipboard, root.showHidden)

    signal activated(var row)
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

    // Swallows the click that dismisses the menu so it does not also land
    // on whatever row happens to sit under the cursor.
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

        implicitWidth: 220
        implicitHeight: column.implicitHeight + Theme.filesPadding

        radius: Theme.filesRadius
        color: Theme.bgDark
        border.width: 1
        border.color: Theme.border

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
}
