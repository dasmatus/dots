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
import "rank.js" as Rank

Scope {
    id: root

    // How many rows fit before the list scrolls, from the palette.
    readonly property int visibleRows: Theme.launcherLines

    property string query: ""
    property int selected: 0

    // The timestamp every frecency score in this launcher session decays
    // against, refreshed in show(). Not Date.now() read from inside the sort:
    // a QML binding does not re-evaluate because time passed, so a comparator
    // calling Date.now() would get a different answer on each keystroke that
    // happened to re-run it and a different one again on the keystroke that
    // did not — two rows a few hours apart could swap places mid-typing for no
    // reason the typist did anything to cause. One stamp per open is stable
    // for as long as the window is up, which is the only interval that has to
    // be self-consistent.
    property real rankNow: Date.now()

    // The pill bar's own selection: "" is its All state. Released by every
    // query edit (see the TextInput's onTextChanged below) rather than kept
    // across one — rust/beamenu/tests/pills.rs named this
    // editing_the_query_releases_the_engaged_provider for a reason: a pill
    // chosen while browsing must not silently keep hiding rows a fresh
    // search matches in other providers.
    property string selectedPill: ""

    // A pill change swaps out the list wholesale, so whatever row index was
    // highlighted under the old filter has nothing reliable to mean under the
    // new one.
    onSelectedPillChanged: root.selected = 0

    // The highlighted row's path, or "" for a row that has none. The file
    // provider sets `path` on every row it returns, and deviceRows sets it
    // too, deliberately, on a mounted device's open row, so arrowing onto
    // that row previews the mount root the same way arrowing onto a file
    // previews the file. An application, a calculation, an emoji, a
    // device's eject row, none of those set `path`, so previewPath stays ""
    // for them: this is still the whole "is there something here to
    // preview" test, just no longer scoped to files alone.
    readonly property string previewPath: root.results[root.selected]?.path ?? ""

    readonly property var focusedScreen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? null

    // Every provider's rows for the current query, concatenated in registry
    // order and never reordered — a prefixed query is already exactly one
    // provider's own list. This, not `unfilteredResults` below, is what the
    // pill bar's left-to-right order comes from: `unfilteredResults` sorts by
    // prefix match and then title, which would otherwise make the bar itself
    // reorder under the pointer as scores change between keystrokes. beamenu's
    // own rule for this list was "nothing may carry an index across a change
    // in the visible set" — a pill bar that visibly reshuffles is that rule
    // broken in a way you can see rather than crash on. Pill *counts* are a
    // separate question, answered where `pills` is computed below.
    readonly property var ambientRows: {
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

        return providers.applicationRows(needle).concat(providers.systemRows(needle)).concat(providers.quicklinkRows(needle)).concat(providers.snippetRows(needle)).concat(providers.fileRows(needle)).concat(providers.deviceRows(needle)).concat(providers.statusRows(needle));
    }

    // Rows are computed fresh per keystroke. The result sets here are small
    // (a few hundred desktop entries at worst) and recomputing is simpler to
    // reason about than invalidating a cache on every provider's own
    // schedule. A prefixed query already answers from one provider alone
    // (ambientRows above), so only the ambient case has anything left to sort.
    //
    // Rank.order does the sorting and returns a new array, which is what keeps
    // `ambientRows` — a shared reference `pills` also reads — from being
    // reordered as a side effect of rendering the list.
    //
    // Prefix matches still come first, so typing "bra" reaches Brave before
    // anything merely containing "bra" however little Brave gets used. What
    // changed is the tiebreak underneath: this used to fall to
    // localeCompare, which is why an unused browser starting with B sat above
    // a daily driver starting with L. Now it falls to decayed usage, then to
    // most-recently-used, then to the order the providers emitted rows in.
    // The needle is lowercased and trimmed HERE rather than inside rank.js,
    // which takes it already normalised.
    readonly property var unfilteredResults: {
        const text = root.query;

        if (text.startsWith("=") || text.startsWith("?") || text.startsWith("w ") || text.startsWith("c ") || text.startsWith("e "))
            return root.ambientRows;

        const needle = text.trim().toLowerCase();

        return Rank.order(root.ambientRows, providers.frecencyRecords, needle, root.rankNow).slice(0, 50);
    }

    // One pill per provider present in the query's rows — item.rs's
    // contract. Order comes from ambientRows (registry order) so the bar's
    // left-to-right order stays put across a keystroke instead of reshuffling
    // with scores; counts come from unfilteredResults, the exact list
    // `results` below filters, so a pill's own number always matches what
    // clicking it shows. Sourcing both from ambientRows once let a provider
    // pushed past unfilteredResults' 50-row cap keep a nonzero pill that
    // delivered fewer rows than promised, or none at all.
    readonly property var pills: Pills.pillsFor(root.ambientRows, root.unfilteredResults)

    // What the list actually shows: the pill bar's filter applied on top of
    // the query's own matches and their display sort.
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
        root.rankNow = Date.now();
        window.visible = true;
    }

    function hide(): void {
        window.visible = false;
    }

    function activate(): void {
        const row = root.results[root.selected];
        if (!row)
            return;

        // Recorded before run(), not after: run() hands off to execDetached or
        // a singleton and this function does not get to see whether that
        // worked. "The user chose this row" is the fact worth ranking on
        // anyway — a launch that fails is still a launch that was wanted.
        //
        // Rows from providers that opted out of ranking carry no key and are
        // skipped, so this stays a no-op for files, clipboard and the rest.
        if (row.key)
            providers.recordUse(row.key, row.parentKey ?? "");

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

                            // Editing the query releases whichever pill was
                            // engaged while browsing — beamenu's own rule
                            // (rust/beamenu/tests/pills.rs:
                            // editing_the_query_releases_the_engaged_provider).
                            // Without this, typing further after clicking a
                            // pill keeps filtering to that one provider and
                            // can quietly hide a row a fresh search matched
                            // in another.
                            root.selectedPill = "";

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
