// app.rs::Screen::WifiConnecting. No key handling here, matching app.rs's
// `Screen::Installing | Screen::WifiConnecting => {}` arm — a half-finished
// nmcli handshake is worse than a screen the user can back out of.
//
// The actual `nmcli device wifi connect` call is deliberately NOT wired up:
// task 3 only drives nmcli through Process for scanning (Network.qml). This
// plan writes no system state before Confirm, and running the connect
// command is exactly that kind of state, so this screen is a dead end here —
// whichever later plan needs the installer to reach a networked target also
// owns net.rs::run_connect's QML side and the ConnectDone transitions
// app.rs::on_net_event handles.
import QtQuick
import ".."

Frame {
    id: root

    required property string ssid

    title: "Connecting"

    Text {
        width: parent.width
        text: `connecting to ${root.ssid}…`
        color: Theme.fgDark
        font.family: Theme.fontUi
        font.pixelSize: Theme.fontSize
    }
}
