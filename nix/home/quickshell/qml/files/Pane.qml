// One directory's listing. `find -maxdepth 1 -printf` runs as direct argv
// with no shell. Nothing on this path interpolates a path into a command
// string, so there is nothing here for a shell to need.
//
// `active` is owned by Files.qml, not by this file: only one side may be
// active at a time, and a property this file set on itself could not
// enforce that. A click anywhere in the pane asks the parent for focus via
// focusRequested() instead of claiming it directly.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "files.js" as FilesMath
import "icons.js" as Icons
import "operations.js" as Operations
import ".."

Rectangle {
    id: root

    required property string path
    required property bool active
    required property bool showHidden

    signal navigate(string path)
    signal focusRequested()
    // Window coordinates, because the menu is mounted on the window rather
    // than inside this pane: a menu clipped to the pane it was opened in
    // could not overhang the pane's own edge.
    signal contextRequested(real x, real y)

    // What `find` returned, before the dotfile filter. `entries` is what
    // the list actually shows, and every index on screen indexes into it.
    property var allEntries: []
    readonly property var entries: FilesMath.visibleEntries(root.allEntries, root.showHidden)
    property int selectedIndex: -1
    // model: is root.entries, a plain JS array, so QML hands each delegate
    // a fresh wrapper object every time the list is rebuilt — a stored
    // entry never === anything a delegate holds. Derive selected from the
    // index instead of storing the object itself.
    readonly property var selected: root.selectedIndex >= 0 && root.selectedIndex < root.entries.length ? root.entries[root.selectedIndex] : null

    // Stamped when a listing lands rather than read live per row: every
    // delegate would otherwise call Date.now() on every repaint, and all of
    // them want the same "now" anyway — the one the listing was taken at.
    property double listedAt: 0

    color: Theme.bg
    radius: Theme.filesRadius

    // Constant width, colour-only change. A border that appears on focus
    // steals its own width from the content and shifts every row sideways
    // as the active side moves, which is what this file used to do.
    border.width: 1
    border.color: root.active ? Theme.accent : Theme.border

    // A stale `selected` pointing at an entry the list no longer shows is
    // how a write operation can land on something the UI never highlighted:
    // navigating away (onPathChanged) drops it immediately, and every
    // completed listing (list()'s own async completion, below) drops it
    // again regardless of why list() ran — including a post-operation
    // refresh that Files.qml triggers with no path change at all.
    onPathChanged: {
        root.selectedIndex = -1;
        root.list();
    }

    // Same hazard, different trigger: revealing or hiding dotfiles renumbers
    // every row, so an index kept across the toggle would point at a
    // different file than the one that was highlighted.
    onShowHiddenChanged: root.selectedIndex = -1
    Component.onCompleted: root.list()

    function list(): void {
        lsProc.command = FilesMath.listingArgv(root.path);
        lsProc.running = true;
    }

    function activate(entry: var): void {
        const child = FilesMath.join(root.path, entry.name);

        if (entry.isDir) {
            root.navigate(child);
        } else {
            // Operations.openArgv, not an inline array literal: it has no
            // "--" and must never grow one — xdg-open's own argument loop
            // rejects it outright ("unexpected option '--'", exit 1),
            // confirmed against the exact binary this service resolves
            // from PATH, and broken that way once already by a "--" added
            // here in an earlier pass over this file. Being a pure
            // builder now means a test pins that shape directly. The
            // leading-dash exposure that earlier "--" was guarding
            // against is closed at its source instead: Files.qml's
            // setActivePath refuses a non-absolute root.path, so `child`
            // can never start with anything but "/".
            Quickshell.execDetached(Operations.openArgv(child));
        }
    }

    Process {
        id: lsProc

        stdout: StdioCollector {
            onStreamFinished: {
                root.selectedIndex = -1;
                root.listedAt = Date.now();
                root.allEntries = FilesMath.parseListing(this.text);
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.filesPadding
        spacing: Theme.filesPadding

        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            model: root.entries

            delegate: Rectangle {
                id: row

                required property var modelData
                required property int index

                readonly property bool current: root.selectedIndex === row.index

                width: ListView.view.width
                height: Theme.filesRowHeight
                radius: Theme.filesRadius / 2
                color: row.current ? Theme.accent : (rowArea.containsMouse ? Theme.bgDark : "transparent")

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    spacing: 0

                    Text {
                        Layout.preferredWidth: Theme.filesIconColumn

                        text: Icons.glyphFor(row.modelData)
                        // icons.js hands back a Theme property name, so the
                        // lookup is a property access rather than a switch
                        // repeated in every consumer of the module.
                        color: row.current ? Theme.bg : (Theme[Icons.colourFor(row.modelData)] ?? Theme.fg)
                        font.family: Theme.fontUi
                        font.pixelSize: Theme.filesIconSize
                    }

                    Text {
                        Layout.fillWidth: true

                        text: row.modelData.name
                        color: row.current ? Theme.bg : Theme.fg
                        font.family: Theme.fontUi
                        font.pixelSize: Theme.fontSize
                        elide: Text.ElideMiddle
                    }

                    Text {
                        Layout.preferredWidth: Theme.filesSizeColumn

                        text: FilesMath.formatSize(row.modelData)
                        color: row.current ? Theme.bg : Theme.muted
                        font.family: Theme.fontMono
                        font.pixelSize: Theme.fontSize
                        horizontalAlignment: Text.AlignRight
                    }

                    Text {
                        Layout.preferredWidth: Theme.filesTimeColumn

                        text: FilesMath.formatTime(row.modelData, root.listedAt)
                        color: row.current ? Theme.bg : Theme.muted
                        font.family: Theme.fontMono
                        font.pixelSize: Theme.fontSize
                        horizontalAlignment: Text.AlignRight
                    }
                }

                MouseArea {
                    id: rowArea

                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.LeftButton | Qt.RightButton

                    // Right-click selects before it opens the menu, so the
                    // menu's actions name the row under the cursor rather
                    // than whatever was selected beforehand.
                    onClicked: (mouse) => {
                        root.focusRequested();
                        root.selectedIndex = row.index;

                        if (mouse.button === Qt.RightButton) {
                            const at = row.mapToItem(null, mouse.x, mouse.y);
                            root.contextRequested(at.x, at.y);
                        }
                    }
                    onDoubleClicked: root.activate(row.modelData)
                }
            }
        }
    }

    // Right-click on bare pane background, below every row. `z: -1` puts it
    // under the ColumnLayout so a row still wins the clicks that land on
    // one; this only ever sees the empty space beneath the last entry.
    // Clearing the selection first is what makes the menu collapse to the
    // actions that need no selection.
    MouseArea {
        anchors.fill: parent
        z: -1
        acceptedButtons: Qt.RightButton

        onClicked: (mouse) => {
            root.focusRequested();
            root.selectedIndex = -1;

            const at = root.mapToItem(null, mouse.x, mouse.y);
            root.contextRequested(at.x, at.y);
        }
    }
}
