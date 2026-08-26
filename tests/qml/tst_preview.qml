// Launcher preview pane arithmetic.
//
// fd marks directories with a trailing slash, which is what makes the
// directory case free — and also what broke the row title before the pane
// existed, because "/home/matus/Dokumente/".split("/").pop() is "".
//
// The command builder is tested for one property above all: the path travels
// in argv, never inside the shell script. A file called `; rm -rf ~` is a
// legal filename and fd will happily hand one over.
import QtQuick
import QtTest
import "../../nix/home/quickshell/qml/launcher/preview.js" as Preview

TestCase {
    name: "Preview"

    function test_kind_of_data() {
        return [
            { tag: "directory", path: "/home/matus/Dokumente/", expected: "directory" },
            { tag: "root", path: "/", expected: "directory" },
            { tag: "png", path: "/home/matus/shot.png", expected: "image" },
            { tag: "uppercase JPEG", path: "/home/matus/Shot.JPEG", expected: "image" },
            { tag: "svg", path: "/home/matus/logo.svg", expected: "image" },
            { tag: "markdown", path: "/home/matus/notes.md", expected: "text" },
            { tag: "no extension", path: "/home/matus/Makefile", expected: "text" },
            { tag: "dotfile", path: "/home/matus/.bashrc", expected: "text" },
            { tag: "image word in a text name", path: "/home/matus/png-notes.txt", expected: "text" }
        ];
    }

    function test_kind_of(row) {
        compare(Preview.kindOf(row.path), row.expected);
    }

    function test_display_name_data() {
        return [
            { tag: "file", path: "/home/matus/notes.md", expected: "notes.md" },
            { tag: "directory keeps its name", path: "/home/matus/Dokumente/", expected: "Dokumente" },
            { tag: "nested directory", path: "/home/matus/a/b/", expected: "b" }
        ];
    }

    function test_display_name(row) {
        compare(Preview.displayName(row.path), row.expected);
    }

    function test_display_parent_data() {
        return [
            { tag: "under home", path: "/home/matus/notes.md", expected: "~" },
            { tag: "deeper", path: "/home/matus/a/b.md", expected: "~/a" },
            { tag: "directory", path: "/home/matus/a/b/", expected: "~/a" },
            { tag: "outside home", path: "/etc/hosts", expected: "/etc" }
        ];
    }

    function test_display_parent(row) {
        compare(Preview.displayParent(row.path, "/home/matus"), row.expected);
    }

    // A path that merely starts with the same characters as home is not
    // inside it: /home/matusek must not render as ~ek.
    function test_display_parent_does_not_match_a_sibling_of_home() {
        compare(Preview.displayParent("/home/matusek/notes.md", "/home/matus"), "/home/matusek");
    }

    function test_file_url_percent_encodes_data() {
        return [
            { tag: "plain", path: "/home/matus/a.png", expected: "file:///home/matus/a.png" },
            { tag: "space", path: "/home/matus/my shot.png", expected: "file:///home/matus/my%20shot.png" },
            { tag: "hash", path: "/home/matus/c#1.png", expected: "file:///home/matus/c%231.png" },
            { tag: "question mark", path: "/home/matus/why?.png", expected: "file:///home/matus/why%3F.png" }
        ];
    }

    function test_file_url_percent_encodes(row) {
        compare(Preview.fileUrl(row.path), row.expected);
    }

    function test_format_size_data() {
        return [
            { tag: "bytes", bytes: 0, expected: "0 B" },
            { tag: "just under a kilobyte", bytes: 1023, expected: "1023 B" },
            { tag: "kilobytes", bytes: 12288, expected: "12 KB" },
            { tag: "one decimal when small", bytes: 1536, expected: "1.5 KB" },
            { tag: "megabytes", bytes: 5242880, expected: "5 MB" }
        ];
    }

    function test_format_size(row) {
        compare(Preview.formatSize(row.bytes), row.expected);
    }

    // The whole point of the argv split. The script is a constant; anything
    // derived from the filesystem is data.
    function test_preview_command_keeps_the_path_out_of_the_script() {
        const nasty = "/home/matus/; rm -rf ~/.png";
        const argv = Preview.previewCommand(nasty, "image");

        compare(argv[0], "sh");
        compare(argv[1], "-c");
        verify(argv.indexOf(nasty) > 2);
        verify(argv[2].indexOf(nasty) === -1);
        verify(argv[2].indexOf("rm -rf") === -1);
    }

    function test_preview_command_passes_the_kind_along() {
        const argv = Preview.previewCommand("/home/matus/a.png", "image");
        compare(argv[argv.length - 1], "image");
    }

    function test_binary_detection() {
        verify(Preview.isBinary("\u0000ELF"));
        verify(!Preview.isBinary("# Notes\nplain text\n"));
        verify(!Preview.isBinary(""));
    }

    function test_metadata_line_is_parsed() {
        const parsed = Preview.parseMeta("META 12288 1756209600 0");
        compare(parsed.bytes, 12288);
        compare(parsed.entries, 0);
    }

    function test_metadata_line_missing_is_tolerated() {
        const parsed = Preview.parseMeta("not a meta line");
        compare(parsed.bytes, 0);
    }
}
