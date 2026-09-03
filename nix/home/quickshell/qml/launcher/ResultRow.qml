// One launcher row: icon, title, subtitle, and an accessory on the right.
//
// The shape is beamenu's, which is the shape ten patches were written against
// bemenu's C renderer to get. Here it is a delegate, so the row that took a
// rebase-forever patch series is now a layout.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import ".."
import "../common"

Rectangle {
    id: root

    required property string title
    required property string subtitle
    required property string icon
    required property string accessory
    required property bool current

    // How many desktop actions the row's app has, 0 for every row that is not
    // an app with actions. Defaulted rather than required so the providers
    // that know nothing about actions need no change to keep working.
    property int actionCount: 0

    signal activated

    // Raised when the action pill is clicked, as distinct from activating the
    // row itself: one launches the app, the other opens its action list.
    signal drillRequested

    implicitHeight: Theme.launcherLineHeight

    radius: 8
    color: root.current ? Theme.accent : "transparent"

    // Declared BEFORE the RowLayout, deliberately. Later siblings sit on top
    // in QML, and this used to come last — which was fine while the row had
    // nothing clickable inside it, and stops being fine the moment the
    // accessory pill below wants its own clicks. With the order flipped the
    // pill wins inside its own bounds and this still catches everywhere else.
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

        // The way into an app's desktop actions. Built from the shared capsule
        // rather than a second rounded rectangle, so it reads as the same kind
        // of control as the filter pills directly above the list — which is
        // what it is, since drilling in is a filter that happens to be scoped
        // to one app instead of one provider.
        Pill {
            Layout.alignment: Qt.AlignVCenter

            visible: root.actionCount > 0
            interactive: true
            color: root.current ? Theme.bg : Theme.bgDark

            onClicked: root.drillRequested()

            Text {
                text: `${root.actionCount} actions`
                color: root.current ? Theme.fg : Theme.dim

                font.family: Theme.fontMono
                font.pointSize: 9
            }
        }
    }
}
