// The extension-to-glyph table. Pure, so it runs with no font, no window
// and no listing.
//
// What these cannot check is whether a codepoint is actually mapped in the
// shipped font: an unmapped one renders as a tofu box and every string
// comparison here still passes. That gap is closed outside the suite, by
// running `fc-list ":charset=<cp>:family=Lilex Nerd Font"` for each glyph
// before it is added to icons.js.
import QtQuick
import QtTest
import "../../nix/home/desktop/quickshell/qml/files/icons.js" as Icons

TestCase {
    name: "FilesIcons"

    function file(name) {
        return { name: name, isDir: false };
    }

    function test_a_directory_takes_the_folder_glyph_and_the_accent() {
        const entry = { name: "Dokumente", isDir: true };

        compare(Icons.glyphFor(entry), Icons.FOLDER);
        compare(Icons.colourFor(entry), "accent");
    }

    // A directory is a directory whatever it is called, so the extension
    // table must never win over isDir.
    function test_a_directory_named_like_a_file_is_still_a_folder() {
        compare(Icons.glyphFor({ name: "archive.zip", isDir: true }), Icons.FOLDER);
    }

    function test_a_known_extension_takes_its_own_glyph_and_colour() {
        compare(Icons.colourFor(file("main.rs")), "orange");
        compare(Icons.colourFor(file("flake.nix")), "blue");
        compare(Icons.colourFor(file("install.sh")), "green");
        compare(Icons.colourFor(file("photo.png")), "magenta");
        compare(Icons.colourFor(file("backup.zip")), "yellow");
    }

    function test_an_unknown_extension_falls_back_to_the_plain_file() {
        compare(Icons.glyphFor(file("notes.qqq")), Icons.FILE);
        compare(Icons.colourFor(file("notes.qqq")), "fg");
    }

    function test_the_extension_match_ignores_case() {
        compare(Icons.colourFor(file("PHOTO.PNG")), "magenta");
    }

    // The last dot only, so a multi-part name is typed by what it actually
    // is: "backup.tar.gz" is a gzip, not a tar.
    function test_only_the_last_extension_decides() {
        compare(Icons.extensionOf("backup.tar.gz"), "gz");
        compare(Icons.colourFor(file("backup.tar.gz")), "yellow");
    }

    // A leading dot marks a hidden file, it does not introduce an
    // extension: ".bashrc" is not a file of type "bashrc".
    function test_a_dotfile_has_no_extension() {
        compare(Icons.extensionOf(".bashrc"), "");
        compare(Icons.glyphFor(file(".bashrc")), Icons.FILE);
    }

    function test_a_name_with_no_dot_has_no_extension() {
        compare(Icons.extensionOf("Makefile"), "");
    }

    // Every colour this module can return has to name a real Theme
    // property, because the QML side resolves it as `Theme[name]` rather
    // than through a switch. A typo here would silently paint the fallback.
    function test_every_colour_names_a_real_palette_token() {
        const known = ["accent", "fg", "blue", "cyan", "green", "magenta", "red", "yellow", "orange", "dim"];

        for (const extension in Icons.BY_EXTENSION)
            verify(known.indexOf(Icons.BY_EXTENSION[extension].colour) >= 0, `${extension} uses an unknown token`);
    }
}
