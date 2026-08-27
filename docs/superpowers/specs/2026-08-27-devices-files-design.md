# Removable media: automount and a file manager, native to the shell

## Why

Plugging a USB stick in today does nothing. `services.udisks2.enable = true`
(`nix/modules/desktop.nix:67`) runs the daemon that *can* mount it, but
nothing ever asks it to — no udiskie, no udev rule, no systemd automount
unit. The drive sits at `/dev/sda1` with `mountpoint: null` until someone
opens a terminal and runs `udisksctl mount -b` by hand.

Opening it once mounted is worse than nothing, because it looks wired up and
isn't. Three surfaces all point at a file manager that was never installed:

- `nix/home/hyprland.nix:414-419` binds SUPER+SHIFT+F to
  `hl.dsp.exec_cmd("nautilus")`. `services.gnome.core-apps` is not enabled
  anywhere in this tree, so the bind silently fails.
- `nix/home/keybinds.nix:26-27` advertises the same bind in the SUPER+/
  cheatsheet as "File manager (Nautilus)", so the shell's own help screen
  documents a dead key.
- `qml/launcher/Providers.qml`'s `fileRows()` sends every directory hit
  through `Quickshell.execDetached(["xdg-open", path])`. With no file
  manager registered as a `.desktop` handler for `inode/directory`, this is
  the same dead end reached a third way.

This closes the gap end to end rather than patching one symptom: udisks2
gets a native driver so plugging a drive in mounts it, and a file manager
that actually exists gets built so every one of the three dead ends above
has somewhere real to send you.

## Decisions

**Driven from the QML tree, not udiskie or a udev rule.** The shell is
already a resident process watching Hyprland's socket for monitor hotplug
(`qml/monitors/Watcher.qml`); block-device hotplug is the same shape of
problem, and a second daemon watching the same udev bus a Quickshell
`Process` can watch directly buys nothing. Rejected explicitly: udiskie
(one more tray-icon daemon with its own config format to theme) and a
`systemd.user` automount unit (no route back into the shell's own state —
the bar pill and the sidebar would have nothing to read).

**Filter on `hotplug`, never on `rm` or on "has a filesystem and isn't
mounted."** Measured on this machine: `/dev/sda1` (the attached WD 2TB USB
disk) reports `rm: false, hotplug: true` — a USB hard disk is not
"removable media" in the kernel's own `rm` sense, so filtering on `rm` would
silently ignore it. `/dev/nvme0n1p1`, the EFI System Partition, reports
`fstype: "vfat", mountpoint: null, hotplug: false` — a filter of "has an
fstype and isn't mounted" would try to mount the ESP into a scratch
directory on every login. Only `hotplug` separates the two, and the captured
fixture at
`.superpowers/sdd/rosy-zooming-lemon/lsblk-fixture.json` carries both
devices side by side so the exclusion is a unit test, not a hope.

**`lsblk -J -b`, never lsblk's default text and never `udisksctl`'s stdout
for state.** Locale is German; `lsblk` without `-b` prints `"1,8T"` with a
locale comma and `udisksctl --help` prints `Aufruf:`. `-J -b` gives raw
bytes under stable JSON keys regardless of locale. `udisksctl` is invoked
only for its exit code — the resulting mount state is always re-read from a
fresh `lsblk`, never parsed from what `udisksctl mount` printed.

**No polkit rule.** `loginctl` shows the graphical session `Active=yes`,
which is what udisks2's shipped polkit rules already key an
unattended-mount allow on for the session's own user. Measured, not
assumed: a plain `udisksctl mount -b` from this session's shell prompts for
nothing.

**`boot.supportedFilesystems.ntfs = true` stays the only filesystem opt-in
this needs.** It is already set at `nix/modules/desktop.nix:67`'s
neighbourhood for other reasons. exFAT and vFAT need nothing added — both
are already in `/proc/filesystems` on this kernel, and udisks2 mounts both
through the in-tree kernel driver with no fsck step, unlike NTFS's
`ntfs3`/FUSE split.

**`pkgs.glib` for `gio trash`, not `trash-cli`.** `glib` is already pulled
in by the GTK closure this desktop carries regardless; `trash-cli` would add
a Python interpreter and its dependency chain for one command. Both honour
the same `.Trash-$uid` convention on a removable filesystem's own top level,
which is what makes a trashed file on a USB stick recoverable from another
Linux box rather than silently `rm`'d.

**`eject()`'s disk lookup reuses `qml/installer/disks.js`'s `parentDisk()`
rather than inventing a second heuristic.** Finding the whole disk behind a
partition is a problem this repo already solved once: the installer's own
`disks.js` strips a trailing partition suffix (`/dev/sda1` → `/dev/sda`,
`/dev/nvme0n1p2` → `/dev/nvme0n1`) as the documented fallback for exactly
the case where a `PKNAME` lookup comes back empty. `devices.js` prefers the
live `PKNAME` column from the same `lsblk` scan that already produced the
device list, and calls `Disks.parentDisk()` only when it is absent — which,
for a whole, unpartitioned disk with no parent to find, correctly hands
back the disk's own path unchanged, since there is no trailing digit left
to strip. One function, two callers, tested once against the installer's
own fixture and now exercised a second way by `tst_devices.qml`.

**The bar module is `bar/Drives.qml`, not `bar/Devices.qml`.** The service
singleton already owns the name `Devices` (`qml/services/Devices.qml`); two
files named `Devices.qml` in one tree is confusing to grep for even though
QML would resolve them fine by directory.

**Launcher-to-file-manager navigation is an in-process signal, not IPC with
an argument.** Every `IpcHandler` function in this tree today —
`launcher`'s `open`/`close`/`toggle`, `wallpaper`'s `open`/`close`/`toggle`,
`monitors`' `apply`, `arrange`'s `open`/`close`/`toggle`, `settings`'s
`open`/`close`/`toggle`, `cheatsheet`'s `toggle`/`close` — takes zero
arguments. There is exactly one exception, `wallpaper`'s
`apply(path: string, output: string, mode: string)` at
`qml/wallpaper/Picker.qml:112`, and nothing anywhere in this repo or its
history ever calls it externally — it compiles, but whether `qs ipc call`
correctly marshals a string argument into a live QML function call has
never actually been exercised. The launcher and the file manager live in
the same process and the same QML engine, so the correct tool for one to
tell the other "open this path" is a plain signal, which sidesteps the
question entirely for the path that matters. A `files` IPC target still
gains an `openPath(path: string)` handler, because something outside the
process — a keybind, a script — is a real future caller, and that gap gets
closed with its own direct proof (`qs ipc call files openPath /some/path`)
rather than inherited untested from the wallpaper picker.

**`qml/services/qmldir` is hand-written and checked in, not generated by
`tree.nix`.** `tree.nix`'s `runCommand` does `cp -r ${./qml}/. "$out/"` and
then overwrites exactly one file afterward: `"$out/qmldir"`, the root one,
which is how it injects the generated `Theme.qml` registration. A `qmldir`
committed inside `qml/services/` is never touched by that `cp`, so it
survives into the built config unchanged — the same reason `qml/common/`
needs no `tree.nix` entry of its own today. If `qmllint` cannot resolve
`import "../services"` against a plain checked-in file (untested until
Plan 0 Task 2 runs it), the fallback is teaching `tree.nix` to write this
`qmldir` the way it writes the root one.

**The file manager window is a `FloatingWindow`, not a `PanelWindow`.**
Every other Quickshell surface in this tree — launcher, cheatsheet,
settings, the wallpaper picker — is a transient overlay: `PanelWindow` on
the `Overlay` layer, an exclusive keyboard grab, dismissed by Escape or a
click outside. A file manager is not that; it is a window you keep open
next to other windows, alt-tab to, and let Hyprland tile like any other
application. `PanelWindow` is backed by `zwlr_layer_shell_v1`, which
Hyprland's own window rules and tiling never apply to a layer-shell
surface the way they do to a normal `xdg_toplevel`. `FloatingWindow` is
already proven in this tree — `installer.qml` uses it under `cage`, for the
unrelated reason that `cage` implements no layer-shell protocol at all —
and it is the correct choice here for the opposite reason: this window
needs to behave like a normal application, not like an overlay.

**Sub-project boundaries.** Part 0 is the devices service plus the bar
pill, the launcher's device rows, and the mount toast — everything that
makes a plugged-in drive visible with no file manager built yet. Part 1 is
the file manager as a single pane: browse, open, eject, the `files` IPC
handler, the sidebar, and the two dead-keybind repairs. Part 2 is the
second pane plus the write operations — rename, mkdir, trash, copy, move.
Each part is independently shippable, mirroring how
`2026-08-26-quickshell-tui-migration-design.md` staged its own sub-projects
by risk: a checkout after Part 0 already automounts and toasts with no file
manager to open into yet; a checkout after Part 1 opens, browses and ejects
with no write operations yet.

## Architecture

    nix/home/quickshell/qml/
    ├── services/
    │   ├── qmldir              hand-written, singleton Devices 1.0 Devices.qml
    │   ├── Devices.qml         udev watch → lsblk → automount → devices[]
    │   └── devices.js          flatten/candidates/mounted/displayLabel/parentPath
    ├── bar/
    │   └── Drives.qml          Pill, visible when Devices.devices is non-empty
    ├── launcher/
    │   └── Providers.qml       + deviceRows(), + fileRows() directory redirect
    └── files/
        ├── Files.qml           Scope + FloatingWindow, IpcHandler "files"
        ├── Sidebar.qml         Devices.devices, click to navigate, eject
        ├── Pane.qml            one directory listing
        ├── files.js            parseListing/join/parentOf
        └── operations.js       copy/move/rename/mkdir/trash argv builders (Part 2)

`Devices` is a `pragma Singleton`, the same shape as `Theme.qml`: nothing in
`shell.qml` ever writes `Devices {}`, because nothing needs to. QML
constructs a singleton on first read, and `Theme.qml`'s own live `FileView`
(the wallpaper-accent watcher, see that file's header) already depends on
this happening early — every panel in the tree reads `Theme.bg` on its
first paint. `Devices` rides the same guarantee: `bar/Drives.qml` reads
`Devices.devices` in its `visible` binding, `Bar.qml` is instantiated
unconditionally per screen the moment `shell.qml` loads
(`Variants { model: Quickshell.screens; Bar {} }`), so the singleton — and
the persistent `udevadm monitor` `Process` living inside it — is alive
before the first frame is on screen, with no explicit wiring anywhere to
that effect.

`Devices`'s `signal requestOpen(string path)` is the one thing that ties the
whole feature together: the launcher's device rows emit it, the launcher's
directory-hit rows emit it (Part 1), and the file manager's own sidebar
emits it (Part 1) — three different sources of "go here" collapsing onto
one listener in `Files.qml`, which is the only thing that ever connects to
it.

## Sub-projects

Ordered by risk, same convention as the migration spec: the repo is
shippable after each one.

### 0. Devices

`qml/services/Devices.qml` runs a persistent
`udevadm monitor --udev --subsystem-match=block` `Process`, the same
`Connections`-into-`Timer`-debounce-into-rescan shape
`qml/monitors/Watcher.qml` already uses for Hyprland's `onRawEvent` —
300ms, matching Watcher's own DEBOUNCE. Every debounced tick re-runs
`lsblk -J -b -o NAME,PATH,LABEL,SIZE,FSTYPE,MOUNTPOINT,RM,HOTPLUG,TYPE,VENDOR,MODEL,PKNAME`,
hands the raw JSON text to `devices.js`, and diffs the result: anything
`hotplug && fstype && !mountpoint` gets `udisksctl mount -b <path>`, exit
code only, followed immediately by another rescan to pick up the real
mountpoint udisks2 chose. Anything newly mounted since the previous scan
fires a `notify-send` toast. `devices` (the property every other consumer
reads) is `hotplug && fstype && mountpoint` — currently-mounted removable
filesystems, each carrying a `label` computed by `displayLabel()` (the
device's own filesystem label, falling back to the trimmed model string,
falling back to the device name). `eject(path)` unmounts the device and
then powers off the disk behind it — `devices.js`'s `parentPath()` resolves
that disk via the scan's own `PKNAME` column, falling back to
`qml/installer/disks.js`'s `parentDisk()` when `PKNAME` is empty — via
`udisksctl power-off`, which is what actually cuts power to a USB device so
it is safe to physically pull, not merely `unmount`.

`bar/Drives.qml` is a `Pill`, visible only when `Devices.devices.length >
0`, same "hide when there's nothing to say" rule `Battery.qml` already
follows for a desktop with no battery. Its click handler runs
`qs ipc call files toggle` unconditionally, from Part 0 — before the
`files` IPC target exists in Part 1. That call fails quietly against an
unregistered target today and starts working the moment Part 1 lands, with
no further edit to this file.

`Providers.qml` gains `deviceRows()`, listed alongside `systemRows()` in
the launcher's ambient results: one row per mounted device, activating it
calls `Devices.requestOpen(device.mountpoint)`.

### 1. Browser

`qml/files/Files.qml` is a `Scope` holding one `FloatingWindow`, opened at
`Quickshell.env("HOME")`, with `Sidebar` and one `Pane` side by side. The
`files` `IpcHandler` gets `open()`/`close()`/`toggle()` matching every
other surface's shape, plus `openPath(path: string)` — the one place this
feature deliberately exercises a string-argument IPC call end to end,
proven with a literal `qs ipc call files openPath <path>` rather than
inherited from the wallpaper picker's unexercised precedent. `Files.qml`
also holds one `Connections { target: Devices }` for `onRequestOpen`,
which is the only wiring `Sidebar.qml` and `Providers.qml`'s device and
directory rows need — none of them talk to `Files.qml` directly.

`Pane.qml` lists one directory: `ls -1Ap --group-directories-first <path>`
as direct argv (no shell — nothing here interpolates a path into a command
string, so nothing here needs the `sh -c` script `preview.js` had to write
for the same reason). `files.js`'s `parseListing()` turns the `-p`
trailing-slash convention into `{name, isDir}` pairs; clicking a directory
row calls `join(root.path, name)` and reassigns `path`; clicking a file
calls `xdg-open` on the joined path — the same `xdg-open` the launcher's
own `fileRows()` already uses for non-directory hits, now finally paired
with a directory story that isn't the same call failing a second way.

`Sidebar.qml` lists `Devices.devices`, click-to-navigate through the shared
`Devices.requestOpen` signal, and one eject affordance per row calling
`Devices.eject(device.path)` directly — an in-process call on the singleton,
no signal needed, since ejecting is an immediate action rather than
something another surface needs to react to.

The dead ends from the Why section get closed here, not before: `hl.dsp.exec_cmd("nautilus")` at `nix/home/hyprland.nix:414-419` becomes
`hl.dsp.exec_cmd("qs ipc call files toggle")`, and
`nix/home/keybinds.nix:26-27`'s cheatsheet copy stops naming software that
was never installed. `Providers.qml`'s `systemCommands` gains an "Open File
Manager" row, and `fileRows()`'s directory branch stops calling `xdg-open`
in favour of `Devices.requestOpen(path)`.

### 2. Panes

`Files.qml` grows a second `Pane`, `leftPath`/`rightPath` and an
`activeSide`; `Pane.qml` grows a real `selected` entry (not just
click-to-activate) because every write operation below needs an operand
that exists independently of the click that triggered it. `operations.js`
is five pure argv builders — `copyArgv`, `moveArgv`, `renameArgv`,
`mkdirArgv`, `trashArgv` — each returning an array with every path as its
own element, the same discipline `preview.js`'s `previewCommand()` already
enforces and `tests/qml/tst_preview.qml` already tests for that file. Copy
and move act between the two panes' current directories; rename and mkdir
prompt inline in the active pane; trash calls `gio trash --`, which needs
`pkgs.glib` added to `nix/home/quickshell/default.nix`'s existing
`home.packages` list (`:172-186`) — `gio` is not on this machine's `PATH`
today, unlike `udisksctl`, `udevadm`, `busctl` and `notify-send`, which
already are.

No conflict resolution is built for a copy or move that lands on an
existing name — `cp`/`mv` do whatever the coreutils default does (overwrite
a same-type target, refuse a type mismatch), and that default is accepted
rather than reimplemented. Named as a real gap in Open risks below, not
silently dropped.

## Testing

- `qmllint --max-warnings 0` over both roots, unchanged gate, now also
  covering `qml/services/`, `qml/bar/Drives.qml` and everything under
  `qml/files/`.
- QtTest in `tests/qml/` for every pure `.pragma library`: `tst_devices.qml`
  against the real captured `lsblk-fixture.json` (the ESP-exclusion case is
  the load-bearing assertion — see Plan 0), `tst_files.qml` for
  `parseListing`/`join`/`parentOf`, `tst_files_operations.qml` for the four
  argv builders' shape.
- Manual verification against the real attached hardware where no fixture
  substitutes for it: the machine already has a real 1.8T USB disk at
  `/dev/sda1` (`hotplug: true`), so automount, the toast, the pill, the
  sidebar and eject are each proven by physically unplugging and
  replugging it, not simulated.

## Open risks

**No `.desktop` file, so this is not the system's default file manager.**
`xdg-open` on a directory still resolves however it resolved before this
feature — nothing here registers `qs ipc call files openPath %f` as an
`inode/directory` handler. In scope is the three call sites this spec
names (the keybind, the launcher's own directory hits, the sidebar);
anything else that shells out to `xdg-open` on a folder is unaffected and
stays exactly as broken as it is today.

**Copy and move have no conflict UI.** A same-named file already at the
destination is silently overwritten or silently refused, whichever `cp`/
`mv` does by default, with nothing in `Files.qml` telling you which one
happened.

**Devices power off, they do not un-appear.** After `eject()`, `lsblk`
should stop listing the device rather than merely losing its `mountpoint` —
that is verified against the real attached disk in Plan 1, not assumed.
