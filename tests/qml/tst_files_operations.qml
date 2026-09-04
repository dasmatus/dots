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
import "../../nix/home/desktop/quickshell/qml/files/operations.js" as Operations

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
    // Deliberately does not cover openArgv: that builder must NOT carry
    // "--" at all (xdg-open rejects it outright), so it has its own
    // dedicated test below asserting the opposite.
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

    // The rename branch's identical hole to the one escapesDirectory
    // closed for trash-confirm: snapshot.name is a rename's SOURCE half,
    // an existing entry's name off a real ls listing, and nothing checked
    // it. beginPrompt("rename", "/tmp/x", "../secret") used to resolve
    // renameArgv straight onto a path outside "/tmp/x" — promptText's own
    // isValidEntryName check has nothing to say about the source half.
    function test_resolvepromptargv_rename_rejects_a_traversal_in_the_snapshot_name() {
        const snapshot = Operations.beginPrompt("rename", "/tmp/x", "../secret");

        compare(Operations.resolvePromptArgv(snapshot, "newname"), null);
    }

    function test_resolvepromptargv_rename_rejects_an_empty_or_dot_or_dotdot_snapshot_name() {
        compare(Operations.resolvePromptArgv(Operations.beginPrompt("rename", "/tmp/x", ""), "newname"), null);
        compare(Operations.resolvePromptArgv(Operations.beginPrompt("rename", "/tmp/x", "."), "newname"), null);
        compare(Operations.resolvePromptArgv(Operations.beginPrompt("rename", "/tmp/x", ".."), "newname"), null);
    }

    function test_resolvepromptargv_rename_rejects_a_path_separator_in_the_middle_of_the_snapshot_name() {
        compare(Operations.resolvePromptArgv(Operations.beginPrompt("rename", "/tmp/x", "sub/escaped"), "newname"), null);
    }

    // Same reasoning as trash-confirm's equivalent test below: a real
    // file already named " " or carrying a tab predates this dialog and
    // is renameable like any other file. escapesDirectory has no
    // CREATE-time hygiene rule, so the fix for the traversal above must
    // not repeat isValidEntryName's blank-name rejection against a name
    // nobody typed — that would just relocate the bug round 4 fixed for
    // trash onto rename instead of fixing rename's real hole.
    function test_resolvepromptargv_rename_accepts_blank_and_tab_snapshot_names() {
        compare(Operations.resolvePromptArgv(Operations.beginPrompt("rename", "/tmp/x", " "), "newname"), ["mv", "--", "/tmp/x/ ", "/tmp/x/newname"]);
        compare(Operations.resolvePromptArgv(Operations.beginPrompt("rename", "/tmp/x", "\t"), "newname"), ["mv", "--", "/tmp/x/\t", "/tmp/x/newname"]);
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
    // escapesDirectory's own check here now closes.
    function test_resolvepromptargv_trash_confirm_rejects_a_traversal_in_the_snapshot_name() {
        const snapshot = Operations.beginPrompt("trash-confirm", "/home/matus", "../../etc/passwd");

        compare(Operations.resolvePromptArgv(snapshot, "irrelevant"), null);
    }

    // join(dir, "") is "dir/" and join(dir, ".") is "dir/." — both name
    // the directory itself, not a distinct entry inside it. Before
    // escapesDirectory covered these, beginPrompt("trash-confirm", dir,
    // "") resolved to trashArgv("dir/"), exit 0, the whole directory
    // gone, silently, with no traversal and no "/" or ".." in sight —
    // exactly the shape the previous round's fix did not close.
    function test_resolvepromptargv_trash_confirm_rejects_an_empty_or_dot_snapshot_name() {
        compare(Operations.resolvePromptArgv(Operations.beginPrompt("trash-confirm", "/home/matus", ""), "irrelevant"), null);
        compare(Operations.resolvePromptArgv(Operations.beginPrompt("trash-confirm", "/home/matus", "."), "irrelevant"), null);
    }

    // The actual bug this round fixes: a real file already named " ", "  "
    // or a bare tab lists, copies, moves and renames fine, since none of
    // those validate the name at all — only Trash used to refuse it, by
    // running isValidEntryName's CREATE-time blank rule over a name that
    // was never typed. escapesDirectory has no such rule, so all three
    // resolve to an ordinary trashArgv now, same as any other filename.
    function test_resolvepromptargv_trash_confirm_accepts_blank_and_tab_snapshot_names() {
        compare(Operations.resolvePromptArgv(Operations.beginPrompt("trash-confirm", "/home/matus", " "), "irrelevant"), ["gio", "trash", "--", "/home/matus/ "]);
        compare(Operations.resolvePromptArgv(Operations.beginPrompt("trash-confirm", "/home/matus", "  "), "irrelevant"), ["gio", "trash", "--", "/home/matus/  "]);
        compare(Operations.resolvePromptArgv(Operations.beginPrompt("trash-confirm", "/home/matus", "\t"), "irrelevant"), ["gio", "trash", "--", "/home/matus/\t"]);
    }

    // trashSelected() never produces a null name — mkdir is the only mode
    // that does, and mkdir never reaches the trash-confirm branch — but
    // resolvePromptArgv has to stay total against a future caller's
    // mistake rather than throw out of confirmPrompt() and leave the
    // confirm label stuck on screen with promptMode never reset.
    function test_resolvepromptargv_trash_confirm_returns_null_for_a_non_string_snapshot_name() {
        compare(Operations.resolvePromptArgv(Operations.beginPrompt("trash-confirm", "/home/matus", null), "irrelevant"), null);
    }

    function test_escapesdirectory_rejects_a_bare_dotdot() {
        verify(Operations.escapesDirectory(".."));
    }

    function test_escapesdirectory_rejects_a_path_separator_anywhere_in_the_name() {
        verify(Operations.escapesDirectory("sub/escaped"));
        verify(Operations.escapesDirectory("../../etc/passwd"));
    }

    function test_escapesdirectory_rejects_non_string_input() {
        verify(Operations.escapesDirectory(null));
        verify(Operations.escapesDirectory(undefined));
        verify(Operations.escapesDirectory(42));
    }

    // join(dir, "") and join(dir, ".") both resolve to dir itself, not a
    // distinct entry inside it — indistinguishable in effect from "..":
    // all three make the operation land somewhere other than the entry
    // the caller meant. Neither "" nor "." contains "/" or equals "..",
    // which is exactly how an empty snapshot.name passed this function
    // before this round's fix.
    function test_escapesdirectory_rejects_empty_and_single_dot_names() {
        verify(Operations.escapesDirectory(""));
        verify(Operations.escapesDirectory("."));
    }

    // Mutation-tested: changing escapesDirectory's `name === ".."` to a
    // `startsWith("..")` check survives every other assertion in this
    // file, since nothing here previously typed a name starting with but
    // not equal to "..". A real, listed dotfile named this way must stay
    // trashable — "..hidden" does not equal ".." and does not leave dir.
    function test_escapesdirectory_accepts_a_dotdot_prefixed_name_that_is_not_exactly_dotdot() {
        verify(!Operations.escapesDirectory("..hidden"));
    }

    // The properties CREATE-time hygiene rejects beyond escapesDirectory
    // (whitespace-only, newline) are not escape properties: neither can
    // leave the directory they are joined against, so escapesDirectory —
    // the check trash-confirm uses for a name that already exists —
    // accepts both.
    function test_escapesdirectory_accepts_whitespace_only_and_newline_carrying_names() {
        verify(!Operations.escapesDirectory("   "));
        verify(!Operations.escapesDirectory("\t"));
        verify(!Operations.escapesDirectory("two\nlines"));
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

    // Inherited from escapesDirectory: renaming a file to "." (or
    // creating a folder named ".") is nonsensical the same way an empty
    // name is — both would collapse onto the directory itself.
    function test_isvalidentryname_rejects_a_single_dot() {
        verify(!Operations.isValidEntryName("."));
    }

    // openArgv/isAbsolutePath/promptErrorMessage were previously inline
    // QML in Pane.qml/Files.qml with no test anywhere referencing them —
    // exactly the gap a review found after the round that had to revert a
    // "--" added to this call. Pulling each into a pure function here is
    // what makes a future regression on any of the three fail a test
    // instead of needing another manual xdg-open invocation to catch.

    function test_openargv_carries_no_end_of_options_marker() {
        // The one builder in this file that must NOT have one: xdg-open's
        // own argument loop rejects "--" outright and exits 1.
        compare(Operations.openArgv("/home/matus/notes.txt"), ["xdg-open", "/home/matus/notes.txt"]);
        verify(!Operations.openArgv("-rf").includes("--"));
    }

    function test_isabsolutepath_accepts_only_a_leading_slash() {
        verify(Operations.isAbsolutePath("/home/matus"));
        verify(Operations.isAbsolutePath("/"));
        verify(!Operations.isAbsolutePath("-foo"));
        verify(!Operations.isAbsolutePath("relative/path"));
        verify(!Operations.isAbsolutePath(""));
    }

    function test_isabsolutepath_rejects_non_string_input() {
        verify(!Operations.isAbsolutePath(null));
        verify(!Operations.isAbsolutePath(undefined));
        verify(!Operations.isAbsolutePath(42));
    }

    function test_isknownpromptmode_accepts_exactly_the_three_modes_this_file_produces() {
        verify(Operations.isKnownPromptMode("rename"));
        verify(Operations.isKnownPromptMode("mkdir"));
        verify(Operations.isKnownPromptMode("trash-confirm"));
        verify(!Operations.isKnownPromptMode("no-such-mode"));
    }

    function test_promptErrorMessage_gives_rename_and_mkdir_the_same_message() {
        const renameMessage = Operations.promptErrorMessage(Operations.beginPrompt("rename", "/home/matus", "old.txt"));
        const mkdirMessage = Operations.promptErrorMessage(Operations.beginPrompt("mkdir", "/home/matus", null));

        verify(renameMessage.includes("Invalid name"));
        compare(mkdirMessage, renameMessage);
    }

    // Mutant M29: the wording was not pinned by any assertion, only
    // `.includes("Invalid name")`. trash-confirm's reachable rejections
    // are escapesDirectory's — "/", ".", ".." and the empty string, plus
    // a non-string — never isValidEntryName's extra CREATE-time rules, so
    // its message must not claim whitespace-only or a newline would be
    // refused, unlike rename/mkdir's. It DOES have to claim empty: an
    // earlier wording here dropped that case by mistake (see
    // promptErrorMessage's comment) and this once asserted the absence
    // that mistake produced instead of catching it.
    function test_promptErrorMessage_trash_confirm_message_is_narrower_than_rename_mkdirs() {
        const trashMessage = Operations.promptErrorMessage(Operations.beginPrompt("trash-confirm", "/home/matus", "x"));
        const renameMessage = Operations.promptErrorMessage(Operations.beginPrompt("rename", "/home/matus", "old.txt"));

        verify(trashMessage.includes("Invalid name"));
        verify(trashMessage.includes("empty"));
        verify(!trashMessage.includes("whitespace"));
        verify(!trashMessage.includes("newline"));
        verify(trashMessage !== renameMessage);
    }

    // escapesDirectory rejects five things: a non-string, the empty
    // string, ".", "..", and any name containing "/". The trash-confirm
    // message must stay true for the four a person can actually produce
    // by leaving a rename/trash target's name blank or picking one apart
    // — round 4's wording named "/", ".." and "." and silently dropped
    // the empty-string case, the exact one an empty snapshot.name hits.
    function test_promptErrorMessage_trash_confirm_names_every_case_escapesdirectory_rejects() {
        const trashMessage = Operations.promptErrorMessage(Operations.beginPrompt("trash-confirm", "/home/matus", "x"));

        verify(trashMessage.includes("empty"));
        verify(trashMessage.includes("\"/\""));
        verify(trashMessage.includes("\"..\""));
        verify(trashMessage.includes("\".\""));
    }

    function test_promptErrorMessage_is_generic_for_a_falsy_or_unrecognised_snapshot() {
        const genericMessage = Operations.promptErrorMessage(null);

        verify(!genericMessage.includes("Invalid name"));
        compare(Operations.promptErrorMessage({ mode: "no-such-mode", dirPath: "/home/matus", name: "x" }), genericMessage);
    }

    // copySelected()/moveSelected() had no check at all until this round:
    // pane.selected.name went straight into FilesMath.join and then
    // copyArgv/moveArgv, the same unguarded shape rename's source half had
    // before escapesDirectory closed it there. resolveSelectionArgv is the
    // pure function Files.qml now routes both through — Files.qml itself
    // instantiates Quickshell.Io, which qmltestrunner cannot load, so this
    // is the only seam these five rejections are reachable from at all.

    function test_resolveselectionargv_copy_joins_the_source_dir_with_the_name() {
        compare(Operations.resolveSelectionArgv("copy", "/home/matus/src", "photo.png", "/home/matus/dst"), ["cp", "-r", "--", "/home/matus/src/photo.png", "/home/matus/dst"]);
    }

    function test_resolveselectionargv_move_joins_the_source_dir_with_the_name() {
        compare(Operations.resolveSelectionArgv("move", "/home/matus/src", "photo.png", "/home/matus/dst"), ["mv", "--", "/home/matus/src/photo.png", "/home/matus/dst"]);
    }

    function test_resolveselectionargv_copy_rejects_a_non_string_name() {
        compare(Operations.resolveSelectionArgv("copy", "/home/matus/src", null, "/home/matus/dst"), null);
        compare(Operations.resolveSelectionArgv("copy", "/home/matus/src", undefined, "/home/matus/dst"), null);
        compare(Operations.resolveSelectionArgv("copy", "/home/matus/src", 42, "/home/matus/dst"), null);
    }

    function test_resolveselectionargv_move_rejects_a_non_string_name() {
        compare(Operations.resolveSelectionArgv("move", "/home/matus/src", null, "/home/matus/dst"), null);
        compare(Operations.resolveSelectionArgv("move", "/home/matus/src", undefined, "/home/matus/dst"), null);
        compare(Operations.resolveSelectionArgv("move", "/home/matus/src", 42, "/home/matus/dst"), null);
    }

    function test_resolveselectionargv_copy_rejects_an_empty_name() {
        compare(Operations.resolveSelectionArgv("copy", "/home/matus/src", "", "/home/matus/dst"), null);
    }

    function test_resolveselectionargv_move_rejects_an_empty_name() {
        compare(Operations.resolveSelectionArgv("move", "/home/matus/src", "", "/home/matus/dst"), null);
    }

    function test_resolveselectionargv_copy_rejects_a_single_dot_name() {
        compare(Operations.resolveSelectionArgv("copy", "/home/matus/src", ".", "/home/matus/dst"), null);
    }

    function test_resolveselectionargv_move_rejects_a_single_dot_name() {
        compare(Operations.resolveSelectionArgv("move", "/home/matus/src", ".", "/home/matus/dst"), null);
    }

    function test_resolveselectionargv_copy_rejects_a_bare_dotdot_name() {
        compare(Operations.resolveSelectionArgv("copy", "/home/matus/src", "..", "/home/matus/dst"), null);
    }

    function test_resolveselectionargv_move_rejects_a_bare_dotdot_name() {
        compare(Operations.resolveSelectionArgv("move", "/home/matus/src", "..", "/home/matus/dst"), null);
    }

    function test_resolveselectionargv_copy_rejects_a_path_separator_anywhere_in_the_name() {
        compare(Operations.resolveSelectionArgv("copy", "/home/matus/src", "sub/escaped", "/home/matus/dst"), null);
        compare(Operations.resolveSelectionArgv("copy", "/home/matus/src", "../../etc/passwd", "/home/matus/dst"), null);
    }

    function test_resolveselectionargv_move_rejects_a_path_separator_anywhere_in_the_name() {
        compare(Operations.resolveSelectionArgv("move", "/home/matus/src", "sub/escaped", "/home/matus/dst"), null);
        compare(Operations.resolveSelectionArgv("move", "/home/matus/src", "../../etc/passwd", "/home/matus/dst"), null);
    }

    // The over-strict check an earlier round had to REMOVE from the trash
    // path for exactly this reason: a real file already named " " or
    // holding a tab predates this dialog and lists, renames and trashes
    // fine already. escapesDirectory has no CREATE-time hygiene rule, so
    // copy/move must not grow one either — both still resolve normally.
    function test_resolveselectionargv_copy_accepts_blank_and_tab_names() {
        compare(Operations.resolveSelectionArgv("copy", "/home/matus/src", " ", "/home/matus/dst"), ["cp", "-r", "--", "/home/matus/src/ ", "/home/matus/dst"]);
        compare(Operations.resolveSelectionArgv("copy", "/home/matus/src", "\t", "/home/matus/dst"), ["cp", "-r", "--", "/home/matus/src/\t", "/home/matus/dst"]);
    }

    function test_resolveselectionargv_move_accepts_blank_and_tab_names() {
        compare(Operations.resolveSelectionArgv("move", "/home/matus/src", " ", "/home/matus/dst"), ["mv", "--", "/home/matus/src/ ", "/home/matus/dst"]);
        compare(Operations.resolveSelectionArgv("move", "/home/matus/src", "\t", "/home/matus/dst"), ["mv", "--", "/home/matus/src/\t", "/home/matus/dst"]);
    }

    function test_resolveselectionargv_returns_null_for_an_unrecognised_mode() {
        compare(Operations.resolveSelectionArgv("no-such-mode", "/home/matus/src", "photo.png", "/home/matus/dst"), null);
    }

    // The text Files.qml sets root.lastError to when resolveSelectionArgv
    // rejects a copy/move — copy and move have no prompt to route a
    // rejection through the way rename/trash-confirm do, so this is a
    // second caller for the same message promptErrorMessage's
    // trash-confirm branch already returns, not a new one written for
    // this case. Must not claim whitespace-only or a newline would be
    // refused: those are isValidEntryName's CREATE-time rules, and a name
    // off a real listing can only ever fail escapesDirectory's four.
    function test_escapesdirectorymessage_names_every_case_escapesdirectory_rejects() {
        const message = Operations.escapesDirectoryMessage();

        verify(message.includes("Invalid name"));
        verify(message.includes("empty"));
        verify(message.includes("\"/\""));
        verify(message.includes("\"..\""));
        verify(message.includes("\".\""));
        verify(!message.includes("whitespace"));
        verify(!message.includes("newline"));
    }

    // promptErrorMessage's trash-confirm branch and escapesDirectoryMessage
    // must stay the same text — they are the same rejection reason
    // reported through two different callers (a prompt vs. copy/move's
    // immediate action), not two independently-maintained strings that
    // could quietly drift apart.
    function test_escapesdirectorymessage_matches_promptErrorMessages_trash_confirm_branch() {
        compare(Operations.escapesDirectoryMessage(), Operations.promptErrorMessage(Operations.beginPrompt("trash-confirm", "/home/matus", "x")));
    }
}
