// The settings panel, reached with SUPER+comma.
//
// Rebuilt on an imported "ChromeOS Settings" layout for its STRUCTURE only —
// a 260px sidebar of nav entries, a header with the panel title over the
// sidebar column and a live search field over the content column, a content
// column of pages (each a title, a description, then groups of rows), and a
// sticky footer with keyboard hints and Save. None of the source design's
// own visual language survives: no light ground, no square corners, no 2px
// rules, every colour and metric comes from Theme (nix/data/palette.json).
//
// common/Chrome.qml is NOT reused here, on purpose, after checking it first:
// Chrome's header is a single title Text spanning the whole panel and its
// footer is a single hint line, both fixed shapes three other surfaces
// (Cheatsheet, Arrange, wallpaper/Picker) already depend on. This shell's
// header is two columns of DIFFERENT widths carrying DIFFERENT content
// (a title over the sidebar's own width, a search field over the content
// column's), and its footer carries hints AND a Save button AND a transient
// acknowledgement — composing all of that as optional Chrome modes would
// either grow Chrome a settings-shaped special case or fork it under a new
// name, which is exactly what reuse is supposed to avoid. common/Panel.qml —
// the translucent rounded surface Chrome itself wraps — is what this shell
// builds directly on instead, the same way launcher/Launcher.qml already
// does for a shape of its own.
//
// Still edits the installer-written settings.nix through
// rust/settings-global, exactly as before: `dump` and `set`, one process per
// changed field so a rejected field fails alone, the `edits` object
// reassigned rather than mutated because QML does not see an in-place
// object mutation. Only Identity is wired to that data — every other nav
// entry (WM, AI, Accounts, Keyboard, Security) is a stub a later task fills
// in; see EmptyState.qml's "not been built yet" message for where they
// stand today. That does mean the three AI toggles global-settings already
// dumps (aiOllama, aiClaude, aiCodex) have no row anywhere in this shell yet
// — they still round-trip through `fields`/`edits`/`save()` correctly, they
// are just not rendered until the AI page exists to own them.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import ".."
import "../common"
import "controls"
import "search.js" as Search

Scope {
    id: root

    readonly property var focusedScreen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? null

    property var fields: []

    // Keyed by field key. Only what the user actually touched is written back,
    // so opening the form and closing it changes nothing on disk.
    property var edits: ({})

    property string status: ""

    // Which row Up/Down highlights, among whatever `visibleRows` currently
    // is — the active page's own rows normally, or the search matches while
    // a query is active. A cursor only, same as before: editing still needs
    // a click, so arrowing past a field never steals focus out from under
    // whatever the mouse last put it on.
    property int selected: 0

    // Which surface the panel is showing. The Proton page is a second
    // screen rather than more rows because connecting an account is an
    // action, not a field you save, and mixing the two under one Enter key
    // would make Enter mean "save" on most rows and "log in" on one.
    property string page: "form"

    // The sidebar's own selection — independent of `page`, which is form
    // vs. Proton, a distinction the old flat form never had to draw at all.
    property string activePage: "identity"

    property string query: ""
    readonly property bool searching: root.query.trim() !== ""

    // The 260px sidebar's own model. Six entries because that is the whole
    // information architecture the source design was imported for — this
    // task ships the chrome around all six; only Identity has a page behind
    // it today.
    readonly property var navPages: [
        {
            id: "identity",
            label: "Identity",
            glyph: "\u{F0004}",
            description: "This machine and the person who owns it."
        },
        {
            id: "wm",
            label: "Window manager",
            glyph: "\u{F0379}",
            description: "Layout, workspaces and how windows behave."
        },
        {
            id: "ai",
            label: "AI",
            glyph: "\u{F06A9}",
            description: "Coding and chat assistants available on this machine."
        },
        {
            id: "accounts",
            label: "Accounts",
            glyph: "\u{F0849}",
            description: "Connected services and how they authenticate."
        },
        {
            id: "keyboard",
            label: "Keyboard",
            glyph: "\u{F030C}",
            description: "Layout, repeat rate and shortcuts."
        },
        {
            id: "security",
            label: "Security",
            glyph: "\u{F099D}",
            description: "Locking, encryption and what can unlock this machine."
        }
    ]

    readonly property var activeNavEntry: root.navPages.find(p => p.id === root.activePage) ?? root.navPages[0]

    // What the cursor actually walks on the Identity page: the dumped fields
    // plus one synthetic row that opens the Proton page. Synthetic rather
    // than a seventh entry in the Rust ITEMS table, because global-settings
    // only knows how to dump and set values, and this row has none.
    readonly property var rows: root.fields.concat([
        {
            key: "proton",
            label: "Proton",
            type: "page"
        }
    ]);

    // A one-line description per row, since global-settings only dumps a
    // key/label/type/value — the "one-line description" the row grammar
    // wants is this shell's own copy, not Rust's.
    readonly property var fieldDescriptions: ({
            gitName: "Used for commit authorship on this machine.",
            gitEmail: "Used for commit authorship on this machine.",
            hostname: "The name this machine answers to on the network.",
            protonEmail: "The address proton-setup signs in with.",
            proton: "Connect Proton Drive and Calendar."
        })

    function descriptionFor(row: var): string {
        return root.fieldDescriptions[row.key] ?? "";
    }

    // The flat search index: one descriptor per row this shell can actually
    // show today. search.js never sees a live SettingsRow, only this.
    readonly property var searchIndex: root.rows.map(r => ({
                id: r.key,
                pageId: "identity",
                groupId: "identity-general",
                title: r.label,
                description: root.descriptionFor(r),
                keywords: ""
            }))

    readonly property var searchResult: Search.search(root.searchIndex, root.query)

    // What the content column actually renders and the keyboard cursor
    // actually walks: the active page's own rows while browsing (empty for
    // every stub page — there is nothing to select), or every row search.js
    // matched while a query is active, regardless of which nav entry is
    // selected — a real ChromeOS-style search reaches across pages, not
    // just the one on screen.
    readonly property var visibleRows: {
        if (!root.searching)
            return root.activePage === "identity" ? root.rows : [];

        const matched = new Set(root.searchResult.matchedIds);
        return root.rows.filter(r => matched.has(r.key));
    }

    function emptyMessage(): string {
        if (root.searching)
            return `No settings match "${root.query.trim()}"`;

        if (root.activePage !== "identity")
            return "This page has not been built yet — a later task fills it in.";

        return "Nothing to show here yet.";
    }

    function load(): void {
        root.edits = {};
        root.status = "";
        root.selected = 0;
        root.query = "";
        searchField.text = "";
        loader.running = false;
        loader.running = true;
    }

    // Wraps, matching Launcher's own move().
    function moveSelection(delta: int): void {
        const count = root.visibleRows.length;
        if (count === 0)
            return;

        root.selected = (root.selected + delta % count + count) % count;
    }

    function valueOf(field: var): var {
        return field.key in root.edits ? root.edits[field.key] : field.value;
    }

    function edit(key: string, value: var): void {
        // Reassigned rather than mutated: QML does not see a property change
        // when an object's contents are modified in place, so the bindings
        // reading it would keep showing the old value.
        const next = Object.assign({}, root.edits);
        next[key] = value;
        root.edits = next;
    }

    function save(): void {
        const keys = Object.keys(root.edits);
        if (keys.length === 0) {
            root.status = "Nothing changed";
            return;
        }

        root.status = `Writing ${keys.length} field${keys.length === 1 ? "" : "s"}…`;
        writer.pending = keys.slice();
        writer.next();
    }

    // Enter does whatever the highlighted row is for. Only the synthetic
    // Proton row is a page; everything else is a value, and for those Enter
    // still means save, exactly as before.
    function activate(): void {
        const row = root.visibleRows[root.selected];
        if (row && row.type === "page") {
            root.openProton();
            return;
        }
        root.save();
    }

    function openProton(): void {
        root.page = "proton";
        proton.refresh();
    }

    // Leaving drops whatever was typed. A password held in a property until
    // the next visit would outlive the reason it was entered, and the panel
    // builds this page once rather than per visit, so nothing else would
    // clear it.
    function leaveProton(): void {
        proton.forget();
        root.page = "form";
        panel.forceActiveFocus();
    }

    // The address lives in the same settings.nix every other row uses, so the
    // Proton page hands it back here and it is written through the same
    // per-field writer rather than a second path to the same file.
    function rememberProtonEmail(value: string): void {
        const current = root.fields.find(f => f.key === "protonEmail");
        if (!current || current.value === value) {
            return;
        }
        root.edit("protonEmail", value);
        root.save();
    }

    // A "Saved" acknowledgement is meant to be noticed, not lived with —
    // this is what makes it transient. Cleared on anything else so a
    // failure message or a fresh "Writing N fields…" is never raced away by
    // a timer left over from the save before it.
    Timer {
        id: savedAckTimer

        interval: 1600
        onTriggered: root.status = ""
    }

    onStatusChanged: {
        if (root.status === "Saved")
            savedAckTimer.restart();
        else
            savedAckTimer.stop();
    }

    IpcHandler {
        target: "settings"

        function open(): void {
            root.load();
            window.visible = true;
        }

        function close(): void {
            window.visible = false;
        }

        function toggle(): void {
            if (window.visible) {
                window.visible = false;
            } else {
                root.load();
                window.visible = true;
            }
        }
    }

    Process {
        id: loader

        command: ["global-settings", "dump"]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.fields = JSON.parse(this.text);
                } catch (error) {
                    root.fields = [];
                    root.status = "Could not read settings";
                }
            }
        }
    }

    Process {
        id: writer

        property var pending: []

        function next(): void {
            if (writer.pending.length === 0) {
                root.status = "Saved";
                root.load();
                return;
            }

            const key = writer.pending[0];
            writer.pending = writer.pending.slice(1);

            const value = root.edits[key];
            writer.running = false;
            writer.command = ["global-settings", "set", key, typeof value === "boolean" ? (value ? "true" : "false") : `${value}`];
            writer.running = true;
        }

        // Process.exited carries a QProcess::ExitStatus second argument whose
        // type Quickshell does not export, so the linter cannot compile the
        // handler's signature even though it runs.
        // qmllint disable signal-handler-parameters
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                root.status = "A field was rejected, see journalctl";
                return;
            }

            writer.next();
        }
        // qmllint enable signal-handler-parameters
    }

    PanelWindow {
        id: window

        screen: root.focusedScreen
        color: "transparent"
        visible: false

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        WlrLayershell.namespace: "dots-settings"

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

            onClicked: window.visible = false
        }

        Panel {
            id: panel

            anchors.centerIn: parent

            // Fractions of the screen, matching how the launcher sizes
            // itself (Theme.launcherWidthFactor): the settings panel is
            // itself sized relative to the monitor, so a fixed pixel size
            // would mean something different on every one.
            width: Math.round(parent.width * Theme.settingsPanelWidthFactor)
            height: Math.round(parent.height * Theme.settingsPanelHeightFactor)

            padding: 0
            focus: true

            // The arrows in this first hint hold unconditionally; the jk half
            // holds only while the panel itself has focus. A click into a text
            // row moves focus there, and a focused TextInput keeps j and k as
            // typed characters (tests/qml/tst_focus_grammar.qml), while the
            // arrows still bubble up to the handlers below. Nothing hands
            // focus back afterwards — panel.forceActiveFocus() runs on
            // onVisibleChanged and nowhere else — so from that point on the
            // arrows are the only way to move until the window is reopened.
            // Arrange's footer makes the same promise on the same terms.
            Keys.onEscapePressed: {
                if (root.page === "proton") {
                    root.leaveProton();
                } else {
                    window.visible = false;
                }
            }
            Keys.onReturnPressed: root.activate()
            Keys.onEnterPressed: root.activate()
            Keys.onUpPressed: root.moveSelection(-1)
            Keys.onDownPressed: root.moveSelection(1)

            // A focused text row consumes j/k as literal characters before
            // this ever sees them — TextInput's own native handling, driven
            // with real key events in tests/qml/tst_focus_grammar.qml — so
            // the alias only fires when the panel itself holds focus, the
            // same Vim-style aliasing Arrange's own grammar uses elsewhere.
            Keys.onPressed: event => {
                if (event.key === Qt.Key_J) {
                    root.moveSelection(1);
                    event.accepted = true;
                } else if (event.key === Qt.Key_K) {
                    root.moveSelection(-1);
                    event.accepted = true;
                }
            }

            // The sidebar's own background continues under the header, the
            // two-tone fill that stands in for the source design's `box-
            // shadow`-drawn divider: no rule is drawn anywhere in this file.
            Rectangle {
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.left: parent.left

                width: Theme.settingsSidebarWidth
                color: Theme.bgDarker
                visible: root.page === "form"
            }

            ColumnLayout {
                anchors.fill: parent

                spacing: 0

                // --- Header: "Settings" over the sidebar column, search
                // over the content column. ---
                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.settingsHeaderHeight

                    spacing: 0

                    Item {
                        Layout.preferredWidth: Theme.settingsSidebarWidth
                        Layout.fillHeight: true

                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 20
                            anchors.verticalCenter: parent.verticalCenter

                            text: "Settings"
                            color: Theme.fg

                            font.family: Theme.fontUi
                            font.pointSize: Theme.settingsTitleFontSize
                            font.bold: true
                        }
                    }

                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true

                        // common/Field.qml, reused as-is per the task
                        // brief's own callout. It has no placeholder text of
                        // its own, so the ghost "Search settings" label below
                        // is drawn separately rather than added to a shared
                        // component this file cannot touch.
                        Field {
                            id: searchField

                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.leftMargin: 20
                            anchors.rightMargin: 20

                            implicitHeight: Theme.settingsSearchHeight

                            // No `text: root.query` binding here — a live
                            // binding on a TextInput's own text property does
                            // not survive the user's first keystroke (Qt
                            // Quick treats a keystroke's own edit as an
                            // ordinary write, which severs any binding on the
                            // property, live-typed or not), so a later
                            // external reset (a nav click, below) would stop
                            // reaching the field the moment anything had been
                            // typed into it. Plain two-way sync instead: this
                            // Connections block pushes an edit out to
                            // root.query, and every external reset assigns
                            // searchField.text back imperatively.
                            Connections {
                                target: searchField.input

                                function onTextEdited(): void {
                                    root.query = searchField.text;
                                    root.selected = 0;
                                }
                            }

                            onEscaped: panel.forceActiveFocus()
                        }

                        Text {
                            anchors.left: searchField.left
                            anchors.leftMargin: 12
                            anchors.verticalCenter: searchField.verticalCenter

                            text: "Search settings"
                            color: Theme.muted
                            visible: searchField.text === ""

                            font.family: Theme.fontUi
                            font.pointSize: Theme.settingsRowDescFontSize
                        }
                    }
                }

                // --- Body: sidebar nav | content column. ---
                RowLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    spacing: 0

                    Item {
                        Layout.preferredWidth: Theme.settingsSidebarWidth
                        Layout.fillHeight: true

                        visible: root.page === "form"

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.topMargin: 8
                            anchors.bottomMargin: 8

                            spacing: 2

                            Repeater {
                                model: root.navPages

                                delegate: Item {
                                    id: navEntry

                                    required property var modelData

                                    readonly property bool active: root.activePage === navEntry.modelData.id

                                    Layout.fillWidth: true
                                    implicitHeight: Theme.settingsRowHeight - 12

                                    // The idiomatic way to mark "active" here,
                                    // per the task brief: the source design's
                                    // own `box-shadow: inset 4px 0 0` is the
                                    // same idea drawn with CSS instead.
                                    EdgeStrip {
                                        edge: "left"
                                        active: navEntry.active
                                    }

                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: 20
                                        anchors.rightMargin: 12

                                        spacing: 12

                                        Text {
                                            text: navEntry.modelData.glyph
                                            color: navEntry.active ? Theme.accent : Theme.dim

                                            font.family: Theme.fontUi
                                            font.pointSize: Theme.settingsNavFontSize
                                        }

                                        Text {
                                            Layout.fillWidth: true

                                            text: navEntry.modelData.label
                                            color: navEntry.active ? Theme.fg : Theme.muted
                                            elide: Text.ElideRight

                                            font.family: Theme.fontUi
                                            font.pointSize: Theme.settingsNavFontSize
                                        }
                                    }

                                    MouseArea {
                                        anchors.fill: parent

                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            root.activePage = navEntry.modelData.id;
                                            root.selected = 0;
                                            root.query = "";
                                            searchField.text = "";
                                        }
                                    }
                                }
                            }

                            Item {
                                Layout.fillHeight: true
                            }
                        }
                    }

                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 20

                            spacing: Theme.settingsGroupGap

                            visible: root.page === "form"

                            Text {
                                Layout.fillWidth: true

                                text: root.searching ? `Search results for "${root.query.trim()}"` : root.activeNavEntry.label
                                color: Theme.fg
                                elide: Text.ElideRight

                                font.family: Theme.fontUi
                                font.pointSize: Theme.settingsTitleFontSize
                                font.bold: true
                            }

                            Text {
                                Layout.fillWidth: true

                                visible: !root.searching
                                text: root.activeNavEntry.description
                                color: Theme.muted
                                wrapMode: Text.WordWrap

                                font.family: Theme.fontUi
                                font.pointSize: Theme.settingsRowDescFontSize
                            }

                            ColumnLayout {
                                Layout.fillWidth: true

                                visible: root.visibleRows.length > 0
                                spacing: Theme.settingsRowGap

                                Text {
                                    text: root.searching ? "Matches" : "General"
                                    color: Theme.muted

                                    font.family: Theme.fontUi
                                    font.pointSize: Theme.settingsGroupFontSize
                                    font.bold: true
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true

                                    spacing: Theme.settingsRowGap

                                    Repeater {
                                        model: root.visibleRows

                                        delegate: SettingsRow {
                                            id: fieldRow

                                            required property var modelData
                                            required property int index

                                            Layout.fillWidth: true

                                            title: fieldRow.modelData.label
                                            description: root.descriptionFor(fieldRow.modelData)
                                            clickable: fieldRow.modelData.type === "page"
                                            highlighted: root.selected === fieldRow.index

                                            onClicked: {
                                                root.selected = fieldRow.index;
                                                root.activate();
                                            }

                                            Field {
                                                id: valueField

                                                visible: fieldRow.modelData.type === "text"
                                                width: 220

                                                text: root.valueOf(fieldRow.modelData)

                                                Connections {
                                                    target: valueField.input

                                                    function onTextEdited(): void {
                                                        root.edit(fieldRow.modelData.key, valueField.text);
                                                    }
                                                }
                                            }

                                            Toggle {
                                                visible: fieldRow.modelData.type === "checkbox"

                                                checked: root.valueOf(fieldRow.modelData) === true
                                                onToggled: value => root.edit(fieldRow.modelData.key, value)
                                            }

                                            // The Proton row's own control: a
                                            // bare chevron rather than a
                                            // field, since Enter/click on
                                            // this row opens a page instead
                                            // of editing a value —
                                            // `clickable: true` above is what
                                            // makes the WHOLE row (not just
                                            // this glyph) answer the click.
                                            Text {
                                                visible: fieldRow.modelData.type === "page"

                                                text: "\u{F0142}"
                                                color: Theme.muted

                                                font.family: Theme.fontUi
                                                font.pointSize: Theme.settingsRowTitleFontSize
                                            }
                                        }
                                    }
                                }
                            }

                            Item {
                                Layout.fillWidth: true
                                Layout.fillHeight: true

                                visible: root.visibleRows.length === 0

                                EmptyState {
                                    anchors.centerIn: parent

                                    message: root.emptyMessage()
                                }
                            }

                            Item {
                                Layout.fillWidth: true
                                Layout.fillHeight: true

                                visible: root.visibleRows.length > 0
                            }
                        }

                        // The second surface. Built once and hidden rather
                        // than created per visit, which is why leaveProton()
                        // clears its fields by hand. Occupies the same
                        // content column the form uses — the sidebar band
                        // above stays hidden while this is up, but its
                        // reserved width is not reclaimed, so Proton keeps
                        // the same left margin the form's own content does.
                        Proton {
                            id: proton

                            anchors.fill: parent
                            anchors.margins: 20

                            visible: root.page === "proton"

                            initialEmail: {
                                const row = root.fields.find(f => f.key === "protonEmail");
                                return row ? `${row.value}` : "";
                            }

                            onBack: root.leaveProton()
                            onEmailEdited: value => root.rememberProtonEmail(value)
                        }
                    }
                }

                // --- Sticky footer: hints on the left, Save and a
                // transient "Saved" acknowledgement on the right. ---
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Theme.settingsFooterHeight

                    color: Theme.raised

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 20
                        anchors.rightMargin: 20

                        spacing: 12

                        Text {
                            Layout.fillWidth: true

                            text: [
                                {
                                    key: "↑↓/jk",
                                    label: "move"
                                },
                                {
                                    key: "Enter",
                                    label: "save"
                                },
                                {
                                    key: "Esc",
                                    label: "close"
                                }
                            ].map(h => `${h.key} ${h.label}`).join("   ·   ")
                            color: Theme.fg
                            opacity: 0.6
                            elide: Text.ElideRight

                            font.family: Theme.fontUi
                            font.pointSize: Theme.settingsRowDescFontSize
                        }

                        Text {
                            text: root.status
                            visible: root.status !== ""
                            color: root.status === "Saved" ? Theme.accent : Theme.muted

                            font.family: Theme.fontUi
                            font.pointSize: Theme.settingsRowDescFontSize
                            font.bold: root.status === "Saved"

                            Behavior on color {
                                ColorAnimation {
                                    duration: 200
                                }
                            }
                        }

                        Rectangle {
                            implicitWidth: 96
                            implicitHeight: Theme.settingsToggleHeight + 8

                            radius: height / 2
                            color: Object.keys(root.edits).length > 0 ? Theme.accent : Theme.selection

                            Text {
                                anchors.centerIn: parent

                                text: "Save"
                                color: Object.keys(root.edits).length > 0 ? Theme.bg : Theme.muted

                                font.family: Theme.fontUi
                                font.pointSize: Theme.settingsRowDescFontSize
                                font.bold: true
                            }

                            MouseArea {
                                anchors.fill: parent

                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.save()
                            }
                        }
                    }
                }
            }
        }
    }
}
