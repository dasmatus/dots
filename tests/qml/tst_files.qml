// Pure listing-and-path arithmetic for Pane.qml, driven with captured
// `find -maxdepth 1 -printf '%Y\t%s\t%T@\t%f\n'` output. No Process, no
// filesystem, no compositor.
//
// The listing moved off `ls -1Ap` when a row grew a size and a modified
// column: `ls -l` only exposes those inside padded, locale-formatted
// columns, while `-printf` names the fields it emits. These tests are
// written against that format, so a line is type, size, mtime, name.
import QtQuick
import QtTest
import "../../nix/home/quickshell/qml/files/files.js" as Files

TestCase {
    name: "Files"

    function line(type, size, mtime, name) {
        return `${type}\t${size}\t${mtime}\t${name}\n`;
    }

    function test_parselisting_reads_the_type_size_and_mtime_fields() {
        const entries = Files.parseListing(line("d", 4096, 1756819200, "Documents") + line("f", 812, 1756819300, "readme.txt"));

        compare(entries.length, 2);
        compare(entries[0].name, "Documents");
        compare(entries[0].isDir, true);
        compare(entries[1].name, "readme.txt");
        compare(entries[1].isDir, false);
        compare(entries[1].size, 812);
        compare(entries[1].mtime, 1756819300);
    }

    // `%Y` reports the type after following a symlink, so a link pointing at
    // a directory arrives as "d" and behaves as the directory it names. That
    // is what `ls -p`'s trailing slash used to convey.
    function test_parselisting_treats_a_symlink_to_a_directory_as_a_directory() {
        const entries = Files.parseListing(line("d", 12, 1756819200, "link-to-dir"));

        compare(entries[0].isDir, true);
    }

    function test_parselisting_drops_blank_lines() {
        compare(Files.parseListing("\n\n").length, 0);
    }

    // Directories first, then case-insensitively by name, because `find` has
    // no equivalent of `ls --group-directories-first` and the ordering is
    // this file's job now.
    function test_parselisting_groups_directories_first_then_sorts_by_name() {
        const text = line("f", 1, 1, "zebra.txt") + line("f", 1, 1, "apple.txt") + line("d", 1, 1, "Work") + line("d", 1, 1, "admin");

        const names = Files.parseListing(text).map(entry => entry.name);

        compare(names, ["admin", "Work", "apple.txt", "zebra.txt"]);
    }

    // A byte comparison puts "Öffentlich" after "Z"; this tree's home has
    // that exact directory in it, so the comparator is locale-aware.
    function test_sortentries_places_an_umlaut_beside_its_base_letter() {
        const entries = [
            { name: "Zebra", isDir: false },
            { name: "Öffentlich", isDir: false },
            { name: "Ordner", isDir: false }
        ];

        const names = Files.sortEntries(entries).map(entry => entry.name);

        compare(names, ["Öffentlich", "Ordner", "Zebra"]);
    }

    function test_sortentries_does_not_mutate_its_argument() {
        const entries = [{ name: "b", isDir: false }, { name: "a", isDir: false }];

        Files.sortEntries(entries);

        compare(entries[0].name, "b");
    }

    // A leading dot is the whole convention; `find` has no equivalent of
    // `ls -A`, so the filter lives here and the pane can toggle it without
    // re-running the listing.
    function test_a_leading_dot_is_what_marks_an_entry_hidden() {
        verify(Files.isHidden({ name: ".bashrc" }));
        verify(Files.isHidden({ name: ".config" }));
        verify(!Files.isHidden({ name: "readme.md" }));
        verify(!Files.isHidden({ name: "a.b.c" }));
    }

    function test_hidden_entries_are_dropped_unless_asked_for() {
        const entries = [{ name: ".config" }, { name: "Dokumente" }, { name: ".bashrc" }];

        compare(Files.visibleEntries(entries, false).length, 1);
        compare(Files.visibleEntries(entries, false)[0].name, "Dokumente");
        compare(Files.visibleEntries(entries, true).length, 3);
    }

    function test_join_handles_the_root_directory() {
        compare(Files.join("/", "home"), "/home");
        compare(Files.join("/home/matus", "Documents"), "/home/matus/Documents");
    }

    function test_parentof_stops_at_root() {
        compare(Files.parentOf("/"), "/");
        compare(Files.parentOf("/home"), "/");
        compare(Files.parentOf("/home/matus"), "/home");
    }

    // Nothing on this path runs a name through a shell, see files.js's own
    // header, so a space, a quote or a leading dash is just a byte inside
    // the string. This is what proves that rather than assuming it: the
    // three characters together, still in the name field, come back as one
    // untouched entry.
    function test_parselisting_keeps_spaces_quotes_and_a_leading_dash_verbatim() {
        const entries = Files.parseListing(line("f", 4, 1, "-my \"quoted\" file.txt"));

        compare(entries.length, 1);
        compare(entries[0].name, "-my \"quoted\" file.txt");
        compare(entries[0].isDir, false);
    }

    // A tab inside a name would land in the name field, which is why the
    // name is joined back from every field past the third rather than being
    // indexed. The entry keeps its whole name instead of losing the tail.
    function test_parselisting_keeps_a_tab_inside_a_name() {
        const entries = Files.parseListing("f\t4\t1\tweird\tname.txt\n");

        compare(entries.length, 1);
        compare(entries[0].name, "weird\tname.txt");
    }

    function test_join_preserves_spaces_quotes_and_a_leading_dash() {
        compare(Files.join("/mnt/usb", "-my \"quoted\" file.txt"), "/mnt/usb/-my \"quoted\" file.txt");
    }

    function test_parentof_is_unaffected_by_special_characters_in_the_leaf() {
        compare(Files.parentOf("/mnt/usb/-my \"quoted\" file.txt"), "/mnt/usb");
    }

    // The format has no per-entry length prefix, only a newline between
    // entries, so a name containing a raw newline is indistinguishable in
    // the captured text from two entries. The tail has no type, size or
    // mtime field, so it is dropped rather than becoming a phantom file —
    // which the old `ls` parse did produce.
    function test_parselisting_drops_the_tail_of_a_name_containing_a_newline() {
        const entries = Files.parseListing("f\t4\t1\tweird\nname.txt\n");

        compare(entries.length, 1);
        compare(entries[0].name, "weird");
    }

    function test_listingargv_passes_the_path_as_its_own_element() {
        const argv = Files.listingArgv("/mnt/usb/-weird dir");

        compare(argv[0], "find");
        compare(argv[1], "/mnt/usb/-weird dir");
        verify(argv.indexOf("-maxdepth") > 0);
    }

    function test_formatsize_uses_binary_units_above_a_kilobyte() {
        compare(Files.formatSize({ isDir: false, size: 812 }), "812 B");
        compare(Files.formatSize({ isDir: false, size: 1024 }), "1.0 KB");
        compare(Files.formatSize({ isDir: false, size: 4404 }), "4.3 KB");
        compare(Files.formatSize({ isDir: false, size: 1048576 }), "1.0 MB");
    }

    // `find` reports a directory's own inode size, not the size of what it
    // holds, so printing it would claim every folder is 4.0 KB.
    function test_formatsize_reports_no_size_for_a_directory() {
        compare(Files.formatSize({ isDir: true, size: 4096 }), "—");
    }

    // Expected values are built through the same Date the function uses, so
    // the assertion holds in whatever timezone the runner has.
    function test_formattime_shows_a_clock_for_a_recent_entry() {
        const mtime = 1756819200;
        const when = new Date(mtime * 1000);
        const now = mtime * 1000 + 24 * 60 * 60 * 1000;

        const hours = String(when.getHours()).padStart(2, "0");
        const minutes = String(when.getMinutes()).padStart(2, "0");

        verify(Files.formatTime({ mtime: mtime }, now).endsWith(`${hours}:${minutes}`));
    }

    // Past the cutoff the clock stops mattering and the year starts to,
    // which is the same trade `ls -l` makes.
    function test_formattime_shows_a_year_for_an_old_entry() {
        const mtime = 1756819200;
        const when = new Date(mtime * 1000);
        const now = mtime * 1000 + 400 * 24 * 60 * 60 * 1000;

        verify(Files.formatTime({ mtime: mtime }, now).endsWith(String(when.getFullYear())));
    }
}
