// The monitor arrange surface, reached with SUPER+M.
//
// Replaces `hyprmon override`, the crate's own interactive TUI for pinning a
// layout by hand. That one drew monitors as ASCII boxes in a terminal grid,
// nudged with arrow keys; this one is the shell's own surface, so the boxes
// are real rectangles and the nudging is a mouse drag — Watcher.qml already
// owns everything downstream of overrides.json, so this component's entire
// job is producing that one file.
//
// Positions only. A drag changes where a monitor sits, never its resolution,
// scale or VRR — those still come from monitors.json's rules, matching what
// the crate's own override entries did (a partial override; see plan.js's
// applyOverrides, which merges this file's `position` on top of the planned
// spec rather than replacing it).
//
// Takes a snapshot of Quickshell.Hyprland's live monitor list on open()
// rather than binding to it directly: the canvas has to stay still while a
// drag is in progress, and Hyprland's own model updating mid-drag (a
// coincidental hotplug, or Watcher.qml's own apply() moving something) would
// otherwise fight the pointer.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import "arrange.js" as ArrangeLogic
import ".."
import "../common"

Scope {
    id: root

    readonly property var focusedScreen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? null

    readonly property real canvasWidth: 720
    readonly property real canvasHeight: 420

    // Canvas-pixel distance within which a dragged edge snaps to a
    // neighbour's edge. 14 is comfortably wider than a stray pixel of mouse
    // jitter but narrower than the gap between two monitors placed only
    // roughly close together, so it catches an intended edge-to-edge drag
    // without also catching a deliberate small gap.
    readonly property real snapThreshold: 14

    property var monitorsSnapshot: []
    property var transform: ({ originX: 0, originY: 0, scale: 1 })

    // Which rectangle Up/Down moves between. Drag still owns position; this
    // is only a keyboard cursor over the same list, ready for a future
    // screen to act on "the selected monitor" without repeating the lookup.
    property int selected: 0

    // $XDG_CONFIG_HOME, falling back to ~/.config — see Watcher.qml's own
    // property of the same name for why this isn't just "$HOME/.config".
    readonly property string configHome: {
        const xdg = Quickshell.env("XDG_CONFIG_HOME");
        return xdg && xdg.length > 0 ? xdg : Quickshell.env("HOME") + "/.config";
    }

    function open(): void {
        root.refreshSnapshot();
        root.selected = 0;
        window.visible = true;
    }

    // Wraps, matching Launcher's own move(): a flat list of monitors has no
    // 2D ambiguity the way a grid does, so there is no reason to stop at the
    // edge instead of coming back around.
    function moveSelection(delta: int): void {
        const count = root.monitorsSnapshot.length;
        if (count === 0)
            return;

        root.selected = (root.selected + delta % count + count) % count;
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

    function refreshSnapshot(): void {
        const list = Hyprland.monitors.values.map(m => ({
            name: m.name,
            x: m.x,
            y: m.y,
            width: m.width,
            height: m.height
        }));

        root.transform = ArrangeLogic.fitTransform(list, root.canvasWidth, root.canvasHeight);
        root.monitorsSnapshot = list;
    }

    function screenX(monitor): real {
        return ArrangeLogic.toScreen(monitor, root.transform).x;
    }

    function screenY(monitor): real {
        return ArrangeLogic.toScreen(monitor, root.transform).y;
    }

    // qmllint disable unresolved-type
    function confirm(): void {
        const items = root.rectItems().map(item => ({
            name: item.monitorName,
            position: ArrangeLogic.toWorldPosition(item.x, item.y, root.transform)
        }));
        const merged = ArrangeLogic.mergedOverrides(overridesFile.adapter.root, items);
        overridesFile.setText(JSON.stringify(merged));
        root.close();
    }
    // qmllint enable unresolved-type

    IpcHandler {
        target: "arrange"

        function open(): void {
            root.open();
        }

        function close(): void {
            root.close();
        }

        function toggle(): void {
            root.toggle();
        }
    }

    // qmllint disable unresolved-type
    FileView {
        id: overridesFile

        path: root.configHome + "/dots-shell/overrides.json"
        adapter: JsonAdapter {}
    }
    // qmllint enable unresolved-type

    PanelWindow {
        id: window

        screen: root.focusedScreen
        color: "transparent"
        visible: false

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        WlrLayershell.namespace: "dots-arrange"

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

        // Clicking the backdrop cancels, the same as Escape — a click
        // outside the canvas is not a confirmation, and overrides.json
        // stays whatever it already was.
        MouseArea {
            anchors.fill: parent

            onClicked: root.close()
        }

        Chrome {
            id: panel

            anchors.centerIn: parent

            width: root.canvasWidth + 2 * padding
            height: root.canvasHeight + 96

            padding: 24

            focus: true

            title: "Arrange Monitors"
            hints: [
                {
                    key: "↑↓/jk",
                    label: "select"
                },
                {
                    key: "drag",
                    label: "reposition"
                },
                {
                    key: "Enter",
                    label: "save"
                },
                {
                    key: "Esc",
                    label: "cancel"
                }
            ]

            Keys.onEscapePressed: root.close()
            Keys.onReturnPressed: root.confirm()
            Keys.onEnterPressed: root.confirm()
            Keys.onUpPressed: root.moveSelection(-1)
            Keys.onDownPressed: root.moveSelection(1)

            // No focused text field on this surface to steal j/k as literal
            // characters, so they alias the arrows Vim-style.
            Keys.onPressed: event => {
                if (event.key === Qt.Key_J) {
                    root.moveSelection(1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_K) {
                    root.moveSelection(-1);
                    event.accepted = true;
                }
            }

            ColumnLayout {
                anchors.fill: parent

                spacing: 12

                Item {
                    id: canvas

                    Layout.preferredWidth: root.canvasWidth
                    Layout.preferredHeight: root.canvasHeight

                    Repeater {
                        id: rectRepeater

                        model: root.monitorsSnapshot

                        delegate: Rectangle {
                            id: rect

                            required property var modelData
                            required property int index

                            // The dragged screen-space position, read back by
                            // confirm() through rectRepeater.itemAt(i) — kept
                            // as its own property (rather than reusing x/y
                            // directly) only so mergedOverrides' `.x`/`.y`/
                            // `.monitorName` reads look the same whether the
                            // item came from a live drag or was never
                            // touched.
                            readonly property string monitorName: rect.modelData.name

                            x: root.screenX(rect.modelData)
                            y: root.screenY(rect.modelData)
                            width: Math.max(24, rect.modelData.width * root.transform.scale)
                            height: Math.max(24, rect.modelData.height * root.transform.scale)

                            radius: 6
                            color: Theme.bgDark
                            border.width: rect.index === root.selected ? 3 : 2
                            border.color: rect.index === root.selected ? Theme.cyan : Theme.accent

                            Column {
                                anchors.centerIn: parent

                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter

                                    text: rect.modelData.name
                                    color: Theme.fg

                                    font.family: Theme.fontUi
                                    font.pointSize: 10
                                    font.bold: true
                                }

                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter

                                    text: `${rect.modelData.width}x${rect.modelData.height}`
                                    color: Theme.muted

                                    font.family: Theme.fontUi
                                    font.pointSize: 9
                                }
                            }

                            MouseArea {
                                anchors.fill: parent

                                cursorShape: Qt.SizeAllCursor

                                drag.target: rect
                                drag.axis: Drag.XAndYAxis
                                drag.minimumX: 0
                                drag.minimumY: 0
                                drag.maximumX: canvas.width - rect.width
                                drag.maximumY: canvas.height - rect.height

                                onReleased: {
                                    const snapped = ArrangeLogic.snappedPosition(rect, root.rectItems(), root.snapThreshold);
                                    rect.x = snapped.x;
                                    rect.y = snapped.y;
                                }
                            }
                        }
                    }
                }

                RowLayout {
                    Layout.fillWidth: true

                    spacing: 12

                    // Pushes the Save button to the trailing edge now that
                    // the hint text it used to sit beside lives in Chrome's
                    // own footer instead.
                    Item {
                        Layout.fillWidth: true
                    }

                    Rectangle {
                        Layout.preferredWidth: 90
                        Layout.preferredHeight: 32

                        radius: 8
                        color: Theme.accent

                        Text {
                            anchors.centerIn: parent

                            text: "Save"
                            color: Theme.bg

                            font.family: Theme.fontUi
                            font.pointSize: 10
                            font.bold: true
                        }

                        MouseArea {
                            anchors.fill: parent

                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.confirm()
                        }
                    }
                }
            }
        }
    }

    // Every currently-placed rectangle, for snap() to measure the dragged
    // one against. Read through the Repeater rather than kept as a parallel
    // array: the delegates are the only place a mid-drag x/y actually lives.
    function rectItems() {
        const items = [];
        for (let i = 0; i < rectRepeater.count; i++)
            items.push(rectRepeater.itemAt(i));
        return items;
    }
}
