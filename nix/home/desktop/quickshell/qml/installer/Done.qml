// app.rs::Screen::Done. The terminal build's Enter arm reboots into the
// freshly installed system (`self.reboot = true; self.should_quit = true`);
// this plan runs no install, so there is nothing to reboot into yet — Enter
// here only quits the shell. Whichever plan wires the real install runner
// also owns making this Enter mean "reboot" again.
pragma ComponentBehavior: Bound

import QtQuick
import ".."

Frame {
    id: root

    signal quit()

    title: "Done"
    hint: "Enter to quit"

    onActivated: capture.forceActiveFocus()

    Item {
        id: capture

        width: parent.width
        height: 1
        focus: true

        Keys.onReturnPressed: root.quit()
        Keys.onEnterPressed: root.quit()
    }

    Text {
        width: parent.width

        text: "The settings above are what a real run would install. Nothing was written to disk."
        color: Theme.fgDark
        wrapMode: Text.WordWrap

        font.family: Theme.fontUi
        font.pixelSize: Theme.fontSize
    }
}
