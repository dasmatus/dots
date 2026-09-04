// The ask pane: a side surface that replaces Claude Desktop with something
// inside the shell, talking to the dots-ask daemon over one unix socket.
//
// Shaped after launcher/Launcher.qml, which is the closest existing surface: a
// Scope holding an IpcHandler and one PanelWindow, routed to the focused
// monitor by the same idiom every other popup here uses. It differs in two
// deliberate ways. It docks to the right edge instead of floating in the
// middle, because a conversation is something you read beside your work rather
// than on top of it. And it holds no exclusive keyboard grab: the launcher is a
// modal question, this is a pane you type in while the answer streams and while
// you keep glancing at what it is talking about.
//
// GATED ON THE TOGGLES. tree.nix writes ask/backends.json from
// dots.ai.{claude,codex,ollama}. With every toggle off the file holds an empty
// list, and toggle() then does nothing at all: no window, no flicker, no empty
// pane offering a picker with nothing in it. That check comes before anything
// else in every entry point.
//
// NEVER A FUNCTION NAMED show. `qs ipc call ask show` is swallowed by the
// `qs ipc show` subcommand, which prints the handler listing, exits 0 and calls
// nothing, with no error to say so. The handler is open/close/toggle, the same
// three names Launcher settled on for the same measured reason.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import ".."
import "../common"
import "../services"
import "../services/ask.js" as AskMath

Scope {
    id: root

    readonly property var focusedScreen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? null

    // The conversation on screen, or "" before one has been opened.
    property string conversation: ""

    property string backend: ""
    property string model: ""

    // JsonAdapter has no generic `root` on this Quickshell build: only a
    // property DECLARED on the adapter instance is populated from the file.
    // `items` below is that property, and reading a bare `root` off the
    // adapter would be silently undefined forever.
    // qmllint disable unresolved-type
    readonly property var gate: backendsFile.adapter.items

    property var backendsFile: FileView {
        path: `${Quickshell.shellDir}/ask/backends.json`
        adapter: JsonAdapter {
            property var items: []
        }
    }

    // Which thread was open and which backend and model were picked, so the
    // pane comes back where it was left. Under $XDG_STATE_HOME, never beside
    // the QML: $XDG_CONFIG_HOME/quickshell is a whole-directory symlink into
    // the Nix store and nothing can be written next to shell.qml.
    //
    // printErrors is off because this file does not exist until the pane has
    // been used once, which is not a fault worth a log line every session.
    property var sessionFile: FileView {
        path: Theme.askStatePath
        atomicWrites: true
        printErrors: false

        adapter: JsonAdapter {
            property string conversation: ""
            property string backend: ""
            property string model: ""
        }

        onAdapterUpdated: {
            root.conversation = root.sessionFile.adapter.conversation;
            root.backend = root.sessionFile.adapter.backend;
            root.model = root.sessionFile.adapter.model;
        }

        onSaveFailed: error => console.warn("ask: could not write", root.sessionFile.path, "-", FileViewError.toString(error))
    }
    // qmllint enable unresolved-type

    // Whether the state directory is known to exist. False to start because on
    // a fresh install it does not, and FileView has no createParentDirectories
    // to lean on. Same one-shot mkdir the launcher's frecency writer uses.
    property bool stateDirReady: false

    property var stateDirProbe: Process {
        command: ["mkdir", "-p", Theme.askStateDir]

        // qmllint disable signal-handler-parameters
        onExited: (exitCode, exitStatus) => {
            root.stateDirReady = true;
            root.persist();
        }
        // qmllint enable signal-handler-parameters
    }

    // The backends the picker offers: the Nix gate narrowed by whatever the
    // daemon says about each one. A gated backend the daemon has not answered
    // for still lists, greyed, so an unreachable daemon reads as unreachable
    // rather than as no AI being installed.
    readonly property var offered: AskMath.selectableBackends(AskBus.state, root.gate)

    readonly property var rows: AskBus.rowsOf(root.conversation)
    readonly property bool busy: AskBus.liveTurnOf(root.conversation) !== null

    function persist(): void {
        if (!root.stateDirReady) {
            root.stateDirProbe.running = true;
            return;
        }

        root.sessionFile.adapter.conversation = root.conversation;
        root.sessionFile.adapter.backend = root.backend;
        root.sessionFile.adapter.model = root.model;
        root.sessionFile.writeAdapter();
    }

    // The gate. Every entry point runs through this, so a machine with every
    // dots.ai toggle off has no pane rather than an empty one.
    function enabled(): bool {
        return root.gate.length > 0;
    }

    // The same gate, applied to the socket. AskBus does not dial until this
    // fires, so a machine with every toggle off never opens a connection and
    // never re-dials for the life of the session. The bus is told rather than
    // reading backends.json itself, which keeps one gate in one file.
    //
    // Driven by the change signal rather than by Component.onCompleted because
    // FileView loads asynchronously: the list is empty at completion whether
    // or not there is anything in it.
    onGateChanged: {
        if (root.enabled())
            AskBus.enable();
    }

    function open(): void {
        if (!root.enabled())
            return;

        if (root.backend === "" && root.offered.length > 0)
            root.backend = root.offered[0].id;

        if (root.conversation !== "")
            AskBus.open(root.conversation);

        window.visible = true;
    }

    function close(): void {
        window.visible = false;
    }

    function startThread(): void {
        if (root.backend === "")
            return;

        root.conversation = AskBus.create(root.backend, root.model, Quickshell.env("HOME") ?? "/");
        root.persist();
    }

    // Deletes a thread, and lets go of it first when it is the open one.
    //
    // Without the check the pane keeps rendering rows for a thread the daemon
    // has just dropped, and persist() writes the dead id into session.json for
    // the next session to try to restore.
    function forget(conversation: string): void {
        if (root.conversation === conversation) {
            root.conversation = "";
            root.persist();
        }

        AskBus.remove(conversation);
    }

    function pick(conversation: string): void {
        root.conversation = conversation;
        AskBus.open(conversation);
        root.persist();
    }

    // Sends a prompt, minting a thread first when there is none. Typing into
    // an empty pane and pressing Enter is the shortest path to a first answer,
    // and making the user press New first would only be ceremony.
    function ask(text: string, attachments: var): void {
        if (root.conversation === "")
            root.startThread();

        if (root.conversation === "")
            return;

        AskBus.send(root.conversation, text, attachments);
    }

    IpcHandler {
        target: "ask"

        function open(): void {
            root.open();
        }

        function close(): void {
            root.close();
        }

        function toggle(): void {
            if (window.visible) {
                root.close();
            } else {
                root.open();
            }
        }
    }

    PanelWindow {
        id: window

        screen: root.focusedScreen
        color: "transparent"
        visible: false

        // Top rather than Overlay, and OnDemand rather than Exclusive: this
        // pane is meant to sit beside a window you keep working in, so it must
        // not hold the keyboard away from that window the way the launcher
        // deliberately does.
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
        WlrLayershell.namespace: "dots-ask"

        anchors {
            top: true
            right: true
            bottom: true
        }

        implicitWidth: Theme.askWidth
        exclusiveZone: 0

        onVisibleChanged: {
            if (window.visible)
                composer.focusInput();
        }

        Chrome {
            id: chrome

            anchors.fill: parent
            anchors.margins: Theme.askGutter

            padding: Theme.askPadding

            title: "Ask"
            hints: [
                {
                    key: "Enter",
                    label: "send"
                },
                {
                    key: "Shift+Enter",
                    label: "newline"
                },
                {
                    key: "Esc",
                    label: root.busy ? "stop" : "close"
                }
            ]

            // Escape stops a running turn before it closes anything. An
            // interrupt is the thing you want out of while an answer is
            // running, the same way the launcher's Escape backs out of a drill
            // before it dismisses the window.
            Keys.onEscapePressed: {
                if (root.busy) {
                    AskBus.interrupt(root.conversation);
                    return;
                }

                root.close();
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.minimumHeight: 0

                spacing: Theme.askPadding

                History {
                    Layout.preferredWidth: Theme.askHistoryWidth
                    Layout.fillHeight: true

                    conversations: AskBus.conversations
                    current: root.conversation

                    onPicked: conversation => root.pick(conversation)
                    onRemoved: conversation => root.forget(conversation)
                    onCreated: root.startThread()
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumHeight: 0

                    spacing: Theme.askGutter

                    // A connection-scoped error names no thread, so it shows as
                    // a banner over the pane rather than as a row inside one.
                    // It is never fatal by definition: it killed no
                    // conversation, because it named none.
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: banner.implicitHeight + 12

                        visible: AskBus.notice !== null || !AskBus.connected

                        radius: Theme.askRadius
                        color: Qt.alpha(Theme.orange, 0.14)
                        border.width: 1
                        border.color: Theme.orange

                        Text {
                            id: banner

                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.margins: Theme.askGutter

                            text: AskBus.notice !== null ? `${AskBus.notice.kind}: ${AskBus.notice.message}` : "waiting for the dots-ask daemon"
                            textFormat: Text.PlainText
                            color: Theme.orange

                            font.family: Theme.fontUi
                            font.pointSize: 9

                            wrapMode: Text.Wrap
                        }
                    }

                    Thread {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.minimumHeight: 0

                        conversation: root.conversation
                        rows: root.rows
                    }

                    Composer {
                        id: composer

                        Layout.fillWidth: true

                        backends: root.offered
                        backend: root.backend
                        model: root.model
                        busy: root.busy

                        onSubmitted: (text, attachments) => root.ask(text, attachments)
                        onInterrupted: AskBus.interrupt(root.conversation)

                        // A real backend swap starts a new thread rather than
                        // moving this one: the harness has to be respawned with
                        // a different argv, so a thread cannot change backend
                        // mid-flight and pretending otherwise would silently
                        // drop the history. Clicking the pill that is already
                        // active is not a swap, and must not abandon the open
                        // thread on its way to changing nothing.
                        onBackendPicked: id => {
                            if (id === root.backend)
                                return;

                            root.backend = id;
                            root.model = "";
                            root.conversation = "";
                            root.persist();
                        }

                        onModelPicked: name => {
                            root.model = name;
                            root.persist();
                        }
                    }
                }
            }
        }
    }
}
