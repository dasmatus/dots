// Everything the launcher can search, and what activating a row does.
//
// Each provider is a function from a query string to a list of rows. A row is
// a plain object carrying what it shows plus a `run` closure, so adding one is
// a function rather than a trait implementation, a registration and a config
// schema, which is what it cost in beamenu.
//
// Triggers are beamenu's: `=` with no space for arithmetic, `w ` for windows,
// `c ` for clipboard, `e ` for emoji, `?` for web search. A prefixed query
// answers from that provider alone, which is why they are checked before the
// ambient ones.
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import ".."
import "apps.js" as AppsLogic
import "rank.js" as Rank
import "preview.js" as PreviewMath
import "status.js" as StatusMath
import "keyboard.js" as KeyboardMath
import "../services"
import "../services/devices.js" as DevicesMath

QtObject {
    id: root

    // Session and power commands, lifted from rust/beamenu/src/providers/
    // system.rs. Two of them used to call dots-osd, which no longer exists;
    // they reach the same actuation through the shell's own OSD handler.
    readonly property var systemCommands: [
        {
            title: "Lock Screen",
            subtitle: "Lock the session with hyprlock",
            argv: ["hyprlock"]
        },
        {
            title: "Log Out",
            subtitle: "End the Hyprland session",
            argv: ["hyprctl", "dispatch", "exit"]
        },
        {
            title: "Suspend",
            subtitle: "Suspend to RAM",
            argv: ["systemctl", "suspend"]
        },
        {
            title: "Hibernate",
            subtitle: "Suspend to disk",
            argv: ["systemctl", "hibernate"]
        },
        {
            title: "Restart",
            subtitle: "Reboot the machine",
            argv: ["systemctl", "reboot"]
        },
        {
            title: "Shut Down",
            subtitle: "Power off the machine",
            argv: ["systemctl", "poweroff"]
        },
        // These start the same dots-screenshot-*@ units the Print keybinds
        // start (nix/home/desktop/session/actions.nix), rather than calling hyprshot
        // themselves. Going through the unit is what gets them the wrapper
        // that pins the save folder, the flags each mode needs, and the
        // KillMode=process that stops systemd killing the capture — none of
        // which a bare "hyprshot" here would have. The instance name is fixed
        // rather than randomised the way the keybinds' is, because
        // execDetached has no shell to expand a suffix in; the cost is that
        // re-running one mode while it is still capturing is a no-op.
        {
            title: "Screenshot Screen",
            subtitle: "Capture the focused output",
            argv: ["systemctl", "--user", "start", "--no-block", "dots-screenshot-output@launcher.service"]
        },
        {
            title: "Screenshot Region",
            subtitle: "Select a region to capture",
            argv: ["systemctl", "--user", "start", "--no-block", "dots-screenshot-region@launcher.service"]
        },
        {
            title: "Screenshot Window",
            subtitle: "Pick a window to capture",
            argv: ["systemctl", "--user", "start", "--no-block", "dots-screenshot-window@launcher.service"]
        },
        {
            title: "Toggle Touchpad",
            subtitle: "Disable or re-enable the touchpad",
            argv: ["qs", "ipc", "call", "osd", "touchpadToggle"]
        },
        {
            title: "Toggle Privacy Mode",
            subtitle: "Mute the microphone",
            argv: ["qs", "ipc", "call", "osd", "privacyToggle"]
        },
        {
            title: "Open File Manager",
            subtitle: "Browse files, dual-pane, SUPER+SHIFT+F",
            argv: ["qs", "ipc", "call", "files", "toggle"]
        }
    ]

    // Clipboard history, newest first, deduplicated on text. beamenu kept this
    // in a daemon thread appending NDJSON; the shell is already resident, so
    // it holds the list and never needs a second process to own it.
    property var clipboardHistory: []

    readonly property int clipboardLimit: 500

    property var emojiData: []

    // File search is the one provider that costs a process, so it is the one
    // that must not run per keystroke. beamenu forked fd on every character;
    // this waits for a pause first. Below three characters it does not search
    // at all, because "e" matches most of a home directory.
    property string fileQuery: ""

    property var fileResults: []

    onFileQueryChanged: {
        if (root.fileQuery.length < 3) {
            root.fileResults = [];
            root.fileDebounce.stop();
            return;
        }

        root.fileDebounce.restart();
    }

    // `path` is what makes a row previewable: PreviewPane keys off it, and no
    // other provider sets it, so "is this entry a file" needs no type tag.
    //
    // The title comes from preview.js rather than from split("/").pop(),
    // which returns the empty string for every directory fd hands over —
    // directories arrive with a trailing slash, so the last segment is blank.
    function fileRows(text: string): var {
        return root.fileResults.map(path => ({
                    title: PreviewMath.displayName(path) + (PreviewMath.isDirectory(path) ? "/" : ""),
                    subtitle: path.replace(Quickshell.env("HOME"), "~"),
                    icon: "",
                    accessory: "open",
                    path: path,
                    provider: "files",
                    run: () => PreviewMath.isDirectory(path) ? Devices.requestOpen(path) : Quickshell.execDetached(["xdg-open", path])
                }));
    }

    // Reads Devices.flat rather than the mounted-only Devices.devices: a
    // device automount left unmounted, a filesystem udisksctl refuses, a
    // mount that failed and is not retried, is exactly the row this
    // provider exists to offer a manual mount button for, and the
    // mounted-only list drops it on purpose. Matching and the title both go
    // through DevicesMath.displayLabel rather than the raw `label` field,
    // which lsblk leaves null for a superfloppy with no filesystem label,
    // so typing the volume name still finds a drive that only has a vendor
    // and a model to go by.
    //
    // `path` on the open row is what buys the mount root a free preview:
    // PreviewPane keys off it exactly the way fileRows already relies on.
    // Activating that row hands the mount point to Devices.requestOpen
    // rather than to xdg-open — the same thing fileRows does for a
    // directory hit and files/Sidebar.qml does for this very mount point.
    // The shell draws its own file manager now, and nothing installs an
    // `inode/directory` handler for xdg-open to find.
    //
    // This is also the read that wakes Devices.qml. shell.qml instantiates
    // Launcher {} unconditionally, Launcher's `results` binding evaluates
    // eagerly against the empty startup query, and that empty query still
    // reaches this line, `for (const device of Devices.flat)`, before the
    // bar pill or anything else in the tree gets a chance to touch the
    // singleton. Drives.qml reads Devices.devices too, later, but by then
    // this call has already had the singleton running for as long as the
    // shell has been up; do not let Drives.qml's own comment convince a
    // later change that deleting that pill would put the service back to
    // sleep, because this read stays here either way.
    function deviceRows(text: string): var {
        const rows = [];

        for (const device of Devices.flat) {
            const label = DevicesMath.displayLabel(device);
            if (!root.matches(label, text))
                continue;

            const subtitle = PreviewMath.formatSize(device.sizeBytes);

            if (device.mountPoint) {
                rows.push({
                    title: label,
                    subtitle: subtitle,
                    icon: "",
                    accessory: "open",
                    provider: "devices",
                    path: device.mountPoint,
                    run: () => Devices.requestOpen(device.mountPoint)
                });

                rows.push({
                    title: `${label}: Eject`,
                    subtitle: subtitle,
                    icon: "",
                    accessory: "eject",
                    provider: "devices",
                    run: () => Devices.eject(device.path, device.diskPath)
                });
            } else {
                rows.push({
                    title: label,
                    subtitle: subtitle,
                    icon: "",
                    accessory: "mount",
                    provider: "devices",
                    run: () => Devices.mount(device.path)
                });
            }
        }

        return rows;
    }

    function matches(haystack: string, needle: string): bool {
        if (needle === "")
            return true;

        return haystack.toLowerCase().includes(needle.toLowerCase());
    }

    function preview(text: string, limit: int): string {
        const collapsed = text.replace(/\s+/g, " ").trim();
        return collapsed.length > limit ? `${collapsed.slice(0, limit - 1)}…` : collapsed;
    }

    function copy(text: string): void {
        // Settable property rather than forking wl-copy, which beamenu had to
        // do because it was not a running process with a Wayland connection.
        Quickshell.clipboardText = text;
    }

    function applicationRows(text: string): var {
        const rows = [];

        for (const entry of DesktopEntries.applications.values) {
            if (entry.noDisplay)
                continue;

            // Brave and Chromium install one .desktop per installed web app,
            // so a browser with three PWAs contributes four entries that all
            // look like ordinary applications. On the empty query — the
            // default screen, where every app is a match — they are noise
            // between the programs actually worth launching. A non-empty
            // query still reaches them, so typing "edu" finds EduPage.
            //
            // The test is on execString rather than on the entry id: the id
            // of a Brave PWA is `brave-<32 chars>-Default`, but the real
            // browser's is `brave-browser`, so a `brave-` prefix test would
            // hide the browser itself. `--app-id=` is the flag that makes an
            // invocation a web app, and it catches Chromium's PWAs too.
            if (text === "" && AppsLogic.isWebApp(entry.execString))
                continue;

            if (!root.matches(`${entry.name} ${entry.genericName} ${entry.keywords}`, text))
                continue;

            const icon = entry.icon ? Quickshell.iconPath(entry.icon, true) : "";

            // An app's desktop actions used to be pushed into this same flat
            // list, one row each, titled "Brave Web Browser: New Window". A
            // handful of browsers and terminals was enough to bury the
            // programs themselves under their own submenu items. They hang off
            // the app row instead now, and Launcher.qml swaps the list for
            // them when the row is drilled into.
            //
            // parentKey is what makes running an action count as using the
            // app: recordUse bumps both, so reaching for "New Private Window"
            // lifts LibreWolf itself rather than only that one action.
            const actionRows = entry.actions.map(action => ({
                        title: action.name,
                        subtitle: entry.name,
                        icon: icon,
                        accessory: "action",
                        provider: "apps",
                        key: AppsLogic.actionKey(entry.id, action.id),
                        parentKey: AppsLogic.appKey(entry.id),
                        run: () => action.execute()
                    }));

            rows.push({
                title: entry.name,
                subtitle: entry.comment || entry.genericName,
                icon: icon,
                accessory: "",
                provider: "apps",
                // The row's identity for ranking. Built from entry.id, which
                // DesktopEntry declares constant, rather than from the title:
                // a title is localizable, so keying on it would lose an app's
                // history the first time the session language changes.
                key: AppsLogic.appKey(entry.id),
                actionCount: actionRows.length,
                actionRows: actionRows,
                // execute() rather than execDetached(entry.command): it honours
                // Terminal=true and the entry's working directory, which a raw
                // argv spawn silently drops.
                run: () => entry.execute()
            });
        }

        return rows;
    }

    // The same desktop actions applicationRows nests onto each app row,
    // flattened out here under their own provider id so rank.js can score
    // them and pills.js can count them — nested under actionRows: above,
    // they were reachable only by drilling into the parent app first
    // (Right-arrow), and typing an action's own name, "compose" for
    // Mastodon's "Compose new post", found nothing.
    //
    // DesktopAction carries only id, name, icon, execString and command —
    // no keywords or genericName the way DesktopEntry has — so the match
    // is against the action's own name and its parent app's name, the
    // closest a query has to go on. Concatenated after applicationRows in
    // Launcher.qml's ambientRows, never before: that ordering is what
    // keeps an action's original index above its own app's when rank.js's
    // final tiebreak is what two equally-scored rows fall to.
    function appActionRows(text: string): var {
        const rows = [];

        for (const entry of DesktopEntries.applications.values) {
            if (entry.noDisplay)
                continue;

            // Same guard applicationRows applies to the app row itself: a
            // PWA's own entry is hidden from the empty-query default screen,
            // and an Actions= group on that same entry is not a back door
            // around it — the action's subtitle is the hidden app's own
            // name, so it would be exactly the noise that guard exists to
            // keep out. A non-empty query still reaches it either way.
            if (text === "" && AppsLogic.isWebApp(entry.execString))
                continue;

            const icon = entry.icon ? Quickshell.iconPath(entry.icon, true) : "";

            for (const action of entry.actions) {
                if (!root.matches(`${action.name} ${entry.name}`, text))
                    continue;

                rows.push({
                    title: action.name,
                    subtitle: entry.name,
                    icon: icon,
                    accessory: "action",
                    provider: "actions",
                    key: AppsLogic.actionKey(entry.id, action.id),
                    parentKey: AppsLogic.appKey(entry.id),
                    run: () => action.execute()
                });
            }
        }

        return rows;
    }

    function systemRows(text: string): var {
        const rows = [];

        for (const command of root.systemCommands) {
            if (!root.matches(command.title, text))
                continue;

            rows.push({
                title: command.title,
                subtitle: command.subtitle,
                icon: "",
                accessory: "system",
                provider: "system",
                // Keyed on the title because systemCommands above is a
                // hand-written literal: the titles are fixed strings in this
                // file, not data from anywhere that could churn.
                key: `system:${command.title}`,
                run: () => Quickshell.execDetached(command.argv)
            });
        }

        return rows;
    }

    // One row per layout configured on input:kb_layout, or none at all —
    // see keyboard.js's own header for the two hyprctl shapes this leans on
    // and why a single-layout config gets no rows at all. "all" rather than
    // a specific device name from `hyprctl devices -j`: a laptop with a
    // built-in keyboard plugged into an external one has more than one
    // keyboard device, and switching only one would leave them disagreeing
    // about which layout is active until the next switch — enumerating
    // devices at all buys nothing switchLayoutArgv needs and is one more
    // JSON shape that could go stale.
    function keyboardRows(text: string): var {
        return KeyboardMath.keyboardRows(text, root.configuredKeyboardLayouts, "all", (argv) => Quickshell.execDetached(argv));
    }

    function windowRows(text: string): var {
        const rows = [];

        for (const toplevel of Hyprland.toplevels.values) {
            if (!root.matches(toplevel.title, text))
                continue;

            rows.push({
                title: toplevel.title,
                // The class is only on the raw IPC object; the typed toplevel
                // does not carry it.
                subtitle: toplevel.lastIpcObject?.class ?? "",
                icon: "",
                accessory: `workspace ${toplevel.workspace?.name ?? "?"}`,
                provider: "windows",
                run: () => Hyprland.dispatch(`focuswindow address:${toplevel.address}`)
            });
        }

        return rows;
    }

    function clipboardRows(text: string): var {
        const rows = [];

        for (const item of root.clipboardHistory) {
            if (!root.matches(item, text))
                continue;

            rows.push({
                title: root.preview(item, 80),
                subtitle: "",
                icon: "",
                accessory: "copy",
                provider: "clipboard",
                run: () => root.copy(item)
            });
        }

        return rows;
    }

    function emojiRows(text: string): var {
        const rows = [];

        for (const entry of root.emojiData) {
            if (!root.matches(`${entry.name} ${entry.keywords}`, text))
                continue;

            rows.push({
                // The glyph leads the title so the list reads as a grid of
                // emoji rather than a wall of names, which is how beamenu did
                // it and the reason it was usable.
                title: `${entry.glyph}  ${entry.name}`,
                subtitle: entry.keywords,
                icon: "",
                accessory: "copy",
                provider: "emoji",
                run: () => root.copy(entry.glyph)
            });
        }

        return rows;
    }

    function quicklinkRows(text: string): var {
        const rows = [];
        const links = root.quicklinksFile.adapter.items;

        for (const link of links) {
            if (!root.matches(link.name, text))
                continue;

            rows.push({
                title: link.name,
                subtitle: link.target,
                icon: "",
                accessory: link.command ? "run" : "open",
                provider: "quicklinks",
                // Keyed on the name rather than the target: renaming a
                // quicklink is renaming the thing, but editing its URL to fix
                // a typo is not, and the history should survive the second.
                key: `quicklinks:${link.name}`,
                run: () => Quickshell.execDetached(link.command ? ["sh", "-c", link.target] : ["xdg-open", link.target])
            });
        }

        return rows;
    }

    function snippetRows(text: string): var {
        const rows = [];
        const snippets = root.snippetsFile.adapter.items;

        for (const snippet of snippets) {
            if (!root.matches(snippet.name, text))
                continue;

            rows.push({
                title: snippet.name,
                subtitle: root.preview(snippet.text, 72),
                icon: "",
                accessory: "copy",
                provider: "snippets",
                // Same reasoning as quicklinks: the name is the identity, the
                // body is the payload, and editing the body should not reset
                // how often the snippet gets reached for.
                key: `snippets:${snippet.name}`,
                run: () => root.copy(snippet.text)
            });
        }

        return rows;
    }

    function websearchRows(text: string): var {
        if (text.trim() === "")
            return [];

        // The local SearXNG instance, the same one beamenu's hand-rolled
        // HTTP client talked to. Opening the results page rather than parsing
        // it: the answer belongs in a browser, and this drops the reason
        // beamenu carried its own HTTP implementation to keep TLS out of the
        // ISO closure.
        const url = `http://127.0.0.1:8888/search?q=${encodeURIComponent(text)}`;

        return [
            {
                title: `Search for ${text}`,
                subtitle: "SearXNG on 127.0.0.1:8888",
                icon: "",
                accessory: "web",
                provider: "websearch",
                run: () => Quickshell.execDetached(["xdg-open", url])
            }
        ];
    }

    // Live system readouts, restoring rust/beamenu/src/providers/status.rs's
    // Memory and Disk rows. The cost split that file's header insisted on is
    // preserved here rather than in status.js: meminfoFile is re-read fresh
    // on every call, because /proc is microseconds; diskSnapshot is never
    // read here, only handed over, because df costs a subprocess and is
    // confined to diskTimer instead.
    //
    // reload() first, not just text(): blockAllReads makes a read
    // synchronous, not repeated — text() alone returns whatever the last
    // load or reload() cached, which for meminfoFile below would be its
    // startup read, forever. reload() is the method that actually goes back
    // to the file; blockAllReads is what makes that reload complete
    // synchronously instead of leaving text() to return stale data for one
    // more frame.
    function statusRows(text: string): var {
        root.meminfoFile.reload();
        return StatusMath.statusRows(text, root.meminfoFile.text(), root.diskSnapshot, root.copy);
    }

    // Quickshell types FileView.adapter as FileViewAdapter without exporting
    // that type, so the linter cannot resolve anything reached through it —
    // the category is suppressed here for that reason, not because the
    // bindings below ever read through it correctly on their own. JsonAdapter
    // has no `root` property on this Quickshell build (quickshell-io.qmltypes
    // declares zero properties on it); every optional-chained read off it
    // below was silently `[]` forever. Only a property DECLARED on the
    // adapter instance gets populated from the file, which is why each
    // FileView below declares its own `items`.
    // qmllint disable unresolved-type

    // All three live inside the shell tree, which is a read-only store path:
    // $XDG_CONFIG_HOME/quickshell is a symlink to it, so nothing can be
    // dropped alongside at runtime. Quicklinks and snippets are therefore
    // generated into the tree from Nix options the way Theme.qml is, which
    // also keeps them declarative rather than a file the user must remember
    // to back up.
    property var quicklinksFile: FileView {
        path: `${Quickshell.shellDir}/launcher/quicklinks.json`
        watchChanges: true
        onFileChanged: reload()
        adapter: JsonAdapter {
            property var items: []
        }
    }

    property var snippetsFile: FileView {
        path: `${Quickshell.shellDir}/launcher/snippets.json`
        watchChanges: true
        onFileChanged: reload()
        adapter: JsonAdapter {
            property var items: []
        }
    }

    property var emojiFile: FileView {
        path: `${Quickshell.shellDir}/launcher/emoji.json`
        adapter: JsonAdapter {
            property var items: []
        }

        onAdapterUpdated: root.emojiData = root.emojiFile.adapter.items
    }

    // The frecency store: how often and how recently each keyed row has been
    // activated, which is what Launcher.qml's sort ranks on once the prefix
    // test has had its say. Shape is `{ "<key>": { score, last } }`; the file
    // wraps it in an object because JsonAdapter refuses a non-object root,
    // the same constraint tree.nix's own comment records for quicklinks.json.
    //
    // Unlike the three files above this one is NOT in the read-only shell
    // tree — it is the one piece of launcher data the user writes by using
    // the launcher, so it lives in XDG state, at the path tree.nix generates
    // into Theme so the writer here and any future reader cannot disagree
    // about where it is.
    property var frecencyRecords: ({})

    // Called by Launcher.qml's activate() for any row carrying a key. Takes a
    // fresh Date.now() rather than the launcher's own open-time stamp: `last`
    // is what MRU sorts on, so it has to be when the thing was actually run,
    // not when the window it was run from opened.
    //
    // parentKey is how an app's own history rises when one of its desktop
    // actions is what got activated — running "New Private Window" is using
    // LibreWolf, and the app row should climb accordingly.
    //
    // Reassigning frecencyRecords rather than mutating it in place is what
    // re-fires the sort binding in Launcher.qml; a mutated object is the same
    // object and QML has nothing to notice.
    function recordUse(key: string, parentKey: string): void {
        if (!key)
            return;

        const now = Date.now();
        let next = Rank.bump(root.frecencyRecords, key, now);
        const touched = [key];

        if (parentKey) {
            next = Rank.bump(next, parentKey, now);
            touched.push(parentKey);
        }

        // The keys just bumped are handed over as the ones eviction may not
        // drop. A first-ever record scores exactly 1.0, which loses to every
        // key launched even twice within a half-life, so without this a new
        // app on a full store would be evicted before it was ever written —
        // and again on the next launch, and the one after, forever.
        root.frecencyRecords = Rank.evictOverCap(next, Rank.RECORD_CAP, now, touched);
        root.persistFrecency();
    }

    // Whether the state directory is known to exist. Starts false because on a
    // fresh install it does not, and FileView has no createParentDirectories
    // to lean on.
    property bool launcherStateDirReady: false

    // A write that arrived before the directory existed, held until mkdir
    // returns. Last one wins, which is correct rather than lossy: each stashed
    // payload is the complete serialized store, not a delta, so an older one
    // has nothing the newer is missing.
    property string pendingFrecencyWrite: ""

    // Picker.qml solves the same missing-directory problem by forking mkdir
    // before every single write. That is affordable there because a wallpaper
    // is picked rarely; it is not affordable here, because this runs on every
    // activation. So the fork is one-shot: the first write pays for it, every
    // later write finds the gate already open, and a session where nothing
    // keyed is ever launched pays nothing at all.
    function persistFrecency(): void {
        const payload = JSON.stringify({
            records: root.frecencyRecords
        });

        if (root.launcherStateDirReady) {
            root.frecencyFile.setText(payload);
            return;
        }

        root.pendingFrecencyWrite = payload;
        root.stateDirProbe.running = true;
    }

    property var stateDirProbe: Process {
        command: ["mkdir", "-p", Theme.launcherStateDir]

        // qmllint disable signal-handler-parameters
        onExited: (exitCode, exitStatus) => {
            root.launcherStateDirReady = true;

            if (root.pendingFrecencyWrite === "")
                return;

            root.frecencyFile.setText(root.pendingFrecencyWrite);
            root.pendingFrecencyWrite = "";
        }
        // qmllint enable signal-handler-parameters
    }

    // atomicWrites because this file is rewritten in full on every activation:
    // a crash partway through a plain write would leave a truncated JSON that
    // the next launch reads as no history at all.
    //
    // Deliberately NOT watchChanges: this process is the only writer, so
    // watching it would only mean reloading our own setText back over the
    // in-memory records that produced it.
    //
    // printErrors is off for the one case this file has and the others do
    // not: on a machine that has never launched anything, frecency.json does
    // not exist yet and never did, which is not a fault worth a line in the
    // log every session until the user happens to run something.
    //
    // No load failure needs handling beyond that. A missing file, an empty
    // one, an unreadable one and an unparseable one all leave the adapter at
    // its declared default and mean the same thing here: no history. The
    // launcher ships with no opinion about ranking and forms one only from
    // what actually gets launched, so "no history" is a complete answer
    // rather than a case needing defaults filled in.
    property var frecencyFile: FileView {
        path: Theme.launcherStatePath
        atomicWrites: true
        printErrors: false

        adapter: JsonAdapter {
            property var records: ({})
        }

        onAdapterUpdated: root.frecencyRecords = root.frecencyFile.adapter.records

        // printErrors above silences the read side, which also silences this
        // one — and a write that fails is not the expected condition a
        // missing file is. An unwritable state directory or a full disk would
        // otherwise mean ranking silently never persists across restarts,
        // with nothing anywhere to say why.
        onSaveFailed: (error) => console.warn("launcher: could not write", root.frecencyFile.path, "-", FileViewError.toString(error))
    }
    // qmllint enable unresolved-type

    // /proc/meminfo. statusRows() calls reload() on this before every
    // text(), because meminfo's numbers change constantly and never fire an
    // inotify event to say so — without an explicit reload() this would
    // show the reading from the moment the launcher first opened for as
    // long as it stayed open. blockAllReads makes that reload() complete
    // synchronously rather than leaving text() to return the old content
    // for one more frame; it does not, by itself, repeat the read. It is
    // still a plain read(), not a subprocess, which is the half of
    // status.rs's cost split this can pay on every keystroke.
    property var meminfoFile: FileView {
        path: "/proc/meminfo"
        blockLoading: true
        blockAllReads: true
        printErrors: false
    }

    property var fileDebounce: Timer {
        interval: 120

        onTriggered: {
            // Restarting a running process would leave the previous search's
            // output arriving against the new query, so it is stopped first.
            root.fileSearch.running = false;
            root.fileSearch.command = ["fd", "--hidden", "--follow", "--exclude", ".git", "--max-results", "40", "--max-depth", "5", root.fileQuery, Quickshell.env("HOME")];
            root.fileSearch.running = true;
        }
    }

    property var fileSearch: Process {
        stdout: StdioCollector {
            onStreamFinished: root.fileResults = this.text.split("\n").filter(line => line !== "")
        }
    }

    // The clipboard watcher. beamenu ran this inside `--daemon`; the shell is
    // already resident, so it owns it directly and the daemon has one less
    // reason to exist. The NUL terminator is what makes multi-line clippings
    // arrive whole rather than a line at a time.
    property var clipboardWatch: Process {
        running: true
        command: ["wl-paste", "--type", "text", "--watch", "sh", "-c", "cat; printf '\\0'"]

        stdout: SplitParser {
            // NUL, not a newline: the printf above ends each clipping with one, so a
            // multi-line paste arrives whole instead of one row per line.
            splitMarker: "\0"

            onRead: (data) => {
                const text = data;
                if (text.trim() === "" || text.length > 64 * 1024)
                    return;

                const next = [text].concat(root.clipboardHistory.filter(existing => existing !== text));
                root.clipboardHistory = next.slice(0, root.clipboardLimit);
            }
        }
    }

    // The Disk rows' snapshot. Every mount is asked for in one `df`
    // invocation — still one fork per tick, not one per mount — and the
    // result is parsed once here rather than in statusRows, so a keystroke
    // that never touches a Disk row still costs nothing beyond the array
    // filter status.js already does for every provider.
    readonly property var diskPaths: ["/home", "/nix/store"]

    // Raw stdout and stderr from the most recent df run. Two plain
    // properties rather than reading either StdioCollector by id from the
    // other's handler: diskSnapshot below is a binding over both, so
    // whichever stream's onStreamFinished fires last is the one that
    // recomputes it with both texts current.
    property string diskStdoutText: ""
    property string diskStderrText: ""

    // parseDf needs stderr, not just stdout: a path df cannot reach — gone,
    // permission denied, not yet mounted — produces no stdout row at all,
    // and matching the rows that remain to `diskPaths` by position alone
    // would mislabel every path after the failed one.
    readonly property var diskSnapshot: StatusMath.parseDf(root.diskStdoutText, root.diskStderrText, root.diskPaths)

    // 15s, the same number rust/beamenu-status/src/cache.rs used for
    // STALE_AFTER_SECONDS — three times that daemon's 5s tick. Free space
    // moves slowly enough that df alone does not need the 5s side of that
    // precedent (the daemon's tick also covered volume, mic and network,
    // which do change fast), but 15s as the tick itself keeps every reading
    // within the same margin beamenu called fresh rather than stale.
    property var diskTimer: Timer {
        interval: 15000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.diskProbe.running = true
    }

    property var diskProbe: Process {
        command: ["df", "-B1", "--output=used,size,avail,pcent"].concat(root.diskPaths)

        stdout: StdioCollector {
            onStreamFinished: root.diskStdoutText = this.text
        }

        stderr: StdioCollector {
            onStreamFinished: root.diskStderrText = this.text
        }
    }

    // The layout codes configured on input:kb_layout, parsed once at
    // startup rather than on a timer the way diskProbe above is: unlike
    // free space, this only ever changes when Hyprland's own config is
    // edited and reloaded, which already requires restarting this shell
    // process to pick up everything else Nix generates into it (Theme.qml
    // among it), so a fixed startup read costs nothing a restart was not
    // already going to pay for.
    property var configuredKeyboardLayouts: []

    property var keyboardLayoutProbe: Process {
        running: true
        command: ["hyprctl", "getoption", "input:kb_layout", "-j"]

        stdout: StdioCollector {
            onStreamFinished: root.configuredKeyboardLayouts = KeyboardMath.parseConfiguredLayouts(this.text)
        }
    }
}
