// The launcher.
//
// Replaces beamenu, and with it a ten-patch series maintained against upstream
// bemenu's C renderer. That series existed because bemenu's event loop is
// client-owned: beamenu had to reimplement run_menu() in Rust over FFI to get
// a row with an icon, a subtitle and an accessory. Here a row is a delegate,
// so the thing the patches bought is a layout.
//
// Providers are plain functions returning row objects. A row carries what it
// shows and a `run` closure, so adding one is a function rather than a trait
// implementation plus a registration plus a config schema.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import ".."
import "../common"
import "pills.js" as Pills

Scope {
    id: root

    // How many rows fit before the list scrolls, from the palette.
    readonly property int visibleRows: Theme.launcherLines

    property string query: ""
    property int selected: 0

    // The pill bar's own selection: "" is its All state. Sticky across a
    // keystroke rather than reset by one, so clicking "Apps" and then typing
    // narrows within Apps instead of the filter falling away the moment the
    // query changes underneath it — the same way a browser's search-in-tab
    // scope survives further typing.
    property string selectedPill: ""

    // A pill change swaps out the list wholesale, so whatever row index was
    // highlighted under the old filter has nothing reliable to mean under the
    // new one.
    onSelectedPillChanged: root.selected = 0

    // The highlighted row's path, or "" for a row that has none. Only the file
    // provider sets `path`, so this is the whole "is the entry a file" test:
    // an application, a calculation or an emoji simply has nothing to preview.
    readonly property string previewPath: root.results[root.selected]?.path ?? ""

    readonly property var focusedScreen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? null

    // Rows are computed fresh per keystroke. The result sets here are small
    // (a few hundred desktop entries at worst) and recomputing is simpler to
    // reason about than invalidating a cache on every provider's own schedule.
    // A prefixed query answers from one provider alone, which is beamenu's
    // rule and the reason typing "w " does not also list every application
    // whose name happens to contain a w.
    readonly property var unfilteredResults: {
        const text = root.query;

        if (text.startsWith("="))
            return root.calculatorRows(text.slice(1));

        if (text.startsWith("?"))
            return providers.websearchRows(text.slice(1));

        if (text.startsWith("w "))
            return providers.windowRows(text.slice(2).trim());

        if (text.startsWith("c "))
            return providers.clipboardRows(text.slice(2).trim());

        if (text.startsWith("e "))
            return providers.emojiRows(text.slice(2).trim());

        const needle = text.trim();

        const rows = providers.applicationRows(needle).concat(providers.systemRows(needle)).concat(providers.quicklinkRows(needle)).concat(providers.snippetRows(needle)).concat(providers.fileRows(needle)).concat(providers.statusRows(needle));

        // Prefix matches first: typing "fi" should reach Firefox before it
        // reaches anything merely containing "fi".
        const lowered = needle.toLowerCase();
        rows.sort((a, b) => {
            const aPrefix = a.title.toLowerCase().startsWith(lowered) ? 0 : 1;
            const bPrefix = b.title.toLowerCase().startsWith(lowered) ? 0 : 1;

            if (aPrefix !== bPrefix)
                return aPrefix - bPrefix;

            return a.title.localeCompare(b.title);
        });

        return rows.slice(0, 50);
    }

    // One pill per provider present in the unfiltered rows — item.rs's
    // contract — computed from those rather than from `results` so a pill
    // never disappears out from under its own filter.
    readonly property var pills: Pills.pillsFor(root.unfilteredResults)

    // What the list actually shows: the pill bar's filter applied on top of
    // the query's own matches.
    readonly property var results: Pills.filterByPill(root.unfilteredResults, root.selectedPill)

    function calculatorRows(expression: string): var {
        const value = calculator.evaluate(expression);
        if (value === undefined)
            return [];

        const rendered = `${value}`;

        return [
            {
                title: rendered,
                subtitle: `= ${expression.trim()}`,
                icon: "",
                accessory: "copy",
                provider: "calc",
                run: () => providers.copy(rendered)
            }
        ];
    }

    // Cycles the pill bar with Tab/Shift+Tab, the keyboard half of "let the
    // pointer drive the pills too" — clicking a Pill (below) is the other
    // half. Wraps through "" (All) the same way `move()` wraps the row
    // selection, and resets which row is highlighted since the list under a
    // new pill is a different list.
    function cyclePill(delta: int): void {
        if (root.pills.length === 0)
            return;

        const ids = [""].concat(root.pills.map(pill => pill.id));
        const index = ids.indexOf(root.selectedPill);
        const nextIndex = (index + delta + ids.length) % ids.length;
        // Reassigning even when the index does not move (a single pill,
        // Shift+Tab back to All from All) is harmless: onSelectedPillChanged
        // only fires on an actual change.
        root.selectedPill = ids[nextIndex];
    }

    function show(): void {
        root.query = "";
        root.selected = 0;
        root.selectedPill = "";
        window.visible = true;
    }

    function hide(): void {
        window.visible = false;
    }

    function activate(): void {
        const row = root.results[root.selected];
        if (!row)
            return;

        root.hide();
        row.run();
    }

    function move(delta: int): void {
        const count = root.results.length;
        if (count === 0)
            return;

        // Wraps, because reaching the bottom of a nine-row list and being told
        // no is worse than arriving back at the top.
        root.selected = (root.selected + delta % count + count) % count;
    }

    Calc {
        id: calculator
    }

    Providers {
        id: providers
    }

    // open/close rather than show/hide: `qs ipc call launcher show` is
    // swallowed by the `qs ipc show` subcommand and prints the handler listing
    // instead of calling anything, with no error to say so. Measured, not
    // guessed at.
    IpcHandler {
        target: "launcher"

        function open(): void {
            root.show();
        }

        function close(): void {
            root.hide();
        }

        function toggle(): void {
            if (window.visible) {
                root.hide();
            } else {
                root.show();
            }
        }
    }

    PanelWindow {
        id: window

        screen: root.focusedScreen
        color: "transparent"
        visible: false

        // Overlay so it sits above everything, and an exclusive keyboard grab
        // so typing reaches the search field rather than whatever was focused.
        // The namespace is what Hyprland's blur layer_rule matches on; bemenu
        // hardcoded "menu", and this one can say what it actually is.
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        WlrLayershell.namespace: "dots-launcher"

        anchors {
            top: true
            left: true
            right: true
            bottom: true
        }

        exclusiveZone: 0

        onVisibleChanged: {
            if (window.visible) {
                input.forceActiveFocus();
            }
        }

        // Clicking away dismisses, the way beamenu was patched to behave.
        MouseArea {
            anchors.fill: parent

            onClicked: root.hide()
        }

        Panel {
            id: panel

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: Math.round(parent.height * 0.18)

            // The preview column is added to the panel rather than taken out
            // of it: the list keeps the width it has without a preview, so
            // arrowing onto a file does not reflow the rows you were reading.
            width: Math.round(parent.width * Theme.launcherWidthFactor) + (root.previewPath === "" ? 0 : Theme.launcherPreviewWidth)
            height: Theme.launcherSearchHeight + pillRow.height + (pillRow.height > 0 ? 6 : 0) + list.height + (list.height > 0 ? 8 : 0)

            padding: 4

            // Search field and list on the left, preview on the right, rather
            // than the preview under a full-width search field: the pane wants
            // the panel's whole height for an image or a directory listing.
            RowLayout {
                anchors.fill: parent

                spacing: 0

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    spacing: 4

                    TextInput {
                        id: input

                        Layout.fillWidth: true
                        Layout.preferredHeight: Theme.launcherSearchHeight - 8
                        Layout.leftMargin: 14
                        Layout.rightMargin: 14

                        text: root.query
                        color: Theme.fg

                        font.family: Theme.fontUi
                        font.pointSize: 13

                        verticalAlignment: TextInput.AlignVCenter
                        clip: true
                        selectByMouse: true
                        selectionColor: Theme.accent
                        selectedTextColor: Theme.bg

                        onTextChanged: {
                            root.query = input.text;
                            root.selected = 0;

                            // File search is driven by assignment rather than from
                            // the results binding, because kicking off a process
                            // inside a binding makes the binding a side effect and
                            // re-runs it whenever anything else it touches changes.
                            providers.fileQuery = input.text.startsWith("=") || input.text.startsWith("?") ? "" : input.text.trim();
                        }

                        Keys.onDownPressed: root.move(1)
                        Keys.onUpPressed: root.move(-1)
                        Keys.onEscapePressed: root.hide()
                        Keys.onReturnPressed: root.activate()
                        Keys.onEnterPressed: root.activate()
                        Keys.onTabPressed: root.cyclePill(1)
                        Keys.onBacktabPressed: root.cyclePill(-1)

                        Text {
                            anchors.verticalCenter: parent.verticalCenter

                            text: "Search"
                            color: Theme.muted
                            visible: input.text === ""

                            font.family: Theme.fontUi
                            font.pointSize: 13
                        }
                    }

                    // The filter pill bar (rust/beamenu/src/item.rs: "every
                    // provider owns exactly one pill"). Built from the shared
                    // capsule primitive rather than a second implementation —
                    // Tab/Shift+Tab cycle it from the keyboard, and each Pill's
                    // own MouseArea (see common/Pill.qml) lets the pointer
                    // drive it too.
                    RowLayout {
                        id: pillRow

                        Layout.fillWidth: true
                        Layout.leftMargin: 14
                        Layout.rightMargin: 14
                        Layout.preferredHeight: root.pills.length > 0 ? Theme.barHeight - 8 : 0

                        visible: root.pills.length > 0
                        spacing: 6

                        Repeater {
                            model: root.pills

                            delegate: Pill {
                                id: pillDelegate

                                required property var modelData

                                readonly property bool active: root.selectedPill === pillDelegate.modelData.id

                                interactive: true
                                color: pillDelegate.active ? Theme.accent : Theme.bgDark

                                // Clicking the active pill clears it, so the
                                // pill bar is also its own "All" toggle and
                                // needs no separate All pill taking up space
                                // when nothing is filtered yet.
                                onClicked: root.selectedPill = pillDelegate.active ? "" : pillDelegate.modelData.id

                                Text {
                                    text: `${pillDelegate.modelData.label} ${pillDelegate.modelData.count}`
                                    color: pillDelegate.active ? Theme.bg : Theme.fg

                                    font.family: Theme.fontUi
                                    font.pointSize: 9
                                    font.bold: true
                                }
                            }
                        }

                        Item {
                            Layout.fillWidth: true
                        }
                    }

                    ListView {
                        id: list

                        Layout.fillWidth: true
                        Layout.preferredHeight: Math.min(root.results.length, root.visibleRows) * Theme.launcherLineHeight

                        model: root.results
                        currentIndex: root.selected

                        clip: true
                        // Keeps the selected row on screen when the cursor moves
                        // past the edge of the visible window.
                        highlightFollowsCurrentItem: true
                        highlightMoveDuration: 90

                        delegate: ResultRow {
                            required property var modelData
                            required property int index

                            width: list.width

                            title: modelData.title
                            subtitle: modelData.subtitle ?? ""
                            icon: modelData.icon ?? ""
                            accessory: modelData.accessory ?? ""
                            current: index === root.selected

                            onActivated: {
                                root.selected = index;
                                root.activate();
                            }
                        }
                    }
                }

                // Invisible for every row that carries no path, and an
                // invisible item is left out of a RowLayout entirely — which
                // is what keeps the column from reserving space it cannot use.
                PreviewPane {
                    Layout.preferredWidth: Theme.launcherPreviewWidth
                    Layout.fillHeight: true

                    visible: root.previewPath !== ""
                    path: root.previewPath
                }
            }
        }
    }
}
