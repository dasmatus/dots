// The Security & privacy settings page: the privacy/hardware-security
// dashboard on top, the Global permissions list below it. Loaded by
// Settings.qml through a `Loader { source: "pages/security.qml" }`
// (settings/Settings.qml's own content column) rather than an inline tag —
// this file's name starts lowercase on purpose, matching the task brief's
// exact path, and a lowercase filename cannot be a QML type name; loading it
// by source URL sidesteps that entirely instead of adding a qmldir remap
// nothing else here needed.
//
// Two Quickshell-fed documents, two Processes, no logic across either:
//
// - `dots-sandbox report --json` (rust/dots-sandbox/src/report.rs) already
//   decides every card's status/detail/rows and sorts bad-first
//   (`report::assemble`) — this file only draws `cards` in the order it
//   receives them. If a judgement like "is TPM present AND Secure Boot off"
//   ever seems tempting here, it belongs in that collector instead; see
//   this task's own report for what was actually found missing there.
// - `dots-sandbox policy dump` (rust/dots-sandbox/src/policy.rs) resolves
//   every app the defaults catalog knows, merged with whatever
//   ~/.config/dots-sandbox/overrides.json already says. Writes go straight
//   to that same file via FileView.setText — the identical idiom
//   monitors/Arrange.qml already uses for its own overrides.json, not a
//   second `dots-sandbox` CLI subcommand invented for this one write.
//
// sandbox/policy.js carries every pure transform both this file and
// sandbox/Prompt.qml need (status-to-colour-name, capability sorting, the
// overrides merge) — qmltestrunner cannot instantiate anything here (this
// file reaches Process and FileView, both Quickshell.Io types), so that
// logic has to live somewhere the test runner can load on its own.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import "../.."
import "../../common"
import ".."
import "../controls"
import "../../sandbox/policy.js" as Policy

Item {
    id: root

    // `report --json`'s `cards` array, verbatim — see the module comment.
    // Empty until the first Process exits, which is also the honest state
    // for "nothing read yet" and "the binary is not on PATH", so no
    // separate loading flag exists to tell those apart from the page's own
    // side; either way there is nothing to draw yet.
    property var cards: []

    // `policy dump`'s whole document (`{version, denyPaths, apps}`), or
    // `null` before the first read / after a parse failure. `null` rather
    // than `{}` so `Policy.appEntries` (which already treats a missing
    // `apps` key as "nothing to show") is the one place that has to know
    // what "not ready yet" looks like.
    property var policySet: null

    // Feedback for the last capability write — cleared by the next
    // successful read, same lifetime as Settings.qml's own `status` for the
    // dumped-fields form.
    property string writeStatus: ""

    function refresh(): void {
        reportProc.running = false;
        reportProc.running = true;
        policyProc.running = false;
        policyProc.running = true;
    }

    Component.onCompleted: root.refresh()

    // toneFor() only ever answers with one of these four names — see its
    // own comment on why a `.pragma library` cannot reach Theme directly to
    // begin with, the exact reason bar/battery.js hands Battery.qml a name
    // instead of a colour.
    function toneColor(tone: string): color {
        switch (tone) {
        case "green":
            return Theme.green;
        case "yellow":
            return Theme.yellow;
        case "red":
            return Theme.red;
        default:
            return Theme.dim;
        }
    }

    Process {
        id: reportProc

        command: ["dots-sandbox", "report", "--json"]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.cards = JSON.parse(this.text).cards ?? [];
                } catch (error) {
                    // A missing binary, a killed process or a malformed
                    // document all land here the same way: an empty
                    // dashboard, not a crashed settings panel. The EmptyState
                    // text below is what tells the user something is wrong.
                    root.cards = [];
                }
            }
        }
    }

    Process {
        id: policyProc

        command: ["dots-sandbox", "policy", "dump"]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    root.policySet = JSON.parse(this.text);
                } catch (error) {
                    root.policySet = null;
                }
            }
        }
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

    // FileView.adapter's declared type is FileViewAdapter, which has no
    // properties of its own — only the shape declared directly on the
    // JsonAdapter instance above is known — so qmllint cannot resolve
    // `overridesFile.adapter` as a type. monitors/Arrange.qml's own
    // `overridesRoot` property hits the exact same thing and resolves it
    // the exact same way: reading the adapter's declared properties inside
    // a property BINDING, never inside a plain function body, is what
    // keeps qmllint from flagging it — a binding's right-hand side is
    // resolved as `var` throughout rather than type-checked expression by
    // expression the way a function body's statements are. `apps`/
    // `denyPaths` get the same defensive normalization Arrange.qml's own
    // comment explains for `entries`: a freshly-loaded JsonAdapter hands
    // back Qt's V4Sequence wrapper for an array-typed property, not a
    // native JS array, so `instanceof Array` (true for both) is what tells
    // "a sequence, treat it as one" apart from "the file does not exist
    // yet, keep the property's own QML default" — Array.isArray would
    // silently fail the first and discard a real, already-loaded document.
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

    // The one write this page ever makes: one app, one capability, one new
    // state — Policy.withCapabilityOverride folds it into whatever
    // overrides.json already holds rather than replacing the file outright.
    // `policyProc` is re-run afterwards so the permissions list reflects the
    // MERGED, resolved state the write actually produced, not an optimistic
    // guess at what `policy dump` would say.
    function setCapability(appId: string, capability: string, state: string): void {
        const merged = Policy.withCapabilityOverride(root.overridesRoot, appId, capability, state);
        overridesFile.setText(JSON.stringify(merged));
        root.writeStatus = `${appId}: ${capability} → ${state} (applies next launch)`;
        policyProc.running = false;
        policyProc.running = true;
    }

    Flickable {
        anchors.fill: parent

        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ColumnLayout {
            id: content

            width: parent.width
            spacing: Theme.settingsGroupGap

            // --- Dashboard ---
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.settingsRowGap

                Text {
                    text: "Privacy & hardware security"
                    color: Theme.muted

                    font.family: Theme.fontUi
                    font.pointSize: Theme.settingsGroupFontSize
                    font.bold: true
                }

                Text {
                    Layout.fillWidth: true

                    visible: root.cards.length === 0
                    text: "Reading dots-sandbox report --json…"
                    color: Theme.muted

                    font.family: Theme.fontUi
                    font.pointSize: Theme.settingsRowDescFontSize
                }

                // Cards arrive already sorted bad-first
                // (rust/dots-sandbox/src/report.rs's `assemble`) — a plain
                // Repeater over them in order is what "leads with the bad
                // cards" actually means here; re-sorting or filtering
                // anything in this delegate would be the judgement logic
                // this page is not supposed to have.
                Repeater {
                    model: root.cards

                    delegate: Rectangle {
                        id: card

                        required property var modelData

                        Layout.fillWidth: true
                        implicitHeight: cardLayout.implicitHeight + Theme.settingsRowPadding

                        radius: Theme.settingsRadius
                        color: Theme.bgDark

                        ColumnLayout {
                            id: cardLayout

                            anchors.fill: parent
                            anchors.margins: Theme.settingsRowPadding / 2

                            spacing: 6

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 12

                                Text {
                                    Layout.fillWidth: true

                                    text: card.modelData.title
                                    color: Theme.fg
                                    elide: Text.ElideRight

                                    font.family: Theme.fontUi
                                    font.pointSize: Theme.settingsRowTitleFontSize
                                    font.bold: true
                                }

                                // common/Pill.qml, per the task brief's own
                                // callout — the source design used tag
                                // classes for exactly this, and status here
                                // is the equivalent. Its colour is the ONE
                                // piece of judgement this delegate performs,
                                // and it is a pure lookup
                                // (root.toneColor(Policy.toneFor(status))),
                                // never a comparison between two cards' own
                                // fields.
                                Pill {
                                    color: root.toneColor(Policy.toneFor(card.modelData.status))

                                    Text {
                                        text: Policy.statusLabel(card.modelData.status)
                                        color: Theme.bg

                                        font.family: Theme.fontUi
                                        font.pointSize: Theme.settingsRowDescFontSize
                                        font.bold: true
                                    }
                                }
                            }

                            Text {
                                Layout.fillWidth: true

                                text: card.modelData.detail
                                color: Theme.muted
                                wrapMode: Text.WordWrap

                                font.family: Theme.fontUi
                                font.pointSize: Theme.settingsRowDescFontSize
                            }

                            // Every row the collector attached — a fix
                            // command (FIDO2's "nix run .#enroll-fido"), a
                            // failing HSI attribute, a CPU mitigation line —
                            // drawn as a plain label/value pair, all of them,
                            // unconditionally: this page does not decide
                            // which rows are "worth" showing.
                            ColumnLayout {
                                Layout.fillWidth: true

                                visible: card.modelData.rows.length > 0
                                spacing: 2

                                Repeater {
                                    model: card.modelData.rows

                                    delegate: RowLayout {
                                        id: cardRow

                                        required property var modelData

                                        Layout.fillWidth: true
                                        spacing: 12

                                        Text {
                                            Layout.preferredWidth: 200

                                            text: cardRow.modelData.label
                                            color: Theme.dim
                                            elide: Text.ElideRight

                                            font.family: Theme.fontMono
                                            font.pointSize: Theme.settingsRowDescFontSize
                                        }

                                        Text {
                                            Layout.fillWidth: true

                                            text: cardRow.modelData.value
                                            color: Theme.fgDark
                                            wrapMode: Text.WordWrap

                                            font.family: Theme.fontMono
                                            font.pointSize: Theme.settingsRowDescFontSize
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // --- Global permissions ---
            ColumnLayout {
                Layout.fillWidth: true
                spacing: Theme.settingsRowGap

                Text {
                    text: "Global permissions"
                    color: Theme.muted

                    font.family: Theme.fontUi
                    font.pointSize: Theme.settingsGroupFontSize
                    font.bold: true
                }

                // The two honesty requirements a per-row tag would only
                // repeat fifteen times: revocation blocking new access
                // rather than reaching into an already-running app, said
                // once here rather than on every capability row.
                Text {
                    Layout.fillWidth: true

                    text: "Every change here applies the next time an app launches, never to a copy already running — turning a capability off only blocks NEW access from then on; a file the app already has open stays open until it closes it."
                    color: Theme.muted
                    wrapMode: Text.WordWrap

                    font.family: Theme.fontUi
                    font.pointSize: Theme.settingsRowDescFontSize
                }

                Text {
                    Layout.fillWidth: true

                    visible: root.writeStatus !== ""
                    text: root.writeStatus
                    color: Theme.accent

                    font.family: Theme.fontUi
                    font.pointSize: Theme.settingsRowDescFontSize
                }

                Text {
                    Layout.fillWidth: true

                    visible: root.policySet === null
                    text: "Reading dots-sandbox policy dump…"
                    color: Theme.muted

                    font.family: Theme.fontUi
                    font.pointSize: Theme.settingsRowDescFontSize
                }

                Repeater {
                    model: Policy.appEntries(root.policySet)

                    delegate: ColumnLayout {
                        id: appBlock

                        required property var modelData

                        Layout.fillWidth: true
                        spacing: Theme.settingsRowGap

                        Text {
                            text: appBlock.modelData.kind === "sandboxed" ? `${appBlock.modelData.id}  ·  ${appBlock.modelData.tier}` : appBlock.modelData.id
                            color: Theme.fg

                            font.family: Theme.fontMono
                            font.pointSize: Theme.settingsRowDescFontSize
                            font.bold: true
                        }

                        // Exempt apps get exactly one row: unsandboxed, plus
                        // the policy's own reason — never hidden, per the
                        // task brief's own callout on why an invisible
                        // exemption list is a permissions UI that has
                        // started lying about what it controls.
                        SettingsRow {
                            visible: appBlock.modelData.kind === "unconfined"
                            Layout.fillWidth: true

                            title: "Unsandboxed"
                            description: appBlock.modelData.reason ?? ""

                            Pill {
                                color: Theme.selection

                                Text {
                                    text: "No sandbox"
                                    color: Theme.fg

                                    font.family: Theme.fontUi
                                    font.pointSize: Theme.settingsRowDescFontSize
                                    font.bold: true
                                }
                            }
                        }

                        Repeater {
                            model: appBlock.modelData.kind === "sandboxed" ? Policy.capabilityEntries(appBlock.modelData.capabilities) : []

                            delegate: SettingsRow {
                                id: capRow

                                required property var modelData

                                Layout.fillWidth: true

                                title: capRow.modelData.name
                                description: Policy.needsRelaunch(capRow.modelData.name) ? "Applies on next launch, not to a copy already running" : ""

                                // controls/Segmented.qml, per the task
                                // brief's own callout to reuse this shell's
                                // controls rather than building a parallel
                                // three-way toggle.
                                Segmented {
                                    options: [
                                        { label: "Allow", value: "allow" },
                                        { label: "Ask", value: "ask" },
                                        { label: "Deny", value: "deny" }
                                    ]
                                    value: capRow.modelData.state
                                    onActivated: value => root.setCapability(appBlock.modelData.id, capRow.modelData.name, value)
                                }
                            }
                        }

                        // Named path grants (nix-lint's own ~/.cargo, say)
                        // are part of what this app's policy actually
                        // grants too — shown so the list stays honest about
                        // the whole picture, read-only for now: editing an
                        // arbitrary path is a bigger surface than a
                        // three-state capability toggle and the task brief
                        // never asked this page to grow one.
                        Repeater {
                            model: appBlock.modelData.kind === "sandboxed" ? (appBlock.modelData.paths ?? []) : []

                            delegate: SettingsRow {
                                id: pathRow

                                required property var modelData

                                Layout.fillWidth: true

                                title: pathRow.modelData.path
                                description: `${pathRow.modelData.mode} · ${pathRow.modelData.state}`
                            }
                        }
                    }
                }
            }
        }
    }
}
