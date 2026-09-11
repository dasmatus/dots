// The dropdown a crumb click opens: PathBar.qml's crumbs used to navigate on a
// single click, and now open this instead, so its first row does what that
// click used to. See crumbmenu.js's openRow() for that row, before the rest of
// the crumb's directory follows beneath it, directories first.
//
// The popup mechanics come from PopupShell, extended here the way
// files/Menu.qml extends it rather than wrapping it. Mounted on the window
// rather than inside PathBar for the same reason Menu.qml is mounted there:
// a crumb near either edge would otherwise be unable to open a popup wider
// than the space left beside it.
//
// This needs its own Process, the same shape Pane.qml's is. A crumb other
// than the last one is never the pane's own directory, so `pane.entries`
// cannot be reused here.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "files.js" as FilesMath
import "crumbmenu.js" as CrumbMenu
import "operations.js" as Operations
import "../common"
import ".."

PopupShell {
    id: root

    required property bool showHidden

    property string crumbPath: ""
    property var allEntries: []

    readonly property var entries: FilesMath.visibleEntries(root.allEntries, root.showHidden)
    readonly property var rows: CrumbMenu.crumbMenuRows(root.crumbPath, root.entries, Theme.filesCrumbMenuCap)

    signal navigate(string path)

    panelHeight: column.implicitHeight + Theme.filesPadding

    // Starts the listing and opens the popup in the same call, so a second
    // crumb clicked while this one is still open replaces the anchor and
    // the rows together rather than showing the previous directory's
    // contents at the new point for one frame.
    function openFor(path: string, x: real, y: real): void {
        root.crumbPath = path;
        root.allEntries = [];
        lsProc.command = FilesMath.listingArgv(path);
        lsProc.running = true;
        root.openAt(x, y);
    }

    Process {
        id: lsProc

        stdout: StdioCollector {
            onStreamFinished: {
                root.allEntries = FilesMath.parseListing(this.text);
            }
        }
    }

    ColumnLayout {
        id: column

        anchors.fill: parent
        anchors.margins: Theme.filesPadding / 2
        spacing: 0

        Repeater {
            model: root.rows

            delegate: Rectangle {
                id: item

                required property var modelData

                // The trailer row reports a count; it names nothing to open
                // and takes no click.
                readonly property bool interactive: item.modelData.kind !== "more"

                Layout.fillWidth: true
                implicitHeight: Theme.filesRowHeight

                radius: Theme.filesRadius / 2
                color: item.interactive && itemArea.containsMouse ? Theme.accent : "transparent"

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.filesRowInset
                    anchors.rightMargin: Theme.filesRowInset
                    spacing: 0

                    Text {
                        Layout.preferredWidth: Theme.filesIconColumn

                        text: item.modelData.glyph
                        color: item.interactive && itemArea.containsMouse ? Theme.bg : Tokens.colourOf(item.modelData.colour)
                        font.family: Theme.fontUi
                        font.pixelSize: Theme.filesIconSize
                    }

                    Text {
                        Layout.fillWidth: true

                        text: item.modelData.title
                        color: {
                            if (item.interactive && itemArea.containsMouse)
                                return Theme.bg;

                            return item.interactive ? Theme.fg : Theme.dim;
                        }
                        font.family: Theme.fontUi
                        font.pixelSize: Theme.fontSize
                        elide: Text.ElideMiddle
                    }
                }

                MouseArea {
                    id: itemArea

                    anchors.fill: parent
                    enabled: item.interactive
                    hoverEnabled: item.interactive
                    cursorShape: Qt.PointingHandCursor

                    onClicked: {
                        root.close();

                        if (item.modelData.kind === "open") {
                            root.navigate(root.crumbPath);
                            return;
                        }

                        // "entry": modelData.index already lands on the
                        // right element of root.entries: crumbmenu.js
                        // slices from the front, so a shown row keeps the
                        // index it had before the cap.
                        const entry = root.entries[item.modelData.index];
                        const child = FilesMath.join(root.crumbPath, entry.name);

                        if (entry.isDir)
                            root.navigate(child);
                        else
                            Quickshell.execDetached(Operations.openArgv(child));
                    }
                }
            }
        }
    }
}
