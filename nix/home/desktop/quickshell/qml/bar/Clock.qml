// Clock pill, with waybar's format-alt behaviour on click, plus a calendar
// popup the same click now also opens.
//
// waybar polled this every second to render HH:MM, which is fifty-nine wakeups
// a minute spent redrawing a string that did not change. SystemClock's
// precision is its wakeup rate, so the collapsed clock ticks once a minute and
// only the expanded form, which actually shows seconds, ticks once a second.
//
// The grid itself is pure layout over calendar.js's arithmetic: no new
// service binding, the same SystemClock already read for the pill's own
// text supplies "today", and paging between months is local state that
// never leaves this file.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import "calendar.js" as CalendarMath
import ".."
import "../common"

Pill {
    id: root

    property bool expanded: false

    // The month/year the popup is showing, independent of the calendar
    // clock's own date: paging to next month must not change what "today"
    // is, only what page of the grid is on screen.
    property int viewYear: clock.date.getFullYear()
    property int viewMonth: clock.date.getMonth() + 1

    readonly property var today: ({
            year: clock.date.getFullYear(),
            month: clock.date.getMonth() + 1,
            day: clock.date.getDate()
        })

    readonly property var grid: CalendarMath.buildGrid(root.viewYear, root.viewMonth, root.today)

    // Settings.qml's own idiom for finding the screen a global popup should
    // open on: the monitor whose bar was clicked is not necessarily the one
    // Hyprland considers focused, and this popup, like Settings and
    // Cheatsheet, always opens on the focused one.
    readonly property var focusedScreen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? null

    interactive: true

    onClicked: root.expanded = !root.expanded

    // Reopening always lands back on the current month. Without this, a
    // session that paged forward to check next month, closed the popup and
    // reopened it days later would still be looking at that same page.
    onExpandedChanged: {
        if (!root.expanded)
            return;

        root.viewYear = root.today.year;
        root.viewMonth = root.today.month;
    }

    function pageToPreviousMonth(): void {
        const target = CalendarMath.previousMonth(root.viewYear, root.viewMonth);
        root.viewYear = target.year;
        root.viewMonth = target.month;
    }

    function pageToNextMonth(): void {
        const target = CalendarMath.nextMonth(root.viewYear, root.viewMonth);
        root.viewYear = target.year;
        root.viewMonth = target.month;
    }

    SystemClock {
        id: clock

        precision: root.expanded ? SystemClock.Seconds : SystemClock.Minutes
    }

    Text {
        text: root.expanded ? Qt.formatDateTime(clock.date, "dd.MM.yyyy HH:mm:ss") : Qt.formatDateTime(clock.date, "HH:mm")
        color: Theme.fg

        font.family: Theme.fontUi
        font.pixelSize: Theme.barFontSize
        font.bold: true
    }

    PanelWindow {
        id: popup

        screen: root.focusedScreen
        color: "transparent"
        visible: root.expanded

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
        WlrLayershell.namespace: "dots-calendar"

        anchors {
            top: true
            left: true
            right: true
            bottom: true
        }

        exclusiveZone: 0

        // Swallows the click that dismisses the popup, PopupShell.qml's own
        // reason: without it, a click outside the panel would fall through
        // to whatever the popup is covering as well as closing it.
        MouseArea {
            anchors.fill: parent

            onClicked: root.expanded = false
        }

        Chrome {
            id: chrome

            // Anchored under the bar rather than centred, the same
            // placement Network.qml's own popup uses: this opens from a bar
            // pill, and centring it the way Cheatsheet and Settings centre
            // their full-screen forms would leave it with no visible
            // connection to the capsule that opened it.
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.topMargin: Theme.barHeight + Theme.barSpacing
            anchors.rightMargin: Theme.barSpacing * 2

            // Fixed width, so the grid's seven columns divide it evenly;
            // self-sized height off Chrome's own implicitHeight, since a
            // 42-cell grid plus a two-line header has one real height and
            // guessing a literal instead would either clip it or leave the
            // popup with dead space under it.
            width: 280
            height: chrome.implicitHeight

            padding: 20

            title: "Calendar"
            hints: [
                {
                    key: "Esc",
                    label: "close"
                }
            ]

            Keys.onEscapePressed: root.expanded = false

            RowLayout {
                Layout.fillWidth: true

                Text {
                    text: "\u{F053}"
                    color: Theme.fg

                    font.family: Theme.fontUi
                    font.pixelSize: Theme.barFontSize

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -6
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.pageToPreviousMonth()
                    }
                }

                Text {
                    Layout.fillWidth: true

                    text: CalendarMath.monthLabel(root.viewYear, root.viewMonth)
                    color: Theme.fg
                    horizontalAlignment: Text.AlignHCenter

                    font.family: Theme.fontUi
                    font.pixelSize: Theme.fontSize
                    font.bold: true
                }

                Text {
                    text: "\u{F054}"
                    color: Theme.fg

                    font.family: Theme.fontUi
                    font.pixelSize: Theme.barFontSize

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -6
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.pageToNextMonth()
                    }
                }
            }

            GridLayout {
                Layout.fillWidth: true

                columns: 7
                rowSpacing: 4
                columnSpacing: 4

                Repeater {
                    model: ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]

                    delegate: Text {
                        required property string modelData

                        Layout.fillWidth: true

                        text: modelData
                        color: Theme.muted
                        horizontalAlignment: Text.AlignHCenter

                        font.family: Theme.fontUi
                        font.pixelSize: Theme.fontSize * 0.8
                        font.bold: true
                    }
                }

                Repeater {
                    model: root.grid

                    delegate: Rectangle {
                        id: cell

                        required property var modelData

                        Layout.fillWidth: true
                        Layout.preferredHeight: 28

                        radius: 6
                        color: cell.modelData.isToday ? Theme.accent : "transparent"

                        Text {
                            anchors.centerIn: parent

                            text: cell.modelData.day
                            color: {
                                if (cell.modelData.isToday)
                                    return Theme.bg;

                                return cell.modelData.inMonth ? Theme.fg : Theme.muted;
                            }

                            font.family: Theme.fontUi
                            font.pixelSize: Theme.fontSize
                        }
                    }
                }
            }
        }
    }
}
