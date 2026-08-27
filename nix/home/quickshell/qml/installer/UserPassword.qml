// app.rs::Screen::UserPassword. The typed value is held in `wizard.pending`
// (installer.qml's transient, non-cfg state — app.rs's own `pending_password`
// field, kept off `InstallConfig` for the same reason: it is not final until
// UserPasswordConfirm agrees with it) rather than written to `cfg` yet. No
// Esc handler, matching app.rs.
pragma ComponentBehavior: Bound

import QtQuick

Frame {
    id: root

    required property var wizard

    signal next()

    title: "User password"
    hint: "Enter to continue"

    onActivated: field.focusInput()

    Field {
        id: field

        width: parent.width
        masked: true

        onAccepted: {
            if (text.length === 0) {
                root.error = "password must not be empty";
            } else {
                root.wizard.pending = text;
                root.error = "";
                text = "";
                root.next();
            }
        }
    }
}
