// Every builder returns an array with the path as its own element and
// "--" ahead of it, the same argv-not-a-shell-string discipline
// tst_preview.qml already proves for previewCommand, extended to a name
// that could otherwise be parsed as a flag.
//
// beginPrompt/resolvePromptArgv are Files.qml's prompt state machine,
// extracted here so it is reachable with no live pane, no live selection
// and no window — the seam a code review found missing, since every bug it
// caught (a stale selection surviving a re-list, a confirm dialog
// resolving against whatever was selected by the time Enter landed rather
// than what it showed) lived in code that only existed inside Files.qml
// before this file.
import QtQuick
import QtTest
import "../../nix/home/quickshell/qml/files/operations.js" as Operations

TestCase {
    name: "FilesOperations"

    property string nasty: "; rm -rf ~"

    function test_copyargv_keeps_each_path_as_its_own_argv_element() {
        compare(Operations.copyArgv(nasty, "/home/matus/dst"), ["cp", "-r", "--", nasty, "/home/matus/dst"]);
    }

    function test_moveargv_keeps_each_path_as_its_own_argv_element() {
        compare(Operations.moveArgv(nasty, "/home/matus/dst"), ["mv", "--", nasty, "/home/matus/dst"]);
    }

    function test_renameargv_keeps_each_path_as_its_own_argv_element() {
        compare(Operations.renameArgv("/home/matus/old", nasty), ["mv", "--", "/home/matus/old", nasty]);
    }

    function test_mkdirargv_keeps_the_path_as_its_own_argv_element() {
        compare(Operations.mkdirArgv(nasty), ["mkdir", "--", nasty]);
    }

    function test_trashargv_keeps_the_path_as_its_own_argv_element() {
        compare(Operations.trashArgv(nasty), ["gio", "trash", "--", nasty]);
    }

    // `includes("--")` alone only proves the separator is present
    // somewhere in the array — it passes just as happily whether "--"
    // guards the paths or trails uselessly after them. indexOf() pins the
    // actual position, which is what "end of options" means: everything
    // from here to the end of the array is a path, nothing before it is.
    function test_every_builder_places_the_marker_immediately_before_the_paths() {
        compare(Operations.copyArgv("-rf", "dst").indexOf("--"), 2);
        compare(Operations.moveArgv("-rf", "dst").indexOf("--"), 1);
        compare(Operations.renameArgv("-rf", "dst").indexOf("--"), 1);
        compare(Operations.mkdirArgv("-rf").indexOf("--"), 1);
        compare(Operations.trashArgv("-rf").indexOf("--"), 2);
    }

    function test_beginprompt_returns_a_plain_snapshot_of_its_arguments() {
        const snapshot = Operations.beginPrompt("rename", "/home/matus", "old.txt");

        compare(snapshot.mode, "rename");
        compare(snapshot.dirPath, "/home/matus");
        compare(snapshot.name, "old.txt");
    }

    function test_resolvepromptargv_rename_joins_the_snapshot_dir_with_the_snapshot_name_and_the_typed_text() {
        const snapshot = Operations.beginPrompt("rename", "/home/matus", "old.txt");

        compare(Operations.resolvePromptArgv(snapshot, "new.txt"), ["mv", "--", "/home/matus/old.txt", "/home/matus/new.txt"]);
    }

    function test_resolvepromptargv_mkdir_joins_the_snapshot_dir_with_the_typed_text() {
        const snapshot = Operations.beginPrompt("mkdir", "/home/matus", null);

        compare(Operations.resolvePromptArgv(snapshot, "newdir"), ["mkdir", "--", "/home/matus/newdir"]);
    }

    // The one case that used to be able to throw before the prompt state
    // reset: trash-confirm has nothing for the user to type, so its argv
    // comes entirely from the snapshot. promptText is passed here anyway,
    // deliberately garbage, to prove it plays no part.
    function test_resolvepromptargv_trash_confirm_ignores_the_typed_text_entirely() {
        const snapshot = Operations.beginPrompt("trash-confirm", "/home/matus", "doomed.txt");

        compare(Operations.resolvePromptArgv(snapshot, "; rm -rf /"), ["gio", "trash", "--", "/home/matus/doomed.txt"]);
    }

    function test_resolvepromptargv_returns_null_for_an_unrecognised_mode() {
        compare(Operations.resolvePromptArgv({ mode: "no-such-mode", dirPath: "/home/matus", name: "x" }, "y"), null);
    }

    function test_resolvepromptargv_returns_null_for_a_null_snapshot() {
        compare(Operations.resolvePromptArgv(null, "anything"), null);
    }

    function test_resolvepromptargv_rejects_an_empty_typed_name() {
        compare(Operations.resolvePromptArgv(Operations.beginPrompt("rename", "/home/matus", "old.txt"), ""), null);
        compare(Operations.resolvePromptArgv(Operations.beginPrompt("mkdir", "/home/matus", null), ""), null);
    }

    function test_resolvepromptargv_rejects_a_path_separator_in_the_typed_name() {
        compare(Operations.resolvePromptArgv(Operations.beginPrompt("rename", "/home/matus", "old.txt"), "sub/escaped.txt"), null);
        compare(Operations.resolvePromptArgv(Operations.beginPrompt("mkdir", "/home/matus", null), "sub/escaped"), null);
    }

    function test_resolvepromptargv_rejects_a_bare_dotdot_typed_name() {
        compare(Operations.resolvePromptArgv(Operations.beginPrompt("rename", "/home/matus", "old.txt"), ".."), null);
        compare(Operations.resolvePromptArgv(Operations.beginPrompt("mkdir", "/home/matus", null), ".."), null);
    }

    // Neither of these escapes the directory the prompt opened in — join()
    // is dir + "/" + name, and a name with no "/" and no ".." segment
    // cannot leave dir, whitespace or not. Rejected anyway because each is
    // a working-as-designed footgun elsewhere: " " mints a directory that
    // looks empty in a listing and is easy to lose track of, and a
    // newline byte survives mkdir/mv just fine but breaks files.js's
    // line-based ls parsing the next time either pane re-lists — one
    // directory becomes two phantom rows.
    function test_resolvepromptargv_rejects_a_whitespace_only_typed_name() {
        compare(Operations.resolvePromptArgv(Operations.beginPrompt("rename", "/home/matus", "old.txt"), "   "), null);
        compare(Operations.resolvePromptArgv(Operations.beginPrompt("mkdir", "/home/matus", null), "   "), null);
    }

    function test_resolvepromptargv_rejects_a_typed_name_containing_a_newline() {
        compare(Operations.resolvePromptArgv(Operations.beginPrompt("rename", "/home/matus", "old.txt"), "two\nlines"), null);
        compare(Operations.resolvePromptArgv(Operations.beginPrompt("mkdir", "/home/matus", null), "two\nlines"), null);
    }

    // trash-confirm's name never comes from typed text — trashSelected()
    // always seeds it from a real ls listing — but beginPrompt() itself
    // takes name as a plain argument with no shape guarantee, so nothing
    // stopped this from resolving to a traversal outside what
    // isValidEntryName's own reuse here now closes.
    function test_resolvepromptargv_trash_confirm_rejects_a_traversal_in_the_snapshot_name() {
        const snapshot = Operations.beginPrompt("trash-confirm", "/home/matus", "../../etc/passwd");

        compare(Operations.resolvePromptArgv(snapshot, "irrelevant"), null);
    }

    function test_isvalidentryname_accepts_a_name_that_merely_starts_with_a_dash() {
        // "-rf" is still one ordinary path segment; rejecting it would be
        // conflating "looks like a flag" (operations.js's own "--" already
        // handles that) with "escapes the directory" (this function's job).
        verify(Operations.isValidEntryName("-rf"));
    }

    function test_isvalidentryname_accepts_a_name_with_internal_but_not_only_whitespace() {
        // Only rejects a name that is NOTHING but whitespace; padding
        // around real content is somebody's legitimate file.
        verify(Operations.isValidEntryName(" leading and trailing "));
    }

    function test_isvalidentryname_rejects_whitespace_only_and_newline_carrying_names() {
        verify(!Operations.isValidEntryName(""));
        verify(!Operations.isValidEntryName("   "));
        verify(!Operations.isValidEntryName("two\nlines"));
    }
}
