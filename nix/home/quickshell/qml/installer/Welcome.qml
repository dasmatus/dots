// app.rs::Screen::Welcome. Enter starts the wizard (Network is next, since
// app.rs queues a Wi-Fi scan on the same key press); Esc or 'q' quits, same
// as the terminal build's `KeyCode::Esc | KeyCode::Char('q')` arm.
//
// `ready` gates Enter on installer.qml's background lsblk/meminfo reads
// (Component.onCompleted-scheduled, well before a human finishes reading
// this screen) so Network never asks `autodetectDisk` a question the disk
// listing hasn't answered yet.
pragma ComponentBehavior: Bound

import QtQuick
import ".."

Frame {
    id: root

    required property var cfg
    property bool ready: true

    signal next()
    signal quit()

    title: "tokyonight installer"
    hint: ready ? "Enter to begin · Esc or q to quit" : "detecting hardware…"

    onActivated: capture.forceActiveFocus()

    Item {
        id: capture

        width: parent.width
        height: 1
        focus: true

        Keys.onReturnPressed: if (root.ready)
            root.next()
        Keys.onEnterPressed: if (root.ready)
            root.next()
        Keys.onEscapePressed: root.quit()
        Keys.onPressed: event => {
            if (event.text === "q")
                root.quit();
        }
    }

    Text {
        width: parent.width

        text: "Sets up tokyonight-dots: disk target, hostname, user, git identity and AI tooling. Nothing is written to disk until the final confirmation."
        color: Theme.fgDark
        wrapMode: Text.WordWrap

        font.family: Theme.fontUi
        font.pixelSize: Theme.fontSize
    }
}
