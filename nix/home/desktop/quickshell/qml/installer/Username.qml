// app.rs::Screen::Username. validate_username is installer-tui's own
// (config.rs), not one of settings-global's three — see config.js's header
// for why it still has to be ported. No Esc handler, matching app.rs.
pragma ComponentBehavior: Bound

import QtQuick
import "../common"
import "config.js" as Config

Frame {
    id: root

    required property var cfg

    signal next()

    title: "Username"
    hint: "Enter to continue"

    onActivated: field.focusInput()

    Field {
        id: field

        width: parent.width

        onAccepted: {
            const err = Config.validateUsername(text);
            if (err) {
                root.error = err;
            } else {
                root.cfg.username = text;
                root.error = "";
                text = "";
                root.next();
            }
        }
    }
}
