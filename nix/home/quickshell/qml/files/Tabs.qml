// The tab strip along the top, shaped after the bufferline this user's
// editor already runs: nixvim.nix enables bufferline with
// `settings.options.mode = "tabs"`, so the reference is its tab rendering,
// not its buffer rendering. That means an accent indicator down the
// leading edge of the active tab, the active tab carrying the body's own
// background so it reads as attached to the pane below it, and inactive
// tabs sitting dimmer on the strip.
//
// Every metric comes from Theme (nix/palette.json's `files` block). None
// of the numbers below are written here, because the bar, the launcher and
// this surface all learned the same lesson: a literal in the QML is a
// number nobody can find again.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import "tabs.js" as TabsMath
import "icons.js" as Icons
import ".."
import "../common"

Rectangle {
    id: root

    required property var tabs
    required property int activeIndex

    signal selected(int index)
    signal closed(int index)
    signal added()

    implicitHeight: Theme.filesTabHeight
    color: Theme.bgDarker

    // The strip and the pane area below it are both dark; without this the
    // seam between them is invisible and the active tab appears to float.
    Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: 1
        color: Theme.border
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        Repeater {
            model: root.tabs

            delegate: Rectangle {
                id: tab

                required property var modelData
                required property int index

                readonly property bool current: tab.index === root.activeIndex

                Layout.fillHeight: true
                implicitWidth: tabRow.implicitWidth + Theme.filesTabPadding * 2

                color: tab.current ? Theme.bg : "transparent"

                EdgeStrip {
                    edge: "left"
                    active: tab.current
                    thickness: Theme.filesTabIndicator
                }

                Rectangle {
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    anchors.topMargin: Theme.filesTabPadding / 2
                    anchors.bottomMargin: Theme.filesTabPadding / 2
                    width: 1
                    color: Theme.border
                    visible: !tab.current
                }

                RowLayout {
                    id: tabRow

                    anchors.centerIn: parent
                    spacing: 6

                    Text {
                        text: Icons.FOLDER
                        color: tab.current ? Theme.accent : Theme.muted
                        font.family: Theme.fontUi
                        font.pixelSize: Theme.filesIconSize
                    }

                    Text {
                        text: TabsMath.labelFor(tab.modelData)
                        color: tab.current ? Theme.fg : Theme.muted
                        font.family: Theme.fontUi
                        font.pixelSize: Theme.fontSize
                    }

                    // Only the active tab offers its close control, the way
                    // bufferline only decorates the tab you are on. A close
                    // box on every tab turns a row of directories into a row
                    // of targets to misclick.
                    Text {
                        text: "\u{F0156}"
                        color: closeArea.containsMouse ? Theme.red : Theme.muted
                        font.family: Theme.fontUi
                        font.pixelSize: Theme.filesIconSize
                        visible: tab.current && root.tabs.length > 1

                        MouseArea {
                            id: closeArea

                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.closed(tab.index)
                        }
                    }
                }

                // Declared after the row so the close control above wins the
                // click that lands on it.
                MouseArea {
                    anchors.fill: parent
                    z: -1
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.selected(tab.index)
                }
            }
        }

        Text {
            Layout.leftMargin: Theme.filesTabPadding
            Layout.alignment: Qt.AlignVCenter

            text: "\u{F0415}"
            color: addArea.containsMouse ? Theme.accent : Theme.muted
            font.family: Theme.fontUi
            font.pixelSize: Theme.filesIconSize

            MouseArea {
                id: addArea

                anchors.fill: parent
                anchors.margins: -4
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.added()
            }
        }

        Item {
            Layout.fillWidth: true
        }
    }
}
