// app.rs::Screen::Confirm. Renders Config.settingsNix(cfg) verbatim — the
// same writer Task 1 ported — so the user sees exactly what plan 3c would
// write, byte for byte, before typing the uppercase "ERASE" app.rs also
// requires. Esc returns to wherever Network sent the user on (Hostname if
// autodetection picked the disk, DiskSelect otherwise), matching app.rs's
// `self.screen = self.after_network()` on this exact key.
//
// Enter with "ERASE" only emits `confirmed()` here — nothing runs. Wiring
// that signal to an actual install (spawning install.rs's sequence and
// waiting for install::Event::Finished/Failed before moving on) is plan 3c's
// job, not this one's; installer.qml's handler says so at the call site.
pragma ComponentBehavior: Bound

import QtQuick
import ".."
import "../common"
import "config.js" as Config

Frame {
    id: root

    required property var cfg

    signal confirmed()
    signal back()

    title: "Confirm"
    hint: "Type ERASE and press Enter to continue · Esc to go back"

    onActivated: field.focusInput()

    Text {
        width: parent.width

        text: Config.settingsNix(root.cfg)
        color: Theme.fg
        wrapMode: Text.WordWrap

        font.family: Theme.fontMono
        font.pixelSize: Theme.fontSize * 0.9
    }

    Text {
        width: parent.width

        text: "This is a preview only. Nothing is written until a later step actually runs the install."
        color: Theme.muted
        wrapMode: Text.WordWrap

        font.family: Theme.fontUi
        font.pixelSize: Theme.fontSize * 0.85
    }

    Field {
        id: field

        width: parent.width

        onAccepted: {
            if (text === "ERASE") {
                text = "";
                root.error = "";
                root.confirmed();
            } else {
                root.error = "type ERASE (uppercase) to proceed";
            }
        }
        onEscaped: {
            text = "";
            root.error = "";
            root.back();
        }
    }
}
