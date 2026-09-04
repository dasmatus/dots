// app.rs::Screen::GitName. Esc returns to Username, same as app.rs.
pragma ComponentBehavior: Bound

import QtQuick
import "../common"
import "config.js" as Config

Frame {
    id: root

    required property var cfg

    signal next()
    signal back()

    title: "Git name"
    hint: "Enter to continue · Esc to go back"

    onActivated: field.focusInput()

    Field {
        id: field

        width: parent.width

        onAccepted: {
            const err = Config.validateGitName(text);
            if (err) {
                root.error = err;
            } else {
                root.cfg.gitName = text;
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
