// app.rs::Screen::WifiPassword. 8-63 chars, matching net::run_connect's
// nmcli passphrase argument (WPA's own PSK length bounds). Esc returns to
// Network, same as app.rs.
pragma ComponentBehavior: Bound

import QtQuick
import ".."

Frame {
    id: root

    required property string ssid

    signal connectRequested(string password)
    signal back()

    title: "Wi-Fi password"
    hint: "Enter to continue · Esc to go back"

    onActivated: field.focusInput()

    Text {
        width: parent.width
        text: `Connecting to "${root.ssid}"`
        color: Theme.fgDark
        font.family: Theme.fontUi
        font.pixelSize: Theme.fontSize
    }

    Field {
        id: field

        width: parent.width
        masked: true

        onAccepted: {
            if (text.length >= 8 && text.length <= 63) {
                const password = text;
                text = "";
                root.error = "";
                root.connectRequested(password);
            } else {
                root.error = "passphrase must be 8–63 characters";
            }
        }
        onEscaped: {
            text = "";
            root.error = "";
            root.back();
        }
    }
}
