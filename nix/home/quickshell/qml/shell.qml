// Entry point for the dots Quickshell shell.
//
// Variants over Quickshell.screens rather than one window: it builds and tears
// down a bar per monitor as they come and go, which waybar needed a service
// restart to manage. Bar declares modelData as required, and Variants supplies
// it per screen.
//
// The notification daemon, OSD, launcher and settings form join the bar here
// in the phases that follow.
import Quickshell
import "bar"

ShellRoot {
    Variants {
        model: Quickshell.screens

        Bar {}
    }
}
