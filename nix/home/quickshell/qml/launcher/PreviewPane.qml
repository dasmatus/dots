// The launcher's preview column: what the highlighted file actually is.
//
// beamenu reserved a column and handed a resident `beamenu-canvas` child a
// description of the row, because reading and decoding on the launcher's own
// thread would have cost it the keyboard. None of that split is needed here.
// Image decodes off-thread on its own, and Process has never blocked, so the
// pane is a component in the same window as the list.
//
// One `sh` runs per selection rather than one per keystroke: the highlight
// moves a row at a time when held down, and stat'ing every row it passes
// through is work nobody sees. The path travels in argv — see preview.js.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "preview.js" as PreviewMath
import ".."

Item {
    id: root

    required property string path

    readonly property string kind: root.path === "" ? "" : PreviewMath.kindOf(root.path)

    property var meta: ({
            bytes: 0,
            modified: 0,
            entries: 0
        })
    property string body: ""

    onPathChanged: {
        // Cleared rather than left standing: showing the previous file's text
        // under the new file's name is worse than showing nothing at all.
        root.meta = {
            bytes: 0,
            modified: 0,
            entries: 0
        };
        root.body = "";
        reader.running = false;

        if (root.path === "") {
            debounce.stop();
            return;
        }

        debounce.restart();
    }

    Timer {
        id: debounce

        interval: 120

        onTriggered: {
            reader.command = PreviewMath.previewCommand(root.path, root.kind);
            reader.running = true;
        }
    }

    Process {
        id: reader

        stdout: StdioCollector {
            onStreamFinished: {
                const split = PreviewMath.splitOutput(this.text);
                root.meta = split.meta;
                root.body = split.body;
            }
        }
    }

    // Divider, not a filled panel. The list and the preview share one surface,
    // so the seam is a line rather than a second background painted over it.
    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom

        width: 1
        color: Theme.border
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: 14
        anchors.rightMargin: 8
        anchors.topMargin: 6
        anchors.bottomMargin: 6

        spacing: 2

        Text {
            Layout.fillWidth: true

            text: root.path === "" ? "" : PreviewMath.displayName(root.path)
            color: Theme.fg

            font.family: Theme.fontUi
            font.pointSize: 11
            font.bold: true

            elide: Text.ElideMiddle
            maximumLineCount: 1
        }

        Text {
            Layout.fillWidth: true

            text: root.path === "" ? "" : PreviewMath.displayParent(root.path, Quickshell.env("HOME"))
            color: Theme.muted

            font.family: Theme.fontUi
            font.pointSize: 9

            elide: Text.ElideMiddle
            maximumLineCount: 1
        }

        Text {
            Layout.fillWidth: true
            Layout.bottomMargin: 4

            text: {
                if (root.kind === "directory")
                    return `${root.meta.entries} ${root.meta.entries === 1 ? "item" : "items"}`;

                if (root.meta.modified === 0)
                    return PreviewMath.formatSize(root.meta.bytes);

                const when = Qt.formatDateTime(new Date(root.meta.modified * 1000), "dd.MM.yyyy");
                return `${PreviewMath.formatSize(root.meta.bytes)} · ${when}`;
            }
            color: Theme.dim
            visible: root.path !== ""

            font.family: Theme.fontMono
            font.pointSize: 9
        }

        // Images draw themselves; everything else is text in a scroller. Both
        // fill what is left of the column rather than sizing to content, so
        // the pane's width never depends on what happens to be highlighted.
        Image {
            Layout.fillWidth: true
            Layout.fillHeight: true

            visible: root.kind === "image"
            source: root.kind === "image" ? PreviewMath.fileUrl(root.path) : ""

            // Asynchronous and bounded: a 40 MB photo decodes on the loader
            // thread, and only ever down to the size the column can show.
            asynchronous: true
            fillMode: Image.PreserveAspectFit
            sourceSize.width: Math.round(root.width)
            sourceSize.height: Math.round(root.height)
        }

        Flickable {
            Layout.fillWidth: true
            Layout.fillHeight: true

            visible: root.kind !== "image" && root.path !== ""

            contentWidth: width
            contentHeight: bodyText.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Text {
                id: bodyText

                width: parent.width

                text: PreviewMath.isBinary(root.body) ? "Binary file" : root.body
                color: PreviewMath.isBinary(root.body) ? Theme.dim : Theme.fgDark

                font.family: Theme.fontMono
                font.pointSize: 9

                // Wrapped rather than clipped: at this width most of what gets
                // previewed is prose or config, and a cut-off sentence tells
                // you less than a wrapped one.
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
            }
        }
    }
}
