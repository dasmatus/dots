// app.rs::Screen::Failed. Enter, Esc and 'q' all quit, matching app.rs's
// `KeyCode::Enter | KeyCode::Esc | KeyCode::Char('q')` arm. Nothing in this
// plan can reach this screen — nothing here executes, so nothing here can
// fail — but it is built and lint-/test-clean so plan 3c's install runner
// has somewhere to send install::Event::Failed(e) without inventing a
// fourth terminal screen on top of what app.rs already has.
pragma ComponentBehavior: Bound

import QtQuick

Frame {
    id: root

    property string message: ""

    signal quit()

    title: "Install failed"
    error: message
    hint: "Enter, Esc or q to quit"

    onActivated: capture.forceActiveFocus()

    Item {
        id: capture

        width: parent.width
        height: 1
        focus: true

        Keys.onReturnPressed: root.quit()
        Keys.onEnterPressed: root.quit()
        Keys.onEscapePressed: root.quit()
        Keys.onPressed: event => {
            if (event.text === "q")
                root.quit();
        }
    }
}
