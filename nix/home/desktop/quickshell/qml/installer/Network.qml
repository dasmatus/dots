// app.rs::Screen::Network. Scanning is real — nmcli driven through Process,
// same as net.rs::run_scan — because listing nearby SSIDs touches nothing;
// connecting is deliberately NOT wired here (see WifiConnecting.qml's
// header): this plan writes no system state before Confirm, and running
// `nmcli device wifi connect` is exactly that kind of state.
//
// parseWifiList/splitTerse below port net.rs::parse_wifi_list and
// split_terse; they stay local to this file rather than joining disks.js
// because task 3 only calls for one new module (disks.js) and this logic has
// no caller outside Network.qml to share it with.
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import ".."

Frame {
    id: root

    required property var cfg
    required property bool diskAuto

    property var networks: []
    property int selected: 0
    property bool busy: true
    property string status: "scanning for networks…"

    signal connectOpen(string ssid)
    signal needPassword(string ssid)
    signal skip()
    signal back()

    title: "Network"
    hint: busy ? "" : "Up/Down to move · Enter to connect · r to rescan · s to skip · Esc to go back"

    onActivated: {
        capture.forceActiveFocus();
        root.rescan();
    }

    function rescan() {
        root.busy = true;
        root.status = "scanning for networks…";
        root.error = "";
        scanProc.running = true;
    }

    function attemptConnect() {
        if (root.busy)
            return;
        const n = root.networks[root.selected];
        if (!n) {
            root.error = "no networks found — r to rescan, s to skip";
            return;
        }
        root.error = "";
        if (root.isOpen(n.security))
            root.connectOpen(n.ssid);
        else
            root.needPassword(n.ssid);
    }

    function isOpen(security) {
        return security.length === 0 || security === "--";
    }

    function signalBars(signal) {
        if (signal <= 24)
            return "▂___";
        if (signal <= 49)
            return "▂▄__";
        if (signal <= 74)
            return "▂▄▆_";
        return "▂▄▆█";
    }

    /// Split a `nmcli -t` line on unescaped `:`, treating `\` as an escape
    /// for the next character.
    function splitTerse(line) {
        const fields = [];
        let current = "";
        for (let i = 0; i < line.length; i++) {
            const c = line[i];
            if (c === "\\") {
                if (i + 1 < line.length) {
                    current += line[i + 1];
                    i++;
                }
            } else if (c === ":") {
                fields.push(current);
                current = "";
            } else {
                current += c;
            }
        }
        fields.push(current);
        return fields;
    }

    /// Dedupe by SSID keeping the strongest signal; sort by signal
    /// descending, ties by SSID ascending — net.rs::parse_wifi_list.
    function parseWifiList(terse) {
        const bySsid = new Map();
        for (const line of terse.split("\n")) {
            const fields = root.splitTerse(line);
            if (fields.length !== 3)
                continue;
            const [ssid, signalStr, security] = fields;
            if (ssid.length === 0)
                continue;
            const signal = parseInt(signalStr, 10) || 0;
            const existing = bySsid.get(ssid);
            if (existing) {
                if (signal > existing.signal) {
                    existing.signal = signal;
                    existing.security = security;
                }
            } else {
                bySsid.set(ssid, {
                    ssid,
                    signal,
                    security
                });
            }
        }
        const nets = Array.from(bySsid.values());
        nets.sort((a, b) => b.signal - a.signal || a.ssid.localeCompare(b.ssid));
        return nets;
    }

    Process {
        id: scanProc

        command: ["nmcli", "-t", "-f", "SSID,SIGNAL,SECURITY", "device", "wifi", "list", "--rescan", "yes"]

        stdout: StdioCollector {
            onStreamFinished: {
                root.busy = false;
                root.networks = root.parseWifiList(this.text);
                root.selected = 0;
            }
        }

        // qmllint disable signal-handler-parameters
        onExited: exitCode => {
            if (exitCode !== 0 && root.busy) {
                root.busy = false;
                root.error = "Wi-Fi scan failed — r to rescan, s to skip";
            }
        }
        // qmllint enable signal-handler-parameters
    }

    Item {
        id: capture

        width: parent.width
        height: list.height
        focus: true

        Keys.onUpPressed: root.selected = Math.max(root.selected - 1, 0)
        Keys.onDownPressed: {
            if (root.selected + 1 < root.networks.length)
                root.selected += 1;
        }
        Keys.onEscapePressed: root.back()
        Keys.onReturnPressed: root.attemptConnect()
        Keys.onEnterPressed: root.attemptConnect()
        Keys.onPressed: event => {
            if (root.busy)
                return;
            if (event.key === Qt.Key_R) {
                root.rescan();
                event.accepted = true;
            } else if (event.key === Qt.Key_S) {
                root.skip();
                event.accepted = true;
            }
        }

        Column {
            id: list

            width: parent.width
            spacing: 8

            Text {
                visible: root.busy
                text: root.status
                color: Theme.muted
                font.family: Theme.fontUi
                font.pixelSize: Theme.fontSize
            }

            Text {
                visible: !root.busy && root.networks.length === 0
                text: "no networks found — r to rescan, s to skip"
                color: Theme.muted
                font.family: Theme.fontUi
                font.pixelSize: Theme.fontSize
            }

            Repeater {
                model: root.networks

                delegate: Rectangle {
                    id: row

                    required property var modelData
                    required property int index

                    width: list.width
                    height: 32
                    radius: 6
                    color: index === root.selected ? Theme.selection : "transparent"

                    Row {
                        anchors.fill: parent
                        anchors.leftMargin: 12

                        spacing: 12

                        Text {
                            anchors.verticalCenter: parent.verticalCenter

                            text: root.signalBars(row.modelData.signal)
                            color: Theme.accent

                            font.family: Theme.fontMono
                            font.pixelSize: Theme.fontSize
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter

                            text: row.modelData.ssid + (root.isOpen(row.modelData.security) ? "" : "  🔒")
                            color: Theme.fg

                            font.family: Theme.fontUi
                            font.pixelSize: Theme.fontSize
                        }
                    }
                }
            }
        }
    }
}
