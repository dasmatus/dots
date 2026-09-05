// A wrapping row of togglable chips, for a row whose value is a SET rather
// than a single choice — which providers to enable, which days a rule
// applies to. Built on common/Pill.qml, the shell's one capsule primitive,
// per the task brief's own callout: a chip is a tag, and Pill is what every
// other tag in this shell is already drawn from.
//
// A Flow, not a Row: the set a caller passes has no fixed count the way
// Segmented.qml's options do, and wrapping to a second line costs height,
// which the row grammar has to spare, rather than width, which the control
// column does not.
pragma ComponentBehavior: Bound

import QtQuick
import "../../common"
import "../.."

Flow {
    id: root

    // [{ id, label }, ...] and the subset of ids currently on.
    property var chips: []
    property var selected: []

    signal toggled(string id)

    spacing: 8

    Repeater {
        model: root.chips

        delegate: Pill {
            id: chip

            required property var modelData

            readonly property bool active: root.selected.indexOf(chip.modelData.id) !== -1

            interactive: true
            color: chip.active ? Theme.accent : Theme.bgDark

            onClicked: root.toggled(chip.modelData.id)

            Text {
                text: chip.modelData.label
                color: chip.active ? Theme.bg : Theme.fg

                font.family: Theme.fontUi
                font.pointSize: Theme.settingsRowDescFontSize
                font.bold: chip.active
            }
        }
    }
}
