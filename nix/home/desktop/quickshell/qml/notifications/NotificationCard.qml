// One notification, styled to dunst's card.
//
// The colours, the 2px frame, the 8px radius and the 10/12 padding are the
// dunstrc's, so a notification looks the way it always has. One value is
// deliberately not copied: dunst's normal-urgency frame was the literal
// #7aa2f7, which is the palette's accent fallback. Here it is the live accent,
// so notification frames follow the wallpaper like the rest of the desktop.
//
// dunst rendered `<b>%s</b>\n%b` as a single Pango string. Summary and body are
// separate items instead, which gets the same result without asking a text
// engine to lay out a newline-joined format string.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Notifications
import ".."
import "../common"

Rectangle {
    id: root

    required property var notification

    signal dismissed

    // dunst's transparency was 10, meaning 90% opaque.
    readonly property real backgroundAlpha: 0.9

    readonly property bool critical: root.notification.urgency === NotificationUrgency.Critical

    readonly property bool low: root.notification.urgency === NotificationUrgency.Low

    // The `value` hint is what draws a progress bar. dunst read the same hint
    // to decide whether to show one at all, so an absent hint means no bar
    // rather than a bar sitting at zero.
    readonly property var progress: root.notification.hints?.value

    readonly property bool hasProgress: root.progress !== undefined && root.progress !== null

    // dunst sets no `highlight`, so the progress bar is drawn in the frame
    // colour. One property feeds both rather than two lists of urgency cases
    // drifting apart.
    readonly property color frame: {
        if (root.critical)
            return Theme.red;

        if (root.low)
            return Theme.border;

        return Theme.accent;
    }

    implicitWidth: 300
    implicitHeight: layout.implicitHeight + 20

    radius: 8

    color: Qt.alpha(root.low ? Theme.bg : Theme.bgDark, root.backgroundAlpha)

    // `low` is dunst's no-urgency case, where `frame` falls back to the
    // neutral Theme.border rather than an urgency colour. That carries no
    // information, so this draws no strip for it rather than a neutral one.
    EdgeStrip {
        edge: "left"
        active: !root.low
        tint: root.frame
        thickness: 2
    }

    RowLayout {
        id: layout

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: 12
        anchors.rightMargin: 12

        // dunst's text_icon_padding was 0, which is its signal to fall back to
        // horizontal_padding rather than to draw the icon flush against the
        // text.
        spacing: 12

        Image {
            Layout.alignment: Qt.AlignTop
            Layout.preferredWidth: 32
            Layout.preferredHeight: 32

            // An image hint beats an icon name: it is the actual bitmap the
            // application sent. dunst could resolve neither reliably here, per
            // the note in nix/home/dunst.nix, because no named icon resolved
            // under its theme lookup at all.
            source: {
                if (root.notification.image)
                    return root.notification.image;

                if (root.notification.appIcon)
                    return Quickshell.iconPath(root.notification.appIcon, true);

                return "";
            }

            visible: source !== ""

            sourceSize.width: 32
            sourceSize.height: 32
            fillMode: Image.PreserveAspectFit
        }

        ColumnLayout {
            Layout.fillWidth: true

            spacing: 4

            Text {
                Layout.fillWidth: true

                text: root.notification.summary
                color: root.critical ? Theme.red : Theme.fg

                // dunst's font was "Lilex Nerd Font Bold 10", a point size, and
                // Bold applies to the whole card. The <b> in its format string
                // only re-bolds an already bold summary, which is why the body
                // below is bold too.
                font.family: Theme.fontUi
                font.pointSize: 10
                font.bold: true

                elide: Text.ElideMiddle
                maximumLineCount: 1
            }

            Text {
                Layout.fillWidth: true

                text: root.notification.body
                color: root.critical ? Theme.red : Theme.fg
                visible: text !== ""

                // dunst ran markup=full, so bodies here may carry Pango markup.
                // StyledText covers the tags that survives in practice (b, i,
                // u, a) without RichText's full HTML engine.
                textFormat: Text.StyledText

                font.family: Theme.fontUi
                font.pointSize: 10
                font.bold: true

                wrapMode: Text.WordWrap
                elide: Text.ElideRight
                maximumLineCount: 4
            }

            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 6

                visible: root.hasProgress

                radius: 3
                color: Theme.selection

                Rectangle {
                    width: parent.width * Math.max(0, Math.min(1, root.progress / 100))
                    height: parent.height

                    radius: parent.radius
                    color: root.frame
                }
            }
        }
    }

    MouseArea {
        anchors.fill: parent

        acceptedButtons: Qt.LeftButton | Qt.MiddleButton

        onClicked: (mouse) => {
            // dunst: left closes this one, middle runs the default action and
            // then closes it. Right closed everything, which the layer above
            // handles because it owns the list.
            if (mouse.button === Qt.MiddleButton && root.notification.actions.length > 0) {
                root.notification.actions[0].invoke();
            }

            root.dismissed();
        }
    }
}
