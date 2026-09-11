// A row of mutually-exclusive options drawn as one capsule track with a
// filled active segment, for a row whose value is one of a handful of
// named choices (few enough to show all at once; Select.qml is the
// sibling control for a list too long to lay out flat).
//
// One outer capsule rather than one capsule per option: the source design's
// segmented control reads as a single control with a moving highlight, not
// as several buttons that happen to sit in a row, and `.tag-accent` /
// `.tag-outline`'s "radius: height/2" rule from the task brief applies to
// both the track and each segment alike.
pragma ComponentBehavior: Bound

import QtQuick
import "../.."

Rectangle {
    id: root

    // [{ label, value }, ...]. `value` is compared with ===, so callers
    // pass whatever primitive their field already stores, a string key
    // most often, rather than this control inventing its own encoding.
    property var options: []
    property var value: null

    signal activated(var value)

    implicitWidth: track.implicitWidth + 8
    implicitHeight: Theme.settingsToggleHeight + 8

    radius: height / 2
    color: Theme.bgDark

    Row {
        id: track

        anchors.centerIn: parent
        spacing: 2

        Repeater {
            model: root.options

            delegate: Rectangle {
                id: segment

                required property var modelData

                readonly property bool active: root.value === segment.modelData.value

                implicitWidth: label.implicitWidth + 20
                implicitHeight: root.height - 8

                radius: height / 2
                color: segment.active ? Theme.accent : "transparent"

                Text {
                    id: label

                    anchors.centerIn: parent

                    text: segment.modelData.label
                    color: segment.active ? Theme.bg : Theme.fg

                    font.family: Theme.fontUi
                    font.pointSize: Theme.settingsRowDescFontSize
                    font.bold: segment.active
                }

                MouseArea {
                    anchors.fill: parent

                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.activated(segment.modelData.value)
                }
            }
        }
    }
}
