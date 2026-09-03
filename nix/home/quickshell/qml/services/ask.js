// The arithmetic behind the ask pane: folding the daemon's normalized event
// stream into the rows a thread draws, and building the client frames that go
// back the other way.
//
// It lives here rather than inside AskBus.qml for the reason tests/README.md
// gives: qmltestrunner cannot instantiate a component that inherits a
// Quickshell type, and AskBus owns a Socket. A `.pragma library` file has no
// such problem, so tst_ask_stream.qml drives a whole recorded turn through
// applyEvents() with no daemon, no socket and no compositor anywhere.
//
// The wire schema is docs/superpowers/specs/2026-09-03-ask-pane-design.md,
// section "Normalized event schema". Two of its rules shape this file more
// than the rest:
//
// A burst of text_delta events for one block is ONE row, not one row per
// token. appendText below finds the open row for (turn, block) and grows it.
// AskBus buffers the deltas and calls in here once a frame, so a fast turn
// costs one array rebuild per frame instead of one per token.
//
// An interrupted turn is not a failed turn. The CLI still feeds the model a
// rejection when the user interrupts, so a tool_result arrives with ok false
// on a turn the schema says did not error (fixture line 129). turn_end.stop
// is the only authority on that, which is why toolTone takes the turn's stop
// and why endTurn re-tones every tool row of the turn it closes. Reading
// ok alone paints an error-looking row on every interrupted turn.
.pragma library

// A conversation that has received nothing yet.
//
// `open` maps "<turn>:<block>" to the index of the row currently growing for
// that content block, which is what makes delta coalescing O(1) rather than a
// scan back through the rows. `calls` maps a backend tool-use id to its row
// index, because tool_result, permission_request and diff all correlate
// through `call` and carry no turn of their own.
function emptyThread() {
    return {
        rows: [],
        open: {},
        calls: {},
        turns: {},
        maxSeq: null,
        live: null
    };
}

// The whole client-side model. `threads` is keyed by conversation id;
// `conversations` and `backends` come from the ephemeral replies, which carry
// seq null and never persist.
function emptyState() {
    return {
        protocol: null,
        ready: false,
        seqHead: null,
        lastSeq: null,
        backends: [],
        conversations: [],
        threads: {},
        notice: null
    };
}

// Folds a batch of daemon events into a NEW state object.
//
// New rather than mutated because a QML `var` property assigned the object it
// already holds fires no change signal, so every binding reading the model
// would go stale. The copy is shallow: only the threads a batch actually
// touches are cloned, through threadOf below.
function applyEvents(state, events) {
    const next = {
        protocol: state.protocol,
        ready: state.ready,
        seqHead: state.seqHead,
        lastSeq: state.lastSeq,
        backends: state.backends,
        conversations: state.conversations,
        threads: Object.assign({}, state.threads),
        notice: state.notice
    };

    const touched = {};
    for (let i = 0; i < events.length; i++)
        fold(next, touched, events[i]);

    return next;
}

// The single-event form, for a caller with one event in hand.
function applyEvent(state, event) {
    return applyEvents(state, [event]);
}

// The conversation's thread, cloned once per batch before anything writes to
// it. Rows are sliced rather than shared: a delegate still holding the
// previous array must not see rows appear under it without a change signal.
function threadOf(next, touched, id) {
    if (!id)
        return null;

    if (!touched[id]) {
        const prior = next.threads[id];

        next.threads[id] = prior ? {
            rows: prior.rows.slice(),
            open: Object.assign({}, prior.open),
            calls: Object.assign({}, prior.calls),
            turns: Object.assign({}, prior.turns),
            maxSeq: prior.maxSeq,
            live: prior.live
        } : emptyThread();

        touched[id] = true;
    }

    return next.threads[id];
}

// Routes one event to its handler and records the seq it carried.
//
// A persisted event carries a real seq and a conversation; an ephemeral reply
// carries null for both. lastSeq is what a reconnecting client resumes from,
// so only the persisted half may move it.
function fold(next, touched, event) {
    if (!event || typeof event !== "object" || !event.event)
        return;

    if (typeof event.seq === "number") {
        if (next.lastSeq === null || event.seq > next.lastSeq)
            next.lastSeq = event.seq;
    }

    const thread = threadOf(next, touched, event.conversation);

    if (thread && typeof event.seq === "number") {
        if (thread.maxSeq === null || event.seq > thread.maxSeq)
            thread.maxSeq = event.seq;
    }

    switch (event.event) {
    case "ready":
        next.ready = true;
        next.protocol = event.protocol ?? null;
        next.seqHead = event.seq_head ?? null;
        return;
    case "conversations":
        next.conversations = event.items ?? [];
        return;
    case "backends":
        next.backends = event.items ?? [];
        return;
    case "error":
        foldError(next, thread, event);
        return;
    }

    if (!thread)
        return;

    switch (event.event) {
    case "turn_start":
        startTurn(thread, event);
        return;
    case "text_delta":
        appendText(thread, event);
        return;
    case "thinking_delta":
        appendThinking(thread, event);
        return;
    case "code_block":
        pushCode(thread, event);
        return;
    case "tool_call":
        pushToolCall(thread, event);
        return;
    case "tool_result":
        attachResult(thread, event);
        return;
    case "permission_request":
        attachPermission(thread, event);
        return;
    case "diff":
        attachDiff(thread, event);
        return;
    case "plan":
        pushPlan(thread, event);
        return;
    case "usage":
        recordUsage(thread, event);
        return;
    case "turn_end":
        endTurn(thread, event);
        return;
    }
}

// A connection-scoped error names no thread, so it lands on `notice` where the
// pane shows it as a banner. A conversation-scoped one becomes a row in the
// thread it killed or complained about.
function foldError(next, thread, event) {
    const record = {
        kind: event.kind ?? "protocol",
        message: event.message ?? "",
        fatal: event.fatal === true
    };

    if (!thread) {
        next.notice = record;
        return;
    }

    thread.rows.push({
        kind: "error",
        errorKind: record.kind,
        message: record.message,
        fatal: record.fatal
    });

    if (record.fatal)
        thread.live = null;
}

function startTurn(thread, event) {
    thread.turns[event.turn] = {
        id: event.turn,
        backend: event.backend ?? null,
        model: event.model ?? null,
        startedMs: event.started_ms ?? null,
        stop: null,
        durationMs: null,
        usage: null
    };
    thread.live = event.turn;
}

// The coalescing rule. One row per (turn, block), grown in place, with the row
// object replaced rather than mutated so a delegate bound to modelData.text
// re-evaluates.
function appendText(thread, event) {
    const key = `${event.turn}:${event.block}`;
    const at = thread.open[key];
    const text = event.text ?? "";

    if (at !== undefined && thread.rows[at] && thread.rows[at].kind === "text") {
        const row = thread.rows[at];
        thread.rows[at] = {
            kind: "text",
            turn: row.turn,
            block: row.block,
            text: row.text + text
        };
        return;
    }

    thread.open[key] = thread.rows.length;
    thread.rows.push({
        kind: "text",
        turn: event.turn ?? null,
        block: event.block ?? 0,
        text: text
    });
}

// Thinking is a progress row, never a transcript. The claude harness sends 12
// thinking_delta events per turn and every one carries an empty string, so a
// text view here would be permanently blank. `tokens` is the only signal, and
// `chars` records whether any text ever arrived so a raw provider that does
// send reasoning can be told apart from the harness that does not, without
// anything having to name the backend.
function appendThinking(thread, event) {
    const key = `${event.turn}:thinking:${event.block}`;
    const at = thread.open[key];
    const text = event.text ?? "";
    const tokens = event.tokens ?? null;

    if (at !== undefined && thread.rows[at] && thread.rows[at].kind === "thinking") {
        const row = thread.rows[at];
        thread.rows[at] = {
            kind: "thinking",
            turn: row.turn,
            block: row.block,
            tokens: tokens === null ? row.tokens : tokens,
            chars: row.chars + text.length,
            text: row.text + text
        };
        return;
    }

    thread.open[key] = thread.rows.length;
    thread.rows.push({
        kind: "thinking",
        turn: event.turn ?? null,
        block: event.block ?? 0,
        tokens: tokens,
        chars: text.length,
        text: text
    });
}

// Code arrives already highlighted. `html` is the small rich-text subset a QML
// Text element draws, produced by the daemon's render.rs, so nothing here
// parses markdown or picks a colour per token. `source` is what the copy
// button puts on the clipboard, since the rich text is for the eye only.
function pushCode(thread, event) {
    thread.rows.push({
        kind: "code",
        turn: event.turn ?? null,
        block: event.block ?? 0,
        language: event.language ?? null,
        source: event.source ?? "",
        html: event.html ?? null
    });
}

function pushToolCall(thread, event) {
    const at = toolRowAt(thread, event.call);
    const row = Object.assign({}, thread.rows[at], {
        turn: event.turn ?? thread.rows[at].turn,
        name: event.name ?? thread.rows[at].name,
        displayName: event.display_name ?? null,
        summary: event.summary ?? null,
        input: event.input ?? null,
        origin: event.origin ?? null
    });

    row.tone = toolTone(row, stopOf(thread, row.turn));
    thread.rows[at] = row;
}

// The index of the tool row for `call`, creating an empty one when a result, a
// permission request or a diff reaches this thread before the tool_call that
// names them.
//
// Callers write through Object.assign into a fresh object rather than mutating
// the row in place. Rows are sliced when a thread is cloned, so the array is
// safe to write, but the row OBJECTS are still the ones the previously
// published state handed to the ListView. A delegate bound to modelData.result
// would never re-evaluate if that object changed under it.
function toolRowAt(thread, call) {
    const at = thread.calls[call];
    if (at !== undefined && thread.rows[at])
        return at;

    thread.calls[call] = thread.rows.length;
    thread.rows.push({
        kind: "tool",
        turn: null,
        call: call,
        name: "",
        displayName: null,
        summary: null,
        input: null,
        origin: null,
        result: null,
        permission: null,
        diff: null,
        tone: "pending"
    });

    return thread.calls[call];
}

function attachResult(thread, event) {
    const at = toolRowAt(thread, event.call);
    const row = Object.assign({}, thread.rows[at], {
        result: {
            ok: event.ok === true,
            content: event.content ?? "",
            truncated: event.truncated === true
        }
    });

    row.tone = toolTone(row, stopOf(thread, row.turn));
    thread.rows[at] = row;
}

// The pane must dismiss a withdrawn prompt and must not answer it, so
// withdrawn true clears the request rather than recording a second one.
function attachPermission(thread, event) {
    const at = toolRowAt(thread, event.call);

    if (event.withdrawn === true) {
        thread.rows[at] = Object.assign({}, thread.rows[at], {
            permission: null
        });
        return;
    }

    thread.rows[at] = Object.assign({}, thread.rows[at], {
        permission: {
            request: event.request,
            call: event.call,
            name: event.name ?? thread.rows[at].name,
            displayName: event.display_name ?? null,
            description: event.description ?? null,
            input: event.input ?? null,
            suggestions: event.suggestions ?? []
        }
    });
}

function attachDiff(thread, event) {
    const at = toolRowAt(thread, event.call);

    thread.rows[at] = Object.assign({}, thread.rows[at], {
        diff: {
            path: event.path ?? "",
            oldText: event.old_text ?? "",
            newText: event.new_text ?? "",
            added: event.added ?? 0,
            removed: event.removed ?? 0,
            html: event.html ?? null
        }
    });
}

function pushPlan(thread, event) {
    thread.rows.push({
        kind: "plan",
        turn: event.turn ?? null,
        title: event.title ?? null,
        markdown: event.markdown ?? "",
        state: event.state ?? "proposed"
    });
}

function recordUsage(thread, event) {
    const turn = thread.turns[event.turn];
    if (!turn)
        return;

    thread.turns[event.turn] = Object.assign({}, turn, {
        usage: {
            inputTokens: event.input_tokens ?? 0,
            outputTokens: event.output_tokens ?? 0,
            cacheReadTokens: event.cache_read_tokens ?? null,
            cacheWriteTokens: event.cache_write_tokens ?? null,
            thinkingTokens: event.thinking_tokens ?? null,
            costUsd: event.cost_usd ?? null,
            rateLimit: event.rate_limit ?? null
        }
    });
}

// Closes the turn, releases its open blocks so a later turn reusing block 0
// starts a fresh row, and re-tones every tool row the turn produced.
//
// The re-tone is the whole interrupt rule in one line. A tool_result with ok
// false was already toned "error" when it arrived, because at that moment
// nothing had said the turn was interrupted. turn_end is what says so, and it
// arrives afterwards, so a row toned on arrival alone stays red on a turn the
// user cancelled on purpose.
function endTurn(thread, event) {
    const turn = thread.turns[event.turn];
    const stop = event.stop ?? "end_turn";

    if (turn) {
        thread.turns[event.turn] = Object.assign({}, turn, {
            stop: stop,
            durationMs: event.duration_ms ?? null
        });
    }

    for (const key in thread.open) {
        if (key.indexOf(`${event.turn}:`) === 0)
            delete thread.open[key];
    }

    for (let i = 0; i < thread.rows.length; i++) {
        const row = thread.rows[i];
        if (row.kind !== "tool" || row.turn !== event.turn)
            continue;

        thread.rows[i] = Object.assign({}, row, {
            tone: toolTone(row, stop),
            permission: stop === "interrupted" ? null : row.permission
        });
    }

    if (thread.live === event.turn)
        thread.live = null;

    if (stop !== "end_turn") {
        thread.rows.push({
            kind: "status",
            turn: event.turn ?? null,
            stop: stop,
            durationMs: event.duration_ms ?? null
        });
    }
}

function stopOf(thread, turn) {
    const record = thread.turns[turn];
    return record ? record.stop : null;
}

// How a tool row is painted. Four tones rather than a boolean, because
// "failed" and "cancelled" look the same on the wire and must not look the
// same on screen.
//
// `stop` is the turn's turn_end.stop, or null while the turn is still running.
// ok false with stop "interrupted" is the client's own interrupt coming back
// as the CLI's canned rejection, and it renders muted, not red.
function toolTone(row, stop) {
    if (!row.result)
        return stop === "interrupted" ? "cancelled" : "pending";
    if (row.result.ok)
        return "ok";
    if (stop === "interrupted")
        return "cancelled";
    return "error";
}

// True only for a turn that genuinely failed. An interrupt is something the
// user asked for and reports as cancelled instead.
function isFailure(stop) {
    return stop === "error";
}

// The one-word label a status row shows.
function stopLabel(stop) {
    switch (stop) {
    case "interrupted":
        return "Interrupted";
    case "max_tokens":
        return "Stopped at the token limit";
    case "tool_use":
        return "Waiting on a tool";
    case "error":
        return "Failed";
    default:
        return "Done";
    }
}

// Adds the prompt the user just sent as a row, and returns a new state.
//
// The daemon has no event for a user message: the schema's persisted set runs
// from turn_start to turn_end and never carries what was asked. So the pane
// echoes its own prompt locally, which also means a prompt does not survive a
// shell restart the way the answer to it does. Nothing here can close that
// gap; it needs an event the daemon does not send.
function pushUserRow(state, conversation, text) {
    const touched = {};
    const next = applyEvents(state, []);
    const thread = threadOf(next, touched, conversation);

    if (!thread)
        return next;

    thread.rows.push({
        kind: "user",
        text: text
    });

    return next;
}

// The rows a conversation draws, or an empty list for one nothing has arrived
// for yet.
function rowsOf(state, conversation) {
    const thread = state.threads[conversation];
    return thread ? thread.rows : [];
}

// The highest seq the client already holds for this conversation, which is
// what op:"open" passes as from_seq. null means it holds nothing and wants the
// whole thread. The daemon sends strictly greater, so nothing arrives twice.
function fromSeqOf(state, conversation) {
    const thread = state.threads[conversation];
    return thread ? thread.maxSeq : null;
}

// The turn currently running in this conversation, or null. Drives the
// composer's send/interrupt swap.
function liveTurnOf(state, conversation) {
    const thread = state.threads[conversation];
    if (!thread || !thread.live)
        return null;
    return thread.turns[thread.live] ?? null;
}

// Every permission prompt still waiting on a decision, oldest first. Withdrawn
// and interrupted ones are already gone from their rows.
function pendingApprovals(state, conversation) {
    const rows = rowsOf(state, conversation);
    const out = [];

    for (let i = 0; i < rows.length; i++) {
        if (rows[i].kind === "tool" && rows[i].permission)
            out.push(rows[i].permission);
    }

    return out;
}

// A backend the pane may start a conversation on. `unconfigured` and
// `unreachable` entries still list, greyed, so a toggle that is on but has no
// credential says so instead of vanishing.
function selectableBackends(state, gate) {
    if (!gate || gate.length === 0)
        return [];

    const live = {};
    for (let i = 0; i < state.backends.length; i++)
        live[state.backends[i].id] = state.backends[i];

    return gate.map(entry => live[entry.id] ?? {
        id: entry.id,
        label: entry.label,
        state: "unreachable",
        models: [],
        detail: "the daemon has not answered yet"
    });
}

// Client frames. Built here rather than inline in AskBus so the shape the
// daemon reads is testable without a socket.

function helloFrame(resumeSeq) {
    return {
        op: "hello",
        protocol: 1,
        resume_seq: resumeSeq ?? null
    };
}

function listFrame(limit, before) {
    return {
        op: "list",
        limit: limit ?? 50,
        before: before ?? null
    };
}

function openFrame(conversation, fromSeq) {
    return {
        op: "open",
        conversation: conversation,
        from_seq: fromSeq ?? null
    };
}

function newFrame(conversation, backend, model, cwd, title) {
    return {
        op: "new",
        conversation: conversation,
        backend: backend,
        model: model ?? null,
        cwd: cwd,
        title: title ?? null
    };
}

function sendFrame(conversation, blocks) {
    return {
        op: "send",
        conversation: conversation,
        blocks: blocks
    };
}

function textBlock(text) {
    return {
        kind: "text",
        text: text
    };
}

function interruptFrame(conversation) {
    return {
        op: "interrupt",
        conversation: conversation
    };
}

function permissionFrame(conversation, request, decision, scope, updatedInput, message) {
    return {
        op: "permission",
        conversation: conversation,
        request: request,
        decision: decision,
        scope: scope,
        updated_input: updatedInput ?? null,
        message: message ?? null
    };
}

function deleteFrame(conversation) {
    return {
        op: "delete",
        conversation: conversation
    };
}

// A conversation id the client mints so it can address the thread before the
// daemon has answered. Version 4 shape, from Math.random, which is enough for
// a per-user socket that never leaves the machine.
function newConversationId() {
    let out = "";
    for (let i = 0; i < 36; i++) {
        if (i === 8 || i === 13 || i === 18 || i === 23) {
            out += "-";
        } else if (i === 14) {
            out += "4";
        } else if (i === 19) {
            out += "89ab"[Math.floor(Math.random() * 4)];
        } else {
            out += "0123456789abcdef"[Math.floor(Math.random() * 16)];
        }
    }
    return out;
}
