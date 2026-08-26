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

Scope {
    id: root

    // How many rows fit before the list scrolls, from the palette.
    readonly property int visibleRows: Theme.launcherLines

    property string query: ""
    property int selected: 0

    readonly property var focusedScreen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? null

    // Rows are computed fresh per keystroke. The result sets here are small
    // (a few hundred desktop entries at worst) and recomputing is simpler to
    // reason about than invalidating a cache on every provider's own schedule.
    readonly property var results: {
        const text = root.query.trim();

        if (text.startsWith("=")) {
            return root.calculatorRows(text.slice(1));
        }

        const rows = root.applicationRows(text).concat(root.windowRows(text));

        // Prefix matches first: typing "fi" should reach Firefox before it
        // reaches anything merely containing "fi".
        const needle = text.toLowerCase();
        rows.sort((a, b) => {
            const aPrefix = a.title.toLowerCase().startsWith(needle) ? 0 : 1;
            const bPrefix = b.title.toLowerCase().startsWith(needle) ? 0 : 1;

            if (aPrefix !== bPrefix)
                return aPrefix - bPrefix;

            return a.title.localeCompare(b.title);
        });

        return rows.slice(0, 50);
    }

    function matches(haystack: string, needle: string): bool {
        if (needle === "")
            return true;

        return haystack.toLowerCase().includes(needle.toLowerCase());
    }

    function applicationRows(text: string): var {
        const rows = [];

        for (const entry of DesktopEntries.applications.values) {
            if (entry.noDisplay)
                continue;

            const haystack = `${entry.name} ${entry.genericName} ${entry.keywords}`;
            if (!root.matches(haystack, text))
                continue;

            rows.push({
                title: entry.name,
                subtitle: entry.genericName || entry.comment,
                icon: entry.icon ? Quickshell.iconPath(entry.icon, true) : "",
                accessory: "",
                run: () => Quickshell.execDetached(entry.command)
            });
        }

        return rows;
    }

    function windowRows(text: string): var {
        const rows = [];

        for (const toplevel of Hyprland.toplevels.values) {
            if (!root.matches(toplevel.title, text))
                continue;

            rows.push({
                title: toplevel.title,
                subtitle: `workspace ${toplevel.workspace?.name ?? "?"}`,
                icon: "",
                accessory: "window",
                run: () => Hyprland.dispatch(`focuswindow address:${toplevel.address}`)
            });
        }

        return rows;
    }

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
                run: () => Quickshell.execDetached(["wl-copy", "--", rendered])
            }
        ];
    }

    function show(): void {
        root.query = "";
        root.selected = 0;
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

        Rectangle {
            id: panel

            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: Math.round(parent.height * 0.18)

            width: Math.round(parent.width * Theme.launcherWidthFactor)
            height: Theme.launcherSearchHeight + list.height + (list.height > 0 ? 8 : 0)

            radius: Theme.launcherRadius
            color: Qt.alpha(Theme.bg, 0.95)
            border.width: 2
            border.color: Theme.accent

            // Swallows clicks so they do not reach the dismiss handler behind.
            MouseArea {
                anchors.fill: parent
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 4

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
                    }

                    Keys.onDownPressed: root.move(1)
                    Keys.onUpPressed: root.move(-1)
                    Keys.onEscapePressed: root.hide()
                    Keys.onReturnPressed: root.activate()
                    Keys.onEnterPressed: root.activate()

                    Text {
                        anchors.verticalCenter: parent.verticalCenter

                        text: "Search"
                        color: Theme.muted
                        visible: input.text === ""

                        font.family: Theme.fontUi
                        font.pointSize: 13
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
        }
    }
}
