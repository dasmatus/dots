// Row assembly for the crumb dropdown, driven with a fixed listing and no
// window — CrumbMenu.qml itself reaches Quickshell.Io, which
// qmltestrunner cannot load, so every behaviour worth pinning has to be
// reachable through crumbmenu.js alone.
import QtQuick
import QtTest
import "../../nix/home/desktop/quickshell/qml/files/crumbmenu.js" as CrumbMenu

TestCase {
    name: "FilesCrumbMenu"

    property var listing: [
        { name: "Dokumente", isDir: true },
        { name: "Downloads", isDir: true },
        { name: "readme.md", isDir: false },
        { name: "report.pdf", isDir: false }
    ]

    function titles(rows) {
        return rows.map(row => row.title);
    }

    function test_the_first_row_opens_the_crumbs_own_directory() {
        const rows = CrumbMenu.crumbMenuRows("/home/matus", listing, 10);

        compare(rows[0].kind, "open");
        compare(rows[0].subtitle, "/home/matus");
    }

    function test_the_open_row_is_present_even_for_an_empty_directory() {
        const rows = CrumbMenu.crumbMenuRows("/home/matus/empty", [], 10);

        compare(rows.length, 1);
        compare(rows[0].kind, "open");
    }

    // Under the cap, every entry shows and there is nothing to report as
    // left out.
    function test_every_entry_shows_when_the_listing_is_under_the_cap() {
        const rows = CrumbMenu.crumbMenuRows("/home/matus", listing, 10);

        compare(rows.filter(row => row.kind === "more").length, 0);
        compare(titles(rows.filter(row => row.kind === "entry")), ["Dokumente", "Downloads", "readme.md", "report.pdf"]);
    }

    // Over the cap, the trailer names exactly what got cut, and nothing
    // silently disappears.
    function test_a_listing_over_the_cap_is_capped_with_a_trailer_naming_the_rest() {
        const rows = CrumbMenu.crumbMenuRows("/home/matus", listing, 2);
        const entries = rows.filter(row => row.kind === "entry");
        const trailer = rows.filter(row => row.kind === "more");

        compare(entries.length, 2);
        compare(titles(entries), ["Dokumente", "Downloads"]);
        compare(trailer.length, 1);
        compare(trailer[0].title, "2 more not shown");
    }

    // A listing exactly at the cap needs no trailer: nothing was left out.
    function test_a_listing_exactly_at_the_cap_gets_no_trailer() {
        const rows = CrumbMenu.crumbMenuRows("/home/matus", listing, listing.length);

        compare(rows.filter(row => row.kind === "more").length, 0);
    }

    // A shown row's index has to land on the same element of the ORIGINAL
    // listing even after the cap slices it, since that is what CrumbMenu.qml
    // reads root.entries[row.index] against.
    function test_a_shown_entrys_index_still_points_at_the_right_element() {
        const rows = CrumbMenu.crumbMenuRows("/home/matus", listing, 3);
        const entries = rows.filter(row => row.kind === "entry");

        compare(listing[entries[2].index].name, "readme.md");
    }

    function test_crumbentries_slices_from_the_front() {
        compare(CrumbMenu.crumbEntries(listing, 2).map(entry => entry.name), ["Dokumente", "Downloads"]);
        compare(CrumbMenu.crumbEntries(listing, 100).length, listing.length);
    }

    function test_crumbremainder_never_goes_negative() {
        compare(CrumbMenu.crumbRemainder(listing, 2), 2);
        compare(CrumbMenu.crumbRemainder(listing, 100), 0);
        compare(CrumbMenu.crumbRemainder([], 0), 0);
    }

    // Every row the popup can show must carry a colour naming a real Theme
    // property, exactly as tst_files_commands.qml pins for the other two
    // surfaces built on the same {kind, glyph, colour} row shape.
    function test_every_row_names_a_real_palette_token() {
        const known = ["accent", "fg", "blue", "cyan", "green", "magenta", "red", "yellow", "orange", "dim"];
        const rows = CrumbMenu.crumbMenuRows("/home/matus", listing, 2);

        for (const row of rows)
            verify(known.indexOf(row.colour) >= 0, `${row.title} uses an unknown token`);
    }
}
