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
        verify(state.indexOf("root.retry()") !== -1, "a dropped connection has to re-dial, or the pane goes quiet for the session");
    }

    // A refused connection raises both onError and onConnectionStateChanged.
    // Doubling in each handler grows the wait 4x per attempt while the comment
    // beside it promises 2x, so both go through one scheduler that leaves an
    // already-armed redial alone.
    function test_one_failed_dial_backs_off_exactly_once() {
        const source = busSource();
        const retry = Scan.blockAfter(source, "function retry(): void {");

        verify(retry !== "", "AskBus must funnel both failure paths through retry()");
        verify(retry.indexOf("if (redial.running)") !== -1, "a redial already scheduled must not be backed off a second time for the same failure");
        verify(retry.indexOf("root.backoffMs * 2") !== -1, "and the backoff still has to double per attempt");
        verify(retry.indexOf("30000") !== -1, "capped, so a daemon that is not installed costs one dial a half minute");

        // Exactly one place multiplies the backoff. Two would be the bug this
        // test exists to stop, whatever the handlers happen to look like.
        const doublings = source.split("backoffMs * 2").length - 1;
        compare(doublings, 1, "exactly one place may double the backoff");
    }

    // With every dots.ai toggle off there is no daemon to reach, so the shell
    // must not open a socket or re-dial for the life of the session. The gate
    // itself stays in Ask.qml so the toggle decision has one home.
    function test_the_socket_does_not_dial_until_the_gate_opens() {
        const bus = busSource();
        const dial = Scan.blockAfter(bus, "function dial(): void {");

        verify(dial !== "", "AskBus must route every dial through one function");
        verify(dial.indexOf("if (!root.enabled") !== -1, "and refuse to dial before the gate is open");
        verify(bus.indexOf("Component.onCompleted") === -1, "the bus must not dial itself on completion: it cannot see the gate");

        const pane = paneSource();
        const gate = Scan.blockAfter(pane, "onGateChanged: {");

        verify(gate !== "", "Ask must open the gate when backends.json arrives");
        verify(gate.indexOf("AskBus.enable()") !== -1, "by telling the bus, rather than the bus reading backends.json a second time");
        verify(gate.indexOf("root.enabled()") !== -1, "and only when the toggle list is non-empty");
    }

    // A Flickable has no implicit height, so a card that measures itself
    // through a layout whose body is one measures its header alone. DiffView
    // shipped that way and rendered as a no-op. tst_ask_layout.qml proves the
    // rule; this pins the file to it.
    function test_the_diff_card_sums_its_body_height() {
        const source = readSource("../../nix/home/quickshell/qml/ask/DiffView.qml");
        const line = /implicitHeight:[^\n]*/.exec(source);

        verify(line !== null, "DiffView must declare an implicitHeight");
        verify(line[0].indexOf("body.implicitHeight") !== -1, "it has to sum the body's own implicitHeight: a fill-height Flickable contributes zero and the diff is clipped away");
        verify(line[0].indexOf("Theme.askCodeMaxHeight") !== -1, "and still cap, or a long diff grows without bound");
    }

    // The same rule, on the component that already got it right, so a later
    // edit cannot quietly regress CodeBlock into DiffView's old shape.
    function test_the_code_card_sums_its_body_height() {
        const source = readSource("../../nix/home/quickshell/qml/ask/CodeBlock.qml");
        const line = /implicitHeight:[^\n]*/.exec(source);

        verify(line !== null, "CodeBlock must declare an implicitHeight");
        verify(line[0].indexOf("body.implicitHeight") !== -1, "summed from the body, for the same reason DiffView has to");
    }

    // Assigning a JS array of a different length to `model` is a model reset:
    // it tears down the visible delegates and snaps contentY to 0. The fold
    // appends a row per block, tool call and status line, so a reader who
    // scrolled up got thrown to the top several times a turn.
    function test_the_thread_does_not_use_a_bare_array_model() {
        const source = readSource("../../nix/home/quickshell/qml/ask/Thread.qml");

        verify(/model:\s*root\.rows\b/.test(source) === false, "model: root.rows resets the view on every append and must not come back");
        verify(source.indexOf("model: ListModel {") !== -1, "the model has to be a ListModel, whose appends are insertions rather than resets");

        const sync = Scan.blockAfter(source, "function sync(): void {");
        verify(sync !== "", "Thread must sync the backing model to the row count");
        verify(sync.indexOf("backing.append(") !== -1, "growing by append");
        verify(sync.indexOf("backing.remove(") !== -1, "and shrinking by remove, never by replacing the model");

        const delegate = Scan.blockAfter(source, "delegate: Message {");
        verify(delegate.indexOf("root.rows[index]") !== -1, "the delegate reads the real row out of the array by index, since the model carries only a count");
    }

    // Deleting the open thread has to let go of it. Otherwise the pane keeps
    // rendering a thread the daemon dropped, and persist() writes the dead id
    // into session.json for the next session to restore.
    function test_deleting_the_open_thread_clears_it() {
        const block = Scan.blockAfter(paneSource(), "function forget(conversation: string): void {");

        verify(block !== "", "Ask must define forget()");
        verify(block.indexOf("root.conversation === conversation") !== -1, "deleting the open thread has to be told apart from deleting another one");
        verify(block.indexOf("root.persist()") !== -1, "and the cleared id has to reach session.json, or the next session restores a dead thread");
        verify(block.indexOf("AskBus.remove(conversation)") !== -1, "the daemon still has to be told");
    }

    // The bus half of the same fact. `subscribed` is what a reconnect
    // re-opens, so a deleted id left there makes the next dropped connection
    // send op:"open" for a conversation the daemon no longer has.
    function test_deleting_the_subscribed_thread_clears_the_subscription() {
        const block = Scan.blockAfter(busSource(), "function remove(conversation: string): void {");

        verify(block !== "", "AskBus must define remove()");
        verify(block.indexOf("root.subscribed") !== -1, "removing the subscribed thread has to drop the subscription, or a reconnect re-opens a dead conversation");
        verify(block.indexOf("Ask.deleteFrame(conversation)") !== -1, "and the daemon still has to be told");
    }

    // Clicking the already-active backend pill is not a swap, and must not
    // abandon the open thread on its way to changing nothing.
    function test_repicking_the_same_backend_keeps_the_thread() {
        const block = Scan.blockAfter(paneSource(), "onBackendPicked: id => {");

        verify(block !== "", "Ask must handle onBackendPicked");
        verify(block.indexOf("if (id === root.backend)") !== -1, "re-picking the active backend has to return early");
        verify(block.indexOf('root.conversation = ""') !== -1, "a real swap still starts a new thread, since the harness respawns with different argv");
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

    // -- the escaping boundary ---------------------------------------------
    //
    // WHERE render.rs's ALLOWLIST STOPS. Phase 2 built a tag allowlist so
    // that `code_block.html` and `diff.html` are safe to hand to
    // Text.RichText. Those two fields are the whole of its scope. Every OTHER
    // model-derived string on this protocol reaches the pane unescaped:
    // `text_delta.text`, `tool_result.content`, `plan.title`,
    // `plan.markdown`, `tool_call.name`, `tool_call.summary`,
    // `tool_call.input`, `permission_request.description`, `diff.path`,
    // `code_block.language`, `error.message` and a thread title the model
    // named.
    //
    // A `Text` with no `textFormat` is `Text.AutoText`, which calls
    // Qt::mightBeRichText() and parses anything that looks like markup AS
    // markup. Qt then resolves `<img src>` through QQuickPixmap for `http:`
    // and `file:`, and there is no property that turns that off. So a tool
    // result carrying `<img src="http://…/?leak">` would be a request off
    // this machine, drawn by a pane that never decided to allow one.
    //
    // Every binding below therefore names PlainText explicitly. AutoText is
    // never the right answer for a string this daemon did not build itself,
    // and "it happens not to contain a tag today" is not a property of a
    // string the model chooses.
    //
    // ARTIFACTS DO NOT INHERIT THIS, and that is the point of phase 5's
    // security work rather than a footnote. An artifact is model-written HTML
    // opened in a real Chromium, where script runs and `fetch` works. Nothing
    // above helps there. Its containment is the CSP that
    // rust/ask-daemon/src/artifact/serve.rs puts on every response, and it is
    // a separate argument with separate tests.
    function test_every_model_derived_string_is_drawn_as_plain_text() {
        // file, then the bindings in it that carry model output. A binding is
        // named by the source substring that identifies it, and the check is
        // that a `textFormat: Text.PlainText` follows it before the block
        // ends.
        const guarded = [
            ["../../nix/home/quickshell/qml/ask/ToolCall.qml", [
                "root.row.displayName ?? root.row.name",
                "root.row.summary ?? \"\"",
                "JSON.stringify(root.row.input, null, 2)",
                "root.row.result.content"
            ]],
            ["../../nix/home/quickshell/qml/ask/Approval.qml", [
                "root.request.displayName ?? root.request.name",
                "root.request.description ??"
            ]],
            ["../../nix/home/quickshell/qml/ask/Message.qml", [
                "text: root.row.title ??",
                "${root.row.errorKind}: ${root.row.message}"
            ]],
            ["../../nix/home/quickshell/qml/ask/History.qml", [
                "entry.modelData.title ??"
            ]],
            ["../../nix/home/quickshell/qml/ask/DiffView.qml", [
                "text: root.path"
            ]],
            ["../../nix/home/quickshell/qml/ask/CodeBlock.qml", [
                "root.language === \"\" ? \"code\" : root.language"
            ]],
            ["../../nix/home/quickshell/qml/ask/Ask.qml", [
                "${AskBus.notice.kind}: ${AskBus.notice.message}"
            ]]
        ];

        for (const [path, bindings] of guarded) {
            const source = readSource(path);
            for (const binding of bindings) {
                const at = source.indexOf(binding);
                verify(at !== -1, path + " no longer contains " + binding);

                // The next 200 characters cover the rest of the property
                // block; a textFormat further away than that belongs to a
                // different element.
                const after = source.slice(at, at + 200);
                verify(after.indexOf("textFormat: Text.PlainText") !== -1,
                       path + ": " + binding + " must be drawn as PlainText, "
                       + "because Text.AutoText parses model output as markup");
            }
        }
    }

    // The two fields render.rs DOES escape are the two allowed to be rich,
    // and only while the daemon actually populated them. `html` is null until
    // a backend renders one, and falling back to the raw source under
    // RichText would draw exactly the markup the allowlist exists to strip.
    function test_only_the_two_rendered_fields_reach_rich_text() {
        const code = readSource("../../nix/home/quickshell/qml/ask/CodeBlock.qml");
        const diff = readSource("../../nix/home/quickshell/qml/ask/DiffView.qml");

        verify(code.indexOf("textFormat: root.highlighted ? Text.RichText : Text.PlainText") !== -1,
               "CodeBlock must fall back to PlainText when html is null");
        verify(diff.indexOf("textFormat: root.rendered ? Text.RichText : Text.PlainText") !== -1,
               "DiffView must fall back to PlainText when html is null");

        // And nothing else in the pane may reach for RichText at all.
        const others = ["Message.qml", "ToolCall.qml", "Approval.qml", "History.qml",
                        "Composer.qml", "Thread.qml", "Ask.qml"];
        for (const name of others) {
            const source = readSource("../../nix/home/quickshell/qml/ask/" + name);
            verify(source.indexOf("Text.RichText") === -1,
                   name + " must not use RichText: only code_block.html and "
                   + "diff.html go through render.rs's allowlist");
        }
    }
}
