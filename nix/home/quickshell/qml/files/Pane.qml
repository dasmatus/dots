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
import "../common"
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

    // Theme.bgDark reads at roughly 1.1:1 contrast against the window's
    // own Theme.bg — with no border to fall back on, that pair is not
    // actually distinguishable. Theme.selection is the strongest fill the
    // existing palette offers against bg (~1.7:1) without inventing a new
    // token. The active/inactive distinction is carried by the strip
    // below, not by this fill, which stays the same for both.
    color: Theme.selection
    radius: Theme.filesRadius

    EdgeStrip {
        edge: "top"
        active: root.active
    }

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

    // Keyboard selection. Each of these also drags the view along, because
    // a selection that has scrolled out of sight is the same as no
    // selection at all — the next j moves something the user cannot see.
    function selectIndex(index: int): void {
        if (root.entries.length === 0)
            return;

        root.selectedIndex = Math.max(0, Math.min(index, root.entries.length - 1));
        list.positionViewAtIndex(root.selectedIndex, ListView.Contain);
    }

    // Starting from -1 means the first j selects the first row rather than
    // the second, and the first k selects the last.
    function moveSelection(delta: int): void {
        if (root.selectedIndex < 0) {
            root.selectIndex(delta > 0 ? 0 : root.entries.length - 1);
            return;
        }

        root.selectIndex(root.selectedIndex + delta);
    }

    function activateSelected(): void {
        if (root.selected)
            root.activate(root.selected);
    }

    function activate(entry: var): void {
        root.activateAt(root.path, entry);
    }

    // Opening an entry that lives somewhere other than this pane. `/`
    // answers from all of $HOME now, so a hit carries the directory it was
    // found in and this pane's own path is no longer the answer for every
    // row it is asked to open.
    //
    // `dir` is absolute on both paths that reach here: Files.qml's
    // setActivePath refuses a non-absolute root.path, and a search hit's
    // directory is built from Quickshell.env("HOME") by index.js's locate.
    function activateAt(dir: string, entry: var): void {
        const child = FilesMath.join(dir, entry.name);

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
            id: list

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
                // bgDark (~0.0175 luminance) sits below this pane's own
                // Theme.selection fill (~0.057), so hovering used to make
                // a row read as a hole punched in the pane rather than a
                // row lifted off it. raised is the smallest available step
                // above selection (~1.03:1) — enough to read as raised
                // instead of sunken without pushing the size/time columns'
                // Theme.muted text, already tight at 2.36:1 on the bare
                // pane, any further than the 2.28:1 it costs here.
                color: row.current ? Theme.accent : (rowArea.containsMouse ? Theme.raised : "transparent")

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 8
                    anchors.rightMargin: 8
                    spacing: 0

                    Text {
                        Layout.preferredWidth: Theme.filesIconColumn

                        text: Icons.glyphFor(row.modelData)
                        // icons.js hands back a Theme property NAME, and
                        // common/Tokens resolves it. Not `Theme[name]`: a
                        // dynamic key does not reliably register the binding
                        // dependency, so a wallpaper change would leave every
                        // icon on the old accent while the borders repainted.
                        color: row.current ? Theme.bg : Tokens.colourOf(Icons.colourFor(row.modelData))
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
