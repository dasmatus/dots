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
// The launcher, cheatsheet, settings form and wallpaper picker are single
// instances too: only one can be open, and it belongs where you are looking.
import Quickshell
import "bar"
import "cheatsheet"
import "launcher"
import "notifications"
import "osd"
import "settings"
import "wallpaper"

ShellRoot {
    Variants {
        model: Quickshell.screens

        Bar {}
    }

    Notifications {}

    Osd {}

    Launcher {}

    Cheatsheet {}

    Settings {}

    Picker {}
}
