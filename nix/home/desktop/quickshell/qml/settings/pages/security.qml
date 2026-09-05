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
// - `dots-sandbox watch` streams the same document `catalog --json` prints
//   (rust/dots-sandbox/src/catalog.rs): every app the defaults catalog
//   knows, each carrying the real Name/Icon its desktop entry declares (so
//   rows show an app, not a policy key) and its already-resolved capability
//   state. One complete JSON document per line, pushed on startup and again
//   whenever the policy changes.
//
//   Streamed rather than fetched because the fetch version re-ran the
//   binary on every read — a process spawn per repaint, and no way to
//   notice a change without re-running it. `watch` connects to the
//   org.dots.Sandbox1 daemon once and stays connected. It is a pipe rather
//   than a D-Bus call because Quickshell 0.3.0 exposes no generic D-Bus
//   client to QML (`Quickshell.DBusMenu` is the tray-menu protocol, not a
//   call interface), so this page cannot subscribe to the daemon itself.
//
//   Writes still go straight to ~/.config/dots-sandbox/overrides.json via
//   FileView.setText — the identical idiom monitors/Arrange.qml already
//   uses for its own overrides.json — for the same reason: QML cannot make
//   the D-Bus call that would let the daemon do the write. The daemon stats
//   that file before answering, so a write it did not make is still picked
//   up rather than served from a stale cache.
//
// The permissions list below groups by CAPABILITY first, same as an
// Android permission manager: a row per capability `policy.rs` knows,
// each showing how many apps requested it, opening onto exactly those
// apps and their own three-way control — never the reverse (an app,
// then its capabilities), which is what this page drew before.
//
// sandbox/policy.js carries every pure transform both this file and
// sandbox/Prompt.qml need (status-to-colour-name, the capability grouping,
// the overrides merge) — qmltestrunner cannot instantiate anything here
// (this file reaches Process and FileView, both Quickshell.Io types), so
// that logic has to live somewhere the test runner can load on its own.
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

    // `catalog --json`'s whole document (`{version, apps}`), or `null`
    // before the first read / after a parse failure — including the
    // binary being entirely missing, which lands in the exact same catch
    // block as a malformed document (see catalogProc below). `null` rather
    // than `{}` so `Policy.catalogApps` (which already treats a missing
    // `apps` key as "nothing to show") is the one place that has to know
    // what "not ready yet" looks like; every Policy function the
    // permissions section calls goes through it.
    property var catalogSet: null

    // Which capability's own app list the permissions section is showing,
    // or "" for the top-level list of capabilities itself. Local page
    // state only — this page is rebuilt fresh every time the Security tab
    // is opened (Settings.qml's own Loader `active` binding), so there is
    // nothing to reset on the way out.
    property string selectedCapability: ""

    // Feedback for the last capability write — cleared by the next
    // successful read, same lifetime as Settings.qml's own `status` for the
    // dumped-fields form.
    property string writeStatus: ""

    function refresh(): void {
        reportProc.running = false;
        reportProc.running = true;
        catalogProc.running = false;
        catalogProc.running = true;
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

    // The permissions model, streamed rather than fetched.
    //
    // This used to be `dots-sandbox catalog --json` re-run on every read,
    // which meant a process spawn per repaint and no way to notice a policy
    // change without re-running it. `watch` instead connects to the
    // org.dots.Sandbox1 daemon once and prints a complete catalog on
    // startup and again on every PolicyChanged, so this page holds ONE
    // long-lived process for its lifetime and updates when the policy
    // actually changes.
    //
    // Why a pipe and not D-Bus directly: Quickshell 0.3.0 exposes no
    // generic D-Bus client to QML — `Quickshell.DBusMenu` is the
    // StatusNotifierItem tray-menu protocol, not a call interface — so this
    // page cannot subscribe to the daemon itself. Shelling out to `busctl
    // call` per read would have kept the spawn-per-repaint the daemon
    // exists to remove, so the direction is inverted: the daemon pushes,
    // this reads.
    //
    // SplitParser, not StdioCollector: the stream never ends, so
    // `onStreamFinished` would fire only when the daemon died — i.e. never,
    // in the case that matters. `watch` emits one complete JSON document
    // per line precisely so a line split is the whole framing.
    Process {
        id: catalogProc

        command: ["dots-sandbox", "watch"]

        stdout: SplitParser {
            splitMarker: "\n"

            onRead: line => {
                try {
                    root.catalogSet = JSON.parse(line);
                } catch (error) {
                    // A malformed line is skipped, and the last good
                    // document is KEPT rather than cleared. Blanking the
                    // page because one line arrived truncated would turn a
                    // transient glitch into "no app is sandboxed", which is
                    // the most misleading thing this page can say. A
                    // missing binary is the different case that leaves
                    // catalogSet at its initial null, which the loading
                    // message below reports honestly.
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
    // `selectedCapability` is left untouched, so flipping a segment stays on
    // the same drill-in list rather than bouncing the user back to the top.
    //
    // The write still goes through FileView rather than the daemon's own
    // SetCapability, because Quickshell exposes no way for QML to make a
    // D-Bus call. The daemon copes: it stats overrides.json before
    // answering, so a write it did not make is picked up on the next read
    // rather than being served from a stale cache. That also covers the
    // case of a person editing the file by hand, which the policy design
    // deliberately keeps working.
    //
    // Restarting `catalogProc` is what forces that next read. Note this is
    // a stream, not a one-shot: cycling it drops the daemon connection and
    // reconnects, which is heavier than the old re-run and happens far less
    // often — on a write, not on a repaint. A push from the daemon's own
    // PolicyChanged would be lighter still, but it only fires for writes
    // the daemon itself performed, and this is not one.
    function setCapability(appId: string, capability: string, state: string): void {
        const merged = Policy.withCapabilityOverride(root.overridesRoot, appId, capability, state);
        overridesFile.setText(JSON.stringify(merged));
        root.writeStatus = `${appId}: ${capability} → ${state} (applies next launch)`;
        catalogProc.running = false;
        catalogProc.running = true;
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

                    visible: root.catalogSet === null
                    text: "Reading dots-sandbox catalog --json…"
                    color: Theme.muted

                    font.family: Theme.fontUi
                    font.pointSize: Theme.settingsRowDescFontSize
                }

                // Exempt apps: shown at this section's own top level,
                // never behind a capability click — an unconfined app has
                // no capability list of its own to be filed under, and
                // hiding it even one click deep is the same invisible-
                // exemption problem the task brief's own callout warns
                // against. Hidden only while drilled into one capability,
                // where it would just be noise unrelated to that list.
                ColumnLayout {
                    Layout.fillWidth: true

                    visible: root.catalogSet !== null && root.selectedCapability === "" && unconfinedRepeater.count > 0
                    spacing: Theme.settingsRowGap

                    Repeater {
                        id: unconfinedRepeater

                        model: Policy.unconfinedEntries(root.catalogSet)

                        delegate: Rectangle {
                            id: unconfinedRow

                            required property var modelData

                            Layout.fillWidth: true
                            implicitHeight: Math.max(Theme.settingsRowHeight, unconfinedLayout.implicitHeight + Theme.settingsRowPadding)

                            radius: Theme.settingsRadius
                            color: Theme.bgDark

                            RowLayout {
                                id: unconfinedLayout

                                anchors.fill: parent
                                anchors.margins: Theme.settingsRowPadding

                                spacing: 16

                                // Most unconfined apps were never rewrapped
                                // at all (wrap.nix returns them untouched —
                                // see the wrap-contract's own Piece 1 rule
                                // 5), so there is usually no desktop entry
                                // for the catalog to have sourced an icon
                                // from; an empty string just hides this.
                                Image {
                                    Layout.preferredWidth: Theme.settingsIconSize
                                    Layout.preferredHeight: Theme.settingsIconSize
                                    Layout.alignment: Qt.AlignVCenter

                                    visible: unconfinedRow.modelData.icon !== ""
                                    source: unconfinedRow.modelData.icon !== "" ? Quickshell.iconPath(unconfinedRow.modelData.icon, true) : ""
                                    sourceSize.width: Theme.settingsIconSize
                                    sourceSize.height: Theme.settingsIconSize
                                    fillMode: Image.PreserveAspectFit
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 2

                                    Text {
                                        Layout.fillWidth: true

                                        text: unconfinedRow.modelData.name
                                        color: Theme.fg
                                        elide: Text.ElideRight

                                        font.family: Theme.fontUi
                                        font.pointSize: Theme.settingsRowTitleFontSize
                                    }

                                    Text {
                                        Layout.fillWidth: true

                                        // Empty today for every real entry:
                                        // `catalog --json` does not surface
                                        // `ResolvedApp::Unconfined`'s reason
                                        // string yet (see Policy.unconfinedEntries'
                                        // own comment) — hidden rather than
                                        // shown blank, the honest degrade
                                        // until that one field lands.
                                        visible: text !== ""
                                        text: unconfinedRow.modelData.reason
                                        color: Theme.muted
                                        wrapMode: Text.WordWrap

                                        font.family: Theme.fontUi
                                        font.pointSize: Theme.settingsRowDescFontSize
                                    }
                                }

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
                        }
                    }
                }

                // The permission-manager top level: one row per capability
                // policy.rs knows, in its own declared order, each leading
                // to the apps that requested it — the task brief's own
                // words, "make permission type buttons that'll lead to
                // apps that requested them", rather than the app-then-
                // capabilities shape this page drew before.
                ColumnLayout {
                    Layout.fillWidth: true

                    visible: root.catalogSet !== null && root.selectedCapability === ""
                    spacing: Theme.settingsRowGap

                    Repeater {
                        model: Policy.capabilityGroups(root.catalogSet)

                        delegate: SettingsRow {
                            id: capGroupRow

                            required property var modelData

                            Layout.fillWidth: true
                            clickable: true

                            title: capGroupRow.modelData.label
                            description: `${capGroupRow.modelData.count} app${capGroupRow.modelData.count === 1 ? "" : "s"} requested this`

                            onClicked: root.selectedCapability = capGroupRow.modelData.name

                            // The same drill-in chevron Settings.qml's own
                            // Proton row uses, for the same reason: this
                            // row opens a second view rather than editing a
                            // value in place.
                            Text {
                                text: "\u{F0142}"
                                color: Theme.muted

                                font.family: Theme.fontUi
                                font.pointSize: Theme.settingsRowTitleFontSize
                            }
                        }
                    }

                    // Named path grants, as a group beside the capabilities.
                    //
                    // Not a capability and not inside one: a path grant has
                    // no `Capability` variant, and the capability-first
                    // restructuring dropped it from this page entirely for a
                    // while. It belongs at the top level for the same reason
                    // Android and iOS put filesystem access in the
                    // permission list — someone scanning for "what can reach
                    // my files" has to find the answer here, not three taps
                    // into an app they had to guess at first.
                    //
                    // Hidden at zero rather than shown empty: an app has to
                    // declare a path grant for this to mean anything, and a
                    // row reading "0 apps" is noise on a page whose whole
                    // job is making the non-zero rows visible.
                    SettingsRow {
                        id: pathGroupRow

                        readonly property var group: Policy.pathGrantGroup(root.catalogSet)

                        Layout.fillWidth: true

                        visible: pathGroupRow.group !== null && pathGroupRow.group.count > 0
                        clickable: true

                        title: pathGroupRow.group ? pathGroupRow.group.label : ""
                        description: pathGroupRow.group
                            ? `${pathGroupRow.group.count} app${pathGroupRow.group.count === 1 ? "" : "s"} granted specific paths`
                            : ""

                        onClicked: root.selectedCapability = pathGroupRow.group ? pathGroupRow.group.name : ""

                        Text {
                            text: "\u{F0142}"
                            color: Theme.muted

                            font.family: Theme.fontUi
                            font.pointSize: Theme.settingsRowTitleFontSize
                        }
                    }
                }

                // Drilled into one capability: exactly the apps that
                // requested it, each with the three-way Allow/Ask/Deny
                // control the task brief's own non-negotiable calls out —
                // a two-state toggle here would silently delete the "ask"
                // state, the state that makes an app prompt at all.
                ColumnLayout {
                    Layout.fillWidth: true

                    // "paths" is excluded because it has its own drill-in
                    // below: `appsForCapability` matches against an app's
                    // `caps`, where a path grant never appears, so this
                    // section would render an empty list under a heading
                    // that promised otherwise.
                    visible: root.catalogSet !== null
                             && root.selectedCapability !== ""
                             && root.selectedCapability !== "paths"
                    spacing: Theme.settingsRowGap

                    SettingsRow {
                        Layout.fillWidth: true
                        clickable: true

                        title: "\u{F0141}  Back to permissions"

                        onClicked: root.selectedCapability = ""
                    }

                    Repeater {
                        model: Policy.appsForCapability(root.catalogSet, root.selectedCapability)

                        // Not SettingsRow: that component's title is a
                        // plain string with no room for a leading icon, and
                        // the whole point of reading the catalog instead of
                        // `policy dump` is showing the app's own Name/Icon
                        // rather than its bare policy key.
                        delegate: Rectangle {
                            id: appPermRow

                            required property var modelData

                            Layout.fillWidth: true
                            implicitHeight: Math.max(Theme.settingsRowHeight, appPermLayout.implicitHeight + Theme.settingsRowPadding)

                            radius: Theme.settingsRadius
                            color: Theme.bgDark

                            RowLayout {
                                id: appPermLayout

                                anchors.fill: parent
                                anchors.margins: Theme.settingsRowPadding

                                spacing: 16

                                Image {
                                    Layout.preferredWidth: Theme.settingsIconSize
                                    Layout.preferredHeight: Theme.settingsIconSize
                                    Layout.alignment: Qt.AlignVCenter

                                    visible: appPermRow.modelData.icon !== ""
                                    source: appPermRow.modelData.icon !== "" ? Quickshell.iconPath(appPermRow.modelData.icon, true) : ""
                                    sourceSize.width: Theme.settingsIconSize
                                    sourceSize.height: Theme.settingsIconSize
                                    fillMode: Image.PreserveAspectFit
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 2

                                    Text {
                                        Layout.fillWidth: true

                                        text: appPermRow.modelData.name
                                        color: Theme.fg
                                        elide: Text.ElideRight

                                        font.family: Theme.fontUi
                                        font.pointSize: Theme.settingsRowTitleFontSize
                                    }

                                    Text {
                                        Layout.fillWidth: true

                                        visible: Policy.needsRelaunch(root.selectedCapability)
                                        text: "Applies on next launch, not to a copy already running"
                                        color: Theme.muted
                                        wrapMode: Text.WordWrap

                                        font.family: Theme.fontUi
                                        font.pointSize: Theme.settingsRowDescFontSize
                                    }
                                }

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
                                    value: appPermRow.modelData.state
                                    onActivated: value => root.setCapability(appPermRow.modelData.appId, root.selectedCapability, value)
                                }
                            }
                        }
                    }
                }

                // Drilled into path grants: each app with the specific
                // paths its policy hands it, and whether each is readable
                // or writable.
                //
                // Deliberately read-only, and that is not an omission. A
                // capability is a yes/no the user can flip from here; a
                // path grant names a specific directory, so "editing" it
                // means choosing a new path, which is a file picker and a
                // validation pass this page does not have. Showing them
                // read-only is the honest half — the page states what is
                // granted without implying it can be changed here. The
                // alternative, leaving them off the page as the first
                // version of this restructuring did, meant the permissions
                // UI silently omitted part of what an app can reach.
                ColumnLayout {
                    Layout.fillWidth: true

                    visible: root.catalogSet !== null && root.selectedCapability === "paths"
                    spacing: Theme.settingsRowGap

                    SettingsRow {
                        Layout.fillWidth: true
                        clickable: true

                        title: "\u{F0141}  Back to permissions"

                        onClicked: root.selectedCapability = ""
                    }

                    Repeater {
                        model: Policy.appsWithPathGrants(root.catalogSet)

                        delegate: Rectangle {
                            id: pathAppRow

                            required property var modelData

                            Layout.fillWidth: true
                            implicitHeight: pathAppLayout.implicitHeight + Theme.settingsRowPadding * 2

                            radius: Theme.settingsRadius
                            color: Theme.bgDark

                            ColumnLayout {
                                id: pathAppLayout

                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.margins: Theme.settingsRowPadding

                                spacing: 8

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 16

                                    Image {
                                        Layout.preferredWidth: Theme.settingsIconSize
                                        Layout.preferredHeight: Theme.settingsIconSize
                                        Layout.alignment: Qt.AlignVCenter

                                        visible: pathAppRow.modelData.icon !== ""
                                        source: pathAppRow.modelData.icon !== "" ? Quickshell.iconPath(pathAppRow.modelData.icon, true) : ""
                                        sourceSize.width: Theme.settingsIconSize
                                        sourceSize.height: Theme.settingsIconSize
                                        fillMode: Image.PreserveAspectFit
                                    }

                                    Text {
                                        Layout.fillWidth: true

                                        text: pathAppRow.modelData.name
                                        color: Theme.fg
                                        elide: Text.ElideRight

                                        font.family: Theme.fontUi
                                        font.pointSize: Theme.settingsRowTitleFontSize
                                    }
                                }

                                Repeater {
                                    model: pathAppRow.modelData.paths

                                    delegate: RowLayout {
                                        id: grantRow

                                        required property var modelData

                                        Layout.fillWidth: true
                                        Layout.leftMargin: Theme.settingsIconSize + 16

                                        spacing: 12

                                        Text {
                                            Layout.fillWidth: true

                                            text: grantRow.modelData.path
                                            color: Theme.fg
                                            elide: Text.ElideMiddle

                                            font.family: Theme.fontMono
                                            font.pointSize: Theme.settingsRowDescFontSize
                                        }

                                        // Spelled out rather than shown as
                                        // "rw"/"ro": those differ by one
                                        // character in a list where a
                                        // misread is a wrong conclusion
                                        // about what an app can do to a
                                        // directory.
                                        Text {
                                            text: grantRow.modelData.modeLabel
                                            color: grantRow.modelData.mode === "rw" ? Theme.accent : Theme.muted

                                            font.family: Theme.fontUi
                                            font.pointSize: Theme.settingsRowDescFontSize
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
