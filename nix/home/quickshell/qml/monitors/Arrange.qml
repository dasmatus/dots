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

    // The edit form column's width — named rather than read back off the
    // ColumnLayout's own resolved width, which would make Chrome's own
    // width a binding loop (Chrome's width feeding the RowLayout that
    // determines the form column's width, which would be feeding back into
    // Chrome's width).
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

    // Keyed by monitor name: whatever the four optional fields held the
    // last time this session moved away from that monitor. Without this, a
    // click on a second rectangle silently discards whatever the first
    // monitor's fields held — confirm() only ever read the currently
    // selected monitor's Fields, and loadFormFor() overwrites them on every
    // selection change, so an edit made and then abandoned by a click
    // elsewhere was gone before Enter ever ran. flushSelectedIntoPending()
    // is what populates this; confirm() reads it for every monitor, not
    // only the one currently selected.
    property var pendingEdits: ({})

    // The value Hyprland is reporting right now for the selected monitor's
    // resolution/scale/transform — shown as PLACEHOLDER text on an empty
    // field (see loadFormFor()), never written into the field's real text,
    // so a blind Enter can never promote it into a standing override. Read
    // live rather than from monitorsSnapshot on purpose: unlike the
    // snapshot (frozen so the canvas doesn't fight a drag), these three
    // don't drive canvas geometry, so there's nothing for a live read to
    // fight. vrr has no equivalent: Hyprland's own monitor JSON reports vrr
    // as a plain on/off boolean, which cannot be mapped back to this
    // schema's off/left/right/auto without guessing which "on" submode is
    // active, so its placeholder stays the legal-values hint on the label
    // instead (see the VRR Text below).
    property string effectiveResolution: ""
    property string effectiveScale: ""
    property string effectiveTransform: ""

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

    // FileView.adapter's declared type is FileViewAdapter, and neither it
    // nor JsonAdapter (its own subtype) has a `root` property in this
    // Quickshell version — confirmed against the shipped
    // quickshell-io.qmltypes, which declares qs::io::JsonAdapter with zero
    // Property entries. Reading `root` off it was always undefined, so every
    // read through it silently fell through to an empty base and every
    // save from this surface discarded whatever overrides.json already
    // held instead of merging onto it. The working idiom is declaring the
    // shape directly on the JsonAdapter instance (the `entries` property
    // below, on `overridesFile`) and reading that declared property
    // instead — its own QML default ([]) is what a missing file falls
    // back to, since there is nothing on disk yet to overwrite it with;
    // Array.isArray guards against anything else unexpected reaching here
    // without throwing.
    readonly property var overridesRoot: {
        const raw = overridesFile.adapter.entries;
        return { entries: Array.isArray(raw) ? raw : [] };
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
        root.pendingEdits = {};
        root.effectiveResolution = "";
        root.effectiveScale = "";
        root.effectiveTransform = "";
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
    // Selecting a rectangle first banks the outgoing monitor's typed
    // fields into pendingEdits (see that property's own comment), then
    // loads the form for the newly selected one. The order matters: the
    // Fields still hold the OUTGOING monitor's text at the moment this
    // runs, so flushing has to happen before selectedName changes.
    function selectMonitor(name: string): void {
        root.flushSelectedIntoPending();
        root.selectedName = name;
        root.loadFormFor(name);
    }

    function flushSelectedIntoPending(): void {
        if (!root.selectedName)
            return;
        root.pendingEdits[root.selectedName] = {
            resolution: resolutionField.text,
            scale: scaleField.text,
            transform: transformField.text,
            vrr: vrrField.text
        };
    }

    // Priority per field: a pending edit from earlier this session (the
    // most recent thing the user actually did) beats the override entry
    // (an earlier save's chosen value) beats blank. Pre-filling from
    // Hyprland's live-reported state was deliberately left out of both —
    // that would mean an untouched Save silently promoting a rule-derived
    // value into a standing override, which the surface's own job
    // description forbids (overrides stay a separate document from the
    // Nix-managed rules). The live value is still shown, just as
    // refreshEffectiveValues()'s placeholder text rather than as the
    // field's real text, so a blind Enter can never pick it up. Position
    // reads neither map: it always comes from the rectangle's own dragged
    // position, so it stays in step with the canvas regardless of either.
    function loadFormFor(name: string): void {
        const pending = root.pendingEdits[name];
        const entries = root.overridesRoot.entries;
        const entry = entries.find(e => e.name === name) || {};
        const rect = root.rectItems().find(item => item.monitorName === name);
        resolutionField.text = pending ? pending.resolution : (entry.resolution != null ? String(entry.resolution) : "");
        scaleField.text = pending ? pending.scale : (entry.scale != null ? String(entry.scale) : "");
        transformField.text = pending ? pending.transform : (entry.transform != null ? String(entry.transform) : "");
        vrrField.text = pending ? pending.vrr : (entry.vrr != null ? String(entry.vrr) : "");
        positionField.text = rect ? ArrangeLogic.toWorldPosition(rect.x, rect.y, root.transform) : (entry.position != null ? String(entry.position) : "");
        root.refreshEffectiveValues(name);
    }

    // The three live-derived placeholder values — see effectiveResolution's
    // own comment for what "live" means here and why vrr has no equivalent.
    // lastIpcObject's shape is documented only as "last json returned for
    // this monitor" with no schema, so transform's read is defensive (a
    // plain typeof check) rather than assumed.
    function refreshEffectiveValues(name: string): void {
        const live = Hyprland.monitors.values.find(m => m.name === name);
        root.effectiveResolution = live ? `${live.width}x${live.height}` : "";
        root.effectiveScale = live ? String(live.scale) : "";
        root.effectiveTransform = (live && live.lastIpcObject && typeof live.lastIpcObject.transform === "number") ? String(live.lastIpcObject.transform) : "";
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
    // one. Every monitor that has a pendingEdits entry (this session's
    // selected one included — flushSelectedIntoPending() banks its current
    // Field text first) also carries whichever of the other four fields it
    // set, which is what "alongside the dragged position" (not instead of
    // it) means for confirm(). Reading from pendingEdits rather than only
    // the live Fields is what keeps a monitor's edits from being discarded
    // by clicking a second rectangle before pressing Enter. scale/transform/
    // vrr all go through arrange.js's own parsers rather than being written
    // raw, so a typo drops just that field (becomes absent) instead of
    // either corrupting the entry or reaching Hyprland as a value it
    // rejects outright.
    function confirm(): void {
        root.applyPositionField(positionField.text);
        root.flushSelectedIntoPending();
        const items = root.rectItems().map(item => {
            const entry = {
                name: item.monitorName,
                position: ArrangeLogic.toWorldPosition(item.x, item.y, root.transform)
            };
            const pending = root.pendingEdits[item.monitorName];
            if (pending) {
                entry.resolution = pending.resolution;
                entry.scale = ArrangeLogic.numberField(pending.scale);
                entry.transform = ArrangeLogic.parseTransform(pending.transform);
                entry.vrr = ArrangeLogic.parseVrr(pending.vrr);
            }
            return entry;
        });
        const merged = ArrangeLogic.mergedOverrides(root.overridesRoot, items);
        overridesFile.setText(JSON.stringify(merged));
        root.close();
    }

    // The TUI's Ctrl+R: drops the selected monitor's entry from
    // overrides.json outright, rather than only clearing the form the way
    // the crate's own Ctrl+R did — this surface has no separate Ctrl+S, so
    // an immediate, self-contained un-override is the equivalent that does
    // not need a second keystroke to actually take effect. Also drops any
    // pendingEdits for this monitor — Ctrl+R means "forget this monitor's
    // configuration", which should include whatever was typed and not yet
    // saved, not just what was already on disk.
    //
    // The four optional fields are set to "" directly here rather than by
    // calling loadFormFor() (which would re-read overridesFile.adapter's
    // declared entries property) — Quickshell's own FileView docs do not
    // say whether the adapter reparses synchronously with setText() or on
    // a later tick, and this monitor's entry is gone by construction
    // (filtered out of `entries` right above), so there is nothing to
    // read back that isn't already known here.
    function reset(): void {
        if (!root.selectedName)
            return;
        delete root.pendingEdits[root.selectedName];
        const entries = root.overridesRoot.entries.filter(e => e.name !== root.selectedName);
        overridesFile.setText(JSON.stringify({ entries: entries }));
        resolutionField.text = "";
        scaleField.text = "";
        transformField.text = "";
        vrrField.text = "";
        root.refreshEffectiveValues(root.selectedName);
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
        adapter: JsonAdapter {
            property var entries: []
        }
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

                    // Each optional field sits under an Item the same size
                    // as the Field, with a second Text layered on top —
                    // painted after the Field in this Item's own child
                    // list, so it draws over it — showing the live value as
                    // a placeholder exactly while the field is empty. A
                    // plain Text has no mouse handling of its own, so a
                    // click still reaches the Field underneath and starts
                    // typing normally.
                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: resolutionField.implicitHeight

                        Field {
                            id: resolutionField

                            anchors.fill: parent

                            onAccepted: root.confirm()
                            onEscaped: root.close()
                        }

                        Text {
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12

                            visible: resolutionField.text.length === 0
                            text: root.effectiveResolution
                            color: Theme.muted
                            elide: Text.ElideRight
                            verticalAlignment: Text.AlignVCenter

                            font.family: Theme.fontMono
                            font.pixelSize: Theme.fontSize
                        }
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

                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: scaleField.implicitHeight

                        Field {
                            id: scaleField

                            anchors.fill: parent

                            onAccepted: root.confirm()
                            onEscaped: root.close()
                        }

                        Text {
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12

                            visible: scaleField.text.length === 0
                            text: root.effectiveScale
                            color: Theme.muted
                            elide: Text.ElideRight
                            verticalAlignment: Text.AlignVCenter

                            font.family: Theme.fontMono
                            font.pixelSize: Theme.fontSize
                        }
                    }

                    // The legal-values hint lives on the label rather than
                    // as placeholder text: the placeholder slot on these
                    // two fields is reserved for the live effective value
                    // (transform) or is empty because there is no honest
                    // one to show (vrr — see effectiveResolution's comment).
                    Text {
                        text: "Transform (0-7)"
                        color: Theme.muted

                        font.family: Theme.fontUi
                        font.pointSize: 9
                    }

                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: transformField.implicitHeight

                        Field {
                            id: transformField

                            anchors.fill: parent

                            onAccepted: root.confirm()
                            onEscaped: root.close()
                        }

                        Text {
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12

                            visible: transformField.text.length === 0
                            text: root.effectiveTransform
                            color: Theme.muted
                            elide: Text.ElideRight
                            verticalAlignment: Text.AlignVCenter

                            font.family: Theme.fontMono
                            font.pixelSize: Theme.fontSize
                        }
                    }

                    Text {
                        text: "VRR (off|left|right|auto)"
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

                    Rectangle {
                        Layout.fillWidth: true
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
