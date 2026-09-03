// Keyboard layout pill: shows the active XKB layout, shortened to fit.
//
// Hyprland has no property for this anywhere on the Hyprland singleton or
// on a monitor or workspace — the only live source is `activelayout`, one
// of the unfiltered lines `Hyprland.rawEvent` forwards off the compositor's
// own event socket. That signal only fires on a change, so `hyprctl devices
// -j`, read once at startup, is what keeps the pill from sitting blank
// until the first switch.
//
// Always neutral: Pill's own default fill and text colour already are
// Theme.bgDark and Theme.fg, the "at rest" half of the bar's pill scheme
// Battery.qml and Network.qml light up only for a real warning state. A
// keymap has no such state, so this pill never overrides either colour.
//
// Switching the layout from here is a separate task, wired through the app
// runner instead of a click on this pill.
import QtQuick
import Quickshell.Io
import Quickshell.Hyprland
import "keymap.js" as KeymapLogic
import ".."
import "../common"

Pill {
    id: root

    property string layout: ""

    Text {
        text: root.layout !== "" ? root.layout : "--"
        color: Theme.fg

        font.family: Theme.fontUi
        font.pixelSize: Theme.barFontSize
        font.bold: true
    }

    Connections {
        target: Hyprland

        function onRawEvent(event) {
            if (event.name !== "activelayout")
                return;

            root.layout = KeymapLogic.shortenLayout(KeymapLogic.parseActiveLayoutEvent(event.data).layout);
        }
    }

    // The one-shot seed read. Runs once at load and is never restarted:
    // every layout change after this point arrives through rawEvent above.
    Process {
        running: true
        command: ["hyprctl", "devices", "-j"]

        stdout: StdioCollector {
            onStreamFinished: root.layout = KeymapLogic.shortenLayout(KeymapLogic.activeKeymapFrom(this.text))
        }
    }
}
