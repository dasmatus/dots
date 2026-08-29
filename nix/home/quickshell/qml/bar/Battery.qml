// Battery pill.
//
// The eleven-glyph ramp and the 30/15 warning thresholds are waybar's, kept
// exactly: the whole point of a battery indicator is that you have learned
// what its colours mean without reading them.
//
// Hidden entirely on machines with no battery. waybar left an empty module
// there; a desktop has nothing to say about charge and should not reserve a
// capsule to say it.
//
// The arithmetic lives in battery.js so tests/qml/tst_battery.qml can reach
// it without a compositor, a palette or a D-Bus connection.
import QtQuick
import Quickshell.Services.UPower
import "battery.js" as BatteryMath
import ".."
import "../common"

Pill {
    id: root

    readonly property var device: UPower.displayDevice

    readonly property int percent: BatteryMath.percent(root.device?.percentage)

    readonly property bool charging: root.device?.state === UPowerDeviceState.Charging || root.device?.state === UPowerDeviceState.FullyCharged

    readonly property var ramp: ["\u{F008E}", "\u{F007A}", "\u{F007B}", "\u{F007C}", "\u{F007D}", "\u{F007E}", "\u{F007F}", "\u{F0080}", "\u{F0081}", "\u{F0082}", "\u{F0079}"]

    readonly property string icon: root.charging ? "\u{F0084}" : root.ramp[BatteryMath.rampIndex(root.percent, root.ramp.length)]

    visible: root.device?.isLaptopBattery ?? false

    color: {
        const name = BatteryMath.colorName(root.percent, root.charging);

        if (name === "red")
            return Theme.red;

        if (name === "yellow")
            return Theme.yellow;

        return Theme.green;
    }

    Text {
        text: `${root.icon} ${root.percent}%`
        color: Theme.bg

        font.family: Theme.fontUi
        font.pixelSize: Theme.barFontSize
        font.bold: true
    }
}
