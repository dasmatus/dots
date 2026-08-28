// The file manager's outer shell: one FloatingWindow holding a Sidebar and
// a Pane side by side in a RowLayout. A second Pane for dual-pane browsing
// arrives in a later plan.
//
// Devices.requestOpen(path) is the single way anything outside this file
// tells it where to go: this window's own Sidebar calls it, the launcher's
// directory hits will too once a later task in this plan wires them up,
// and this Connections block is the only listener.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../services"

Scope {
    id: root

    property string path: Quickshell.env("HOME")

    function open(): void {
        window.visible = true;
    }

    function close(): void {
        window.visible = false;
    }

    function toggle(): void {
        window.visible = !window.visible;
    }

    Connections {
        target: Devices

        function onRequestOpen(path) {
            root.path = path;
            root.open();
        }
    }

    IpcHandler {
        target: "files"

        function open(): void {
            root.open();
        }

        function close(): void {
            root.close();
        }

        function toggle(): void {
            root.toggle();
        }

        function openPath(path: string): void {
            root.path = path;
            root.open();
        }
    }

    FloatingWindow {
        id: window

        visible: false
        implicitWidth: 900
        implicitHeight: 600

        RowLayout {
            anchors.fill: parent
            spacing: 0

            Sidebar {
                Layout.fillHeight: true
                Layout.preferredWidth: 200
            }

            Pane {
                Layout.fillWidth: true
                Layout.fillHeight: true

                path: root.path
                onNavigate: (path) => root.path = path
            }
        }
    }
}
