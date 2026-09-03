// Reachability tests for the ask pane, in the idiom tst_launcher_wiring.qml
// established: qmltestrunner cannot instantiate AskBus.qml or Ask.qml, since
// both reach Quickshell.Io and Ask also reaches PanelWindow, WlrLayershell and
// IpcHandler, all of which tests/README.md rules out. So these read the shipped
// source as text.
//
// tst_ask_stream.qml unit-tests services/ask.js in isolation. That coverage
// stays green while nothing calls it, or while a caller passes the wrong list,
// which is the gap this file closes. Every assertion here is about a CALLER.
//
// Everything is checked against comment-stripped source, because the prose in
// these files names `flush`, `toolTone` and `show` while explaining why they
// are shaped the way they are, and an unstripped scan would let a comment stand
// in for the binding it describes.
import QtQuick
import QtTest
import "sourcescan.js" as Scan

TestCase {
    name: "AskWiring"

    function readSource(relPath) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl(relPath), false);
        xhr.send();
        compare(xhr.status, 200, relPath + " must be readable (needs QML_XHR_ALLOW_FILE_READ=1)");
        return Scan.stripComments(xhr.responseText);
    }

    function busSource() {
        return readSource("../../nix/home/quickshell/qml/services/AskBus.qml");
    }

    function paneSource() {
        return readSource("../../nix/home/quickshell/qml/ask/Ask.qml");
    }

    function toolSource() {
        return readSource("../../nix/home/quickshell/qml/ask/ToolCall.qml");
    }

    function treeSource() {
        return readSource("../../nix/home/quickshell/tree.nix");
    }

    // `qs ipc call ask show` is swallowed by the `qs ipc show` subcommand: it
    // prints the handler listing, exits 0, and calls nothing, with no error to
    // say so. Measured on this build, and the one thing about this handler
    // that cannot be found by reading it.
    function test_the_ipc_handler_is_never_named_show() {
        const block = Scan.blockAfter(paneSource(), "IpcHandler {");
        verify(block !== "", "Ask must declare an IpcHandler");
        verify(block.indexOf('target: "ask"') !== -1, "the handler has to answer on the ask target");
        verify(block.indexOf("function show(") === -1, "a function named show is swallowed by the qs ipc show subcommand and is never called");
        verify(block.indexOf("function open(") !== -1, "open is the name that reaches the handler");
        verify(block.indexOf("function close(") !== -1);
        verify(block.indexOf("function toggle(") !== -1);
    }

    // With every dots.ai toggle off, backends.json holds an empty list and the
    // pane must not appear at all. A window that opens empty and closes again
    // is worse than a keybind that does nothing.
    function test_the_pane_is_gated_on_the_backends_file() {
        const source = paneSource();

        verify(source.indexOf("ask/backends.json") !== -1, "the gate is the generated backends.json, not a hardcoded list");

        const gate = Scan.blockAfter(source, "function enabled(): bool {");
        verify(gate !== "", "Ask must define enabled()");
        verify(gate.indexOf("root.gate.length > 0") !== -1, "the gate is the length of the toggle list");

        const open = Scan.blockAfter(source, "function open(): void {");
        verify(open.indexOf("if (!root.enabled())") !== -1, "open must return early on an empty gate before it shows anything");
    }

    // JsonAdapter on this build has no generic `root`: only a property
    // DECLARED on the adapter instance gets populated. Reading a bare root off
    // it is silently undefined, which is how the cheatsheet once rendered
    // empty.
    function test_the_backends_adapter_declares_its_own_property() {
        const block = Scan.blockAfter(paneSource(), "adapter: JsonAdapter {");
        verify(block.indexOf("property var items") !== -1, "the adapter must declare items, since JsonAdapter has no root to read through");
    }

    // Runtime-writable state never goes under the quickshell config dir, which
    // is a whole-directory Nix store symlink.
    function test_pane_state_goes_to_xdg_state() {
        const source = paneSource();

        verify(source.indexOf("Theme.askStatePath") !== -1, "the session record must use the generated state path");
        verify(source.indexOf("Theme.askStateDir") !== -1, "and mkdir its parent, since FileView creates no directories");
        verify(source.indexOf("Quickshell.shellDir}/ask/session") === -1, "nothing writable may live beside the QML: that directory is a store symlink");

        const tree = treeSource();
        verify(tree.indexOf("askStateDir = \"${stateHome}/dots-shell/ask\"") !== -1, "tree.nix owns the one definition of where that directory is");
    }

    // The daemon does not batch; it emits a text_delta per token. Appending
    // each one straight to the model would relayout the ListView per token.
    function test_deltas_are_buffered_and_flushed_on_a_frame_timer() {
        const source = busSource();

        const ingest = Scan.blockAfter(source, "function ingestEvent(event: var): void {");
        verify(ingest !== "", "AskBus must define ingestEvent");
        verify(ingest.indexOf("root.pending.push(event)") !== -1, "an incoming event has to queue rather than fold straight into the model");
        verify(ingest.indexOf("flush.start()") !== -1, "and arm the flush timer");
        verify(ingest.indexOf("flush.restart()") === -1, "restarting on every event would push the flush out for as long as tokens kept arriving");

        const timer = Scan.blockAfter(source, "Timer {\n        id: flush\n");
        verify(timer !== "", "AskBus must declare the flush timer");
        verify(timer.indexOf("interval: 16") !== -1, "the flush is one frame, so the ListView relayouts at most once a frame");

        const flushBody = Scan.blockAfter(source, "function flushPending(): void {");
        verify(flushBody.indexOf("Ask.applyEvents(root.state, batch)") !== -1, "the whole batch has to fold in one call, or the buffering bought nothing");
    }

    // The socket half. This is the shell's first Socket, so nothing else
    // establishes the framing.
    function test_the_socket_reads_newline_delimited_json_and_reconnects() {
        const source = busSource();

        verify(source.indexOf("dots-ask.sock") !== -1, "the daemon listens on $XDG_RUNTIME_DIR/dots-ask.sock");
        verify(source.indexOf("XDG_RUNTIME_DIR") !== -1, "and the path comes from the environment, not a hardcoded /run/user");

        const parser = Scan.blockAfter(source, "parser: SplitParser {");
        verify(parser.indexOf('splitMarker: "\\n"') !== -1, "the wire is one JSON object per line");

        const state = Scan.blockAfter(source, "onConnectionStateChanged: {");
        verify(state.indexOf("Ask.helloFrame(root.state.lastSeq)") !== -1, "every connection opens with hello carrying the highest seq already rendered");
        verify(state.indexOf("redial.restart()") !== -1, "a dropped connection has to re-dial, or the pane goes quiet for the session");
        verify(state.indexOf("root.backoffMs * 2") !== -1, "and back off, so a daemon that is not installed costs one dial a half minute");
    }

    // op:"open" never re-sends what the client already holds. Passing null
    // there would replay the whole thread on every reconnect and double every
    // row in it.
    function test_open_passes_the_conversations_own_highest_seq() {
        const block = Scan.blockAfter(busSource(), "function open(conversation: string): void {");
        verify(block !== "", "AskBus must define open()");
        verify(block.indexOf("Ask.fromSeqOf(root.state, conversation)") !== -1, "from_seq is the highest seq held for THAT conversation, not null and not the global lastSeq");
    }

    // The rendering trap. ok false arrives on an interrupted turn too, so the
    // colour cannot come from it alone.
    function test_the_tool_row_never_colours_on_ok_alone() {
        const source = toolSource();
        const tone = Scan.blockAfter(source, "readonly property color toneColor: {");

        verify(tone !== "", "ToolCall must map a tone to a colour");
        verify(tone.indexOf(".ok") === -1, "the colour must not read result.ok: ok false means both a failure and a plain interrupt");
        verify(tone.indexOf('case "cancelled"') !== -1, "an interrupted tool needs a tone of its own, separate from an error");
        verify(source.indexOf("row.tone") !== -1, "the tone comes from ask.js, which is the only place that also sees turn_end.stop");
    }

    // The turn's stop is the authority, and it arrives after the result, so
    // the rows of a turn have to be re-toned when it closes.
    function test_turn_end_retones_the_turns_tool_rows() {
        const source = readSource("../../nix/home/quickshell/qml/services/ask.js");
        const block = Scan.blockAfter(source, "function endTurn(thread, event) {");

        verify(block !== "", "ask.js must define endTurn");
        verify(block.indexOf("toolTone(row, stop)") !== -1, "closing a turn has to re-tone its tool rows against the stop it just learned");
    }

    // Thinking is a progress indicator. The harness sends twelve empty deltas
    // a turn, so a text view driven off the backend name would be blank
    // forever on the one backend that is actually installed.
    function test_thinking_is_driven_by_what_arrived_not_by_the_backend() {
        const source = readSource("../../nix/home/quickshell/qml/ask/Message.qml");
        const block = Scan.blockAfter(source, "Component {\n        id: thinkingRow\n");

        verify(block !== "", "Message must have a thinking row");
        verify(block.indexOf("root.row.tokens") !== -1, "the indicator is driven by the token estimate");
        verify(block.indexOf("root.row.chars > 0") !== -1, "and real reasoning text shows only when text actually arrived");
        verify(block.indexOf("claude") === -1, "nothing here may switch on a backend name");
    }

    // The daemon sends code already highlighted. A highlighter or a markdown
    // parser in QML would run on the UI thread, per token, for nothing.
    function test_the_code_block_renders_what_it_is_given() {
        const source = readSource("../../nix/home/quickshell/qml/ask/CodeBlock.qml");

        verify(source.indexOf("Text.RichText") !== -1, "the pre-rendered html is drawn as rich text");
        verify(source.indexOf("Quickshell.clipboardText = root.source") !== -1, "copying must take the plain source, since copying the rich text would paste markup");
        verify(source.indexOf("Text.StyledText") === -1, "the plain fallback is raw source and StyledText would read an angle bracket in it as a tag");
    }

    // tree.nix owns the generated data files. backends.json has to be
    // generated from the toggles the same way quicklinks.json and keybinds.json
    // already are.
    function test_tree_nix_generates_the_backends_file() {
        const tree = treeSource();

        verify(tree.indexOf("backendsFile = pkgs.writeText \"backends.json\"") !== -1, "tree.nix must generate backends.json");
        verify(tree.indexOf("items = backends") !== -1, "wrapped in an object, since JsonAdapter refuses a non-object root");
        verify(tree.indexOf("cp ${backendsFile} \"$out/ask/backends.json\"") !== -1, "and copy it into the tree beside the pane that reads it");
    }

    // The surface has to be in shell.qml or nothing instantiates it.
    function test_the_pane_is_wired_into_the_shell() {
        const shell = readSource("../../nix/home/quickshell/qml/shell.qml");

        verify(shell.indexOf('import "ask"') !== -1, "shell.qml must import the ask directory");
        verify(/\bAsk\s*\{\s*\}/.test(shell), "and instantiate the pane alongside the other single-instance surfaces");
    }
}
