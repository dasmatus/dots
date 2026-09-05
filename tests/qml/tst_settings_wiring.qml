// Reachability test, tst_pill_wiring.qml's own pattern: proves Settings.qml
// actually builds its shell out of the pieces this task shipped — the sidebar's
// EdgeStrip, the row grammar's SettingsRow, search.js's pure search(), the
// sticky footer's Save control — rather than shipping them unused beside a
// hand-rolled shell that duplicates what they do. It also pins that the
// pre-existing integrations (the IpcHandler, the dump/set processes, the
// edits-reassigned-not-mutated rule, the keyboard grammar) survived the
// rebuild, the same promise tst_proton.qml already holds for the Proton page
// specifically.
//
// qmltestrunner cannot instantiate Settings.qml itself: it reaches
// PanelWindow, WlrLayershell, IpcHandler and Quickshell.Io's Process, all
// Quickshell types tests/README.md rules out. So this reads the shipped
// source as text instead, comment-stripped through sourcescan.js for the
// reason its own header gives — a comment that happens to mention a binding
// by name must not be able to stand in for the binding itself.
import QtQuick
import QtTest
import "sourcescan.js" as Scan

TestCase {
    name: "SettingsWiring"

    function readSource(relPath) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl(relPath), false);
        xhr.send();
        compare(xhr.status, 200, relPath + " must be readable (needs QML_XHR_ALLOW_FILE_READ=1)");
        return Scan.stripComments(xhr.responseText);
    }

    function settingsSource() {
        return readSource("../../nix/home/desktop/quickshell/qml/settings/Settings.qml");
    }

    // --- integrations the task brief required preserving verbatim ---

    function test_ipc_handler_targets_settings_with_open_close_toggle() {
        const handler = Scan.blockAfter(settingsSource(), "IpcHandler {");
        verify(handler.indexOf("target: \"settings\"") !== -1, "the IpcHandler must keep targeting \"settings\"");
        verify(handler.indexOf("function open(): void {") !== -1);
        verify(handler.indexOf("function close(): void {") !== -1);
        verify(handler.indexOf("function toggle(): void {") !== -1);
    }

    function test_loader_still_dumps_and_writer_still_sets_per_field() {
        const src = settingsSource();
        verify(src.indexOf("[\"global-settings\", \"dump\"]") !== -1, "the loader must still run global-settings dump");
        verify(src.indexOf("\"global-settings\", \"set\", key,") !== -1, "the writer must still set one field per process, so a rejected field fails alone");
    }

    function test_edits_are_reassigned_not_mutated() {
        const edit = Scan.blockAfter(settingsSource(), "function edit(key: string, value: var): void {");
        verify(edit.indexOf("Object.assign({}, root.edits)") !== -1, "edit() must reassign root.edits through a copy — QML does not see an in-place object mutation");
    }

    // The generic claim (a focused field swallows j/k while the arrows still
    // bubble) is tst_focus_grammar.qml's job; this only pins that Settings.qml
    // still wires the same shape of handler onto its panel.
    function test_keyboard_grammar_is_wired_on_the_panel() {
        const src = settingsSource();
        verify(src.indexOf("Keys.onUpPressed: root.moveSelection(-1)") !== -1);
        verify(src.indexOf("Keys.onDownPressed: root.moveSelection(1)") !== -1);
        verify(src.indexOf("Keys.onReturnPressed: root.activate()") !== -1);
        verify(src.indexOf("Keys.onEnterPressed: root.activate()") !== -1);
        verify(src.indexOf("event.key === Qt.Key_J") !== -1, "the j alias must still be wired");
        verify(src.indexOf("event.key === Qt.Key_K") !== -1, "the k alias must still be wired");
    }

    // --- the new shell's own reusable pieces, actually reached ---

    function test_shell_builds_on_panel_directly() {
        const src = settingsSource();
        verify(src.indexOf("Panel {") !== -1, "the shell must build on common/Panel.qml, the translucent rounded surface Chrome itself wraps");
        verify(src.indexOf("id: panel") !== -1);
    }

    // The settings panel is a fraction of the screen, like the launcher —
    // not sized off its own implicitHeight the way Chrome's three other
    // callers are, which would make the panel grow or shrink with how much
    // of the sidebar/content happens to be built on any given day.
    function test_panel_is_sized_from_the_palette_factors() {
        const src = settingsSource();
        verify(src.indexOf("Theme.settingsPanelWidthFactor") !== -1, "the panel's width must come from the palette factor, not a hardcoded pixel width");
        verify(src.indexOf("Theme.settingsPanelHeightFactor") !== -1);
    }

    function test_sidebar_nav_marks_the_active_entry_with_edge_strip() {
        const sidebar = Scan.blockAfter(settingsSource(), "delegate: Item {");
        verify(sidebar.indexOf("EdgeStrip {") !== -1, "the sidebar's active nav entry must be marked with EdgeStrip, the task brief's own idiomatic choice — not a hand-rolled bar");
    }

    function test_search_field_is_filtered_through_search_js() {
        const src = settingsSource();
        verify(src.indexOf("import \"search.js\" as Search") !== -1);
        verify(src.indexOf("Search.search(root.searchIndex, root.query)") !== -1, "the search field must be filtered through search.js's pure search(), the testable seam — not a hand-rolled scan living only in QML");
    }

    function test_footer_carries_a_save_control_and_a_transient_acknowledgement() {
        const src = settingsSource();
        verify(src.indexOf("onClicked: root.save()") !== -1, "the sticky footer must still carry a Save control wired to root.save()");
        verify(src.indexOf("root.status === \"Saved\"") !== -1, "the footer must distinguish the transient \"Saved\" acknowledgement from an ordinary status line");
    }

    function test_identity_rows_use_the_shared_row_grammar() {
        verify(settingsSource().indexOf("delegate: SettingsRow {") !== -1, "the Identity page's rows must be built from SettingsRow, not a page-local reimplementation of the row grammar");
    }

    function test_a_page_with_nothing_to_show_renders_the_empty_state() {
        verify(settingsSource().indexOf("EmptyState {") !== -1, "a stub page or an empty search result must render EmptyState, not go blank");
    }
}
