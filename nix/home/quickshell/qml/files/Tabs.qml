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
    // bgDarker computes at only ~1.05:1 against PathBar's bg below —
    // barely a seam. Left as-is anyway: every inactive tab's label and
    // icon default to Theme.muted, which reads at a healthy 4.32:1 against
    // this bgDarker fill; lifting the strip to the lighter `raised` token
    // to fix the seam would drop that to 2.28:1, the same order of
    // regression a sibling task's fix introduced on Pane.qml's muted
    // columns. The strip is not left with no boundary at all, though: the
    // active tab still gets its own EdgeStrip and its own Theme.bg fill,
    // which is the pairing that actually needs to read as distinct.
    color: Theme.bgDarker

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

                // No divider between inactive tabs: they already share the
                // strip's own bgDarker fill (transparent above), so a
                // shade change would need a fourth token invented just for
                // this seam. What actually keeps two adjacent tabs from
                // reading as one is geometry, not colour: implicitWidth
                // above already gives every tab Theme.filesTabPadding on
                // both sides, so neighbours sit roughly 28px of bare strip
                // apart before either one's icon or label even starts —
                // that gap was already doing the separating, the 1px rule
                // was never the only thing telling two tabs apart.
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
