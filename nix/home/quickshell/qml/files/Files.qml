// The file manager's outer shell: one FloatingWindow around one Pane. The
// second Pane and the Sidebar's write operations arrive in later plans;
// Sidebar itself (Task 3) is the next task in this one.
//
// Devices.requestOpen(path) is the single way anything outside this file
// tells it where to go: the launcher's device rows (Plan 0), the
// launcher's directory hits and this window's own Sidebar (both later in
// this plan) all call it, and this Connections block is the only listener.
pragma ComponentBehavior: Bound

import QtQuick
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

        Pane {
            anchors.fill: parent

            path: root.path
            onNavigate: (path) => root.path = path
        }
    }
}
