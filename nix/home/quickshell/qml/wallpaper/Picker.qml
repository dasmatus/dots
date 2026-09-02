// The wallpaper picker, reached with SUPER+W.
//
// A thumbnail grid over Wallpapers/, wired straight to awww: picking a
// tile runs `awww img`, extracts the new accent from the same file with
// accent.js (plan 1a) over a Canvas, writes it to Theme.tintStatePath for
// tree.nix's FileView to pick up, and hands the accent to every tint
// target — Icons.qml, Borders.qml, Gtk.qml and Kvantum.qml — so one pick
// repaints the icon theme, the Hyprland borders, the GTK stylesheets and
// the Kvantum theme together. No home-manager switch sits between a click
// and the bar repainting — that FileView is the whole point.
//
// apply(path, output, mode) is also reachable over IPC (`qs ipc call
// wallpaper apply <path> <output> <mode>`) for an external caller — a
// keybind or a terminal. Rotation.qml lives inside this same process, so it
// holds a direct reference to this component instead of shelling out to its
// own IPC socket: one implementation, reached in-process by the timer and
// externally by IPC, rather than either re-deriving what the other does.
//
// Ported from rust/wallpaper-tui's App::handle_key (deleted at aa995a4):
// cursor movement, apply, mode/output/colour cycling and restore all come
// back here, in picker.js and the key handling below. The TUI's `p` (toggle
// preview) does not: this grid already renders real thumbnails, which is
// exactly what `p` existed to fake on a terminal that cannot show an image.
//
// A successful apply also records which path/mode/fillColor just went to
// which output(s), in outputs.json next to Theme.tintStatePath's own
// current.json — config.rs's own state.json schema (an object of output
// name -> { path, mode, fill_color }, every field optional), just at this
// port's own path rather than the deleted crate's. `o` reloads a newly
// selected output's own mode/colour from it, and `r` replays every
// output's own last-recorded wallpaper, rather than either only ever
// seeing the live cycling state this session happened to be on.
// Rotation.qml's hourly pick is the one apply() caller that opts out of
// recording — restoring the rotation's latest random guess instead of
// what the user last actually chose is not what `r` is for.
pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import "../launcher/preview.js" as PreviewMath
import "accent.js" as Accent
import "picker.js" as PickerLogic
import ".."
import "../common"

Scope {
    id: root

    readonly property var focusedScreen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name) ?? null

    // Hardcoded the same way wallpaper-tui.nix's own default wallpaperFolder
    // and dots-repo.nix's clone destination are: the repo only ever lives at
    // one place relative to $HOME on this machine, and there is no home-
    // manager option that hands a plain QML tree that path today.
    readonly property string wallpapersDir: Quickshell.env("HOME") + "/Dokumente/codeberg/personal/dots/Wallpapers"

    property var files: []
    property int selected: -1

    // Live picker state, cycled by m/o/c below. config.rs's own defaults —
    // the TUI started here too when a wallpaper folder had no prior state.
    property string mode: "fill"
    property string output: "*"
    property string fillColor: PickerLogic.DEFAULT_COLOR

    // Every screen Quickshell currently knows about — cycleOutput()'s own
    // list, and restore()'s notion of which outputs are worth asking
    // outputRecords about at all.
    readonly property var outputNames: Quickshell.screens.map(s => s.name)

    // Persisted per-output state — config.rs's own on-disk schema, kept
    // under the same directory Theme.tintStatePath already lives in:
    // { "outputs": { "<name>": { "path", "mode", "fill_color" } } }, an
    // object keyed by output name (config.rs's State.outputs was a
    // BTreeMap<String, OutputOverride>, not a list), every field optional
    // and omitted — never null, never "" — the moment it is unset.
    // recordOutputState() below is the only writer; reading through the
    // FileView's own adapter, rather than a local copy, keeps
    // cycleOutput()'s reload and restore()'s replay both looking at
    // whatever the last successful apply actually wrote.
    //
    // JsonAdapter has no `root` — quickshell-io.qmltypes declares it (and
    // its FileViewAdapter prototype) with not one property — only a
    // property DECLARED on the adapter instance gets populated from the
    // file. outputStateFile.adapter.outputs below is that property, and
    // is already the bare map picker.js's functions take; there is
    // nothing left to unwrap.
    // qmllint disable unresolved-type
    readonly property var outputRecords: outputStateFile.adapter.outputs
    // qmllint enable unresolved-type

    // Chrome's own hint-footer shape (a list of { key, label }), wired
    // straight into the Chrome instance below rather than hand-rolled.
    // Movement, apply and close are the same grammar every Chrome surface
    // uses; m/o/c/r are this picker's own, ported from the deleted TUI.
    readonly property var hints: [
        { key: "↑↓←→/hjkl", label: "move" },
        { key: "enter", label: "apply" },
        { key: "m", label: "mode: " + root.mode },
        { key: "o", label: "output: " + root.output },
        { key: "c", label: "color: " + root.fillColor },
        { key: "r", label: "restore" },
        { key: "esc", label: "close" }
    ]

    Icons {
        id: icons
    }

    Borders {
        id: borders
    }

    Gtk {
        id: gtk
    }

    Kvantum {
        id: kvantum
    }

    function open(): void {
        root.reload();
        root.selected = 0;
        window.visible = true;
    }

    function close(): void {
        window.visible = false;

        // Entries queued by a restore() the user never waited out
        // otherwise keep firing after the picker is gone — awww has
        // already committed to whichever apply is actually in flight, but
        // nothing queued behind it needs to run once nobody is looking.
        root.pendingQueue = [];
    }

    function toggle(): void {
        if (window.visible)
            root.close();
        else
            root.open();
    }

    function reload(): void {
        lister.running = false;
        lister.running = true;
    }

    // delta is +-1 for h/l (a column within the current row) or
    // +-columnsPerRow() for j/k (a row): gridMove itself only clamps, it
    // has no notion of rows, so the caller supplies whichever step size
    // matches the key that fired.
    function moveCursor(delta): void {
        root.selected = PickerLogic.gridMove(root.selected, delta, root.files.length);
    }

    // GridView lays cells out left-to-right, wrapping at its own width —
    // there is no property that already reports how many fit per row, so
    // this recomputes it from the same width/cellWidth the layout itself
    // uses.
    function columnsPerRow(): int {
        return Math.max(1, Math.floor(grid.width / grid.cellWidth));
    }

    // The keyboard half of what the grid's click handler already does —
    // both funnel through apply() with the live mode/output/fillColor
    // rather than either hardcoding its own triple.
    function applySelected(): void {
        if (root.selected < 0 || root.selected >= root.files.length)
            return;
        root.apply(root.files[root.selected], root.output, root.mode, root.fillColor);
    }

    function cycleMode(): void {
        root.mode = PickerLogic.cycleMode(root.mode);
    }

    function cycleColor(): void {
        root.fillColor = PickerLogic.cycleColor(root.fillColor);
    }

    // config.rs's cycle_output reloaded fill_mode/current_color through
    // effective_output the moment the selection moved, but only ever had
    // to fall back to "fill"/DEFAULT_COLOR when NOTHING — no state, no
    // declarative config either — had an opinion on that output. This port
    // has no declarative layer, so effectiveOutput()'s own fallback is the
    // ONLY thing standing behind an output nothing has ever been applied
    // to, and reloading unconditionally would silently overwrite whatever
    // the user had just cycled m/c to with that fallback the moment they
    // landed on such an output (or on "*", which never gets its own
    // record — see recordOutputState()). hasOutputRecord() distinguishes
    // "found, reload from it" from "nothing recorded, leave the live
    // cycling state alone".
    function cycleOutput(): void {
        root.output = PickerLogic.cycleOutput(root.output, root.outputNames);
        if (!PickerLogic.hasOutputRecord(root.outputRecords, root.output))
            return;

        const effective = PickerLogic.effectiveOutput(root.outputRecords, root.output);
        root.mode = effective.mode;
        root.fillColor = effective.fillColor;
    }

    // -e is case-insensitive in fd, so a stray .JPG is still found. "." is
    // the required PATTERN argument when every file under PATH is wanted,
    // not a path itself — fd's own idiom for "no filter but the extensions".
    Process {
        id: lister

        command: ["fd", "--type", "f", "-e", "jpg", "-e", "jpeg", "-e", "png", "-e", "webp", "-e", "gif", ".", root.wallpapersDir]

        stdout: StdioCollector {
            onStreamFinished: {
                root.files = this.text.split("\n").filter(p => p.length > 0).sort();
            }
        }
    }

    IpcHandler {
        target: "wallpaper"

        function open(): void {
            root.open();
        }

        function close(): void {
            root.close();
        }

        function toggle(): void {
            root.toggle();
        }

        function apply(path: string, output: string, mode: string): void {
            root.apply(path, output, mode);
        }
    }

    // awww has no "tile"; hyprtile-wallpaperd's backend degraded it to crop
    // and awww.rs's map_mode kept that choice, so this does too. Unknown
    // modes fall to the same crop default for the same reason: a bad mode
    // string should still hang a wallpaper, not refuse one.
    function awwwResizeMode(mode) {
        if (mode === "fit")
            return "fit";
        if (mode === "stretch")
            return "stretch";
        if (mode === "center")
            return "no";
        return "crop";
    }

    property var pendingTriple: null

    // Queued awww invocations, and whether one is currently in flight.
    // `pumpApplyQueue()`'s own decision to start the next entry is gated
    // entirely on this flag, never on awwwProc.running directly — nothing
    // here can confirm Quickshell 0.3.0 clears `running` before `exited`
    // fires rather than after, so a pump gated on that ordering would be
    // either correct or permanently stalled depending on an assumption
    // nobody could check. `applyBusy` is set by pumpApplyQueue() itself
    // and cleared from two places on awwwProc below — onExited for a
    // normal completion, and onRunningChanged as a fallback for a process
    // that never started at all, which never fires onExited — see that
    // Process's own comments for why. awww itself has no argv for "these
    // N outputs, each with its own path", so restore()'s per-output loop
    // still needs the queue regardless.
    property var pendingQueue: []
    property bool applyBusy: false
    property var activeApply: null
    property var pendingOutputState: null

    // recordOutputState() calls queued here instead of written straight
    // through, for the window between the shell starting (Rotation.qml's
    // triggeredOnStart can fire immediately) and outputStateFile resolving
    // its own first load attempt — see recordOutputState()'s own comment.
    property var pendingOutputRecords: []

    // True once outputStateFile's first load attempt has resolved, one
    // way or the other. A missing outputs.json (the fresh-install case)
    // makes Quickshell emit loadFailed rather than loaded — confirmed
    // live — so gating solely on outputStateFile.loaded would mean that
    // first apply queues and nothing ever un-queues it: outputs.json has
    // exactly one writer in this file, so nothing else would ever bring
    // it into existence to make a real `loaded` happen. Both onLoaded and
    // onLoadFailed below set this the same way.
    property bool outputStateKnown: false

    // output/mode/fillColor default to "*"/"fill"/DEFAULT_COLOR (every
    // output, cropped to fill, the palette's own default swatch) —
    // wallpaper-tui.nix's own defaults — so a caller that only has a path,
    // like a grid click or Rotation's random pick, does not have to name
    // them.
    //
    // "*" never reaches awww's argv: this awww build takes "every output" by
    // the ABSENCE of --outputs, not by a wildcard, and passing the literal
    // asterisk fails outright ("none of the requested outputs are valid") —
    // found by actually running the built command rather than trusting
    // awww.rs's own convention, which named "*" a level up, in random_wp.nix,
    // not in the CLI it shells out to.
    // `record` is false only for Rotation.qml's own hourly pick: outputs.json
    // is meant to answer "what did the user last deliberately choose",
    // and a random rotation stamping over that on every shell start would
    // mean `r` replays the rotation's latest guess instead of the pick it
    // is actually supposed to restore. Every other caller — a grid click,
    // Enter, the IPC entry point, restore() itself replaying an existing
    // record — leaves it at the default.
    function apply(path, output, mode, fillColor = PickerLogic.DEFAULT_COLOR, record = true) {
        root.enqueueApply(path, output, mode, fillColor, true, record);
    }

    // r: every output that has ever had a wallpaper applied to it by name
    // gets its OWN recorded path/mode/fillColor back — app.rs's own
    // restore(), now that outputRecords gives this port the state.json
    // half it was missing. `tint: i === 0` is the QML side of "tinting
    // from the first": the accent palette is global, so re-running
    // extraction once per output would just redo the same work N times.
    function restore() {
        const entries = PickerLogic.restoreEntries(root.outputRecords, root.outputNames);
        for (let i = 0; i < entries.length; i++)
            root.enqueueApply(entries[i].path, entries[i].name, entries[i].mode, entries[i].fillColor, i === 0, true);
    }

    // `tint` marks the one queue entry, out of a possibly-multi-output
    // restore() batch, allowed to feed the accent extraction Canvas below.
    // `record` marks whether a successful run should be written back to
    // outputRecords at all — see apply()'s own comment for why Rotation's
    // entries carry false.
    function enqueueApply(path, output, mode, fillColor, tint, record) {
        root.pendingQueue.push({ path, output, mode, fillColor, tint, record });
        root.pumpApplyQueue();
    }

    function pumpApplyQueue() {
        const decision = PickerLogic.nextApply(root.applyBusy, root.pendingQueue);
        root.pendingQueue = decision.queue;
        if (!decision.entry)
            return;

        const entry = decision.entry;

        // Normalized onto the entry itself, not just a local — so
        // recordOutputState() below persists what actually got applied —
        // before applyBusy flips true. An unguarded fillColor reaching
        // fillColorArg()'s .startsWith('#') would throw between that write
        // and awwwProc.running = true a few lines down, latching applyBusy
        // with no process ever started and no runningChanged ever coming
        // to clear it: the same failure the onRunningChanged handler below
        // exists to route around, through a different door. Legacy
        // fill_color is optional and omitted rather than defaulted on
        // disk (see outputEntry() in picker.js), so an output record
        // missing it is the normal case now, not a hypothetical.
        entry.output = entry.output && entry.output.length > 0 ? entry.output : "*";
        entry.mode = entry.mode && entry.mode.length > 0 ? entry.mode : "fill";
        entry.fillColor = entry.fillColor && entry.fillColor.length > 0 ? entry.fillColor : PickerLogic.DEFAULT_COLOR;

        const targetOutput = entry.output;
        const targetMode = awwwResizeMode(entry.mode);

        // Resolved to concrete output names now, before either awww or
        // outputRecords ever sees this entry: a "*" apply is, from the
        // record's point of view, the same event as applying to every
        // currently connected output one at a time.
        entry.recordOutputs = targetOutput === "*" ? root.outputNames : [targetOutput];
        root.activeApply = entry;
        root.applyBusy = true;

        const args = ["awww", "img", entry.path];
        if (targetOutput !== "*")
            args.push("--outputs", targetOutput);
        args.push("--resize", targetMode, "--fill-color", PickerLogic.fillColorArg(entry.fillColor), "--transition-type", "fade", "--transition-duration", "1", "--transition-fps", "60");

        awwwProc.command = args;
        awwwProc.running = true;
    }

    // Folds `entry`'s path/mode/fillColor into every output name it
    // resolved to. Rotation.qml's triggeredOnStart can fire the instant
    // the shell starts, well before outputStateFile resolves its own
    // first load attempt — merging onto outputRecords before that
    // resolves would merge onto its declared property's own empty
    // default rather than what is actually on disk, and the write below
    // would silently drop every other output's real record. Queued
    // instead until outputStateKnown says that first attempt is done;
    // see flushPendingOutputRecords() for where a queued record actually
    // gets written.
    function recordOutputState(entry) {
        const records = entry.recordOutputs.map(name => ({
            name: name,
            path: entry.path,
            mode: entry.mode,
            fillColor: entry.fillColor
        }));

        if (!root.outputStateKnown) {
            root.pendingOutputRecords = root.pendingOutputRecords.concat(records);
            return;
        }

        root.writeOutputRecords(records);
    }

    // Marks the first load attempt resolved and writes whatever
    // recordOutputState() queued while waiting on it — called from both
    // outputStateFile's onLoaded and onLoadFailed below, since a missing
    // outputs.json fires the latter, never the former. outputStateKnown
    // is set unconditionally before the drain, so a second call (should
    // both signals somehow fire for the same file) still gates
    // recordOutputState() correctly either way; drainPending() itself is
    // what makes that second call a no-op rather than a double write —
    // see its own comment in picker.js, and tst_picker.qml's tests on it,
    // for why that is a tested property rather than an assumption.
    function flushPendingOutputRecords() {
        root.outputStateKnown = true;

        const decision = PickerLogic.drainPending(root.pendingOutputRecords);
        root.pendingOutputRecords = decision.queue;
        if (!decision.records)
            return;

        root.writeOutputRecords(decision.records);
    }

    // The merge-then-write recordOutputState() (or flushPendingOutputRecords())
    // actually wants — split out only so both have one place to call.
    // mkdir first, same as applyAccent()'s own stateDir/stateWriter pair
    // below, since outputs.json lives in that same
    // not-yet-guaranteed-to-exist directory and is otherwise a completely
    // independent write. root.outputRecords reads {} here in the
    // loadFailed case exactly as it would for an empty file — the merge
    // below does not need to know which one it was.
    function writeOutputRecords(records) {
        root.pendingOutputState = PickerLogic.mergeOutputState(root.outputRecords, records);
        outputStateDir.command = ["mkdir", "-p", Theme.tintStateDir];
        outputStateDir.running = true;
    }

    Process {
        id: outputStateDir

        // qmllint disable signal-handler-parameters
        onExited: (exitCode, exitStatus) => {
            outputStateFile.setText(JSON.stringify({ outputs: root.pendingOutputState }));
        }
        // qmllint enable signal-handler-parameters
    }

    // qmllint disable unresolved-type
    FileView {
        id: outputStateFile

        path: Theme.tintStateDir + "/outputs.json"
        watchChanges: true
        onFileChanged: reload()

        // Both flush whatever recordOutputState() queued while this
        // FileView's own first load attempt was still in flight — see
        // pendingOutputRecords', recordOutputState()'s and
        // flushPendingOutputRecords()'s own comments. A file that does
        // not exist yet — the fresh-install case, and outputs.json has no
        // writer anywhere else — resolves through onLoadFailed, never
        // onLoaded; confirmed live rather than assumed, the same way the
        // adapter.root gap above was. Both fire again on every later
        // reload too (an external edit, or watchChanges catching this
        // file's own write); a no-op past the first flush either way.
        onLoaded: root.flushPendingOutputRecords()
        onLoadFailed: root.flushPendingOutputRecords()

        // A bare `JsonAdapter {}` has nothing for the parsed JSON to land
        // on — this declared property is what actually gets populated
        // from the file's top-level "outputs" key; see outputRecords'
        // own comment above for why reading a `root` off the adapter
        // never worked here at all.
        adapter: JsonAdapter {
            property var outputs: ({})
        }
    }
    // qmllint enable unresolved-type

    Process {
        id: awwwProc

        // Quickshell 0.3.0 does not emit exited when the binary itself
        // cannot be found (an `awww` missing from PATH logs "Process
        // failed to start" and only ever drops `running`) — confirmed by
        // running it. applyBusy cleared solely in onExited would then
        // latch true forever, queuing every future apply behind a
        // process that already failed and is never coming back.
        //
        // This does not also call pumpApplyQueue(): onExited is still the
        // only place that does, since it alone knows whether this run
        // actually reached the point of having an exit code to check —
        // calling pumpApplyQueue() from here too could start the next
        // queued entry (reassigning activeApply) before a still-pending
        // onExited for THIS entry has run, corrupting which entry that
        // handler ends up recording/tinting. A start-failure's own
        // queue therefore only resumes on the next independent apply
        // (a click, Enter, r, Rotation, IPC) rather than draining
        // immediately — acceptable, since a missing binary fails every
        // later attempt identically, and none of them stay stuck.
        onRunningChanged: {
            if (!awwwProc.running)
                root.applyBusy = false;
        }

        // qmllint disable signal-handler-parameters
        onExited: (exitCode, exitStatus) => {
            root.applyBusy = false;

            const entry = root.activeApply;
            root.activeApply = null;

            // A failed apply leaves the old wallpaper on screen; recording
            // it or re-tinting from it would just make the state file and
            // the bar both lie about what is actually behind it.
            if (exitCode === 0 && entry) {
                if (entry.record)
                    root.recordOutputState(entry);
                if (entry.tint)
                    sizer.source = PreviewMath.fileUrl(entry.path);
            }

            root.pumpApplyQueue();
        }
        // qmllint enable signal-handler-parameters
    }

    // A second, permanently-visible layer-shell surface, 1x1 and background-
    // layer so nothing about it is ever seen — Canvas.onPaint only fires for
    // an item inside a window that is actually part of a live scene graph,
    // and the picker's own `window` below sits at visible: false until the
    // user opens it. Rotation.qml's hourly apply() has no reason to open
    // that window, so the extraction Canvas needs a window of its own that
    // is never toggled. Found by running apply() with the picker closed and
    // watching onPaint simply never fire — qmllint and qmltestrunner cannot
    // catch a missing scene graph, only a running compositor can.
    PanelWindow {
        id: accentSurface

        screen: root.focusedScreen
        color: "transparent"
        visible: true

        WlrLayershell.layer: WlrLayer.Background
        WlrLayershell.namespace: "dots-wallpaper-accent"
        exclusiveZone: 0

        implicitWidth: 1
        implicitHeight: 1

        // Sized to accent.rs's own thumbnail bounding box (fit within 64x64,
        // keep the aspect ratio) rather than a flat 64x64 stretch:
        // accentFrom only counts hue votes, so squashing every photo to
        // square would not change which hue wins, but this keeps the port
        // honest about what accent.rs's `thumbnail(64, 64)` actually does
        // before the bucket loop ever runs (see tst_accent.qml's 64x36
        // fixture for the same call).
        Image {
            id: sizer

            visible: false
            asynchronous: true
            cache: false

            onStatusChanged: {
                if (status !== Image.Ready)
                    return;

                const iw = Math.max(1, sizer.implicitWidth);
                const ih = Math.max(1, sizer.implicitHeight);
                const scale = Math.min(64 / iw, 64 / ih, 1);

                accentCanvas.width = Math.max(1, Math.round(iw * scale));
                accentCanvas.height = Math.max(1, Math.round(ih * scale));
                accentCanvas.loadImage(sizer.source.toString());
            }
        }

        Canvas {
            id: accentCanvas

            visible: false
            renderTarget: Canvas.Image
            width: 1
            height: 1

            onImageLoaded: requestPaint()
            onPaint: {
                // The scene graph paints this on its own the moment the
                // surface above maps, before apply() has ever run and
                // sizer has a source — drawImage("") on that first pass
                // logs a type-mismatch warning and aborts the handler,
                // which this guard skips instead of provoking.
                if (sizer.status !== Image.Ready)
                    return;

                const ctx = getContext("2d");
                ctx.drawImage(sizer.source.toString(), 0, 0, width, height);
                root.applyAccent(Accent.accentFrom(ctx.getImageData(0, 0, width, height).data));
            }
        }
    }

    function applyAccent(triple) {
        // Every target below is independent of the others: each manages
        // its own destination (or, for borders, its own live IPC call) and
        // none reads tintStatePath, so all four run the moment an accent
        // exists rather than waiting on the state-file write below, and a
        // failure or skip in one (no Hyprland instance, a missing Kvantum
        // base, an unwritable GTK dir) never blocks the rest.
        icons.retint(triple.accent);
        borders.apply(triple.accent, triple.dark);
        gtk.write(triple.accent, triple.dark, triple.light);
        kvantum.retint(triple.accent, triple.dark, triple.light);

        root.pendingTriple = triple;
        stateDir.command = ["mkdir", "-p", Theme.tintStateDir];
        stateDir.running = true;
    }

    Process {
        id: stateDir

        // qmllint disable signal-handler-parameters
        onExited: (exitCode, exitStatus) => {
            stateWriter.path = Theme.tintStatePath;
            stateWriter.setText(JSON.stringify(root.pendingTriple));
        }
        // qmllint enable signal-handler-parameters
    }

    // No adapter: this side only ever writes, and a plain string needs no
    // schema of its own to keep in sync with whatever reads current.json
    // back — this file does not need to know what that reader does.
    // (If it did use one: outputStateFile's own adapter above is this
    // file's own idiom for reading a JsonAdapter-backed file back — a
    // property DECLARED on the adapter instance, since JsonAdapter has no
    // generic `.root` to read through; see outputRecords' own comment for
    // where that gap was confirmed.) Setting `path` loads eagerly, so the
    // very first ever pick logs one "file does not exist" warning for a
    // file this same call is about to create — the same warning any
    // FileView pointed at a not-yet-written path logs, not a sign either
    // side is broken.
    FileView {
        id: stateWriter
    }

    PanelWindow {
        id: window

        screen: root.focusedScreen
        color: "transparent"
        visible: false

        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        WlrLayershell.namespace: "dots-wallpaper"

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

        MouseArea {
            anchors.fill: parent

            onClicked: root.close()
        }

        Chrome {
            id: panel

            anchors.centerIn: parent

            width: Math.round(parent.width * 0.8)
            height: Math.round(parent.height * 0.8)

            padding: 16

            focus: true

            title: "Wallpapers"
            hints: root.hints

            Keys.onEscapePressed: root.close()
            Keys.onUpPressed: root.moveCursor(-root.columnsPerRow())
            Keys.onDownPressed: root.moveCursor(root.columnsPerRow())
            Keys.onLeftPressed: root.moveCursor(-1)
            Keys.onRightPressed: root.moveCursor(1)
            Keys.onReturnPressed: {
                root.applySelected();
                root.close();
            }
            Keys.onEnterPressed: {
                root.applySelected();
                root.close();
            }

            // No focused text field on this surface to steal j/k/h/l as
            // literal characters, so they alias the arrows Vim-style — the
            // same reasoning Cheatsheet, Arrange and Settings all apply.
            // m/o/c/r cycle the ported picker state through picker.js's
            // own pure functions rather than reimplementing the cycling
            // here. Escape is left out of this switch, the same way
            // Arrange's own merged handler leaves it out, since the named
            // handler above already covers it.
            Keys.onPressed: event => {
                switch (event.key) {
                case Qt.Key_J:
                    root.moveCursor(root.columnsPerRow());
                    break;
                case Qt.Key_K:
                    root.moveCursor(-root.columnsPerRow());
                    break;
                case Qt.Key_H:
                    root.moveCursor(-1);
                    break;
                case Qt.Key_L:
                    root.moveCursor(1);
                    break;
                case Qt.Key_M:
                    root.cycleMode();
                    break;
                case Qt.Key_C:
                    root.cycleColor();
                    break;
                case Qt.Key_O:
                    root.cycleOutput();
                    break;
                case Qt.Key_R:
                    root.restore();
                    break;
                default:
                    return;
                }
                event.accepted = true;
            }

            GridView {
                id: grid

                Layout.fillWidth: true
                Layout.fillHeight: true

                clip: true
                cellWidth: 200
                cellHeight: 130

                model: root.files
                currentIndex: root.selected
                highlightFollowsCurrentItem: true

                delegate: Rectangle {
                    id: cell

                    required property string modelData
                    required property int index

                    width: grid.cellWidth - 8
                    height: grid.cellHeight - 8

                    radius: 6
                    color: Theme.bgDark
                    border.width: cell.index === root.selected ? 2 : 0
                    border.color: Theme.accent

                    // Capped at 320x200 (sourceSize, not the cell's own
                    // display size): the old preview cache's own bound,
                    // kept so a directory of a few hundred photos never
                    // decodes at full resolution just to show a tile.
                    Image {
                        anchors.fill: parent
                        anchors.margins: 2

                        source: PreviewMath.fileUrl(cell.modelData)
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        sourceSize.width: 320
                        sourceSize.height: 200
                    }

                    MouseArea {
                        anchors.fill: parent

                        onClicked: {
                            root.selected = cell.index;
                            root.applySelected();
                            root.close();
                        }
                    }
                }
            }
        }
    }
}
