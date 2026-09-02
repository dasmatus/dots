// System tray pill, over StatusNotifierItem.
//
// waybar dimmed passive items to 60% and turned the ones asking for attention
// red. Both are kept: an item that has gone passive is still there for a
// reason, and one demanding attention is the only thing in the tray that
// should be able to interrupt you.
//
// Every icon also renders desaturated at rest and returns to full colour
// while the pointer sits over it, so a row of unrelated vendor icons does
// not compete with the rest of the bar; hovering makes the icon's identity
// recoverable on demand.
//
// Left click activates, middle click is the item's secondary action, right
// click opens its DBusMenu. display() wants the window to anchor the menu to,
// which QsWindow.window supplies from anywhere inside the bar.
import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Services.SystemTray
import ".."

Pill {
    id: root

    readonly property var items: SystemTray.items.values

    visible: root.items.length > 0
    horizontalPadding: 10

    Repeater {
        model: root.items

        delegate: Item {
            id: entry

            required property var modelData

            implicitWidth: Theme.barIconSize
            implicitHeight: Theme.barIconSize

            opacity: entry.modelData.status === Status.Passive ? 0.6 : 1

            Image {
                id: icon

                anchors.fill: parent
                visible: false

                source: entry.modelData.icon

                sourceSize.width: Theme.barIconSize
                sourceSize.height: Theme.barIconSize
            }

            // Grey every icon out at rest and let hovering restore it: the
            // icon's identity stays recoverable on demand, so desaturating
            // it loses nothing the way permanently recolouring it would.
            // The attention overlay below is still the only thing in the
            // tray allowed to interrupt you, which is why it alone stays
            // tinted rather than merely desaturated.
            MultiEffect {
                anchors.fill: parent

                source: icon
                saturation: hoverArea.containsMouse ? 0 : -1

                Behavior on saturation {
                    NumberAnimation {
                        duration: 120
                    }
                }
            }

            Rectangle {
                anchors.fill: parent

                visible: entry.modelData.status === Status.NeedsAttention
                color: Theme.red
                opacity: 0.35
                radius: 4
            }

            MouseArea {
                id: hoverArea

                anchors.fill: parent

                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor

                onClicked: (mouse) => {
                    if (mouse.button === Qt.RightButton) {
                        if (entry.modelData.hasMenu) {
                            entry.modelData.display(QsWindow.window, entry.width / 2, entry.height);
                        }
                        return;
                    }

                    if (mouse.button === Qt.MiddleButton) {
                        entry.modelData.secondaryActivate();
                        return;
                    }

                    // An item with only a menu has nothing to activate, so a
                    // left click there should open the menu rather than do
                    // nothing at all.
                    if (entry.modelData.onlyMenu) {
                        entry.modelData.display(QsWindow.window, entry.width / 2, entry.height);
                    } else {
                        entry.modelData.activate();
                    }
                }
            }
        }
    }
}
