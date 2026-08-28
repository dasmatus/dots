// app.rs::Screen::Hostname. Empty input on Enter falls back to "tokyonight"
// (app.rs's own default), then validate_hostname gates advancing. No Esc
// handler here — app.rs has none either: Hostname is reached from both
// Network (auto-picked disk) and DiskSelect (manual pick), so there is no
// single screen "back" means, and the terminal build never invented one.
pragma ComponentBehavior: Bound

import QtQuick
import "../common"
import "config.js" as Config

Frame {
    id: root

    required property var cfg

    signal next()

    title: "Hostname"
    hint: "Enter to continue — leave blank for \"tokyonight\""

    onActivated: field.focusInput()

    Field {
        id: field

        width: parent.width

        onAccepted: {
            const candidate = text.length === 0 ? "tokyonight" : text;
            const err = Config.validateHostname(candidate);
            if (err) {
                root.error = err;
            } else {
                root.cfg.hostname = candidate;
                root.error = "";
                text = "";
                root.next();
            }
        }
    }
}
