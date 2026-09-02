// The breadcrumb bar: where you are, one clickable component at a time.
//
// It spans the whole window between the tab strip and the body rather than
// sitting inside the pane, because it describes the tab, not the pane —
// the sidebar's selection changes it too. A band with its own fill and a
// rule along the bottom, so it separates the strip above from the body
// below instead of being a line of text floating over the same ground.
//
// Crumb paths come from FilesMath.crumbsFor, which is unit-tested: a
// breadcrumb that is one slash out sends a click somewhere the user did
// not point at, and nothing on screen would show it was wrong.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import "files.js" as FilesMath
import ".."

Rectangle {
    id: root

    required property string path

    signal navigate(string path)

    implicitHeight: Theme.filesRowHeight + Theme.filesPadding
    color: Theme.bgDark

    Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: 1
        color: Theme.border
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Theme.filesPadding
        anchors.rightMargin: Theme.filesPadding

        spacing: 8

        Text {
            text: "\u{F005D}"
            color: upArea.containsMouse ? Theme.accent : Theme.muted
            font.family: Theme.fontUi
            font.pixelSize: Theme.filesIconSize

            MouseArea {
                id: upArea

                anchors.fill: parent
                anchors.margins: -6
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.navigate(FilesMath.parentOf(root.path))
            }
        }

        Repeater {
            model: FilesMath.crumbsFor(root.path)

            delegate: RowLayout {
                id: crumb

                required property var modelData
                required property int index

                spacing: 4

                // The separator leads each crumb except the first, so root
                // does not get a slash in front of the slash it already is.
                Text {
                    text: "\u{F0142}"
                    color: Theme.dim
                    font.family: Theme.fontUi
                    font.pixelSize: Theme.filesIconSize
                    visible: crumb.index > 0
                }

                Text {
                    text: crumb.modelData.label
                    // The last crumb is where you actually are, so it gets
                    // the emphasis and the rest read as the trail to it.
                    color: {
                        if (crumbArea.containsMouse)
                            return Theme.accent;

                        return crumb.index === FilesMath.crumbsFor(root.path).length - 1 ? Theme.fg : Theme.muted;
                    }
                    font.family: Theme.fontUi
                    font.pixelSize: Theme.fontSize
                    font.bold: crumb.index === FilesMath.crumbsFor(root.path).length - 1

                    MouseArea {
                        id: crumbArea

                        anchors.fill: parent
                        anchors.margins: -4
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.navigate(crumb.modelData.path)
                    }
                }
            }
        }

        Item {
            Layout.fillWidth: true
        }
    }
}
