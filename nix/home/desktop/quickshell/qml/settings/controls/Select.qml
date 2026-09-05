// One choice out of a list too long to lay flat as Segmented.qml's options
// are — a timezone, a monitor, anything enumerated at runtime rather than
// fixed at design time. Collapsed, it is a button naming the current value;
// clicking it reveals the option list in place, underneath.
//
// In place, not a floating popup. A real dropdown wants to paint over
// whatever sits below it, and every floating surface this shell already has
// (common/PopupShell.qml, files/Menu.qml, files/CrumbMenu.qml) is mounted
// directly on its window's top level for exactly that reason — Qt Quick
// only lets `z` reorder siblings under the SAME parent, so a popup nested
// three components deep cannot out-paint a sibling subtree no matter how
// high its `z` goes; it has to be a child of something both subtrees share.
// SettingsRow's control slot is not that: it sits inside whichever page and
// group host the row, with no shared overlay layer above them for a nested
// popup to reach. Expanding in place sidesteps the whole problem — the
// option list is an ordinary Layout child, so opening it simply grows this
// control's own height and the Layout around it reflows, the same as an
// accordion. A floating variant can still reuse PopupShell later, once a
// page actually needs one badly enough to be worth Settings.qml growing a
// shared overlay mount point for it.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import "../.."

ColumnLayout {
    id: root

    // [{ label, value }, ...].
    property var options: []
    property var value: null

    signal activated(var value)

    property bool expanded: false

    readonly property string currentLabel: {
        const found = root.options.find(o => o.value === root.value);
        return found ? found.label : "";
    }

    spacing: 4

    Rectangle {
        id: button

        Layout.fillWidth: true
        implicitHeight: Theme.settingsToggleHeight + 8

        radius: Theme.settingsRadius / 2
        color: Theme.bgDark

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: 10

            spacing: 8

            Text {
                Layout.fillWidth: true

                text: root.currentLabel
                color: Theme.fg
                elide: Text.ElideRight

                font.family: Theme.fontUi
                font.pointSize: Theme.settingsRowDescFontSize
            }

            Text {
                // A caret rather than a second icon font: it flips with
                // `expanded` so the button itself says which way the list
                // is about to move, same as any native combo box.
                text: root.expanded ? "▴" : "▾"
                color: Theme.muted

                font.family: Theme.fontUi
                font.pointSize: Theme.settingsRowDescFontSize
            }
        }

        MouseArea {
            anchors.fill: parent

            cursorShape: Qt.PointingHandCursor
            onClicked: root.expanded = !root.expanded
        }
    }

    ColumnLayout {
        Layout.fillWidth: true

        visible: root.expanded
        spacing: 2

        Repeater {
            model: root.options

            delegate: Rectangle {
                id: option

                required property var modelData

                readonly property bool current: root.value === option.modelData.value

                Layout.fillWidth: true
                implicitHeight: Theme.settingsToggleHeight

                radius: Theme.settingsRadius / 2
                color: optionArea.containsMouse ? Theme.raised : "transparent"

                Text {
                    anchors.fill: parent
                    anchors.leftMargin: 10

                    verticalAlignment: Text.AlignVCenter
                    text: option.modelData.label
                    color: option.current ? Theme.accent : Theme.fg

                    font.family: Theme.fontUi
                    font.pointSize: Theme.settingsRowDescFontSize
                    font.bold: option.current
                }

                MouseArea {
                    id: optionArea

                    anchors.fill: parent

                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        root.value = option.modelData.value;
                        root.expanded = false;
                        root.activated(option.modelData.value);
                    }
                }
            }
        }
    }
}
