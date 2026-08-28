// The wallpaper picker, reached with SUPER+W.
//
// A thumbnail grid over Wallpapers/, wired straight to awww: picking a
// tile runs `awww img`, extracts the new accent from the same file with
// accent.js (plan 1a) over a Canvas, writes it to Theme.tintStatePath for
// tree.nix's FileView to pick up, and hands the accent to every tint
// target — Icons.qml, Borders.qml, Gtk.qml and Kvantum.qml — so one pick
// repaints the icon theme, the Hyprland borders, the GTK stylesheets and
// the Kvantum theme together. No home-manager switch sits between a click
// and the bar repainting — that FileView is the whole point.
//
// apply(path, output, mode) is also reachable over IPC (`qs ipc call
// wallpaper apply <path> <output> <mode>`) for an external caller — a
// keybind or a terminal. Rotation.qml lives inside this same process, so it
// holds a direct reference to this component instead of shelling out to its
// own IPC socket: one implementation, reached in-process by the timer and
// externally by IPC, rather than either re-deriving what the other does.
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

    // GridView has no "columns" property of its own; this is the same
    // divide-and-floor the delegate's own cell sizing implies, read back so
    // Up/Down can jump a whole row instead of the Left/Right single step.
    readonly property int gridColumns: Math.max(1, Math.floor(grid.width / grid.cellWidth))

    Icons {
        id: icons
    }

    Borders {
        id: borders
    }

    Gtk {
        id: gtk
    }

    Kvantum {
        id: kvantum
    }

    function open(): void {
        root.reload();
        root.selected = 0;
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

    // Clamped rather than wrapped: a flat list wrapping top-to-bottom reads
    // naturally (Launcher does exactly that), but a row-jump wrap in a 2D
    // grid can land the cursor in an arbitrary column, which reads as a bug
    // rather than a shortcut.
    function moveSelection(delta: int): void {
        const count = root.files.length;
        if (count === 0)
            return;

        const start = root.selected < 0 ? 0 : root.selected;
        root.selected = Math.min(count - 1, Math.max(0, start + delta));
    }

    // The keyboard half of what the grid's click handler already does; task
    // 2 is the one that changes what apply() itself is called with.
    function applySelected(): void {
        const path = root.files[root.selected];
        if (!path)
            return;

        root.apply(path, "*", "fill");
        root.close();
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
    //
    // "*" never reaches awww's argv: this awww build takes "every output" by
    // the ABSENCE of --outputs, not by a wildcard, and passing the literal
    // asterisk fails outright ("none of the requested outputs are valid") —
    // found by actually running the built command rather than trusting
    // awww.rs's own convention, which named "*" a level up, in random_wp.nix,
    // not in the CLI it shells out to.
    function apply(path, output, mode) {
        root.pendingPath = path;

        const targetOutput = output && output.length > 0 ? output : "*";
        const targetMode = awwwResizeMode(mode && mode.length > 0 ? mode : "fill");

        const args = ["awww", "img", path];
        if (targetOutput !== "*")
            args.push("--outputs", targetOutput);
        args.push("--resize", targetMode, "--fill-color", "d2a1a1", "--transition-type", "fade", "--transition-duration", "1", "--transition-fps", "60");

        awwwProc.command = args;
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

    // A second, permanently-visible layer-shell surface, 1x1 and background-
    // layer so nothing about it is ever seen — Canvas.onPaint only fires for
    // an item inside a window that is actually part of a live scene graph,
    // and the picker's own `window` below sits at visible: false until the
    // user opens it. Rotation.qml's hourly apply() has no reason to open
    // that window, so the extraction Canvas needs a window of its own that
    // is never toggled. Found by running apply() with the picker closed and
    // watching onPaint simply never fire — qmllint and qmltestrunner cannot
    // catch a missing scene graph, only a running compositor can.
    PanelWindow {
        id: accentSurface

        screen: root.focusedScreen
        color: "transparent"
        visible: true

        WlrLayershell.layer: WlrLayer.Background
        WlrLayershell.namespace: "dots-wallpaper-accent"
        exclusiveZone: 0

        implicitWidth: 1
        implicitHeight: 1

        // Sized to accent.rs's own thumbnail bounding box (fit within 64x64,
        // keep the aspect ratio) rather than a flat 64x64 stretch:
        // accentFrom only counts hue votes, so squashing every photo to
        // square would not change which hue wins, but this keeps the port
        // honest about what accent.rs's `thumbnail(64, 64)` actually does
        // before the bucket loop ever runs (see tst_accent.qml's 64x36
        // fixture for the same call).
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
                // The scene graph paints this on its own the moment the
                // surface above maps, before apply() has ever run and
                // sizer has a source — drawImage("") on that first pass
                // logs a type-mismatch warning and aborts the handler,
                // which this guard skips instead of provoking.
                if (sizer.status !== Image.Ready)
                    return;

                const ctx = getContext("2d");
                ctx.drawImage(sizer.source.toString(), 0, 0, width, height);
                root.applyAccent(Accent.accentFrom(ctx.getImageData(0, 0, width, height).data));
            }
        }
    }

    function applyAccent(triple) {
        // Every target below is independent of the others: each manages
        // its own destination (or, for borders, its own live IPC call) and
        // none reads tintStatePath, so all four run the moment an accent
        // exists rather than waiting on the state-file write below, and a
        // failure or skip in one (no Hyprland instance, a missing Kvantum
        // base, an unwritable GTK dir) never blocks the rest.
        icons.retint(triple.accent);
        borders.apply(triple.accent, triple.dark);
        gtk.write(triple.accent, triple.dark, triple.light);
        kvantum.retint(triple.accent, triple.dark, triple.light);

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
    // back through JsonAdapter's generic `.root`. Setting `path` loads
    // eagerly, so the very first ever pick logs one "file does not exist"
    // warning for a file this same call is about to create — the same
    // fresh-install warning tree.nix's own tintState reader already accepts,
    // not a sign either side is broken.
    FileView {
        id: stateWriter
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

        Chrome {
            id: panel

            anchors.centerIn: parent

            width: Math.round(parent.width * 0.8)
            height: Math.round(parent.height * 0.8)

            padding: 16

            focus: true

            title: "Wallpapers"
            hints: [
                {
                    key: "↑↓/jk",
                    label: "row"
                },
                {
                    key: "←→/hl",
                    label: "column"
                },
                {
                    key: "Enter",
                    label: "apply"
                },
                {
                    key: "Esc",
                    label: "close"
                }
            ]

            Keys.onEscapePressed: root.close()
            Keys.onUpPressed: root.moveSelection(-root.gridColumns)
            Keys.onDownPressed: root.moveSelection(root.gridColumns)
            Keys.onLeftPressed: root.moveSelection(-1)
            Keys.onRightPressed: root.moveSelection(1)
            Keys.onReturnPressed: root.applySelected()
            Keys.onEnterPressed: root.applySelected()

            // No focused text field on this surface to steal j/k/h/l as
            // literal characters, so they alias the arrows Vim-style — the
            // same reasoning Cheatsheet and Arrange apply, and Settings
            // does not.
            Keys.onPressed: event => {
                switch (event.key) {
                case Qt.Key_J:
                    root.moveSelection(root.gridColumns);
                    event.accepted = true;
                    break;
                case Qt.Key_K:
                    root.moveSelection(-root.gridColumns);
                    event.accepted = true;
                    break;
                case Qt.Key_H:
                    root.moveSelection(-1);
                    event.accepted = true;
                    break;
                case Qt.Key_L:
                    root.moveSelection(1);
                    event.accepted = true;
                    break;
                }
            }

            GridView {
                id: grid

                Layout.fillWidth: true
                Layout.fillHeight: true

                clip: true
                cellWidth: 200
                cellHeight: 130

                model: root.files
                currentIndex: root.selected
                highlightFollowsCurrentItem: true

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
