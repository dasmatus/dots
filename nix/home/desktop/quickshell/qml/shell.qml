// Builds a QApplication rather than Quickshell's default QGuiApplication,
// which is what Qt's platform-menu layer needs to exist at all. Tray.qml
// opens a tray item's DBusMenu through SystemTrayItem.display(), and without
// this line every one of those calls aborts into the log — "Cannot display
// PlatformMenuEntry as quickshell was not started in QApplication mode" —
// having drawn nothing and thrown nothing. QsMenuAnchor.open() is gated on
// the same flag, so it is the platform-menu path that needs this, not the
// one API. Costs no closure: the quickshell binary already links
// libQt6Widgets. Pinned by tests/qml/tst_platform_menu.qml, which has to
// read this file's raw text because the line is a comment.
//@ pragma UseQApplication

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
// The launcher, cheatsheet, settings form, wallpaper picker, monitor
// arrange surface and file manager are single instances too: only one can
// be open, and it belongs where you are looking.
//
// Rotation has no window of its own; it holds a reference to the one
// Picker instance so its hourly random pick can drive the same apply() a
// grid click does.
//
// Watcher has no window either — it is the monitor hotplug daemon
// (hyprmon.service, before this migration) folded into a plain Scope. It
// runs unconditionally rather than lazily behind a keybind because a
// monitor can be plugged in at any time, not just while some other surface
// is open.
import Quickshell
import "bar"
import "cheatsheet"
import "files"
import "launcher"
import "monitors"
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

    Files {}

    Picker {
        id: picker
    }

    Rotation {
        picker: picker
    }

    Watcher {}

    Arrange {}
}
