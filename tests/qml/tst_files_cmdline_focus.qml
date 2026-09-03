// Drives the shipped files/CommandLine.qml with real key events and asserts
// the one thing the surface exists to do: that what you type after `:` or `/`
// lands in it.
//
// It did not. Files.qml's openCmdline sets promptMode and then calls
// cmdline.clear(); setting the mode fired CommandLine's onModeChanged, which
// took focus with input.forceActiveFocus(), and clear() ended by handing it
// straight back with input.focus = false. Two functions each correct alone,
// in the one order that cancels them out. The line came up on screen with
// nothing in the window focused at all, so every keystroke went nowhere —
// no error, no warning, just a `:` prompt that ignored the keyboard.
//
// The fix made the TextInput's focus a binding on the mode, so this file
// deliberately opens the line the way openCmdline does — mode first, then
// clear() — because that exact sequence is what used to break it. It also
// runs the reverse order, since the whole point of a binding over a pair of
// imperative calls is that neither order can lose.
//
// Real CommandLine.qml, symlinked into fixtures/theme-stub/files/ rather
// than copied, so this drives the shipped component and not a snapshot of it
// that could drift. Nothing here reaches Quickshell: CommandLine only needs
// QtQuick, QtQuick.Layouts, commands.js and Theme, and the stub supplies the
// last. Files.qml itself cannot be instantiated — FloatingWindow, Process,
// IpcHandler and Quickshell.env are all out of qmltestrunner's reach (see
// tests/README.md) — so the half of the handover that lives there, the
// `catcher` item that holds focus while the line is closed, is asserted as
// source text by tst_files_wiring.qml instead.
import QtQuick
import QtTest
import "fixtures/theme-stub/files"

TestCase {
    id: tc
    name: "FilesCmdlineFocus"
    when: windowShown
    visible: true
    width: 600
    height: 400

    // One directory listing for the `/` line to match against, in the shape
    // Pane's parseListing hands over.
    readonly property var entries: [
        {
            name: "report.txt",
            isDir: false,
            size: 12,
            mtime: 1756819200
        },
        {
            name: "Work",
            isDir: true,
            size: 4096,
            mtime: 1756819200
        }
    ]

    CommandLine {
        id: cmdline

        anchors.fill: parent

        mode: ""
        entries: tc.entries
        selection: null
        clipboard: null
        showHidden: false
    }

    // Files.qml's openCmdline(), statement for statement.
    function openLine(mode) {
        cmdline.mode = mode;
        cmdline.clear();
    }

    function closeLine() {
        cmdline.mode = "";
        cmdline.clear();
    }

    function init() {
        tc.closeLine();
    }

    function test_the_command_line_takes_what_is_typed_into_it() {
        tc.openLine("command");

        keyClick(Qt.Key_M);
        keyClick(Qt.Key_K);

        compare(cmdline.query, "mk", "a `:` line that does not receive keys is the bug this file exists for");
    }

    function test_the_search_line_takes_what_is_typed_into_it() {
        tc.openLine("search");

        keyClick(Qt.Key_W);

        compare(cmdline.query, "w");
    }

    // The filtered row list is what the query is for, so this checks the
    // keystroke reached the model and not merely the property.
    function test_typing_filters_the_rows() {
        tc.openLine("search");

        keyClick(Qt.Key_W);

        compare(cmdline.rows.length, 1);
        compare(cmdline.rows[0].title, "Work");
    }

    // clear() before the mode change rather than after. Under the old
    // imperative pair this was the order that happened to work; both orders
    // have to now, which is the difference a binding makes.
    function test_the_line_takes_input_whichever_order_it_was_opened_in() {
        cmdline.clear();
        cmdline.mode = "command";

        keyClick(Qt.Key_M);

        compare(cmdline.query, "m");
    }

    // Reopening after a close is its own case: the TextInput is inside a
    // FocusScope in the real tree and stays that scope's focused child after
    // being hidden, which is what made a second `:` do nothing before
    // f142be5. The binding has to release focus on the way out for the
    // reopen to be able to take it again.
    function test_the_line_takes_input_again_after_being_closed() {
        tc.openLine("command");
        keyClick(Qt.Key_M);
        tc.closeLine();

        tc.openLine("command");
        keyClick(Qt.Key_K);

        compare(cmdline.query, "k");
    }

    // The closed line must not keep focus, or Files.qml's `catcher` cannot
    // get it back and j/k/h/l stop navigating the pane.
    function test_the_closed_line_holds_no_focus() {
        tc.openLine("command");
        verify(cmdline.input.activeFocus, "the open line must hold focus");

        tc.closeLine();

        verify(!cmdline.input.activeFocus, "a closed line still holding focus swallows every key the pane wanted");
    }

    // The trash confirmation hides the TextInput and answers Enter and Esc
    // from a sibling item instead, so focus has to move off the field rather
    // than onto a field nobody can see.
    function test_the_trash_confirmation_does_not_focus_the_hidden_field() {
        tc.openLine("command");

        cmdline.mode = "trash-confirm";

        verify(!cmdline.input.activeFocus, "the confirmation takes no text — focusing its hidden field swallows Enter and Esc");
    }

    // A rename or a New Folder prompt is still a field, and still has to
    // take the name being typed into it.
    function test_a_prompt_takes_the_name_typed_into_it() {
        cmdline.mode = "rename";
        cmdline.beginPrompt("old.txt");

        keyClick(Qt.Key_N);

        compare(cmdline.input.text, "n", "beginPrompt selects the seed, so the first key typed replaces it");
    }
}
