// The live permission prompt: an app the sandbox is launching asked for a
// capability its policy leaves as "ask" (rust/dots-sandbox/src/policy.rs's
// `PolicyState::Ask`), and `dots-sandbox run` wants a human answer before
// deciding what that launch actually gets — rust/dots-sandbox/src/broker.rs's
// `gui_prompt` calls out to `qs ipc call sandboxprompt ask …` for exactly
// this, over a Wayland session.
//
// IMPORTANT, and the reason `ask()` below is not a literal blocking wait:
// `qs ipc call` reaches this function through quickshell's own IPC dispatch
// (`StringCallCommand::exec` in quickshell's `src/io/ipccomm.cpp`), which
// invokes the QML function and reads its return value in the same
// synchronous pass, on quickshell's one GUI thread — the same thread that
// would have to keep pumping Wayland input for this window to ever repaint
// or receive the very click this function is "waiting" for. Blocking here
// is a deadlock, not a prompt: nothing on screen (this window, the bar,
// every other surface this same process draws) can update while this call
// is still on the stack, and no click can ever arrive to unblock it — so
// broker.rs's own 20-second prompt timeout would expire against a shell
// that can never recover on its own, not even after the CLI side gives up
// and disconnects.
//
// So `ask()` answers instead from whatever was decided the LAST time this
// exact (app, capability) pair was asked — defaulting to deny — and shows
// this window so a human can set that answer for the NEXT attempt. That
// still matches what "ask" means operationally: broker.rs's `decide()` runs
// once per launch, so "the next attempt" is this app's next launch either
// way, the same relaunch every capability change already needs (see
// sandbox/policy.js's `needsRelaunch`).
//
// `app_id` reaching this function at all is this file's own extension of
// broker.rs's existing call, which today passes only `capability` — see
// this task's own report for why that is a real gap (no app_id crosses the
// IPC boundary yet, so "allow always" cannot honestly target one app's
// override without a matching one-line change to `gui_prompt`'s argv on the
// Rust side).
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import ".."
import "../common"
import "policy.js" as Policy

Scope {
    id: root

    readonly property var focusedScreen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? null

    // What the window is currently showing. Cleared by nothing on close —
    // a stale label behind a hidden window answers nothing, since the next
    // ask() call always overwrites both before showing it again.
    property string appId: ""
    property string capability: ""

    // One-shot answers, keyed by "appId capability" joined with a plain
    // space. Neither vocabulary allows a space of its own (app ids and
    // capability names are both fixed, known identifiers — see
    // rust/dots-sandbox/src/policy.rs's Capability::ALL for the latter), so
    // this cannot collide. Each entry is consumed — deleted — the moment
    // ask() reads it, which is the literal shape of "once": the SAME
    // answer can never be replayed for a second request without a human
    // clicking again.
    property var pendingAnswers: ({})

    function keyFor(appId: string, capability: string): string {
        return appId + " " + capability;
    }

    function show(appId: string, capability: string): void {
        root.appId = appId;
        root.capability = capability;
        window.visible = true;
    }

    function close(): void {
        window.visible = false;
    }

    // Records `allow` as the one-shot answer for whatever this window is
    // currently showing, then hides it. Shared by all three buttons: they
    // differ only in whether they ALSO persist (allowAlways below) and in
    // which boolean they record, never in how the record itself lands.
    function record(allow: bool): void {
        const key = root.keyFor(root.appId, root.capability);
        const next = Object.assign({}, root.pendingAnswers);
        next[key] = allow;
        root.pendingAnswers = next;
        root.close();
    }

    // "Allow once": the answer lives only in `pendingAnswers` above, never
    // on disk — rust/dots-sandbox/src/policy.rs's own `PolicyState` enum
    // already refuses to deserialize a persisted "allow-once" at all
    // (unknown variant), so this function not writing anywhere is this
    // page's half of that same guarantee, not a policy this file could
    // violate even by accident.
    function allowOnce(): void {
        root.record(true);
    }

    // "Allow always": the ONLY one of the three that touches
    // ~/.config/dots-sandbox/overrides.json — the same plain FileView.setText
    // idiom monitors/Arrange.qml and settings/pages/security.qml both use to
    // edit it, not a second `dots-sandbox` CLI subcommand invented for this
    // one write. Also records the one-shot answer, same as allowOnce, so an
    // app that retries within this same session is not denied a second time
    // while waiting for a relaunch to pick up the just-written override.
    function allowAlways(): void {
        const merged = Policy.withCapabilityOverride(root.overridesRoot, root.appId, root.capability, "allow");
        overridesFile.setText(JSON.stringify(merged));
        root.record(true);
    }

    function deny(): void {
        root.record(false);
    }

    // qmllint disable unresolved-type
    FileView {
        id: overridesFile

        path: `${Quickshell.env("HOME")}/.config/dots-sandbox/overrides.json`
        adapter: JsonAdapter {
            property int version: 1
            property var apps: ({})
            property var denyPaths: []
        }
    }

    // See settings/pages/security.qml's own overridesRoot property for why
    // this has to be a property BINDING and not a plain function body:
    // FileView.adapter resolves to FileViewAdapter, which declares no
    // properties of its own, so qmllint cannot type-check
    // `overridesFile.adapter.*` inside a function — only inside a
    // binding's right-hand side, which is resolved as `var` throughout
    // rather than expression-by-expression.
    readonly property var overridesRoot: {
        const apps = overridesFile.adapter.apps;
        const denyPaths = overridesFile.adapter.denyPaths;
        return {
            version: overridesFile.adapter.version || 1,
            apps: apps && typeof apps === "object" ? apps : {},
            denyPaths: denyPaths instanceof Array ? Array.from(denyPaths) : []
        };
    }
    // qmllint enable unresolved-type

    IpcHandler {
        target: "sandboxprompt"

        // See this file's own header for why this cannot be a literal
        // blocking wait. `qs ipc call sandboxprompt ask <appId> <capability>`
        // is this function's real invocation shape today; broker.rs's
        // `gui_prompt` needs a matching update before that call actually
        // carries `appId` — see the header again.
        function ask(appId: string, capability: string): bool {
            const key = root.keyFor(appId, capability);
            if (key in root.pendingAnswers) {
                const answer = root.pendingAnswers[key];
                const next = Object.assign({}, root.pendingAnswers);
                delete next[key];
                root.pendingAnswers = next;
                return answer;
            }

            root.show(appId, capability);
            return false;
        }
    }

    PanelWindow {
        id: window

        screen: root.focusedScreen
        color: "transparent"
        visible: false

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        WlrLayershell.namespace: "dots-sandbox-prompt"

        anchors {
            top: true
            left: true
            right: true
            bottom: true
        }

        exclusiveZone: 0

        onVisibleChanged: {
            if (window.visible)
                panel.forceActiveFocus();
        }

        // A click on the backdrop answers deny explicitly, rather than just
        // hiding the window — leaving the last shown pair's answer unset
        // would let a STALE cached answer from a much earlier ask() (there
        // is no timeout on `pendingAnswers` entries) look like this request
        // was actually decided just now.
        MouseArea {
            anchors.fill: parent

            onClicked: root.deny()
        }

        Chrome {
            id: panel

            anchors.centerIn: parent

            width: Math.min(560, parent.width - 80)
            height: panel.implicitHeight

            padding: 24
            focus: true

            title: "Permission request"
            hints: [
                { key: "Enter", label: "allow once" },
                { key: "Esc", label: "deny" }
            ]

            // Deny is the safe default on every path that is not an
            // explicit click: Escape, and (via the MouseArea above) the
            // backdrop too.
            Keys.onEscapePressed: root.deny()
            Keys.onReturnPressed: root.allowOnce()
            Keys.onEnterPressed: root.allowOnce()

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 16

                Text {
                    Layout.fillWidth: true

                    text: `"${root.appId}" wants the "${root.capability}" capability, which its current policy leaves as "ask".`
                    color: Theme.fg
                    wrapMode: Text.WordWrap

                    font.family: Theme.fontUi
                    font.pointSize: Theme.settingsRowTitleFontSize
                }

                Text {
                    Layout.fillWidth: true

                    // The honesty the brief asks for, said where the human
                    // answering this is actually looking: an answer here
                    // changes what the NEXT launch attempt gets, never the
                    // one that is already running.
                    text: "This answers the app's next launch attempt, not anything already running — and \"allow always\" only ever blocks new access from then on; a file the app already has open stays open until it closes it."
                    color: Theme.muted
                    wrapMode: Text.WordWrap

                    font.family: Theme.fontUi
                    font.pointSize: Theme.settingsRowDescFontSize
                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8

                    Item {
                        Layout.fillWidth: true
                    }

                    Rectangle {
                        implicitWidth: denyLabel.implicitWidth + 32
                        implicitHeight: Theme.settingsToggleHeight + 8

                        radius: height / 2
                        color: Theme.selection

                        Text {
                            id: denyLabel

                            anchors.centerIn: parent

                            text: "Deny"
                            color: Theme.fg

                            font.family: Theme.fontUi
                            font.pointSize: Theme.settingsRowDescFontSize
                            font.bold: true
                        }

                        MouseArea {
                            anchors.fill: parent

                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.deny()
                        }
                    }

                    Rectangle {
                        implicitWidth: allowOnceLabel.implicitWidth + 32
                        implicitHeight: Theme.settingsToggleHeight + 8

                        radius: height / 2
                        color: Theme.raised

                        Text {
                            id: allowOnceLabel

                            anchors.centerIn: parent

                            text: "Allow once"
                            color: Theme.fg

                            font.family: Theme.fontUi
                            font.pointSize: Theme.settingsRowDescFontSize
                            font.bold: true
                        }

                        MouseArea {
                            anchors.fill: parent

                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.allowOnce()
                        }
                    }

                    Rectangle {
                        implicitWidth: allowAlwaysLabel.implicitWidth + 32
                        implicitHeight: Theme.settingsToggleHeight + 8

                        radius: height / 2
                        color: Theme.accent

                        Text {
                            id: allowAlwaysLabel

                            anchors.centerIn: parent

                            text: "Allow always"
                            color: Theme.bg

                            font.family: Theme.fontUi
                            font.pointSize: Theme.settingsRowDescFontSize
                            font.bold: true
                        }

                        MouseArea {
                            anchors.fill: parent

                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.allowAlways()
                        }
                    }
                }
            }
        }
    }
}
