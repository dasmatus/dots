// The wallpaper picker, reached with SUPER+W.
//
// A thumbnail grid over Wallpapers/, wired straight to awww: picking a
// tile runs `awww img`, extracts the new accent from the same file with
// accent.js (plan 1a) over a Canvas, writes it to Theme.tintStatePath for
// tree.nix's FileView to pick up, and hands the accent to Icons.qml's
// retint(). No home-manager switch sits between a click and the bar
// repainting — that FileView is the whole point.
//
// apply(path, output, mode) is also reachable over IPC (`qs ipc call
// wallpaper apply <path> <output> <mode>`), which is how Rotation.qml
// drives it: two callers, one implementation, rather than the hourly timer
// re-deriving what a click already does.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import "../launcher/preview.js" as PreviewMath
import "accent.js" as Accent
import ".."
import "../common"

Scope {
    id: root

    readonly property var focusedScreen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? null

    // Hardcoded the same way wallpaper-tui.nix's own default wallpaperFolder
    // and dots-repo.nix's clone destination are: the repo only ever lives at
    // one place relative to $HOME on this machine, and there is no home-
    // manager option that hands a plain QML tree that path today.
    readonly property string wallpapersDir: Quickshell.env("HOME") + "/Dokumente/codeberg/personal/dots/Wallpapers"

    property var files: []
    property int selected: -1

    Icons {
        id: icons
    }

    function open(): void {
        root.reload();
        window.visible = true;
    }

    function close(): void {
        window.visible = false;
    }

    function toggle(): void {
        if (window.visible)
            root.close();
        else
            root.open();
    }

    function reload(): void {
        lister.running = false;
        lister.running = true;
    }

    // -e is case-insensitive in fd, so a stray .JPG is still found. "." is
    // the required PATTERN argument when every file under PATH is wanted,
    // not a path itself — fd's own idiom for "no filter but the extensions".
    Process {
        id: lister

        command: ["fd", "--type", "f", "-e", "jpg", "-e", "jpeg", "-e", "png", "-e", "webp", "-e", "gif", ".", root.wallpapersDir]

        stdout: StdioCollector {
            onStreamFinished: {
                root.files = this.text.split("\n").filter(p => p.length > 0).sort();
            }
        }
    }

    IpcHandler {
        target: "wallpaper"

        function open(): void {
            root.open();
        }

        function close(): void {
            root.close();
        }

        function toggle(): void {
            root.toggle();
        }

        function apply(path: string, output: string, mode: string): void {
            root.apply(path, output, mode);
        }
    }

    // awww has no "tile"; hyprtile-wallpaperd's backend degraded it to crop
    // and awww.rs's map_mode kept that choice, so this does too. Unknown
    // modes fall to the same crop default for the same reason: a bad mode
    // string should still hang a wallpaper, not refuse one.
    function awwwResizeMode(mode) {
        if (mode === "fit")
            return "fit";
        if (mode === "stretch")
            return "stretch";
        if (mode === "center")
            return "no";
        return "crop";
    }

    property string pendingPath: ""
    property var pendingTriple: null

    // output/mode default to "*"/"fill" (every output, cropped to fill) —
    // wallpaper-tui.nix's own defaults — so a caller that only has a path,
    // like a grid click or Rotation's random pick, does not have to name them.
    function apply(path, output, mode) {
        root.pendingPath = path;

        const targetOutput = output && output.length > 0 ? output : "*";
        const targetMode = awwwResizeMode(mode && mode.length > 0 ? mode : "fill");

        awwwProc.command = ["awww", "img", path, "--outputs", targetOutput, "--resize", targetMode, "--fill-color", "d2a1a1", "--transition-type", "fade", "--transition-duration", "1", "--transition-fps", "60"];
        awwwProc.running = true;
    }

    Process {
        id: awwwProc

        // qmllint disable signal-handler-parameters
        onExited: (exitCode, exitStatus) => {
            // A failed apply leaves the old wallpaper on screen; re-tinting
            // for an image that never actually got applied would just make
            // the bar lie about what is behind it.
            if (exitCode !== 0)
                return;

            sizer.source = PreviewMath.fileUrl(root.pendingPath);
        }
        // qmllint enable signal-handler-parameters
    }

    // Sized to accent.rs's own thumbnail bounding box (fit within 64x64,
    // keep the aspect ratio) rather than a flat 64x64 stretch: accentFrom
    // only counts hue votes, so squashing every photo to square would not
    // change which hue wins, but this keeps the port honest about what
    // accent.rs's `thumbnail(64, 64)` actually does before the bucket loop
    // ever runs (see tst_accent.qml's 64x36 fixture for the same call).
    Image {
        id: sizer

        visible: false
        asynchronous: true
        cache: false

        onStatusChanged: {
            if (status !== Image.Ready)
                return;

            const iw = Math.max(1, sizer.implicitWidth);
            const ih = Math.max(1, sizer.implicitHeight);
            const scale = Math.min(64 / iw, 64 / ih, 1);

            accentCanvas.width = Math.max(1, Math.round(iw * scale));
            accentCanvas.height = Math.max(1, Math.round(ih * scale));
            accentCanvas.loadImage(sizer.source.toString());
        }
    }

    Canvas {
        id: accentCanvas

        visible: false
        renderTarget: Canvas.Image
        width: 1
        height: 1

        onImageLoaded: requestPaint()
        onPaint: {
            const ctx = getContext("2d");
            ctx.drawImage(sizer.source.toString(), 0, 0, width, height);
            root.applyAccent(Accent.accentFrom(ctx.getImageData(0, 0, width, height).data));
        }
    }

    function applyAccent(triple) {
        // Independent of each other: retint() manages its own destination
        // tree and never reads tintStatePath, so it runs the moment an
        // accent exists rather than waiting on the state-file write below.
        icons.retint(triple.accent);

        root.pendingTriple = triple;
        stateDir.command = ["mkdir", "-p", Theme.tintStateDir];
        stateDir.running = true;
    }

    Process {
        id: stateDir

        // qmllint disable signal-handler-parameters
        onExited: (exitCode, exitStatus) => {
            stateWriter.path = Theme.tintStatePath;
            stateWriter.setText(JSON.stringify(root.pendingTriple));
        }
        // qmllint enable signal-handler-parameters
    }

    // No adapter: this side only ever writes, and a plain string is one
    // fewer schema to keep in sync with what tree.nix's tintState reads
    // back through JsonAdapter's generic `.root`.
    FileView {
        id: stateWriter

        printErrors: true
    }

    PanelWindow {
        id: window

        screen: root.focusedScreen
        color: "transparent"
        visible: false

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        WlrLayershell.namespace: "dots-wallpaper"

        anchors {
            top: true
            left: true
            right: true
            bottom: true
        }

        exclusiveZone: 0

        onVisibleChanged: {
            if (window.visible)
                panel.forceActiveFocus();
        }

        MouseArea {
            anchors.fill: parent

            onClicked: root.close()
        }

        Panel {
            id: panel

            anchors.centerIn: parent

            width: Math.round(parent.width * 0.8)
            height: Math.round(parent.height * 0.8)

            padding: 16

            focus: true

            Keys.onEscapePressed: root.close()

            ColumnLayout {
                anchors.fill: parent

                spacing: 10

                Text {
                    text: "Wallpapers"
                    color: Theme.accent

                    font.family: Theme.fontUi
                    font.pointSize: 14
                    font.bold: true
                }

                GridView {
                    id: grid

                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    clip: true
                    cellWidth: 200
                    cellHeight: 130

                    model: root.files

                    delegate: Rectangle {
                        id: cell

                        required property string modelData
                        required property int index

                        width: grid.cellWidth - 8
                        height: grid.cellHeight - 8

                        radius: 6
                        color: Theme.bgDark
                        border.width: cell.index === root.selected ? 2 : 0
                        border.color: Theme.accent

                        // Capped at 320x200 (sourceSize, not the cell's own
                        // display size): the old preview cache's own bound,
                        // kept so a directory of a few hundred photos never
                        // decodes at full resolution just to show a tile.
                        Image {
                            anchors.fill: parent
                            anchors.margins: 2

                            source: PreviewMath.fileUrl(cell.modelData)
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            sourceSize.width: 320
                            sourceSize.height: 200
                        }

                        MouseArea {
                            anchors.fill: parent

                            onClicked: {
                                root.selected = cell.index;
                                root.apply(cell.modelData, "*", "fill");
                                root.close();
                            }
                        }
                    }
                }
            }
        }
    }
}
