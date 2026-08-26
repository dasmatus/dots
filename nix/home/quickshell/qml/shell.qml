// Entry point for the dots Quickshell shell.
//
// Variants over Quickshell.screens rather than one window: it builds and tears
// down a bar per monitor as they come and go, which waybar needed a service
// restart to manage. Bar declares modelData as required, and Variants supplies
// it per screen.
//
// The notification layer and the OSD are single instances that follow the
// focused monitor, rather than one per screen. Two monitors showing the same
// notification is a duplicate, not a feature.
//
// The launcher and settings form join them in the phases that follow.
import Quickshell
import "bar"
import "notifications"
import "osd"

ShellRoot {
    Variants {
        model: Quickshell.screens

        Bar {}
    }

    Notifications {}

    Osd {}
}
