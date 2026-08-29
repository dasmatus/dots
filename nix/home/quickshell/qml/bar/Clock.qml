// Clock pill, with waybar's format-alt behaviour on click.
//
// waybar polled this every second to render HH:MM, which is fifty-nine wakeups
// a minute spent redrawing a string that did not change. SystemClock's
// precision is its wakeup rate, so the collapsed clock ticks once a minute and
// only the expanded form, which actually shows seconds, ticks once a second.
import QtQuick
import Quickshell
import ".."
import "../common"

Pill {
    id: root

    property bool expanded: false

    color: Theme.magenta
    interactive: true

    onClicked: root.expanded = !root.expanded

    SystemClock {
        id: clock

        precision: root.expanded ? SystemClock.Seconds : SystemClock.Minutes
    }

    Text {
        text: root.expanded ? Qt.formatDateTime(clock.date, "dd.MM.yyyy HH:mm:ss") : Qt.formatDateTime(clock.date, "HH:mm")
        color: Theme.bg

        font.family: Theme.fontUi
        font.pixelSize: Theme.barFontSize
        font.bold: true
    }
}
