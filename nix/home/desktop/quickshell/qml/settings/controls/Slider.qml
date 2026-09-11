// A continuous value between `from` and `to`, drawn as a filled track and a
// round handle. That is the shape a volume or brightness row wants, neither
// of which is a handful of named choices (Segmented.qml) or a long list
// (Select.qml).
//
// The whole track is the hit target, not just the handle: clicking anywhere
// on it jumps the value straight there, same as a real slider, and dragging
// after that press keeps tracking the pointer. The handle's `x` stays a
// plain binding on `value` the entire time. Nothing here ever assigns
// `handle.x` directly, which is what a `drag.target` on the handle itself
// cannot promise: Qt's drag machinery assigns the dragged item's position
// imperatively, and an imperative assignment permanently breaks a binding
// on the same property, leaving the handle stuck wherever the last drag put
// it instead of tracking `value` if anything else ever changes it.
import QtQuick
import "../.."

Item {
    id: root

    property real from: 0
    property real to: 1
    property real value: 0
    // 0 means continuous; any other value snaps `value` to that grid before
    // it is emitted.
    property real stepSize: 0

    signal moved(real value)

    implicitWidth: 160
    implicitHeight: Theme.settingsToggleHeight

    readonly property real ratio: root.to > root.from ? (root.value - root.from) / (root.to - root.from) : 0

    function commit(x) {
        const clampedRatio = Math.max(0, Math.min(1, x / root.width));
        const raw = root.from + clampedRatio * (root.to - root.from);
        const stepped = root.stepSize > 0 ? Math.round(raw / root.stepSize) * root.stepSize : raw;
        const next = Math.max(root.from, Math.min(root.to, stepped));

        root.value = next;
        root.moved(next);
    }

    Rectangle {
        id: track

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter

        height: 4
        radius: height / 2
        color: Theme.selection

        Rectangle {
            width: parent.width * root.ratio
            height: parent.height
            radius: parent.radius
            color: Theme.accent
        }
    }

    Rectangle {
        id: handle

        width: 16
        height: 16
        radius: width / 2

        anchors.verticalCenter: parent.verticalCenter
        x: Math.round((root.width - width) * root.ratio)

        color: Theme.fg
    }

    MouseArea {
        anchors.fill: parent

        cursorShape: Qt.PointingHandCursor
        onPressed: mouse => root.commit(mouse.x)
        onPositionChanged: mouse => {
            if (pressed)
                root.commit(mouse.x);
        }
    }
}
