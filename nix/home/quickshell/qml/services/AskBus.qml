// The ask daemon's client half: one unix socket, one folded conversation
// model, and the batching that keeps a streaming turn off the compositor's
// back.
//
// This is the first Socket in the shell, so it is also the pattern. Transport
// is newline-delimited JSON on $XDG_RUNTIME_DIR/dots-ask.sock, one object per
// line in both directions, which SplitParser reads and JSON.stringify writes.
// The daemon is a systemd user service rather than part of this tree for a
// reason worth repeating here: nix/home/quickshell/default.nix puts the QML on
// X-Restart-Triggers, so every rebuild restarts the shell, and a turn running
// inside the shell would die with it.
//
// STREAMING MUST NOT JANK THE DESKTOP. The daemon does not batch: it emits a
// text_delta per token. Appending each one to the model would relayout the
// ListView per token, which is a few hundred relayouts on one answer. So every
// line lands in `pending`, and a 16ms Timer folds the whole batch in one call
// and publishes one new state. The timer starts on the first pending line and
// does not restart on later ones, so it fires at most once a frame and never
// pushes a lone event further out than one frame.
//
// RECONNECT. The daemon can be restarted, upgraded or simply not running yet
// when the shell starts. A dropped connection re-dials on a doubling backoff
// capped at 30s, and the hello that opens each connection carries `lastSeq`,
// the highest seq this client has already rendered. The daemon replays what it
// missed and nothing else. This is the only automatic replay in the protocol:
// op:"open" never re-sends what the client already holds, because open passes
// the conversation's own highest seq and the daemon sends strictly greater.
//
// INJECTABLE. ingestEvent() and ingestLine() are public and know nothing about
// the socket, so a test drives an event sequence straight into the model with
// no daemon running. tst_ask_stream.qml uses the same ask.js entry point the
// flush below calls.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "ask.js" as Ask

Singleton {
    id: root

    // The whole client-side model: threads by conversation, the conversation
    // list, the backend list, and the last connection-scoped error. Replaced
    // wholesale on each flush rather than mutated, because a `var` property
    // assigned the object it already holds fires no change signal.
    property var state: Ask.emptyState()

    // Events read off the socket and not yet folded. Never rendered from:
    // this is a frame's worth of backlog, not model state.
    property var pending: []

    // The conversation op:"open" was last called for. Kept so a reconnect can
    // re-subscribe without the pane having to notice the drop.
    property string subscribed: ""

    readonly property bool connected: socket.connected

    readonly property var conversations: root.state.conversations
    readonly property var backends: root.state.backends
    readonly property var notice: root.state.notice

    // $XDG_RUNTIME_DIR is guaranteed present in a logind session, which is the
    // only way this shell ever starts. An empty string would make Socket dial
    // "/dots-ask.sock" and fail forever with a confusing path in the log, so
    // the socket stays disabled instead when the variable is missing.
    readonly property string socketPath: {
        const dir = Quickshell.env("XDG_RUNTIME_DIR");
        return dir ? `${dir}/dots-ask.sock` : "";
    }

    signal opened(string conversation)

    function rowsOf(conversation: string): var {
        return Ask.rowsOf(root.state, conversation);
    }

    function liveTurnOf(conversation: string): var {
        return Ask.liveTurnOf(root.state, conversation);
    }

    function pendingApprovals(conversation: string): var {
        return Ask.pendingApprovals(root.state, conversation);
    }

    // Parses one NDJSON line and queues it. A line the daemon truncated or a
    // line from a version this client cannot read must not take the pane down,
    // so a parse failure is logged and dropped rather than thrown.
    function ingestLine(line: string): void {
        if (line === "")
            return;

        let event = null;
        try {
            event = JSON.parse(line);
        } catch (error) {
            console.warn("ask: unparseable line from the daemon:", error);
            return;
        }

        root.ingestEvent(event);
    }

    // Queues one already-parsed event. The public injection point: a test
    // calls this directly, and so does ingestLine above.
    function ingestEvent(event: var): void {
        root.pending.push(event);

        if (!flush.running)
            flush.start();
    }

    // Folds everything queued and publishes one new state. Called by the timer
    // in the running shell; called directly by a test that does not want to
    // wait a frame.
    function flushPending(): void {
        if (root.pending.length === 0)
            return;

        const batch = root.pending;
        root.pending = [];
        root.state = Ask.applyEvents(root.state, batch);
    }

    function sendFrame(frame: var): void {
        if (!socket.connected) {
            console.warn("ask: dropping", frame.op, "with no daemon connected");
            return;
        }

        socket.write(`${JSON.stringify(frame)}\n`);
        socket.flush();
    }

    function list(): void {
        root.sendFrame(Ask.listFrame(50, null));
    }

    // Subscribes to a conversation. from_seq is this client's own highest seq
    // for that thread, so the daemon sends strictly greater and nothing the
    // pane already holds arrives twice.
    function open(conversation: string): void {
        root.subscribed = conversation;
        root.sendFrame(Ask.openFrame(conversation, Ask.fromSeqOf(root.state, conversation)));
        root.opened(conversation);
    }

    // Mints the conversation id here so the pane can address the thread before
    // the daemon has answered, which is what the schema asks for.
    function create(backend: string, model: string, cwd: string): string {
        const id = Ask.newConversationId();

        root.sendFrame(Ask.newFrame(id, backend, model, cwd, null));
        root.subscribed = id;

        return id;
    }

    // Sends a prompt and echoes it into the thread, because no daemon event
    // carries a user message back. ask.js's pushUserRow says what that costs.
    function send(conversation: string, text: string): void {
        root.sendFrame(Ask.sendFrame(conversation, [Ask.textBlock(text)]));
        root.state = Ask.pushUserRow(root.state, conversation, text);
    }

    function interrupt(conversation: string): void {
        root.sendFrame(Ask.interruptFrame(conversation));
    }

    function decide(conversation: string, request: string, decision: string, scope: string): void {
        root.sendFrame(Ask.permissionFrame(conversation, request, decision, scope, null, decision === "deny" ? "denied from the ask pane" : null));
    }

    function remove(conversation: string): void {
        root.sendFrame(Ask.deleteFrame(conversation));
    }

    // One frame's worth of backlog. Started on the first queued event and left
    // alone by later ones: restarting it on every event would push the flush
    // out for as long as tokens kept arriving, which on a fast turn is the
    // whole answer.
    Timer {
        id: flush

        interval: 16
        repeat: false

        onTriggered: root.flushPending()
    }

    // How long the next re-dial waits. Doubles per failure to 30s and resets
    // on a connection, so a daemon that is briefly down comes back fast and one
    // that is not installed at all costs a dial every half minute rather than a
    // tight loop.
    property int backoffMs: 500

    Timer {
        id: redial

        interval: root.backoffMs
        repeat: false

        onTriggered: {
            if (root.socketPath !== "")
                socket.connected = true;
        }
    }

    Socket {
        id: socket

        path: root.socketPath
        connected: false

        parser: SplitParser {
            splitMarker: "\n"

            onRead: line => root.ingestLine(line)
        }

        onConnectionStateChanged: {
            if (socket.connected) {
                root.backoffMs = 500;
                root.sendFrame(Ask.helloFrame(root.state.lastSeq));
                root.list();

                if (root.subscribed !== "")
                    root.open(root.subscribed);

                return;
            }

            root.backoffMs = Math.min(root.backoffMs * 2, 30000);
            redial.restart();
        }

        // QLocalSocket::LocalSocketError is not a type Quickshell exports, the
        // same gap Devices.qml works around for QProcess::ExitStatus.
        // qmllint disable signal-handler-parameters
        onError: error => {
            root.backoffMs = Math.min(root.backoffMs * 2, 30000);
            redial.restart();
        }
        // qmllint enable signal-handler-parameters
    }

    // The first dial. Deferred to a component completion rather than
    // `connected: true` on the Socket itself so `socketPath` is already
    // resolved: dialing an empty path fails, and the failure would set the
    // backoff going before there was anything to reach.
    Component.onCompleted: {
        if (root.socketPath !== "")
            socket.connected = true;
    }
}
