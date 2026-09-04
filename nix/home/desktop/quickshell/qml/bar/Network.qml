// Network pill.
//
// waybar had no network module: it was moved into beamenu as a searchable row
// backed by a Rust probe that shelled out to nmcli every five seconds. That
// probe is going away with beamenu, and Quickshell talks to NetworkManager
// over D-Bus directly, so the state arrives on a signal instead of a poll and
// can afford to be visible again.
//
// Connectivity is reported separately from association on purpose. Being
// joined to an access point that cannot reach anything is the failure worth
// showing, and it is exactly the one a plain "connected" indicator hides.
import QtQuick
import Quickshell.Networking
import ".."
import "../common"

Pill {
    id: root

    readonly property var device: Networking.devices.values.find(d => d.connected) ?? null

    readonly property bool isWifi: root.device?.type === DeviceType.Wifi

    readonly property var network: {
        if (!root.device)
            return null;

        return (root.device.networks?.values ?? []).find(n => n.connected) ?? null;
    }

    readonly property bool degraded: Networking.connectivity === NetworkConnectivity.Portal || Networking.connectivity === NetworkConnectivity.Limited

    readonly property string icon: {
        if (!root.device)
            return "\u{F127}";

        return root.isWifi ? "\u{F1EB}" : "\u{F0E8}";
    }

    readonly property string label: {
        if (!root.device)
            return "offline";

        if (root.isWifi)
            return root.network?.name ?? "wifi";

        return "wired";
    }

    // A working connection is the boring case and stays on the neutral fill,
    // the same way a healthy battery does. Offline and captive-portal are the
    // failures worth showing, so they alone light up.
    readonly property bool warning: !root.device || root.degraded

    color: {
        if (!root.device)
            return Theme.red;

        if (root.degraded)
            return Theme.yellow;

        return Theme.bgDark;
    }

    Text {
        text: `${root.icon} ${root.label}`

        // Dark text reads on a bright fill, light text on the neutral one.
        color: root.warning ? Theme.bg : Theme.fg

        font.family: Theme.fontUi
        font.pixelSize: Theme.barFontSize
        font.bold: true
    }
}
