// Keyboard layout pill: shows the active XKB layout code, shortened to fit.
//
// Hyprland has no property for this anywhere on the Hyprland singleton or
// on a monitor or workspace — the only live signal is `activelayout`, one
// of the unfiltered lines `Hyprland.rawEvent` forwards off the compositor's
// own event socket. Its own payload only carries Hyprland's human-readable
// description of the new layout ("Slovak", "English (US)"), though, not the
// configured code launcher/keyboard.js's rows switch by ("sk", "us") —
// truncating the description does not generally land on that code (see
// keymap.js's activeLayoutCodeFrom), so this pill would disagree with the
// launcher about what a layout is even called. `activelayout` is used only
// as a "something changed, re-read `hyprctl devices -j`" trigger instead;
// that same read also seeds the pill at startup, since the signal only
// fires on a change and would otherwise leave it blank until the first one.
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
    property int layoutCount: 0

    // Matches launcher/keyboard.js's own floor for offering a row: one
    // configured layout has nothing to switch to, so neither surface gives
    // the user something to act on. Drives.qml and Battery.qml already
    // guard their own pills the same way rather than showing one that can
    // never mean anything.
    visible: root.layoutCount >= 2

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

            probe.running = true;
        }
    }

    // Both the startup seed and every later re-read after an activelayout
    // event restart this same Process, the way Providers.qml's diskProbe
    // is restarted from its own Timer.
    Process {
        id: probe

        running: true
        command: ["hyprctl", "devices", "-j"]

        stdout: StdioCollector {
            onStreamFinished: {
                root.layout = KeymapLogic.shortenLayout(KeymapLogic.activeLayoutCodeFrom(this.text));
                root.layoutCount = KeymapLogic.configuredLayoutCount(this.text);
            }
        }
    }
}
