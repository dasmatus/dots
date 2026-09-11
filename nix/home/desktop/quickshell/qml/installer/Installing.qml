// app.rs::Screen::Installing. Runs Runner.qml against `actions`, plan.js's
// planFor() output in the real flow, a harmless stand-in in a test, and
// renders the three things install.rs's Event stream produces: a step
// counter, a scrolling log, and the recovery key once it arrives. No key
// handling here, matching app.rs's `Screen::Installing | Screen::WifiConnecting
// => {}` arm. A half-finished install is worse than a screen the user can
// back out of.
//
// The recovery key is shown in its own always-visible banner, not folded
// into the scrolling log: it is the one line in this whole screen that
// locks the user out of their own disk if lost, so it must survive being
// scrolled past.
pragma ComponentBehavior: Bound

import QtQuick
import ".."

Frame {
    id: root

    required property var actions

    signal installed()
    signal installFailed(string message)

    property int current: 0
    property int total: 0
    property string currentTitle: "Preparing…"
    property string recoveryKey: ""
    property var logLines: []

    title: "Installing"
    hint: ""

    // This is the ONE line that makes Runner.qml reachable rather than a
    // unit-tested dead end (plan 1b's gap: four writers ported and tested,
    // three never wired to a caller). Runner imports Quickshell.Io, so
    // neither it nor this file, which instantiates it, can be run under
    // qmltestrunner at all (confirmed: the plugin only loads inside the
    // `quickshell` binary itself, not a bare Qt QML host); linting the BUILT
    // tree (nix-lint's other QML gate) is what stands in instead. Typo-ing
    // this call (`runner.rnu`) reproduced as a missing-property error at
    // this exact line, checked while writing this file, then reverted.
    onActivated: runner.run(root.actions)

    Runner {
        id: runner

        onStepStarted: (index, total, stepTitle) => {
            root.current = index;
            root.total = total;
            root.currentTitle = stepTitle;
        }
        onLog: line => {
            // Reassigned rather than pushed: QML bindings only notice a
            // property CHANGE, not an in-place array mutation. This is
            // the same reason Settings.qml's edit map is reassigned
            // rather than mutated (see that file's header).
            root.logLines = root.logLines.concat([line]);
        }
        onRecoveryKey: key => root.recoveryKey = key
        onFinished: root.installed()
        onFailed: message => root.installFailed(message)
    }

    Column {
        width: parent.width
        spacing: 16

        Text {
            width: parent.width

            text: root.total > 0 ? `Step ${root.current} / ${root.total} — ${root.currentTitle}` : root.currentTitle
            color: Theme.fg
            wrapMode: Text.WordWrap

            font.family: Theme.fontUi
            font.pixelSize: Theme.fontSize
        }

        Rectangle {
            width: parent.width
            height: keyText.implicitHeight + 24
            radius: 6
            color: Theme.selection
            visible: root.recoveryKey.length > 0

            Text {
                id: keyText

                anchors.centerIn: parent
                width: parent.width - 24

                text: `Recovery key — write this down, it will not be shown again:\n${root.recoveryKey}`
                color: Theme.accent
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter

                font.family: Theme.fontMono
                font.pixelSize: Theme.fontSize
            }
        }

        Flickable {
            id: logScroll

            width: parent.width
            height: 260
            contentWidth: width
            contentHeight: logColumn.height
            clip: true

            // Auto-scroll to the newest line as the log grows, so a long
            // install (nixos-install runs for minutes) always shows the
            // tail without the user having to touch anything.
            onContentHeightChanged: logScroll.contentY = Math.max(0, logScroll.contentHeight - logScroll.height)

            Column {
                id: logColumn

                width: parent.width

                Repeater {
                    model: root.logLines

                    delegate: Text {
                        id: logLine

                        required property string modelData

                        width: logColumn.width

                        text: logLine.modelData
                        color: Theme.fgDark
                        wrapMode: Text.WrapAnywhere

                        font.family: Theme.fontMono
                        font.pixelSize: Theme.fontSize * 0.85
                    }
                }
            }
        }
    }
}
