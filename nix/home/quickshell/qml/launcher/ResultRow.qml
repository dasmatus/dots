// One launcher row: icon, title, subtitle, and an accessory on the right.
//
// The shape is beamenu's, which is the shape ten patches were written against
// bemenu's C renderer to get. Here it is a delegate, so the row that took a
// rebase-forever patch series is now a layout.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import ".."

Rectangle {
    id: root

    required property string title
    required property string subtitle
    required property string icon
    required property string accessory
    required property bool current

    signal activated

    implicitHeight: Theme.launcherLineHeight

    radius: 8
    color: root.current ? Theme.accent : "transparent"

    // Declared BEFORE the RowLayout, deliberately. Later siblings sit on top
    // in QML, so a full-row MouseArea written last swallows the clicks of
    // anything interactive inside the layout. Nothing in there asks for its
    // own clicks today — the accessory capsule that did has moved to the
    // pill bar — so the ordering is kept as the standing rule rather than
    // left to be rediscovered the next time a row grows something clickable.
    MouseArea {
        anchors.fill: parent

        cursorShape: Qt.PointingHandCursor
        onClicked: root.activated()
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: 14
        anchors.rightMargin: 14

        spacing: 12

        Image {
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: Theme.launcherIconSize
            Layout.preferredHeight: Theme.launcherIconSize

            source: root.icon
            visible: root.icon !== ""

            sourceSize.width: Theme.launcherIconSize
            sourceSize.height: Theme.launcherIconSize
            fillMode: Image.PreserveAspectFit
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter

            spacing: 0

            Text {
                Layout.fillWidth: true

                text: root.title
                // On the selected row the background is the accent, so the
                // text has to flip to the dark base or it reads as light on
                // light the moment the wallpaper accent is a pale one.
                color: root.current ? Theme.bg : Theme.fg

                font.family: Theme.fontUi
                font.pointSize: 11
                font.bold: true

                elide: Text.ElideRight
                maximumLineCount: 1
            }

            Text {
                Layout.fillWidth: true

                text: root.subtitle
                color: root.current ? Theme.bg : Theme.muted
                visible: text !== ""

                font.family: Theme.fontUi
                font.pointSize: 9

                elide: Text.ElideRight
                maximumLineCount: 1
            }
        }

        Text {
            Layout.alignment: Qt.AlignVCenter

            text: root.accessory
            color: root.current ? Theme.bg : Theme.dim
            visible: text !== ""

            font.family: Theme.fontMono
            font.pointSize: 9
        }
    }
}
