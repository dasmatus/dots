// Home, the XDG user directories, and every currently-mounted device.
//
// The XDG rows are read from user-dirs.dirs rather than hardcoded: their
// names are localised, so this login's Desktop is "Schreibtisch" and its
// Public is "Öffentlich", and an English literal would point at
// directories that do not exist here. places.js does the parsing and is
// unit-tested; this file only draws what it returns.
//
// Navigation calls Devices.requestOpen, the signal Files.qml already
// listens for, so nothing in Files.qml needs touching for these clicks to
// work. Eject is a direct in-process call on the singleton instead: it is
// an immediate action, not something another surface needs to react to.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "places.js" as Places
import "../services"
import "../services/devices.js" as DevicesMath
import "../common"
import ".."

Rectangle {
    id: root

    readonly property string home: Quickshell.env("HOME")
    property var places: [
        {
            label: "Home",
            path: root.home,
            glyph: "\u{F02DC}",
            colour: "accent"
        }
    ]

    signal requested(string path)

    color: Theme.bgDarker
    radius: Theme.filesRadius
    border.width: 1
    border.color: Theme.border

    property var bookmarks: []

    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || `${root.home}/.config`

    // qmllint disable unresolved-type
    FileView {
        path: `${root.configHome}/user-dirs.dirs`
        watchChanges: true
        onFileChanged: reload()

        // A login with no user-dirs.dirs at all is normal, not an error:
        // places.js then returns Home alone, which is the same list this
        // sidebar had before it learned about XDG.
        onLoadFailed: root.places = Places.placesFor("", root.home)
        onLoaded: root.places = Places.placesFor(text(), root.home)
    }

    // The same file every GTK file manager reads, so a bookmark added here
    // shows up there and the other way round. nix/home/default.nix declares
    // it, which makes the path a read-only nix-store symlink — this only
    // ever reads it, and a new bookmark is a home-manager edit.
    FileView {
        path: `${root.configHome}/gtk-3.0/bookmarks`
        watchChanges: true
        onFileChanged: reload()

        onLoadFailed: root.bookmarks = []
        onLoaded: root.bookmarks = Places.parseBookmarks(text())
    }
    // qmllint enable unresolved-type

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.filesPadding

        spacing: 2

        Text {
            Layout.bottomMargin: 4

            text: "Places"
            color: Theme.muted
            font.family: Theme.fontUi
            font.pixelSize: Theme.fontSize
            font.bold: true
        }

        Repeater {
            model: root.places

            delegate: Item {
                id: place

                required property var modelData

                Layout.fillWidth: true
                implicitHeight: Theme.filesRowHeight

                Rectangle {
                    anchors.fill: parent
                    radius: Theme.filesRadius / 2
                    color: placeArea.containsMouse ? Theme.bgDark : "transparent"
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    spacing: 0

                    Text {
                        Layout.preferredWidth: Theme.filesIconColumn
                        text: place.modelData.glyph
                        color: Tokens.colourOf(place.modelData.colour)
                        font.family: Theme.fontUi
                        font.pixelSize: Theme.filesIconSize
                    }

                    Text {
                        Layout.fillWidth: true
                        text: place.modelData.label
                        color: Theme.fg
                        font.family: Theme.fontUi
                        font.pixelSize: Theme.fontSize
                        elide: Text.ElideRight
                    }
                }

                MouseArea {
                    id: placeArea

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.requested(place.modelData.path)
                }
            }
        }

        Text {
            Layout.topMargin: 10
            Layout.bottomMargin: 4

            text: "Bookmarks"
            color: Theme.muted
            font.family: Theme.fontUi
            font.pixelSize: Theme.fontSize
            font.bold: true
            visible: root.bookmarks.length > 0
        }

        Repeater {
            model: root.bookmarks

            delegate: Item {
                id: bookmark

                required property var modelData

                Layout.fillWidth: true
                implicitHeight: Theme.filesRowHeight

                Rectangle {
                    anchors.fill: parent
                    radius: Theme.filesRadius / 2
                    color: bookmarkArea.containsMouse ? Theme.bgDark : "transparent"
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    spacing: 0

                    Text {
                        Layout.preferredWidth: Theme.filesIconColumn
                        text: bookmark.modelData.glyph
                        color: Tokens.colourOf(bookmark.modelData.colour)
                        font.family: Theme.fontUi
                        font.pixelSize: Theme.filesIconSize
                    }

                    Text {
                        Layout.fillWidth: true
                        text: bookmark.modelData.label
                        color: Theme.fg
                        font.family: Theme.fontUi
                        font.pixelSize: Theme.fontSize
                        elide: Text.ElideRight
                    }
                }

                MouseArea {
                    id: bookmarkArea

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.requested(bookmark.modelData.path)
                }
            }
        }

        Text {
            Layout.topMargin: 10
            Layout.bottomMargin: 4

            text: "Devices"
            color: Theme.muted
            font.family: Theme.fontUi
            font.pixelSize: Theme.fontSize
            font.bold: true
            visible: Devices.devices.length > 0
        }

        Repeater {
            model: Devices.devices

            delegate: Item {
                id: entry

                required property var modelData

                Layout.fillWidth: true
                implicitHeight: Theme.filesRowHeight

                Rectangle {
                    anchors.fill: parent
                    radius: Theme.filesRadius / 2
                    color: deviceArea.containsMouse ? Theme.bgDark : "transparent"
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    spacing: 0

                    Text {
                        Layout.preferredWidth: Theme.filesIconColumn
                        text: "\u{F02CA}"
                        color: Theme.blue
                        font.family: Theme.fontUi
                        font.pixelSize: Theme.filesIconSize
                    }

                    Text {
                        Layout.fillWidth: true
                        text: DevicesMath.displayLabel(entry.modelData)
                        color: Theme.fg
                        font.family: Theme.fontUi
                        font.pixelSize: Theme.fontSize
                        elide: Text.ElideRight
                    }

                    Text {
                        text: "\u{F0183}"
                        color: ejectArea.containsMouse ? Theme.accent : Theme.muted
                        font.family: Theme.fontUi
                        font.pixelSize: Theme.filesIconSize

                        MouseArea {
                            id: ejectArea

                            anchors.fill: parent
                            anchors.margins: -4
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: Devices.eject(entry.modelData.path, entry.modelData.diskPath)
                        }
                    }
                }

                MouseArea {
                    id: deviceArea

                    anchors.fill: parent
                    z: -1
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.requested(entry.modelData.mountPoint)
                }
            }
        }

        // Without this, ColumnLayout hands the leftover height to its
        // children and the whole list floats at the vertical centre. The
        // filler takes the slack so Places stays pinned to the top.
        Item {
            Layout.fillHeight: true
        }
    }
}
