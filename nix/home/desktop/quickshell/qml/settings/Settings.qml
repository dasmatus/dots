// The settings panel, reached with SUPER+comma.
//
// Rebuilt on an imported "ChromeOS Settings" layout for its STRUCTURE only:
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
// acknowledgement. Composing all of that as optional Chrome modes would
// either grow Chrome a settings-shaped special case or fork it under a new
// name, which is exactly what reuse is supposed to avoid. common/Panel.qml,
// the translucent rounded surface Chrome itself wraps, is what this shell
// builds directly on instead, the same way launcher/Launcher.qml already
// does for a shape of its own.
//
// Still edits the installer-written settings.nix through
// rust/settings-global, exactly as before: `dump` and `set`, one process per
// changed field so a rejected field fails alone, the `edits` object
// reassigned rather than mutated because QML does not see an in-place
// object mutation.
//
// Five real pages now sit behind the Identity page this shell shipped with:
// Window manager, AI, Accounts and Keyboard join it, each filtering the same
// `fields` array down to its own keys through pages.js's PAGE_FIELDS table
// (dump's own order interleaves keys from every page, so a page's row order
// is this shell's presentation choice, not something dump's array can be
// trusted to match). Security is a sixth, different shape of page: it owns
// no dumped field at all, so it is a Loader onto pages/security.qml instead
// of more rows, see showingSecurityPage below, and the sidebar itself is
// unchanged: it was already data-driven off navPages before any of this
// landed, precisely so that a later page only ever adds one nav entry
// instead of restructuring this file.
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
import "pages.js" as Pages
import "wm.js" as Wm

Scope {
    id: root

    readonly property var focusedScreen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? null

    property var fields: []

    // Keyed by field key. Only what the user actually touched is written back,
    // so opening the form and closing it changes nothing on disk.
    property var edits: ({})

    property string status: ""

    // Which row Up/Down highlights, among whatever `visibleRows` currently
    // is: the active page's own rows normally, or the search matches while
    // a query is active. A cursor only, same as before: editing still needs
    // a click, so arrowing past a field never steals focus out from under
    // whatever the mouse last put it on.
    property int selected: 0

    // Which surface the panel is showing. The Proton page is a second
    // screen rather than more rows because connecting an account is an
    // action, not a field you save, and mixing the two under one Enter key
    // would make Enter mean "save" on most rows and "log in" on one.
    property string page: "form"

    // The sidebar's own selection, independent of `page`, which is form
    // vs. Proton, a distinction the old flat form never had to draw at all.
    property string activePage: "identity"

    property string query: ""
    readonly property bool searching: root.query.trim() !== ""

    // The 260px sidebar's own model, one entry per real page. It started as
    // the six the source design was imported for; Session is the newest, and
    // exists because the idle thresholds qml/idle/ reads had nowhere to go —
    // they are not window-manager behaviour, and Security below renders its
    // own dashboard through a Loader rather than the rows grammar these two
    // need.
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
            id: "displays",
            label: "Displays",
            glyph: "\u{F0379}",
            description: "How monitors are arranged, scaled and rotated."
        },
        {
            id: "wallpaper",
            label: "Wallpaper",
            glyph: "\u{F02BA}",
            description: "The image behind everything, and the accent it sets."
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
            description: "Every SUPER shortcut this session recognises."
        },
        {
            id: "session",
            label: "Session",
            glyph: "\u{F0150}",
            description: "When this machine blanks the screen and locks itself."
        },
        {
            id: "security",
            label: "Security",
            glyph: "\u{F099D}",
            description: "Locking, encryption and what can unlock this machine."
        }
    ]

    readonly property var activeNavEntry: root.navPages.find(p => p.id === root.activePage) ?? root.navPages[0]

    // ~/.claude/settings.json is a different store than settings.nix, a
    // store symlink into the Nix store that `home-manager switch` rewrites
    // wholesale (nix/home/ai/claude.nix's own comment on its `model` key says
    // so), so there is nothing here for edit()/save() to write back to.
    // Read the same watch-and-reload way Theme.qml's tintState property
    // does for tint/current.json.
    // qmllint disable unresolved-type
    property var claudeSettingsFile: FileView {
        path: `${Quickshell.env("HOME")}/.claude/settings.json`
        watchChanges: true
        onFileChanged: reload()
        adapter: JsonAdapter {
            property string model: ""
            property var permissions: ({})
        }
    }

    // The Keyboard page's own data: the same keybinds.json tree.nix already
    // writes for the SUPER+/ cheatsheet, read the identical way
    // Cheatsheet.qml reads it so a change to that file's shape only has to
    // be taught once.
    property var keybindsFile: FileView {
        path: `${Quickshell.shellDir}/cheatsheet/keybinds.json`
        adapter: JsonAdapter {
            property var groups: []
        }
    }
    // qmllint enable unresolved-type

    readonly property var keyboardGroups: root.keybindsFile.adapter.groups

    // Whether the content column is showing the Keyboard page's own
    // keybind list instead of the rows grammar every other real page uses.
    // Keyboard owns no dumped field at all (see pages.js's PAGE_FIELDS),
    // so there is nothing for visibleRows, the empty state or the keyboard
    // cursor to walk while it is up.
    readonly property bool showingKeyboardPage: root.activePage === "keyboard" && !root.searching

    // Whether the content column is showing the Security page's own
    // Loader-built dashboard/permissions surface instead of the rows
    // grammar. Same shape as showingKeyboardPage, and for the same reason:
    // Security owns no dumped field either (see pages.js's PAGE_FIELDS,
    // "security" has no entry, so rowsForPage("security") always answers
    // []), so there is nothing here for visibleRows, the empty state or the
    // keyboard cursor to walk while it is up.
    readonly property bool showingSecurityPage: root.activePage === "security" && !root.searching

    // Wallpaper and Displays, same shape and same reason as the two above:
    // both own no dumped field (pages.js's PAGE_FIELDS names neither), so
    // there is nothing for visibleRows, the empty state or the keyboard
    // cursor to walk while either is up.
    //
    // These two are consolidations rather than new surfaces: the wallpaper
    // grid and the monitor arranger used to be their own full-screen
    // overlays on SUPER+W and SUPER+M. Those binds now open Settings at
    // these pages instead (see the `openAt` IPC below), so there is one
    // place each lives rather than two that drift apart.
    // The shell's one wallpaper/Picker.qml, handed in by shell.qml. Held here
    // only to pass on to pages/wallpaper.qml's Loader. Settings itself never
    // touches it. Typed `var` rather than `Picker` so this file needs no
    // import of the wallpaper module for a reference it only forwards.
    property var wallpaperPicker: null

    readonly property bool showingWallpaperPage: root.activePage === "wallpaper" && !root.searching
    readonly property bool showingDisplaysPage: root.activePage === "displays" && !root.searching

    // Synthetic rows for the three Claude Code fields that live in
    // ~/.claude/settings.json rather than settings.nix. See
    // fieldDescriptions' entries for these keys for why they render
    // read-only instead of through edit()/save() like every dumped field.
    readonly property var claudeReadonlyRows: [
        {
            key: "claudeModel",
            label: "Claude model",
            type: "readonly",
            value: root.claudeSettingsFile.adapter.model || "(unset)"
        },
        {
            key: "claudePermissionMode",
            label: "Claude permission mode",
            type: "readonly",
            value: root.claudeSettingsFile.adapter.permissions.defaultMode || "(unset)"
        },
        {
            key: "claudeAllowedTools",
            label: "Claude allowed tools",
            type: "readonly",
            value: `${(root.claudeSettingsFile.adapter.permissions.allow ?? []).length} allow rule(s)`
        }
    ]

    // What the cursor walked on the Identity page before this shell had more
    // than one real page, kept around verbatim: the synthetic Proton row
    // still hangs off it (Accounts' own rows below borrow it rather than
    // declaring a second one), and every dumped field is still in here for
    // any caller that wants the whole set regardless of page.
    readonly property var rows: root.fields.concat([
        {
            key: "proton",
            label: "Proton",
            type: "page"
        }
    ]);

    // One page's own rows, in pages.js's order, plus whatever synthetic rows
    // that page owns: Accounts' drill-in to Proton, AI's three read-only
    // Claude rows. "keyboard" and "security" fall through to
    // Pages.fieldsForPage's empty answer: Keyboard renders keybindsFile
    // directly instead (see showingKeyboardPage above), and Security
    // renders pages/security.qml instead (see showingSecurityPage above).
    function rowsForPage(pageId) {
        if (pageId === "ai")
            return Pages.fieldsForPage(root.fields, "ai").concat(root.claudeReadonlyRows);
        if (pageId === "accounts")
            return Pages.fieldsForPage(root.fields, "accounts").concat(root.rows.filter(r => r.key === "proton"));
        return Pages.fieldsForPage(root.fields, pageId);
    }

    // A one-line description per row, since global-settings only dumps a
    // key/label/type/value. The "one-line description" the row grammar
    // wants is this shell's own copy, not Rust's. The three claude* entries
    // double as the "labelled" requirement the task brief asks for on rows
    // that write nowhere this Save button reaches: read-only here, and said
    // so, rather than a write that could corrupt a config the user's agent
    // depends on.
    readonly property var fieldDescriptions: ({
            gitName: "Used for commit authorship on this machine.",
            gitEmail: "Used for commit authorship on this machine.",
            hostname: "The name this machine answers to on the network.",
            timezone: "The IANA zone this machine's clock uses.",
            desktop: "Which desktop environment the system module enables.",
            gitSigningKey: "Overrides the SSH key commits and tags are signed with.",
            wmGapsIn: "Space between adjacent tiled windows.",
            wmGapsOut: "Space between a tiled window and the screen edge.",
            wmBorderSize: "Width of the focused/unfocused window border.",
            wmFollowMouse: "Moving the pointer over a window focuses it.",
            wmAnimations: "Window open, close and move animations.",
            wmLayout: "The tiling algorithm new windows join.",
            idleBlankTimeout: "Seconds of inactivity before the screen turns off. Applied on the next rebuild.",
            idleLockTimeout: "Seconds of inactivity before the session locks itself. Applied on the next rebuild.",
            aiOllama: "Runs models on this machine, no cloud involved.",
            aiClaude: "Enables the Claude Code CLI.",
            aiCodex: "Enables the Codex CLI.",
            aiOllamaEndpoint: "Where the Ollama HTTP API listens.",
            aiOllamaDefaultModel: "Which pulled model answers by default.",
            protonEmail: "The address proton-setup signs in with.",
            proton: "Connect Proton Drive and Calendar.",
            claudeModel: "Read from ~/.claude/settings.json, managed by Home Manager (nix/home/ai/claude.nix) — read-only here.",
            claudePermissionMode: "Read from ~/.claude/settings.json, managed by Home Manager (nix/home/ai/claude.nix) — read-only here.",
            claudeAllowedTools: "Read from ~/.claude/settings.json, managed by Home Manager (nix/home/ai/claude.nix) — read-only here."
        })

    function descriptionFor(row: var): string {
        return root.fieldDescriptions[row.key] ?? "";
    }

    // The parent value a dependent row's `dependsOn` reads, null for a key
    // pages.js's DEPENDS_ON does not name, which the row-building delegate
    // below treats as "not dependent at all" rather than looking a key up
    // that has no parent to find.
    function valueOfKey(key: string): var {
        const field = root.fields.find(f => f.key === key);
        return field ? root.valueOf(field) : null;
    }

    // Which real pages search.js's search() reaches across. Keyboard is not
    // one of them: its rows are keybinds.json entries, not settings.nix
    // fields, so there is nothing here yet for a query to match against.
    readonly property var searchablePages: ["identity", "wm", "session", "ai", "accounts"]

    // The flat search index: one descriptor per row any real page can show
    // today. search.js never sees a live SettingsRow, only this.
    readonly property var searchIndex: {
        const out = [];
        for (const pageId of root.searchablePages) {
            for (const row of root.rowsForPage(pageId)) {
                out.push({
                    id: row.key,
                    pageId: pageId,
                    groupId: `${pageId}-general`,
                    title: row.label,
                    description: root.descriptionFor(row),
                    keywords: ""
                });
            }
        }
        return out;
    }

    readonly property var searchResult: Search.search(root.searchIndex, root.query)

    // What the content column actually renders and the keyboard cursor
    // actually walks: the active page's own rows while browsing (empty for
    // the Security stub, and for Keyboard, which renders keybindsFile
    // instead), or every row search.js matched while a query is active,
    // regardless of which nav entry is selected. A real ChromeOS-style
    // search reaches across pages, not just the one on screen.
    readonly property var visibleRows: {
        if (!root.searching)
            return root.rowsForPage(root.activePage);

        const matched = new Set(root.searchResult.matchedIds);
        const out = [];
        for (const pageId of root.searchablePages) {
            for (const row of root.rowsForPage(pageId)) {
                if (matched.has(row.key))
                    out.push(row);
            }
        }
        return out;
    }

    function emptyMessage(): string {
        if (root.searching)
            return `No settings match "${root.query.trim()}"`;

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
    // still means save, exactly as before. A read-only Claude row (type
    // "readonly") falls through to save() too, harmlessly: it is never in
    // root.edits, so save() just reports "Nothing changed" if it was the
    // only thing touched.
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

    // Runs the hyprctl side of a window-manager row's change, and only
    // ever after writer.onExited below has confirmed that same row's
    // persist to settings.nix actually landed. A key wm.js does not map
    // (every non-WM field) is a no-op: hyprctlArgs returns null and there is
    // nothing to run, which is what lets this be called unconditionally
    // from one shared path rather than a second branch that already has to
    // know which keys are WM ones.
    function applyLive(key: string, value: var): void {
        const args = Wm.hyprctlArgs(key, value);
        if (args === null)
            return;

        applier.command = args;
        applier.running = false;
        applier.running = true;
    }

    // A "Saved" acknowledgement is meant to be noticed, not lived with.
    // This is what makes it transient. Cleared on anything else so a
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

        // Open straight onto one page. This is what lets SUPER+W and SUPER+M
        // stay one keystroke after the wallpaper picker and monitor arranger
        // were folded into Settings: without it, consolidation would have
        // cost the user an extra navigation every time, which is a
        // regression wearing consolidation's clothes.
        //
        // An unknown page id is ignored rather than treated as an error.
        // The panel still opens, on whatever page load() settled on. A typo
        // in a keybind should not make Settings unopenable.
        function openAt(page: string): void {
            root.load();
            if (root.navPages.some(p => p.id === page)) {
                root.activePage = page;
            }
            window.visible = true;
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

        // What next() just tried to persist, read back in onExited below
        // so the live-apply path acts on the SAME key/value the just-exited
        // `global-settings set` call carried, not whatever root.edits
        // happens to hold by the time the process reports back.
        property string lastKey: ""
        property var lastValue: null

        function next(): void {
            if (writer.pending.length === 0) {
                root.status = "Saved";
                root.load();
                return;
            }

            const key = writer.pending[0];
            writer.pending = writer.pending.slice(1);

            const value = root.edits[key];
            writer.lastKey = key;
            writer.lastValue = value;
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

            // Persist first, apply second, never the reverse: applyLive
            // only runs once this process's own exit code has confirmed the
            // write landed, so a rejected field can never leave the
            // compositor showing a value settings.nix disagrees with.
            root.applyLive(writer.lastKey, writer.lastValue);
            writer.next();
        }
        // qmllint enable signal-handler-parameters
    }

    // The window-manager live-apply path's own process, fire-and-forget:
    // `hyprctl keyword` either takes immediately or the field simply does
    // not show up until the next `hyprctl reload`, neither of which the
    // settings panel needs to gate anything else on.
    Process {
        id: applier
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
            // focus back afterwards. panel.forceActiveFocus() runs on
            // onVisibleChanged and nowhere else, so from that point on the
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
            // this ever sees them. TextInput's own native handling, driven
            // with real key events in tests/qml/tst_focus_grammar.qml, is why
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
                    id: headerRow

                    Layout.fillWidth: true
                    // preferredHeight alone is a request, not a cap: with no
                    // sibling claiming the slack, a ColumnLayout will happily
                    // stretch this row to fill the panel. Both children below
                    // anchor their content to verticalCenter, so a stretched
                    // header does not look tall. It looks like the title and
                    // the search field have slid to the middle of the panel,
                    // which is exactly the symptom this pins.
                    Layout.preferredHeight: Theme.settingsHeaderHeight
                    Layout.maximumHeight: Theme.settingsHeaderHeight

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

                            // No `text: root.query` binding here. A live
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
                    id: bodyRow

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

                        // QML layouts do not clip. When a page's content is
                        // taller than the space it was given, the children
                        // simply overflow, and because this Item sits inside
                        // a Panel that draws no boundary of its own, that
                        // overflow renders *outside the panel*, over the
                        // desktop. Observed exactly that: the Wallpaper page's
                        // rows painting below the panel's bottom edge.
                        // Clipping keeps a too-tall page ugly instead of
                        // broken.
                        clip: true

                        // Scrollable, because clipping alone turns "content
                        // spills onto the desktop" into "content is
                        // unreachable". The Keyboard page lists every SUPER
                        // bind and runs well past the panel's height. The
                        // Flickable owns the scrolling; the ColumnLayout
                        // inside keeps doing the layout, sized to the
                        // viewport's width and to its own natural height.
                        Flickable {
                            id: contentFlick

                            anchors.fill: parent
                            anchors.margins: 20

                            contentWidth: width
                            contentHeight: contentColumn.implicitHeight
                            // StopAtBounds, not the default elastic overscroll:
                            // this is a settings form, not a touch surface, and
                            // rubber-banding a form reads as jank rather than
                            // as feedback.
                            boundsBehavior: Flickable.StopAtBounds
                            flickableDirection: Flickable.VerticalFlick

                        ColumnLayout {
                            id: contentColumn

                            width: contentFlick.width

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

                                visible: !root.showingKeyboardPage && !root.showingSecurityPage && root.visibleRows.length > 0
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
                                            // Data-dep: the AI page's Ollama
                                            // endpoint/default-model rows only
                                            // mean something while aiOllama
                                            // itself is on (pages.js's
                                            // DEPENDS_ON). Every other row
                                            // has no parent, and dependsOn
                                            // defaults to enabled for exactly
                                            // that case.
                                            dependent: Pages.dependencyKeyFor(fieldRow.modelData.key) !== null
                                            dependsOn: {
                                                const parentKey = Pages.dependencyKeyFor(fieldRow.modelData.key);
                                                return parentKey === null ? true : root.valueOfKey(parentKey) === true;
                                            }

                                            onClicked: {
                                                root.selected = fieldRow.index;
                                                root.activate();
                                            }

                                            Field {
                                                id: valueField

                                                visible: fieldRow.modelData.type === "text"
                                                width: 220

                                                // `?? ""` because a delegate
                                                // outlives its model entry for
                                                // a frame when the page
                                                // changes: modelData is still
                                                // bound but its field is gone,
                                                // valueOf answers undefined,
                                                // and QML warns "Unable to
                                                // assign [undefined] to
                                                // QString" on every switch.
                                                text: root.valueOf(fieldRow.modelData) ?? ""

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

                                            // Bounds come straight from the
                                            // dump payload's min/max/step,
                                            // never a constant here. See
                                            // rust/settings-global/src/menu.rs's
                                            // own comment on why those fields
                                            // reach the payload at all.
                                            Slider {
                                                visible: fieldRow.modelData.type === "number"

                                                from: fieldRow.modelData.min ?? 0
                                                to: fieldRow.modelData.max ?? 100
                                                stepSize: fieldRow.modelData.step ?? 0
                                                // `?? 0` for the same reason
                                                // the text field above needs
                                                // `?? ""`, with the default
                                                // typed to match: a slider
                                                // handed undefined warns about
                                                // a double, not a string.
                                                value: root.valueOf(fieldRow.modelData) ?? 0
                                                onMoved: value => root.edit(fieldRow.modelData.key, value)
                                            }

                                            // Same reasoning as Slider above:
                                            // the option list is whatever the
                                            // dump payload's own `options`
                                            // array says, not a second copy
                                            // of it hand-kept in QML.
                                            Select {
                                                visible: fieldRow.modelData.type === "select"
                                                width: 200

                                                options: (fieldRow.modelData.options ?? []).map(o => ({
                                                            label: o,
                                                            value: o
                                                        }))
                                                value: root.valueOf(fieldRow.modelData)
                                                onActivated: value => root.edit(fieldRow.modelData.key, value)
                                            }

                                            // A value from a different store
                                            // entirely (~/.claude/settings.json,
                                            // see fieldDescriptions'
                                            // claudeModel entry). There is
                                            // nothing here for edit()/save()
                                            // to reach, so this is a label,
                                            // not a control.
                                            Text {
                                                visible: fieldRow.modelData.type === "readonly"

                                                text: fieldRow.modelData.value ?? ""
                                                color: Theme.muted

                                                font.family: Theme.fontMono
                                                font.pointSize: Theme.settingsRowDescFontSize
                                            }

                                            // The Proton row's own control: a
                                            // bare chevron rather than a
                                            // field, since Enter/click on
                                            // this row opens a page instead
                                            // of editing a value.
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

                            // Keyboard page: keybinds.json rendered directly,
                            // the same read-only grouped list Cheatsheet.qml
                            // already shows for SUPER+/, reused rather than
                            // parsed a second way, per the task brief. No row
                            // here reaches edit()/save(): the page carries no
                            // state of its own at all.
                            ColumnLayout {
                                Layout.fillWidth: true
                                Layout.fillHeight: true

                                visible: root.showingKeyboardPage
                                spacing: Theme.settingsGroupGap

                                Repeater {
                                    model: root.keyboardGroups

                                    delegate: ColumnLayout {
                                        id: kbGroup

                                        required property var modelData

                                        Layout.fillWidth: true
                                        spacing: Theme.settingsRowGap

                                        Text {
                                            text: kbGroup.modelData.name
                                            color: Theme.muted

                                            font.family: Theme.fontUi
                                            font.pointSize: Theme.settingsGroupFontSize
                                            font.bold: true
                                        }

                                        Repeater {
                                            model: kbGroup.modelData.items

                                            delegate: SettingsRow {
                                                id: kbRow

                                                required property var modelData

                                                Layout.fillWidth: true

                                                title: kbRow.modelData.desc

                                                Text {
                                                    text: kbRow.modelData.key
                                                    color: Theme.fg

                                                    font.family: Theme.fontMono
                                                    font.pointSize: Theme.settingsRowDescFontSize
                                                    font.bold: true
                                                }
                                            }
                                        }
                                    }
                                }

                                Item {
                                    Layout.fillHeight: true
                                }
                            }

                            // Security page: a Loader, not an inline tag.
                            // settings/pages/security.qml's filename starts
                            // lowercase on purpose (matching the task
                            // brief's own path), and a lowercase filename
                            // cannot be a QML type name, so it is loaded by
                            // source URL instead of imported. `active`
                            // ties the component's lifetime to the tab
                            // itself: leaving the page destroys it, so
                            // coming back always re-runs `report --json`
                            // and `policy dump` fresh rather than showing
                            // whatever this Settings session first read,
                            // which matters more here than it does for any
                            // other page. A security dashboard that goes
                            // stale while the panel sits open is worse than
                            // one that costs a re-read on every visit.
                            Loader {
                                Layout.fillWidth: true
                                // Not fillHeight: inside a Flickable the
                                // column's height comes from its children's
                                // implicit heights, so fillHeight resolves to
                                // zero and the page loads but renders nothing.
                                // The viewport's height is what "fill" means
                                // here.
                                Layout.preferredHeight: contentFlick.height

                                active: root.showingSecurityPage
                                visible: active
                                source: "pages/security.qml"
                            }

                            // Wallpaper: same Loader-by-URL shape as Security
                            // above. `item.picker` is assigned rather than the
                            // page building its own. wallpaper/Picker.qml is
                            // the single instance shell.qml keeps alive,
                            // because Rotation.qml's hourly pick and
                            // `qs ipc call wallpaper apply` drive it whether
                            // or not this page is mounted. A second Picker
                            // here would mean two apply queues, two output
                            // states, and an accent retint racing itself.
                            Loader {
                                Layout.fillWidth: true
                                Layout.preferredHeight: contentFlick.height

                                active: root.showingWallpaperPage
                                visible: active
                                source: "pages/wallpaper.qml"

                                onLoaded: item.picker = root.wallpaperPicker
                            }

                            Loader {
                                Layout.fillWidth: true
                                Layout.preferredHeight: contentFlick.height

                                active: root.showingDisplaysPage
                                visible: active
                                source: "pages/displays.qml"
                            }

                            Item {
                                Layout.fillWidth: true
                                // Same reason as the page Loaders above: a
                                // fillHeight item is zero-height inside a
                                // Flickable, and a zero-height box has nothing
                                // for EmptyState to centre itself in.
                                Layout.preferredHeight: contentFlick.height

                                visible: !root.showingKeyboardPage && !root.showingSecurityPage && root.visibleRows.length === 0

                                EmptyState {
                                    anchors.centerIn: parent

                                    message: root.emptyMessage()
                                }
                            }

                            // A trailing spacer that used to absorb the
                            // column's slack. Inside a Flickable there is no
                            // slack to absorb, the column is exactly as tall
                            // as its content, so it keeps only its old job of
                            // marking the end of the rows.
                            Item {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 0

                                visible: !root.showingKeyboardPage && !root.showingSecurityPage && root.visibleRows.length > 0
                            }
                        }
                        }

                        // The second surface. Built once and hidden rather
                        // than created per visit, which is why leaveProton()
                        // clears its fields by hand. Occupies the same
                        // content column the form uses. The sidebar band
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
