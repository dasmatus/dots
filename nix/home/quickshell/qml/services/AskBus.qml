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
// NOTHING DIALS UNTIL THE PANE SAYS SO. This singleton never opens the socket
// on its own. Ask.qml calls enable() once ask/backends.json turns out to hold
// a backend, so a machine with every dots.ai toggle off opens no socket and
// re-dials nothing for the life of the session. The gate stays in the file
// that already reads it rather than being tested for a second time here.
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

    // Sends a prompt and echoes it into the thread. ask.js's pushUserRow says
    // what the echo costs and why it is still here.
    //
    // A text block goes first and only when there is text, so a message that
    // is nothing but a screenshot does not carry an empty string the model has
    // to interpret. `blocks` is never empty: the composer refuses to submit
    // with neither.
    function send(conversation: string, text: string, attachments: var): void {
        const staged = attachments ?? [];
        const blocks = (text === "" ? [] : [Ask.textBlock(text)]).concat(staged.map(Ask.attachmentBlock));

        root.sendFrame(Ask.sendFrame(conversation, blocks));
        root.state = Ask.pushUserRow(root.state, conversation, text, staged);
    }

    // Opens one artifact in its own browser window.
    //
    // A browser and not the pane: Quickshell cannot host QtWebEngine, so HTML
    // has nowhere to render in here at all. `--app=` gives a window with no
    // tab strip, address bar or bookmark row, which is what makes it read as
    // part of the shell rather than as a tab somebody left open, and --class
    // is what nix/home/hyprland.nix's rule matches to float and pin it.
    //
    // An http url and not file://. A file: document has an opaque origin, so
    // the daemon's Content-Security-Policy could not name 'self' and the
    // reload shim could not fetch at all; loopback also keeps the window from
    // ever being pointed at the filesystem. src/artifact/serve.rs carries the
    // whole argument.
    //
    // execDetached because the browser outlives the shell: a rebuild restarts
    // Quickshell, and an artifact window dying with it would be a surprise.
    function openArtifact(conversation: string, artifact: string): void {
        const url = Ask.artifactUrl(root.state, conversation, artifact);
        if (url === "") {
            console.warn("ask: no artifact server; the page is on disk but nothing serves it");
            return;
        }

        Quickshell.execDetached(["brave", `--app=${url}`, "--class=dots-ask-artifact"]);
    }

    function interrupt(conversation: string): void {
        root.sendFrame(Ask.interruptFrame(conversation));
    }

    function decide(conversation: string, request: string, decision: string, scope: string): void {
        root.sendFrame(Ask.permissionFrame(conversation, request, decision, scope, null, decision === "deny" ? "denied from the ask pane" : null));
    }

    // Deletes a thread, and stops holding it as the subscription.
    //
    // `subscribed` is what a reconnect re-opens. Leaving a deleted id in it
    // means the next dropped connection sends op:"open" for a conversation the
    // daemon no longer has, which is a bad_request the user did nothing to
    // cause. The pane clears its own copy in Ask.qml's forget(); this is the
    // bus half of the same fact, kept here because only the bus knows what it
    // is about to re-open.
    function remove(conversation: string): void {
        if (root.subscribed === conversation)
            root.subscribed = "";

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

    // How long the next re-dial waits. Doubles per failed attempt to 30s and
    // resets on a connection, so a daemon that is briefly down comes back fast
    // and one that is not installed at all costs a dial every half minute
    // rather than a tight loop.
    property int backoffMs: 500

    // Whether anything wants a connection at all. False until the pane opens
    // the gate, so a machine with every dots.ai toggle off never opens a
    // socket and never re-dials.
    //
    // The gate itself stays in Ask.qml, which is the only thing that reads
    // ask/backends.json. This singleton is told, rather than reading the file
    // a second time, so the toggle decision keeps exactly one home.
    property bool enabled: false

    function enable(): void {
        if (root.enabled)
            return;

        root.enabled = true;
        root.dial();
    }

    // Dials, unless there is nothing to dial or nobody asking. Dialing an
    // empty path fails, and the failure would start the backoff running
    // against a socket that was never going to answer.
    function dial(): void {
        if (!root.enabled || root.socketPath === "")
            return;

        socket.connected = true;
    }

    // Schedules one re-dial and backs off exactly once for it.
    //
    // A refused connection raises BOTH onError and onConnectionStateChanged,
    // so doubling in each handler grew the wait 4x per attempt while the
    // comment above promised 2x. Leaving an already-scheduled redial alone is
    // what makes the two handlers idempotent for a single failure.
    function retry(): void {
        if (redial.running)
            return;

        root.backoffMs = Math.min(root.backoffMs * 2, 30000);
        redial.restart();
    }

    Timer {
        id: redial

        interval: root.backoffMs
        repeat: false

        onTriggered: root.dial()
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
                redial.stop();
                root.sendFrame(Ask.helloFrame(root.state.lastSeq));
                root.list();

                if (root.subscribed !== "")
                    root.open(root.subscribed);

                return;
            }

            root.retry();
        }

        // QLocalSocket::LocalSocketError is not a type Quickshell exports, the
        // same gap Devices.qml works around for QProcess::ExitStatus.
        // qmllint disable signal-handler-parameters
        onError: error => root.retry()
        // qmllint enable signal-handler-parameters
    }
}
