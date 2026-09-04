// The notification daemon.
//
// Replaces dunst, and takes org.freedesktop.Notifications off it, so dunst has
// to stop being started in the same change that turns this on. Two daemons
// cannot own the name, and the loser simply never receives anything.
//
// dunst was configured `follow = "mouse"` on `monitor = 0`. This follows the
// focused monitor, which under a keyboard-driven compositor is where you are
// looking, and unlike dunst it costs nothing to re-anchor when focus moves.
//
// The window is masked to the notification column. Without that, a transparent
// 300px strip down the right of the screen would silently eat every click that
// landed in it.
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Services.Notifications

Scope {
    id: root

    // dunst's notification_limit.
    readonly property int limit: 5

    readonly property var focusedScreen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? null

    // dunst ran sort = true, which orders by urgency descending. Without it a
    // critical notification arriving behind five stale low ones is queued out
    // of sight, which is the one case where being seen matters most. Array
    // sort is stable, so arrival order still decides within an urgency.
    readonly property var shown: [...server.trackedNotifications.values].sort((a, b) => b.urgency - a.urgency).slice(0, root.limit)

    NotificationServer {
        id: server

        // Notifications are transient state. Keeping them across a config
        // reload would resurrect popups the user already dismissed.
        keepOnReload: false

        bodySupported: true
        bodyMarkupSupported: true
        bodyImagesSupported: true
        actionsSupported: true
        actionIconsSupported: true
        imageSupported: true
        persistenceSupported: true

        // x-dunst-stack-tag is not a standard hint, so the server only exposes
        // it when asked. dots-osd's watcher still sends it, and dropping it
        // would turn a flapping VPN into a column of identical cards.
        extraHints: ["x-dunst-stack-tag"]

        // Nothing is retained unless it is tracked, so an untracked
        // notification is delivered and immediately forgotten.
        onNotification: (notification) => {
            // Replace in place rather than stack, which is what the tag is
            // for. Dismissing the old one first leaves the new one holding the
            // slot with a fresh timeout.
            const tag = notification.hints["x-dunst-stack-tag"];

            if (tag) {
                for (const existing of server.trackedNotifications.values) {
                    if (existing.hints["x-dunst-stack-tag"] === tag) {
                        existing.dismiss();
                    }
                }
            }

            notification.tracked = true;
        }
    }

    PanelWindow {
        id: window

        screen: root.focusedScreen
        color: "transparent"

        anchors {
            top: true
            right: true
        }

        // dunst's offset was 12x48: clear of the right edge, and below the bar.
        //
        // Quickshell exports PanelWindow's Anchors as a value type but ships no
        // qmltypes entry for Margins, so qmllint cannot resolve this grouped
        // property even though it binds fine. Suppressed here rather than by
        // category, because unqualified access is worth catching everywhere
        // else.
        // qmllint disable unqualified unresolved-type
        margins {
            top: 48
            right: 12
        }
        // qmllint enable unqualified unresolved-type

        // Notifications float over the desktop rather than reserving space.
        exclusiveZone: 0

        implicitWidth: 300
        implicitHeight: Math.max(1, column.implicitHeight)

        visible: root.shown.length > 0

        mask: Region {
            item: column
        }

        Column {
            id: column

            width: parent.width

            // dunst's gap_size.
            spacing: 6

            Repeater {
                model: root.shown

                delegate: Item {
                    id: slot

                    required property var modelData

                    // dunst's per-urgency timeouts. Critical is 0 there, which
                    // means never expire, so it gets no timer at all rather
                    // than a zero-length one that fires immediately.
                    readonly property int urgencyTimeout: {
                        switch (slot.modelData.urgency) {
                        case NotificationUrgency.Critical:
                            return 0;
                        case NotificationUrgency.Low:
                            return 5000;
                        default:
                            return 8000;
                        }
                    }

                    // The spec counts expire_timeout in milliseconds, where -1
                    // means "server decides" and 0 means "never expire". Only
                    // -1 may fall through to the urgency default: treating 0
                    // as unset would quietly dismiss notifications that asked
                    // to stay until they are read.
                    readonly property int effectiveTimeout: slot.modelData.expireTimeout < 0 ? slot.urgencyTimeout : slot.modelData.expireTimeout

                    width: column.width
                    implicitHeight: card.implicitHeight
                    height: card.implicitHeight

                    NotificationCard {
                        id: card

                        width: parent.width
                        notification: slot.modelData

                        onDismissed: slot.modelData.dismiss()
                    }

                    Timer {
                        running: slot.effectiveTimeout > 0
                        interval: Math.max(1, slot.effectiveTimeout)

                        onTriggered: slot.modelData.expire()
                    }
                }
            }
        }

        // dunst's right click closed everything. The cards themselves take the
        // left and middle buttons, so this only ever sees clicks on the gaps,
        // which is close enough to "anywhere in the stack" to be worth having.
        MouseArea {
            anchors.fill: parent

            acceptedButtons: Qt.RightButton
            z: -1

            onClicked: {
                for (const notification of root.shown) {
                    notification.dismiss();
                }
            }
        }
    }
}
