// The Proton page of the settings panel, reached by pressing Enter on the
// "Proton" row in Settings.qml.
//
// It exists because the two Proton modules (nix/home/proton-drive.nix,
// nix/home/proton-calendar.nix) deliberately keep no credentials in Nix:
// rclone and proton-cli each log in once and then persist their own session.
// That left setup as two hand-typed shell commands and no way to tell whether
// either session was still alive. Both of those are what this page answers.
//
// Every credential goes to `proton-setup` (nix/home/proton-setup.nix) over
// stdin, using the same stdinEnabled/write()/EOF dance as
// installer/Runner.qml. Nothing is passed as an argument, so no password
// appears in `ps`, and nothing is written to disk here: the password and the
// code live in QML properties that are cleared the moment they are spent.
//
// Drive and calendar connect separately, with a button each, because a TOTP
// code is single use. Spending one on the Drive login leaves nothing valid
// for the calendar, so asking for both at once would always fail the second
// half and look like a bug.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import ".."
import "../common"

ColumnLayout {
    id: root

    // Seeded from the protonEmail row of `global-settings dump` and handed
    // back on connect, so the address is typed once and then remembered by
    // the same settings file every other row uses.
    property string initialEmail: ""

    signal back
    signal emailEdited(string value)

    property string password: ""
    property string totp: ""
    property string status: ""
    property bool driveOk: false
    property bool calendarOk: false
    property bool busy: false

    spacing: 14

    function refresh(): void {
        statusProc.running = false;
        statusProc.running = true;
    }

    // Clearing on the way out matters as much as clearing after a successful
    // connect: leaving the panel with a password still in a property would
    // keep it alive for the whole session, since Settings.qml builds this page
    // once and only toggles its visibility.
    function forget(): void {
        root.password = "";
        root.totp = "";
    }

    function connect(target: string): void {
        if (emailField.text === "") {
            root.status = "Enter your Proton address first";
            return;
        }
        if (root.password === "") {
            root.status = "Enter your password first";
            return;
        }

        root.busy = true;
        root.status = `Connecting ${target}…`;
        root.emailEdited(emailField.text);

        connector.target = target;
        // One payload, three lines, in the order proton-setup reads them.
        connector._pendingStdin = `${emailField.text}\n${root.password}\n${root.totp}\n`;
        connector.command = ["proton-setup", "connect", target];
        connector.running = false;
        connector.running = true;
    }

    Process {
        id: statusProc

        command: ["proton-setup", "status"]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const parsed = JSON.parse(this.text);
                    root.driveOk = parsed.drive === true;
                    root.calendarOk = parsed.calendar === true;
                } catch (error) {
                    // A status probe that cannot be read is not the same as a
                    // disconnected account, and saying "not configured" here
                    // would send the user off to re-enter working credentials.
                    root.status = "Could not read the Proton status";
                }
            }
        }
    }

    Process {
        id: connector

        property string target: ""
        property var _pendingStdin: null

        onStarted: {
            if (connector._pendingStdin !== null) {
                connector.write(connector._pendingStdin);
                // Close the write side so proton-setup's three `read` calls
                // see EOF rather than blocking on a fourth line.
                connector.stdinEnabled = false;
                connector._pendingStdin = null;
            }
        }

        stdinEnabled: true

        // Process.exited's second argument is a QProcess::ExitStatus, a type
        // Quickshell does not export, so the linter cannot compile the
        // handler's signature even though it runs. Same suppression as
        // Settings.qml's writer.
        // qmllint disable signal-handler-parameters
        onExited: (exitCode, exitStatus) => {
            root.busy = false;
            if (exitCode === 0) {
                root.status = `${connector.target === "drive" ? "Drive" : "Calendar"} connected`;
                // The code is spent either way, and the password has done its
                // job: from here the tool's own cached session is the
                // credential.
                root.forget();
            } else {
                root.status = `${connector.target === "drive" ? "Drive" : "Calendar"} login failed, try a fresh code`;
                root.totp = "";
            }
            root.refresh();
        }
        // qmllint enable signal-handler-parameters
    }

    RowLayout {
        Layout.fillWidth: true

        spacing: 16

        Repeater {
            model: [
                {
                    label: "Drive",
                    ok: root.driveOk
                },
                {
                    label: "Calendar",
                    ok: root.calendarOk
                }
            ]

            delegate: RowLayout {
                id: badge

                required property var modelData

                spacing: 8

                Rectangle {
                    implicitWidth: 10
                    implicitHeight: 10
                    radius: 5

                    color: badge.modelData.ok ? Theme.accent : Theme.selection
                }

                Text {
                    text: `${badge.modelData.label}: ${badge.modelData.ok ? "connected" : "not configured"}`
                    color: badge.modelData.ok ? Theme.fg : Theme.muted

                    font.family: Theme.fontUi
                    font.pointSize: 10
                }
            }
        }

        Item {
            Layout.fillWidth: true
        }
    }

    // Three explicit rows rather than a Repeater over a field model: each one
    // needs an id the rest of the page can read, and a delegate cannot hand
    // one out without a side-channel that costs more than the repetition
    // saves.
    RowLayout {
        Layout.fillWidth: true

        spacing: 16

        Text {
            Layout.preferredWidth: 120

            text: "Email"
            color: Theme.fgDark

            font.family: Theme.fontUi
            font.pointSize: 10
        }

        Field {
            id: emailField

            Layout.fillWidth: true

            text: root.initialEmail

            onEscaped: root.back()
        }
    }

    RowLayout {
        Layout.fillWidth: true

        spacing: 16

        Text {
            Layout.preferredWidth: 120

            text: "Password"
            color: Theme.fgDark

            font.family: Theme.fontUi
            font.pointSize: 10
        }

        Field {
            id: passwordField

            Layout.fillWidth: true

            masked: true
            text: root.password

            onTextChanged: root.password = passwordField.text
            onEscaped: root.back()
        }
    }

    RowLayout {
        Layout.fillWidth: true

        spacing: 16

        Text {
            Layout.preferredWidth: 120

            text: "2FA code"
            color: Theme.fgDark

            font.family: Theme.fontUi
            font.pointSize: 10
        }

        Field {
            id: totpField

            Layout.fillWidth: true

            text: root.totp

            onTextChanged: root.totp = totpField.text
            onEscaped: root.back()
        }
    }

    RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: 8

        spacing: 12

        Text {
            Layout.fillWidth: true

            text: root.status
            color: Theme.muted

            font.family: Theme.fontUi
            font.pointSize: 9
        }

        Repeater {
            model: [
                {
                    target: "drive",
                    label: "Connect Drive"
                },
                {
                    target: "calendar",
                    label: "Connect Calendar"
                }
            ]

            delegate: Rectangle {
                id: button

                required property var modelData

                Layout.preferredWidth: 150
                Layout.preferredHeight: 32

                radius: 8
                color: root.busy ? Theme.selection : Theme.accent

                Text {
                    anchors.centerIn: parent

                    text: button.modelData.label
                    color: root.busy ? Theme.muted : Theme.bg

                    font.family: Theme.fontUi
                    font.pointSize: 10
                    font.bold: true
                }

                MouseArea {
                    anchors.fill: parent

                    enabled: !root.busy
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.connect(button.modelData.target)
                }
            }
        }
    }
}
