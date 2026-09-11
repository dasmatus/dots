// app.rs::Screen::UserPasswordConfirm. A match writes `cfg.userPassword` and
// advances to Confirm; a mismatch clears `wizard.pending` and sends the user
// back to UserPassword to retype both; app.rs does the same rather than
// letting one field survive a failed confirmation, so a stale first attempt
// can never silently become the password. No Esc handler, matching app.rs.
pragma ComponentBehavior: Bound

import QtQuick
import "../common"

Frame {
    id: root

    required property var cfg
    required property var wizard

    signal next()
    signal mismatch()

    title: "Confirm password"
    hint: "Enter to continue"

    onActivated: field.focusInput()

    Field {
        id: field

        width: parent.width
        masked: true

        onAccepted: {
            if (text === root.wizard.pending) {
                root.cfg.userPassword = text;
                root.wizard.pending = "";
                root.error = "";
                text = "";
                root.next();
            } else {
                root.wizard.pending = "";
                root.error = "passwords do not match, try again";
                text = "";
                root.mismatch();
            }
        }
    }
}
