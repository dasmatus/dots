// Rows for the `:` command line and the right-click menu, driven with a
// fixed listing and no window.
//
// The behaviour worth pinning is which rows exist at all: the toolbar these
// replaced offered Copy, Move, Rename and Trash whether or not anything was
// selected, and clicking one with an empty selection did nothing. Paste has
// the same problem in reverse, so it stays hidden until the clipboard holds
// something.
import QtQuick
import QtTest
import "../../nix/home/desktop/quickshell/qml/files/commands.js" as Commands

TestCase {
    name: "FilesCommands"

    property var listing: [
        { name: "Dokumente", isDir: true },
        { name: "Downloads", isDir: true },
        { name: "readme.md", isDir: false },
        { name: "report.pdf", isDir: false }
    ]

    property var selection: ({ name: "readme.md", isDir: false })
    property var clipboard: ({ dir: "/home/matus", name: "readme.md", mode: "copy" })

    function titles(rows) {
        return rows.map(row => row.title);
    }

    function test_without_a_selection_or_a_clipboard_only_the_two_that_need_neither_are_offered() {
        compare(titles(Commands.actionRows(null, null, false)), ["New Folder", "Show Dotfiles"]);
    }

    function test_a_selection_unlocks_the_actions_that_need_one() {
        const found = titles(Commands.actionRows(selection, null, false));

        compare(found, ["Copy", "Cut", "Rename", "New Folder", "Trash", "Show Dotfiles"]);
    }

    // Paste with an empty clipboard would be a row that does nothing, which
    // is the failure mode the old toolbar had.
    function test_paste_appears_only_once_the_clipboard_holds_something() {
        verify(titles(Commands.actionRows(null, null, false)).indexOf("Paste") < 0);
        verify(titles(Commands.actionRows(null, clipboard, false)).indexOf("Paste") >= 0);
    }

    function test_paste_names_what_it_would_land() {
        const rows = Commands.actionRows(null, clipboard, false);
        const paste = rows.filter(row => row.id === "paste")[0];

        compare(paste.subtitle, "readme.md");
    }

    // The dotfile row is a toggle, so it has to say what it will do next
    // rather than what the current state is.
    function test_the_dotfile_row_names_the_action_not_the_state() {
        verify(titles(Commands.actionRows(null, null, false)).indexOf("Show Dotfiles") >= 0);
        verify(titles(Commands.actionRows(null, null, true)).indexOf("Hide Dotfiles") >= 0);
    }

    function test_an_action_names_the_entry_it_would_act_on() {
        compare(Commands.actionRows(selection, null, false)[0].subtitle, "readme.md");
    }

    function test_every_entry_becomes_a_row_carrying_its_own_glyph() {
        const rows = Commands.entryRows(listing);

        compare(rows.length, 4);
        compare(rows[0].title, "Dokumente");
        compare(rows[0].subtitle, "folder");
        compare(rows[2].subtitle, "file");
        verify(rows[0].glyph !== rows[2].glyph);
    }

    // The index travels on the row because activating an entry has to reach
    // back into the pane's own list, not into a copy of it.
    function test_an_entry_row_carries_its_index_into_the_listing() {
        const rows = Commands.entryRows(listing);

        compare(rows[2].index, 2);
        compare(listing[rows[2].index].name, "readme.md");
    }

    // `/` and `:` are separate lines. Each sees only its own kind, which is
    // what stops a directory called "Copy" from outranking the Copy command
    // and vice versa.
    function test_the_search_line_sees_entries_and_no_actions() {
        const found = titles(Commands.entriesFor("do", listing));

        verify(found.indexOf("Dokumente") >= 0);
        verify(found.indexOf("Downloads") >= 0);
        verify(found.indexOf("Copy") < 0);
    }

    function test_the_command_line_sees_actions_and_no_entries() {
        const found = titles(Commands.actionsFor("do", selection, null, false));

        verify(found.indexOf("Dokumente") < 0);
        verify(found.indexOf("Downloads") < 0);
    }

    // Prefix before substring, the same order Launcher.qml sorts its own
    // results in, so typing the start of a name reaches it first.
    // The `:` line still ranks a prefix ahead of a mere substring, the way
    // the launcher does. It builds its own list and never goes near the
    // index, so this is the surface `filtered`'s sort still serves.
    function test_a_prefix_match_outranks_a_substring_match() {
        compare(titles(Commands.actionsFor("n", selection, null, false)), ["New Folder", "Rename"]);
    }

    // The `/` line does not sort. Its rows arrive already ranked by
    // index.js, which puts an exact name first and then the directory you
    // are standing in, and sorting again on the title alone here would
    // undo exactly that — which is the only thing making a search across
    // all of $HOME usable from inside a project.
    // tst_files_index.qml pins the ordering itself.
    function test_the_search_line_keeps_the_order_it_was_handed() {
        const rows = Commands.entriesFor("re", [{ name: "libreoffice", isDir: true }, { name: "readme.md", isDir: false }]);

        compare(titles(rows), ["libreoffice", "readme.md"]);
    }

    // The wildcards files.js documents as deliberate never used to reach a
    // row: `find` returned readme.md for `*.md`, and then this line's
    // substring test asked whether "readme.md" contains "*.md" and threw
    // it away again.
    function test_the_search_line_keeps_a_wildcard_result() {
        const rows = Commands.entriesFor("*.md", [{ name: "readme.md", isDir: false }, { name: "notes.txt", isDir: false }]);

        compare(titles(rows), ["readme.md"]);
    }

    function test_the_filter_ignores_case() {
        compare(titles(Commands.actionsFor("RENAME", selection, null, false)), ["Rename"]);
    }

    function test_a_query_matching_nothing_returns_nothing() {
        compare(Commands.actionsFor("zzzz", selection, null, false).length, 0);
        compare(Commands.entriesFor("zzzz", listing).length, 0);
    }

    function test_an_empty_query_offers_the_whole_side() {
        compare(Commands.entriesFor("", listing).length, listing.length);
        compare(Commands.actionsFor("", selection, clipboard, false).length, 7);
    }

    // The menu is already pointing at something, so it carries the actions
    // and none of the entries. Both surfaces come off actionRows, which is
    // what stops them drifting apart.
    function test_the_menu_offers_the_actions_and_no_entries() {
        const rows = Commands.menuRows(selection, clipboard, false);

        compare(rows.filter(row => row.kind !== "action").length, 0);
        compare(titles(rows), titles(Commands.actionRows(selection, clipboard, false)));
    }

    // Every row the surfaces can show must carry a colour naming a real
    // Theme property, because the QML resolves it as `Theme[name]`.
    function test_every_row_names_a_real_palette_token() {
        const known = ["accent", "fg", "blue", "cyan", "green", "magenta", "red", "yellow", "orange", "dim"];

        const all = Commands.actionsFor("", selection, clipboard, false).concat(Commands.entriesFor("", listing));

        for (const row of all)
            verify(known.indexOf(row.colour) >= 0, `${row.title} uses an unknown token`);
    }
}
