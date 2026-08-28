// The monitor arrange surface, reached with SUPER+M.
//
// Replaces `hyprmon override`, the crate's own interactive TUI for pinning a
// layout by hand: "an interactive editor for overrides.json ... Lists the
// connected monitors (left), shows an edit form for the selected one
// (right)". That one drew monitors as ASCII boxes in a terminal grid, nudged
// with arrow keys, with a seven-field form (name, description, resolution,
// position, scale, transform, vrr) beside it; this one is the shell's own
// surface, so the boxes are real rectangles, the nudging is a mouse drag,
// and the same seven fields sit beside the canvas rather than replacing it —
// Watcher.qml already owns everything downstream of overrides.json, so this
// component's entire job is still producing that one file.
//
// A drag or an edited field changes only what it names; the rest still
// comes from monitors.json's rules, matching what the crate's own override
// entries did (a partial override — see plan.js's applyOverrides, which
// merges each present field on top of the planned spec rather than
// replacing it, and arrange.js's own mergedOverrides, which does the same
// merge one step earlier, over whatever overrides.json already held).
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

    // The edit form column's width — named rather than read back off
    // formColumn.width, which would make Chrome's own width a binding loop
    // (Chrome's width feeding the RowLayout that determines formColumn's
    // width, which would be feeding back into Chrome's width).
    readonly property real formWidth: 220

    // The RowLayout's own spacing between the canvas and the form column —
    // named because Chrome's width formula below needs the exact same
    // number the RowLayout uses, not a copy that could quietly drift from
    // it.
    readonly property real formSpacing: 20

    // Canvas-pixel distance within which a dragged edge snaps to a
    // neighbour's edge. 14 is comfortably wider than a stray pixel of mouse
    // jitter but narrower than the gap between two monitors placed only
    // roughly close together, so it catches an intended edge-to-edge drag
    // without also catching a deliberate small gap.
    readonly property real snapThreshold: 14

    property var monitorsSnapshot: []
    property var transform: ({ originX: 0, originY: 0, scale: 1 })

    // The monitor both the canvas and the edit form agree is current: a
    // click sets it directly (selectMonitor()), Up/Down and j/k move it by
    // one position in monitorsSnapshot (moveSelection()) and then defer to
    // the same selectMonitor() — one property, moved by two inputs, rather
    // than a keyboard cursor and a click target that could each point
    // somewhere different. "" means nothing selected yet — only possible
    // before the first monitor loads. The five editable fields themselves
    // live only on their own Field instances (resolutionField.text and
    // friends, below) rather than mirrored into a property here: a Field
    // bound to an external property loses that binding the instant the
    // user types into it (TextInput's own typing is itself an imperative
    // write, which breaks a prior QML binding for good), so
    // selectMonitor()/loadFormFor() assign each Field's `text` directly
    // instead of relying on one to keep re-syncing the other.
    property string selectedName: ""

    readonly property var footerHints: [
        { key: "↑↓/jk", label: "Select" },
        { key: "Drag", label: "Reposition" },
        { key: "Enter", label: "Save" },
        { key: "Ctrl+R", label: "Reset" },
        { key: "Esc", label: "Cancel" }
    ]

    readonly property string selectedDescription: {
        const m = root.monitorsSnapshot.find(mon => mon.name === root.selectedName);
        return m ? m.description : "";
    }

    // $XDG_CONFIG_HOME, falling back to ~/.config — see Watcher.qml's own
    // property of the same name for why this isn't just "$HOME/.config".
    readonly property string configHome: {
        const xdg = Quickshell.env("XDG_CONFIG_HOME");
        return xdg && xdg.length > 0 ? xdg : Quickshell.env("HOME") + "/.config";
    }

    function open(): void {
        root.refreshSnapshot();
        root.selectedName = "";
        resolutionField.text = "";
        positionField.text = "";
        scaleField.text = "";
        transformField.text = "";
        vrrField.text = "";
        // Keyboard nav needs a starting point the same way a click already
        // has one. Goes through selectMonitor() rather than writing
        // selectedName directly, so the form comes up already showing the
        // first monitor's own override entry instead of sitting blank until
        // the first click or arrow press.
        if (root.monitorsSnapshot.length > 0)
            root.selectMonitor(root.monitorsSnapshot[0].name);
        window.visible = true;
    }

    // Wraps, matching Launcher's own move(): a flat list of monitors has no
    // 2D ambiguity the way a grid does, so there is no reason to stop at the
    // edge instead of coming back around. Goes through selectMonitor()
    // rather than writing selectedName directly, so a keyboard move flushes
    // the outgoing monitor's pending edits and loads the incoming one's
    // form exactly the way a canvas click already does.
    function moveSelection(delta: int): void {
        const count = root.monitorsSnapshot.length;
        if (count === 0)
            return;

        const current = root.monitorsSnapshot.findIndex(m => m.name === root.selectedName);
        const base = current === -1 ? 0 : current;
        const next = (base + delta % count + count) % count;
        root.selectMonitor(root.monitorsSnapshot[next].name);
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
            description: m.description || "",
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
    // Selecting a rectangle loads the form from whatever overrides.json
    // already holds for that monitor, never from Hyprland's live-reported
    // state: pre-filling a rule-derived default would mean an untouched
    // Save silently promoting that rule's value into a standing override,
    // which the surface's own job description forbids (overrides stay a
    // separate document from the Nix-managed rules). Every field but
    // position reads back as "" when the monitor has no override yet;
    // position always has a real value, because a monitor always sits
    // somewhere — it comes from the rectangle's own dragged position, not
    // the override entry, so it stays in step with the canvas.
    function selectMonitor(name: string): void {
        root.selectedName = name;
        root.loadFormFor(name);
    }

    function loadFormFor(name: string): void {
        const entries = (overridesFile.adapter.root && overridesFile.adapter.root.entries) || [];
        const entry = entries.find(e => e.name === name) || {};
        const rect = root.rectItems().find(item => item.monitorName === name);
        resolutionField.text = entry.resolution != null ? String(entry.resolution) : "";
        positionField.text = rect ? ArrangeLogic.toWorldPosition(rect.x, rect.y, root.transform) : (entry.position != null ? String(entry.position) : "");
        scaleField.text = entry.scale != null ? String(entry.scale) : "";
        transformField.text = entry.transform != null ? String(entry.transform) : "";
        vrrField.text = entry.vrr != null ? String(entry.vrr) : "";
    }
    // qmllint enable unresolved-type

    // The position field is the one editable field with no "unset" state —
    // so typing a new value here moves the dragged rectangle itself rather
    // than sitting alongside it as a second, possibly-disagreeing source of
    // truth. An unparseable value is ignored, same as a drag that never
    // happened.
    function applyPositionField(text: string): void {
        const world = ArrangeLogic.parseWorldPosition(text);
        if (!world)
            return;
        const target = root.rectItems().find(item => item.monitorName === root.selectedName);
        if (!target)
            return;
        const screen = ArrangeLogic.toScreen(world, root.transform);
        target.x = Math.max(0, Math.min(canvas.width - target.width, screen.x));
        target.y = Math.max(0, Math.min(canvas.height - target.height, screen.y));
        positionField.text = ArrangeLogic.toWorldPosition(target.x, target.y, root.transform);
    }

    // qmllint disable unresolved-type
    // Every rectangle's dragged position saves, unconditionally — the drag
    // canvas stays live for every monitor whether or not it is the selected
    // one. Only the selected monitor's item also carries the other four form
    // fields, which is what "alongside the dragged position" (not instead of
    // it) means for confirm().
    function confirm(): void {
        root.applyPositionField(positionField.text);
        const items = root.rectItems().map(item => {
            const entry = {
                name: item.monitorName,
                position: ArrangeLogic.toWorldPosition(item.x, item.y, root.transform)
            };
            if (item.monitorName === root.selectedName) {
                entry.resolution = resolutionField.text;
                entry.scale = ArrangeLogic.numberField(scaleField.text);
                entry.transform = ArrangeLogic.integerField(transformField.text);
                entry.vrr = vrrField.text;
            }
            return entry;
        });
        const merged = ArrangeLogic.mergedOverrides(overridesFile.adapter.root, items);
        overridesFile.setText(JSON.stringify(merged));
        root.close();
    }

    // The TUI's Ctrl+R: drops the selected monitor's entry from
    // overrides.json outright, rather than only clearing the form the way
    // the crate's own Ctrl+R did — this surface has no separate Ctrl+S, so
    // an immediate, self-contained un-override is the equivalent that does
    // not need a second keystroke to actually take effect. The window stays
    // open and the form reloads to reflect the now-absent entry, matching
    // Enter and Esc's own "the window makes the change, you decide when to
    // leave" pattern.
    function reset(): void {
        if (!root.selectedName)
            return;
        const existing = overridesFile.adapter.root;
        const entries = ((existing && existing.entries) || []).filter(e => e.name !== root.selectedName);
        overridesFile.setText(JSON.stringify({ entries: entries }));
        root.loadFormFor(root.selectedName);
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

            // Exact, not a guess: the RowLayout below resolves to
            // canvasWidth + formSpacing + formWidth wide, and Panel's own
            // padding widens that by the same amount on both the left and
            // right edge.
            width: root.canvasWidth + root.formSpacing + root.formWidth + 2 * padding
            // Chrome's own implicitHeight already accounts for the header,
            // the hint footer and this content's natural height (canvas
            // and form column, side by side) — no more guessing at what
            // the chrome costs.
            height: panel.implicitHeight

            padding: 24
            title: "Arrange Monitors"
            hints: root.footerHints

            focus: true

            Keys.onEscapePressed: root.close()
            Keys.onReturnPressed: root.confirm()
            Keys.onEnterPressed: root.confirm()
            Keys.onUpPressed: root.moveSelection(-1)
            Keys.onDownPressed: root.moveSelection(1)

            // A focused Field consumes j/k as literal characters before
            // this ever sees them (TextInput's own native handling), so
            // the alias only fires when the canvas/panel itself holds
            // focus — the same Vim-style aliasing Launcher's own grammar
            // uses elsewhere. Ctrl+R shares this handler rather than a
            // second Keys.onPressed, which QML does not allow twice on the
            // same Item.
            Keys.onPressed: event => {
                if (event.key === Qt.Key_J) {
                    root.moveSelection(1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_K) {
                    root.moveSelection(-1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_R && (event.modifiers & Qt.ControlModifier)) {
                    root.reset();
                    event.accepted = true;
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true

                spacing: root.formSpacing

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

                            // The dragged screen-space position, read back by
                            // confirm() through rectRepeater.itemAt(i) — kept
                            // as its own property (rather than reusing x/y
                            // directly) only so mergedOverrides' `.x`/`.y`/
                            // `.monitorName` reads look the same whether the
                            // item came from a live drag or was never
                            // touched.
                            readonly property string monitorName: rect.modelData.name
                            readonly property bool selected: rect.monitorName === root.selectedName

                            x: root.screenX(rect.modelData)
                            y: root.screenY(rect.modelData)
                            width: Math.max(24, rect.modelData.width * root.transform.scale)
                            height: Math.max(24, rect.modelData.height * root.transform.scale)

                            radius: 6
                            color: Theme.bgDark
                            border.width: rect.selected ? 3 : 2
                            border.color: Theme.accent

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

                                // Selecting happens on press rather than on
                                // click: a drag starts with the same press,
                                // and the form should already be showing the
                                // dragged monitor's fields by the time the
                                // drag itself is under way, not only once
                                // the mouse comes back up.
                                onPressed: root.selectMonitor(rect.monitorName)

                                onReleased: {
                                    const snapped = ArrangeLogic.snappedPosition(rect, root.rectItems(), root.snapThreshold);
                                    rect.x = snapped.x;
                                    rect.y = snapped.y;
                                    if (rect.selected)
                                        positionField.text = ArrangeLogic.toWorldPosition(rect.x, rect.y, root.transform);
                                }
                            }
                        }
                    }
                }

                ColumnLayout {
                    id: formColumn

                    Layout.preferredWidth: root.formWidth
                    Layout.fillHeight: true

                    spacing: 6

                    Text {
                        text: "Name"
                        color: Theme.muted

                        font.family: Theme.fontUi
                        font.pointSize: 9
                    }

                    Text {
                        Layout.fillWidth: true

                        text: root.selectedName.length > 0 ? root.selectedName : "—"
                        color: Theme.fg
                        elide: Text.ElideRight

                        font.family: Theme.fontUi
                        font.pointSize: 10
                    }

                    Text {
                        text: "Description"
                        color: Theme.muted

                        font.family: Theme.fontUi
                        font.pointSize: 9
                    }

                    Text {
                        Layout.fillWidth: true

                        text: root.selectedDescription.length > 0 ? root.selectedDescription : "—"
                        color: Theme.fg
                        elide: Text.ElideRight

                        font.family: Theme.fontUi
                        font.pointSize: 10
                    }

                    Text {
                        text: "Resolution"
                        color: Theme.muted

                        font.family: Theme.fontUi
                        font.pointSize: 9
                    }

                    Field {
                        id: resolutionField

                        Layout.fillWidth: true

                        onAccepted: root.confirm()
                        onEscaped: root.close()
                    }

                    Text {
                        text: "Position"
                        color: Theme.muted

                        font.family: Theme.fontUi
                        font.pointSize: 9
                    }

                    Field {
                        id: positionField

                        Layout.fillWidth: true

                        onAccepted: {
                            root.applyPositionField(text);
                            root.confirm();
                        }
                        onEscaped: root.close()
                    }

                    Text {
                        text: "Scale"
                        color: Theme.muted

                        font.family: Theme.fontUi
                        font.pointSize: 9
                    }

                    Field {
                        id: scaleField

                        Layout.fillWidth: true

                        onAccepted: root.confirm()
                        onEscaped: root.close()
                    }

                    Text {
                        text: "Transform"
                        color: Theme.muted

                        font.family: Theme.fontUi
                        font.pointSize: 9
                    }

                    Field {
                        id: transformField

                        Layout.fillWidth: true

                        onAccepted: root.confirm()
                        onEscaped: root.close()
                    }

                    Text {
                        text: "VRR"
                        color: Theme.muted

                        font.family: Theme.fontUi
                        font.pointSize: 9
                    }

                    Field {
                        id: vrrField

                        Layout.fillWidth: true

                        onAccepted: root.confirm()
                        onEscaped: root.close()
                    }

                    Item {
                        Layout.fillHeight: true
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
