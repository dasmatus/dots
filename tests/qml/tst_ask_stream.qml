// The ask pane's event folding, driven by synthetic events with no daemon and
// no socket anywhere.
//
// qmltestrunner cannot instantiate AskBus.qml: it inherits a Quickshell type
// and owns a Socket, which tests/README.md rules out. So the arithmetic lives
// in services/ask.js and this drives applyEvents directly, which is the same
// entry point the bus calls from its flush timer.
//
// The two cases that carry the most weight are the coalescing rule and the
// interrupt rule, and neither is a style preference. A model that pushes one
// row per token relayouts the ListView a few hundred times on one answer. A
// tool row toned on `ok` alone paints an error-looking row on every turn the
// user cancelled on purpose, which is measured behaviour: the CLI feeds the
// model a rejection on an interrupt, so ok arrives false on a turn the schema
// says did not error.
//
// This file covers the arithmetic alone. tst_ask_wiring.qml covers the
// callers, by reading AskBus.qml and Ask.qml as text, because a caller that
// stopped calling any of this would leave every assertion here green.
import QtQuick
import QtTest
import "sourcescan.js" as Scan
import "../../nix/home/quickshell/qml/services/ask.js" as Ask

TestCase {
    name: "AskStream"

    readonly property string conversation: "6f1a0000-0000-4000-8000-000000000001"
    readonly property string turn: "c3d00000-0000-4000-8000-000000000002"

    function turnStart(seq) {
        return {
            seq: seq,
            conversation: conversation,
            event: "turn_start",
            turn: turn,
            backend: "claude-code",
            model: "claude-opus-5",
            started_ms: 1788425059000
        };
    }

    function textDelta(seq, text) {
        return {
            seq: seq,
            conversation: conversation,
            event: "text_delta",
            turn: turn,
            block: 0,
            text: text
        };
    }

    function turnEnd(seq, stop) {
        return {
            seq: seq,
            conversation: conversation,
            event: "turn_end",
            turn: turn,
            stop: stop,
            text: stop === "interrupted" ? null : "done",
            duration_ms: 15673
        };
    }

    function toolCall(seq, call) {
        return {
            seq: seq,
            conversation: conversation,
            event: "tool_call",
            turn: turn,
            call: call,
            name: "Write",
            display_name: "Write",
            summary: "a.txt",
            input: {
                file_path: "/tmp/a.txt",
                content: "alpha\n"
            },
            origin: "harness"
        };
    }

    function toolResult(seq, call, ok, content) {
        return {
            seq: seq,
            conversation: conversation,
            event: "tool_result",
            call: call,
            ok: ok,
            content: content,
            truncated: false
        };
    }

    function rowsOfKind(state, kind) {
        return Ask.rowsOf(state, conversation).filter(row => row.kind === kind);
    }

    // The whole reason the bus buffers on a 16ms timer. A burst of deltas for
    // one content block is ONE row carrying the whole string, not one row per
    // token, so the ListView relayouts once a frame instead of once a token.
    function test_a_burst_of_deltas_coalesces_into_one_message() {
        const words = ["The", " quick", " brown", " fox", " jumps", " over", " the", " lazy", " dog"];
        const events = [turnStart(1)];

        for (let i = 0; i < words.length; i++)
            events.push(textDelta(2 + i, words[i]));

        const state = Ask.applyEvents(Ask.emptyState(), events);
        const rows = rowsOfKind(state, "text");

        compare(rows.length, 1, `${words.length} deltas for one block must fold into one row, not ${rows.length}`);
        compare(rows[0].text, words.join(""), "the folded row must carry every delta in arrival order");
    }

    // Coalescing across separate batches too. The bus flushes once a frame, so
    // a real turn arrives as many small batches and the row has to survive the
    // seam between them.
    function test_deltas_coalesce_across_separate_flushes() {
        let state = Ask.applyEvents(Ask.emptyState(), [turnStart(1), textDelta(2, "one ")]);
        state = Ask.applyEvents(state, [textDelta(3, "two ")]);
        state = Ask.applyEvents(state, [textDelta(4, "three")]);

        const rows = rowsOfKind(state, "text");

        compare(rows.length, 1, "three flushes of the same block must still be one row");
        compare(rows[0].text, "one two three", "the row must survive the flush seam with its text intact");
    }

    // A new turn reusing block 0 is a new paragraph, not a continuation of the
    // last one. turn_end has to release the open block or every answer in a
    // session would grow onto the end of the first.
    function test_a_new_turn_starts_a_new_row_for_the_same_block() {
        const second = "c3d00000-0000-4000-8000-000000000003";
        let state = Ask.applyEvents(Ask.emptyState(), [turnStart(1), textDelta(2, "first"), turnEnd(3, "end_turn")]);

        state = Ask.applyEvents(state, [
            {
                seq: 4,
                conversation: conversation,
                event: "turn_start",
                turn: second,
                backend: "claude-code",
                model: "claude-opus-5",
                started_ms: 1788425060000
            },
            {
                seq: 5,
                conversation: conversation,
                event: "text_delta",
                turn: second,
                block: 0,
                text: "second"
            }
        ]);

        const rows = rowsOfKind(state, "text");

        compare(rows.length, 2, "a second turn must open its own row for block 0");
        compare(rows[0].text, "first");
        compare(rows[1].text, "second");
    }

    // AN INTERRUPTED TURN IS NOT A FAILED TURN. Fixture line 129: the CLI
    // feeds the model its own canned rejection when the user interrupts, so
    // ok arrives false on a turn the schema says raised no error. turn_end
    // arrives afterwards and is the only authority, which is why the tone has
    // to be recomputed when it lands.
    function test_an_interrupted_tool_result_is_cancelled_not_failed() {
        const call = "toolu_0147PnvrgYvQkbYPA9HjHzod";
        let state = Ask.applyEvents(Ask.emptyState(), [turnStart(1), toolCall(2, call), toolResult(3, call, false, "User rejected tool use")]);

        const midTurn = rowsOfKind(state, "tool")[0];
        compare(midTurn.tone, "error", "with no turn_end yet, an ok-false result is genuinely a failure so far");

        state = Ask.applyEvents(state, [turnEnd(4, "interrupted")]);

        const settled = rowsOfKind(state, "tool")[0];
        compare(settled.tone, "cancelled", "turn_end stop interrupted must re-tone the tool row: the CLI's rejection is not a failure");
        verify(settled.tone !== "error", "an interrupted turn must not paint an error-looking row");
    }

    // The other half of that rule. A tool that really failed on a turn that
    // really failed must stay red, or the fix above would have papered over
    // every failure in the pane.
    function test_a_failed_tool_on_a_failed_turn_stays_an_error() {
        const call = "toolu_0999";
        const state = Ask.applyEvents(Ask.emptyState(), [turnStart(1), toolCall(2, call), toolResult(3, call, false, "ENOSPC"), turnEnd(4, "error")]);

        compare(rowsOfKind(state, "tool")[0].tone, "error", "a genuine failure must survive the interrupt carve-out");
    }

    // An interrupt raises turn_end alone. The daemon emits no error event for
    // it, so nothing here may synthesize one either.
    function test_an_interrupt_produces_no_error_row() {
        const state = Ask.applyEvents(Ask.emptyState(), [turnStart(1), textDelta(2, "partial"), turnEnd(3, "interrupted")]);

        compare(rowsOfKind(state, "error").length, 0, "an interrupt is not an error and must not push an error row");
        compare(rowsOfKind(state, "status").length, 1, "it must still say the turn was interrupted");
        compare(rowsOfKind(state, "status")[0].stop, "interrupted");
        verify(!Ask.isFailure("interrupted"), "isFailure must not call an interrupt a failure");
    }

    // A completed turn needs no footer. Saying "Done" after every answer is
    // noise the reader learns to skip past.
    function test_a_clean_turn_adds_no_status_row() {
        const state = Ask.applyEvents(Ask.emptyState(), [turnStart(1), textDelta(2, "hello"), turnEnd(3, "end_turn")]);

        compare(rowsOfKind(state, "status").length, 0, "end_turn is the ordinary case and needs no row of its own");
    }

    // Measured: all 12 harness thinking deltas carry an empty string, and only
    // estimated_tokens carries signal. The row has to record that no text
    // arrived, so the pane can show a progress indicator rather than a
    // permanently blank text view.
    function test_harness_thinking_folds_to_a_token_count_with_no_text() {
        const events = [turnStart(1)];
        for (let i = 0; i < 12; i++) {
            events.push({
                seq: 2 + i,
                conversation: conversation,
                event: "thinking_delta",
                turn: turn,
                block: 0,
                text: "",
                tokens: 50 + i * 10
            });
        }

        const rows = rowsOfKind(Ask.applyEvents(Ask.emptyState(), events), "thinking");

        compare(rows.length, 1, "twelve thinking deltas are one indicator, not twelve rows");
        compare(rows[0].chars, 0, "the harness sends no reasoning text and the row must say so");
        compare(rows[0].tokens, 160, "the latest token estimate is the only signal there is");
    }

    // A raw provider that does send reasoning text has to be told apart from
    // the harness that does not, without anything naming the backend.
    function test_real_thinking_text_is_kept() {
        const state = Ask.applyEvents(Ask.emptyState(), [turnStart(1), {
                seq: 2,
                conversation: conversation,
                event: "thinking_delta",
                turn: turn,
                block: 0,
                text: "let me check ",
                tokens: null
            }, {
                seq: 3,
                conversation: conversation,
                event: "thinking_delta",
                turn: turn,
                block: 0,
                text: "the parser",
                tokens: null
            }]);

        const row = rowsOfKind(state, "thinking")[0];

        compare(row.text, "let me check the parser");
        verify(row.chars > 0, "a provider that really streams reasoning must not be mistaken for the harness");
    }

    // The pane must dismiss a withdrawn prompt and must not answer it.
    function test_a_withdrawn_permission_request_is_dropped() {
        const call = "toolu_0147";
        const request = "9dc45437-01a3-4d31-b99e-9957760c4e01";

        let state = Ask.applyEvents(Ask.emptyState(), [turnStart(1), toolCall(2, call), {
                seq: 3,
                conversation: conversation,
                event: "permission_request",
                request: request,
                call: call,
                name: "Write",
                display_name: "Write",
                description: "a.txt",
                input: {},
                suggestions: [],
                withdrawn: false
            }]);

        compare(Ask.pendingApprovals(state, conversation).length, 1, "an open prompt has to reach the pane");

        state = Ask.applyEvents(state, [{
                seq: 4,
                conversation: conversation,
                event: "permission_request",
                request: request,
                call: call,
                name: "Write",
                display_name: "Write",
                description: "a.txt",
                input: {},
                suggestions: [],
                withdrawn: true
            }]);

        compare(Ask.pendingApprovals(state, conversation).length, 0, "a withdrawn prompt must be dropped, not answered late");
    }

    // An interrupt withdraws whatever prompt was open. Answering it afterwards
    // would be answering a request the CLI has already cancelled.
    function test_an_interrupt_clears_an_open_permission_request() {
        const call = "toolu_0148";
        const state = Ask.applyEvents(Ask.emptyState(), [turnStart(1), toolCall(2, call), {
                seq: 3,
                conversation: conversation,
                event: "permission_request",
                request: "a8f8ddef",
                call: call,
                name: "Write",
                display_name: "Write",
                description: "c.txt",
                input: {},
                suggestions: [],
                withdrawn: false
            }, turnEnd(4, "interrupted")]);

        compare(Ask.pendingApprovals(state, conversation).length, 0, "an interrupted turn leaves no prompt for the user to answer");
    }

    // A result, a diff or a prompt can name a call the tool_call event has not
    // arrived for yet. That must not drop the event on the floor.
    function test_a_result_before_its_tool_call_still_lands() {
        const call = "toolu_0150";
        let state = Ask.applyEvents(Ask.emptyState(), [turnStart(1), toolResult(2, call, true, "written")]);

        compare(rowsOfKind(state, "tool").length, 1, "an early result has to open its own row");

        state = Ask.applyEvents(state, [toolCall(3, call)]);

        const rows = rowsOfKind(state, "tool");
        compare(rows.length, 1, "the late tool_call must fill in the row it already has, not add a second");
        compare(rows[0].name, "Write");
        compare(rows[0].tone, "ok");
    }

    // The schema makes tool_result.ok a required bool, so this only bites on a
    // field that went missing. The schema's own default for that is success:
    // the harness omits is_error entirely on the success path and sets it only
    // on the two non-execution paths. Defaulting the other way would paint a
    // failed row for a field nobody sent.
    function test_a_missing_ok_reads_as_success() {
        const call = "toolu_0151";
        const state = Ask.applyEvents(Ask.emptyState(), [turnStart(1), toolCall(2, call), {
                seq: 3,
                conversation: conversation,
                event: "tool_result",
                call: call,
                content: "File created successfully",
                truncated: false
            }]);

        compare(rowsOfKind(state, "tool")[0].tone, "ok", "a missing is_error means success, and a missing ok has to follow it");
    }

    // hello replays every persisted event above resume_seq, and that boundary
    // does not respect turn starts. A reconnect landing mid-answer must not
    // drop the cost and the stop reason for the turn it landed inside.
    function test_a_replay_that_starts_mid_turn_keeps_usage_and_the_stop() {
        const state = Ask.applyEvents(Ask.emptyState(), [textDelta(4300, "resumed"), {
                seq: 4301,
                conversation: conversation,
                event: "usage",
                turn: turn,
                input_tokens: 6,
                output_tokens: 811,
                cache_read_tokens: 83100,
                cache_write_tokens: 12489,
                thinking_tokens: 576,
                cost_usd: 0.186745,
                rate_limit: null
            }, turnEnd(4302, "interrupted")]);

        compare(rowsOfKind(state, "status")[0].stop, "interrupted", "a turn whose turn_start was never replayed still has to end");
        compare(Ask.rowsOf(state, conversation).length, 2, "and its text still has to render");

        // The half this test is named for and used to skip. Dropping the usage
        // record is what correction 2 in a2d4edd actually fixed, and asserting
        // only the status row left that fix uncovered.
        const usage = state.threads[conversation].turns[turn].usage;

        verify(usage !== null && usage !== undefined, "the usage for a turn whose turn_start was never replayed must still be recorded");
        compare(usage.outputTokens, 811);
        compare(usage.cacheReadTokens, 83100);
        compare(usage.costUsd, 0.186745);
        compare(state.threads[conversation].turns[turn].stop, "interrupted", "and the stop has to land on the same record the usage did");
    }

    // A backend with no estimate sends tokens null, and that must not wipe a
    // count an earlier delta already reported.
    function test_a_null_token_estimate_does_not_erase_the_last_one() {
        const state = Ask.applyEvents(Ask.emptyState(), [turnStart(1), {
                seq: 2,
                conversation: conversation,
                event: "thinking_delta",
                turn: turn,
                block: 0,
                text: "",
                tokens: 120
            }, {
                seq: 3,
                conversation: conversation,
                event: "thinking_delta",
                turn: turn,
                block: 0,
                text: "",
                tokens: null
            }]);

        compare(rowsOfKind(state, "thinking")[0].tokens, 120, "tokens is Option and a null one carries no news, so it must not clear the count");
    }

    // op:"open" passes the highest seq the client already holds, and the
    // daemon sends strictly greater. Getting this wrong duplicates the whole
    // thread on every reconnect.
    function test_from_seq_is_the_highest_seq_the_client_holds() {
        compare(Ask.fromSeqOf(Ask.emptyState(), conversation), null, "a thread nothing has arrived for wants the whole history");

        const state = Ask.applyEvents(Ask.emptyState(), [turnStart(4210), textDelta(4211, "hi"), turnEnd(4212, "end_turn")]);

        compare(Ask.fromSeqOf(state, conversation), 4212, "from_seq must be the highest seq held, not the first or the count");
        compare(state.lastSeq, 4212, "hello resumes from the highest seq across every conversation");
    }

    // ready, conversations and backends are ephemeral per-connection replies:
    // seq null, conversation null, never persisted. Letting one move lastSeq
    // would make a reconnect ask the daemon to resume from a seq that never
    // existed.
    function test_an_ephemeral_reply_does_not_move_the_resume_point() {
        let state = Ask.applyEvents(Ask.emptyState(), [turnStart(10), turnEnd(11, "end_turn")]);

        state = Ask.applyEvents(state, [{
                seq: null,
                conversation: null,
                event: "ready",
                protocol: 1,
                seq_head: 4211
            }, {
                seq: null,
                conversation: null,
                event: "backends",
                items: [
                    {
                        id: "claude-code",
                        label: "Claude Code",
                        state: "ready",
                        models: ["opus", "sonnet"],
                        detail: null
                    }
                ]
            }]);

        compare(state.lastSeq, 11, "an ephemeral reply carries seq null and must not move the resume point");
        verify(state.ready, "ready still has to mark the connection up");
        compare(state.backends.length, 1);
    }

    // A connection-scoped error names no thread, so it cannot become a row in
    // one. It is never fatal either: it killed no conversation.
    function test_a_connection_scoped_error_lands_on_the_banner() {
        const state = Ask.applyEvents(Ask.emptyState(), [{
                seq: null,
                conversation: null,
                event: "error",
                kind: "bad_request",
                message: "unknown op \"opne\"",
                fatal: false
            }]);

        compare(state.notice.kind, "bad_request");
        compare(Ask.rowsOf(state, conversation).length, 0, "a connection-scoped error names no thread to file itself under");
    }

    function test_a_conversation_scoped_error_becomes_a_row() {
        const state = Ask.applyEvents(Ask.emptyState(), [{
                seq: 4238,
                conversation: conversation,
                event: "error",
                kind: "protocol",
                message: "unparseable control_request",
                fatal: false
            }]);

        compare(rowsOfKind(state, "error").length, 1);
        compare(state.notice, null, "a conversation-scoped error belongs in its thread, not on the banner");
    }

    // The gate is the Nix toggle list, and the daemon can only ever narrow it.
    // An empty gate means no pane at all, which is what Ask.qml's toggle
    // checks before it does anything else.
    function test_an_empty_gate_offers_no_backend() {
        compare(Ask.selectableBackends(Ask.emptyState(), []).length, 0);
        compare(Ask.selectableBackends(Ask.emptyState(), null).length, 0);
    }

    function test_a_gated_backend_the_daemon_has_not_answered_for_still_lists() {
        const gate = [
            {
                id: "ollama",
                label: "Ollama"
            }
        ];
        const offered = Ask.selectableBackends(Ask.emptyState(), gate);

        compare(offered.length, 1, "a toggle that is on must show even before the daemon answers");
        compare(offered[0].state, "unreachable", "and it must say it cannot answer yet rather than claiming to be ready");
    }

    // Frame shapes, because the daemon parses these and a typo here is a
    // bad_request the pane cannot explain.
    function test_client_frames_match_the_wire_schema() {
        compare(Ask.helloFrame(null).resume_seq, null, "a cold start holds nothing");
        compare(Ask.helloFrame(4210).protocol, 1);
        compare(Ask.openFrame(conversation, 12).from_seq, 12);
        compare(Ask.sendFrame(conversation, [Ask.textBlock("hi")]).blocks[0].kind, "text");
        compare(Ask.interruptFrame(conversation).op, "interrupt");
        compare(Ask.permissionFrame(conversation, "req", "allow", "forever", null, null).scope, "forever");

        const id = Ask.newConversationId();
        verify(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(id), `the client mints its own conversation id and it has to be a uuid: ${id}`);
    }
}
