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
//
// The write path below is what lets nm-applet leave
// nix/home/desktop/session/actions.nix: Quickshell.Networking can scan,
// connect and supply a passphrase natively over the same D-Bus connection
// this file already reads state from (WifiNetwork.connectWithPsk), so there
// is no nmcli shellout here — see network.js's own header for the split
// between what needs the real Networking types and what does not.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Networking
import Quickshell.Wayland
import "network.js" as NetworkMath
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

    // ---- write path: access-point selection and passphrase entry ----

    interactive: true

    onClicked: root.expanded = !root.expanded

    property bool expanded: false

    // Which network a click is waiting on a passphrase for. Distinct from
    // root.network above, which is read-only state about whatever is
    // already connected; this one names a candidate the popup has not
    // connected to yet.
    property var passwordTarget: null

    property string error: ""

    // Any Wi-Fi device, connected or not: root.device above only ever names
    // a *connected* one, which is exactly the device this popup still needs
    // when there is nothing to connect to yet.
    readonly property var wifiDevice: Networking.devices.values.find(d => d.type === DeviceType.Wifi) ?? null

    readonly property var networks: NetworkMath.sortNetworks(root.wifiDevice?.networks?.values ?? [])

    // Settings.qml's own idiom for finding the screen a global popup should
    // open on: the monitor whose bar was clicked is not necessarily the one
    // Hyprland considers focused, and this popup, like Settings and
    // Cheatsheet, always opens on the focused one.
    readonly property var focusedScreen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? null

    // Scanning costs radio time, so it only runs while someone is actually
    // looking at the list, the same reason WifiPassword.qml's installer
    // sibling rescans on demand rather than on a timer.
    onExpandedChanged: {
        if (root.wifiDevice)
            root.wifiDevice.scannerEnabled = root.expanded;

        if (!root.expanded) {
            root.passwordTarget = null;
            root.error = "";
        }
    }

    // Open air and an already-known profile both go straight to connect();
    // everything else stops at the passphrase field first. See network.js's
    // needsPassword for why the two booleans are computed here rather than
    // handed the network object itself.
    function selectNetwork(network) {
        if (!network)
            return;

        root.error = "";

        const isOpen = network.security === WifiSecurityType.Open;
        if (NetworkMath.needsPassword(network.known, isOpen))
            root.passwordTarget = network;
        else
            network.connect();
    }

    // Retargeted every time passwordTarget changes, so this always listens
    // to whichever network the pending passphrase attempt belongs to.
    Connections {
        target: root.passwordTarget

        function onConnectionFailed(reason) {
            root.error = NetworkMath.connectionErrorMessage(ConnectionFailReason.toString(reason));
        }
    }

    PanelWindow {
        id: popup

        screen: root.focusedScreen
        color: "transparent"
        visible: root.expanded

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        WlrLayershell.namespace: "dots-network"

        anchors {
            top: true
            left: true
            right: true
            bottom: true
        }

        exclusiveZone: 0

        onVisibleChanged: {
            if (popup.visible)
                chrome.forceActiveFocus();
        }

        // Swallows the click that dismisses the popup, PopupShell.qml's own
        // reason: without it, a click outside the panel would fall through
        // to whatever the popup is covering as well as closing it.
        MouseArea {
            anchors.fill: parent

            onClicked: root.expanded = false
        }

        Chrome {
            id: chrome

            // Anchored under the bar rather than centred: this popup opens
            // from a bar pill, and centring it the way Cheatsheet and
            // Settings centre their own full-screen forms would leave it
            // floating with no visible connection to the capsule that
            // opened it.
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.topMargin: Theme.barHeight + Theme.barSpacing
            anchors.rightMargin: Theme.barSpacing * 2

            width: 320
            height: Math.min(360, parent.height - anchors.topMargin - Theme.barSpacing * 2)

            padding: 20
            focus: true

            title: "Wi-Fi"
            hints: root.passwordTarget !== null ? [
                {
                    key: "Enter",
                    label: "connect"
                },
                {
                    key: "Esc",
                    label: "back"
                }
            ] : [
                {
                    key: "Esc",
                    label: "close"
                }
            ]

            Keys.onEscapePressed: {
                if (root.passwordTarget !== null)
                    root.passwordTarget = null;
                else
                    root.expanded = false;
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true

                visible: root.passwordTarget !== null

                spacing: 10

                Text {
                    Layout.fillWidth: true

                    text: `Password for "${root.passwordTarget?.name ?? ""}"`
                    color: Theme.fgDark
                    wrapMode: Text.WordWrap

                    font.family: Theme.fontUi
                    font.pixelSize: Theme.fontSize
                }

                Field {
                    id: pskField

                    Layout.fillWidth: true
                    masked: true

                    onAccepted: {
                        if (root.passwordTarget !== null)
                            root.passwordTarget.connectWithPsk(text);
                    }
                    onEscaped: root.passwordTarget = null
                }

                Text {
                    Layout.fillWidth: true

                    visible: root.error !== ""
                    text: root.error
                    color: Theme.red
                    wrapMode: Text.WordWrap

                    font.family: Theme.fontUi
                    font.pixelSize: Theme.fontSize
                }
            }

            Flickable {
                id: scroll

                Layout.fillWidth: true
                Layout.fillHeight: true

                visible: root.passwordTarget === null

                contentWidth: width
                contentHeight: list.implicitHeight
                clip: true

                ColumnLayout {
                    id: list

                    width: scroll.width
                    spacing: 4

                    Text {
                        Layout.fillWidth: true

                        visible: root.wifiDevice === null
                        text: "No Wi-Fi device"
                        color: Theme.muted

                        font.family: Theme.fontUi
                        font.pixelSize: Theme.fontSize
                    }

                    Repeater {
                        model: root.networks

                        delegate: Rectangle {
                            id: apRow

                            required property var modelData

                            Layout.fillWidth: true
                            implicitHeight: 36

                            radius: 6
                            color: apRow.modelData.connected ? Theme.selection : "transparent"

                            RowLayout {
                                anchors.fill: parent
                                anchors.margins: 6

                                spacing: 8

                                Text {
                                    text: NetworkMath.signalBars(apRow.modelData.signalStrength)
                                    color: Theme.fg

                                    font.family: Theme.fontMono
                                    font.pixelSize: Theme.fontSize
                                }

                                Text {
                                    Layout.fillWidth: true

                                    text: apRow.modelData.name
                                    color: Theme.fg
                                    elide: Text.ElideRight

                                    font.family: Theme.fontUi
                                    font.pixelSize: Theme.fontSize
                                }

                                Text {
                                    visible: apRow.modelData.security !== WifiSecurityType.Open

                                    text: "\u{F023}"
                                    color: Theme.muted

                                    font.family: Theme.fontUi
                                    font.pixelSize: Theme.fontSize
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.selectNetwork(apRow.modelData)
                            }
                        }
                    }
                }
            }
        }
    }
}
