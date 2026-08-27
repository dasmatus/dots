// app.rs::Screen::GitEmail. Esc returns to GitName, same as app.rs.
pragma ComponentBehavior: Bound

import QtQuick
import "config.js" as Config

Frame {
    id: root

    required property var cfg

    signal next()
    signal back()

    title: "Git email"
    hint: "Enter to continue · Esc to go back"

    onActivated: field.focusInput()

    Field {
        id: field

        width: parent.width

        onAccepted: {
            const err = Config.validateGitEmail(text);
            if (err) {
                root.error = err;
            } else {
                root.cfg.gitEmail = text;
                root.error = "";
                text = "";
                root.next();
            }
        }
        onEscaped: {
            text = "";
            root.error = "";
            root.back();
        }
    }
}
