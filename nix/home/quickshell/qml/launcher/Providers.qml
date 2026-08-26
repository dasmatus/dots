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
        {
            title: "Screenshot Screen",
            subtitle: "Capture the focused output",
            argv: ["hyprshot", "-m", "output"]
        },
        {
            title: "Screenshot Region",
            subtitle: "Select a region to capture",
            argv: ["hyprshot", "-m", "region"]
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

    function fileRows(text: string): var {
        return root.fileResults.map(path => ({
                    title: path.split("/").pop(),
                    subtitle: path.replace(Quickshell.env("HOME"), "~"),
                    icon: "",
                    accessory: "open",
                    run: () => Quickshell.execDetached(["xdg-open", path])
                }));
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

            if (!root.matches(`${entry.name} ${entry.genericName} ${entry.keywords}`, text))
                continue;

            rows.push({
                title: entry.name,
                subtitle: entry.comment || entry.genericName,
                icon: entry.icon ? Quickshell.iconPath(entry.icon, true) : "",
                accessory: "",
                // execute() rather than execDetached(entry.command): it honours
                // Terminal=true and the entry's working directory, which a raw
                // argv spawn silently drops.
                run: () => entry.execute()
            });

            for (const action of entry.actions) {
                rows.push({
                    title: `${entry.name}: ${action.name}`,
                    subtitle: entry.comment || entry.genericName,
                    icon: entry.icon ? Quickshell.iconPath(entry.icon, true) : "",
                    accessory: "action",
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
                run: () => Quickshell.execDetached(command.argv)
            });
        }

        return rows;
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
                run: () => root.copy(entry.glyph)
            });
        }

        return rows;
    }

    function quicklinkRows(text: string): var {
        const rows = [];
        const links = root.quicklinksFile.adapter.root?.items ?? [];

        for (const link of links) {
            if (!root.matches(link.name, text))
                continue;

            rows.push({
                title: link.name,
                subtitle: link.target,
                icon: "",
                accessory: link.command ? "run" : "open",
                run: () => Quickshell.execDetached(link.command ? ["sh", "-c", link.target] : ["xdg-open", link.target])
            });
        }

        return rows;
    }

    function snippetRows(text: string): var {
        const rows = [];
        const snippets = root.snippetsFile.adapter.root?.items ?? [];

        for (const snippet of snippets) {
            if (!root.matches(snippet.name, text))
                continue;

            rows.push({
                title: snippet.name,
                subtitle: root.preview(snippet.text, 72),
                icon: "",
                accessory: "copy",
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
                run: () => Quickshell.execDetached(["xdg-open", url])
            }
        ];
    }

    // Quickshell types FileView.adapter as FileViewAdapter without exporting
    // that type, so the linter cannot resolve anything reached through it. The
    // bindings work; only the linter is blind, so it is suppressed here rather
    // than across the whole tree.
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
        adapter: JsonAdapter {}
    }

    property var snippetsFile: FileView {
        path: `${Quickshell.shellDir}/launcher/snippets.json`
        watchChanges: true
        onFileChanged: reload()
        adapter: JsonAdapter {}
    }

    property var emojiFile: FileView {
        path: `${Quickshell.shellDir}/launcher/emoji.json`
        adapter: JsonAdapter {}

        onAdapterUpdated: root.emojiData = root.emojiFile.adapter.root?.items ?? []
    }
    // qmllint enable unresolved-type

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
}
