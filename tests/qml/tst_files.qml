// Pure listing-and-path arithmetic for Pane.qml, driven with captured
// `ls -1Ap --group-directories-first` output. No Process, no filesystem,
// no compositor.
import QtQuick
import QtTest
import "../../nix/home/quickshell/qml/files/files.js" as Files

TestCase {
    name: "Files"

    function test_parselisting_strips_the_trailing_slash_ls_p_appends() {
        const entries = Files.parseListing("Documents/\nDownloads/\nreadme.txt\n");

        compare(entries.length, 3);
        compare(entries[0].name, "Documents");
        compare(entries[0].isDir, true);
        compare(entries[2].name, "readme.txt");
        compare(entries[2].isDir, false);
    }

    function test_parselisting_drops_blank_lines() {
        compare(Files.parseListing("\n\n").length, 0);
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
    // three characters together, still on one `ls -1Ap` line, come back as
    // one untouched entry.
    function test_parselisting_keeps_spaces_quotes_and_a_leading_dash_verbatim() {
        const entries = Files.parseListing("-my \"quoted\" file.txt\n");

        compare(entries.length, 1);
        compare(entries[0].name, "-my \"quoted\" file.txt");
        compare(entries[0].isDir, false);
    }

    function test_join_preserves_spaces_quotes_and_a_leading_dash() {
        compare(Files.join("/mnt/usb", "-my \"quoted\" file.txt"), "/mnt/usb/-my \"quoted\" file.txt");
    }

    function test_parentof_is_unaffected_by_special_characters_in_the_leaf() {
        compare(Files.parentOf("/mnt/usb/-my \"quoted\" file.txt"), "/mnt/usb");
    }

    // `ls`'s output has no per-entry length prefix, only a newline between
    // entries, so a name that itself contains a raw newline byte is
    // indistinguishable in the captured text from two names. This asserts
    // the actual, observed behaviour, two entries, neither one throwing,
    // rather than a byte-perfect round trip no newline-delimited format
    // could deliver.
    function test_parselisting_splits_a_literal_newline_inside_a_name_into_two_entries() {
        const entries = Files.parseListing("weird\nname.txt\n");

        compare(entries.length, 2);
        compare(entries[0].name, "weird");
        compare(entries[1].name, "name.txt");
    }
}
