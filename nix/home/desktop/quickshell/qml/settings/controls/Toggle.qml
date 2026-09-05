// A binary switch: a filled capsule with an animated knob.
//
// Lifted from today's Settings.qml, which drew this inline as a
// hand-rolled Rectangle for its one "checkbox" field type. Every future
// on/off row wants the exact same shape, so it moves here once rather than
// being redrawn per page the way the old flat form never had to worry
// about.
//
// A capsule, per the source design's own `.tag-accent`/`.tag-outline`
// mapping in the task brief: radius is height/2, computed rather than a
// literal, so the shape stays right if settingsToggleHeight ever changes.
import QtQuick
import "../.."

Rectangle {
    id: root

    property bool checked: false

    signal toggled(bool value)

    implicitWidth: Theme.settingsToggleWidth
    implicitHeight: Theme.settingsToggleHeight

    radius: height / 2
    color: root.checked ? Theme.accent : Theme.selection

    // Disabling reaches this for free: a SettingsRow with dependsOn: false
    // sets its own `enabled` to false, and QtQuick's input dispatch already
    // refuses a click to a MouseArea underneath a disabled ancestor, so
    // nothing here has to read the row's state back out.
    Rectangle {
        id: knob

        width: parent.height - 6
        height: width
        radius: width / 2

        anchors.verticalCenter: parent.verticalCenter
        x: root.checked ? parent.width - width - 3 : 3

        color: Theme.bg

        Behavior on x {
            NumberAnimation {
                duration: 90
            }
        }
    }

    MouseArea {
        anchors.fill: parent

        cursorShape: Qt.PointingHandCursor
        onClicked: {
            root.checked = !root.checked;
            root.toggled(root.checked);
        }
    }
}
