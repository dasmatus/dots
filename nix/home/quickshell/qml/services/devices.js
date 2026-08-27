// Removable-storage arithmetic for the tray's Devices menu.
//
// `lsblk -J -b` is a tree: a disk has partitions as children, an encrypted
// partition has its mapper device as a grandchild, and a superfloppy (a
// flash drive with a filesystem directly on the disk, no partition table)
// has no children at all. This file flattens that tree into the flat list
// the menu actually draws, and the flattening is where the one bug that
// matters lives.
//
// lsblk's "rm" column is the SCSI removable-media bit. A USB hard disk
// answers that bit "no" — it is a fixed drive that merely lives behind a
// USB bridge — while the NVMe boot disk's EFI System Partition answers
// "hotplug" false and sits there with a filesystem and no mountpoint,
// looking exactly like a candidate to offer up for mounting. "hotplug" is
// the bit that means "arrived after boot, on a bus meant for that"; "rm" is
// a different question this menu never asks. Filtering on rm would drop the
// real USB disk; filtering on fstype-without-mountpoint instead of hotplug
// would try to mount the ESP. Both are here as fixture-backed regression
// tests, not as a hypothetical.
.pragma library

/// lsblk emits native booleans (util-linux >= 2.37) or "0"/"1" strings,
/// same ambiguity qml/installer/disks.js guards against for the same field.
function flag(v) {
    if (typeof v === "boolean")
        return v;
    if (typeof v === "string")
        return v === "1" || v === "true";
    if (typeof v === "number")
        return v === 1;
    return false;
}

function sizeOf(v) {
    if (typeof v === "number")
        return v;
    if (typeof v === "string") {
        const n = parseInt(v.trim(), 10);
        return Number.isNaN(n) ? 0 : n;
    }
    return 0;
}

function orNull(v) {
    return v === undefined ? null : v;
}

/// Depth-first walk of one top-level lsblk entry. `diskPath` and
/// `diskHotplug` are fixed at the top-level disk and carried unchanged into
/// every descendant, because "on itself OR on its parent disk" means the
/// disk that owns the partition, not whichever node sits one level up —
/// relevant for a logical partition nested inside an extended one.
function walk(node, diskPath, diskHotplug, out) {
    const excludedType = node.type === "loop" || node.type === "rom";
    const ownHotplug = flag(node.hotplug);
    const hotplug = ownHotplug || diskHotplug;
    const fstype = orNull(node.fstype);
    const isPartition = node.type === "part";
    const isSuperfloppy = node.type === "disk" && (!Array.isArray(node.children) || node.children.length === 0);

    if (!excludedType && hotplug && fstype !== null && (isPartition || isSuperfloppy)) {
        out.push({
            name: node.name,
            path: node.path,
            diskPath: isPartition ? diskPath : node.path,
            label: orNull(node.label),
            sizeBytes: sizeOf(node.size),
            fstype: fstype,
            mountPoint: orNull(node.mountpoint),
            type: node.type,
            vendor: orNull(node.vendor),
            model: orNull(node.model),
            hotplug: ownHotplug
        });
    }

    if (Array.isArray(node.children)) {
        for (const child of node.children)
            walk(child, diskPath, diskHotplug, out);
    }
}

/// Parse `lsblk -J -b` output into a flat array of mountable devices: hotplug
/// partitions and hotplug superfloppy disks, everything else — internal
/// disks, the ESP, loop and rom devices, LVM/crypt plumbing — left out.
/// Malformed input yields an empty list rather than throwing, since this
/// runs on every udev poll and one bad read must not crash the shell.
function parseDevices(text) {
    let root;
    try {
        root = JSON.parse(text);
    } catch (e) {
        return [];
    }

    const top = root && Array.isArray(root.blockdevices) ? root.blockdevices : [];
    const out = [];
    for (const disk of top)
        walk(disk, disk.path, flag(disk.hotplug), out);
    return out;
}

/// label, else vendor+model trimmed (lsblk right-pads vendor to 8 columns),
/// else the kernel name — always something to put on the menu row.
function displayLabel(device) {
    if (device.label)
        return device.label;

    const parts = [device.vendor, device.model].map(p => (p || "").trim()).filter(p => p.length > 0);

    return parts.length > 0 ? parts.join(" ") : device.name;
}

/// Devices worth offering a mount button for: unmounted, have a filesystem,
/// and not already the target of an in-flight mount this menu started.
function mountCandidates(devices, attempted) {
    const seen = attempted || {};
    return devices.filter(d => !d.mountPoint && !!d.fstype && !Object.prototype.hasOwnProperty.call(seen, d.path));
}

/// Drop attempted-mount entries for paths that vanished from the last poll,
/// so unplugging and replugging the same stick makes it eligible again
/// instead of being remembered as permanently attempted.
function pruneAttempts(attempted, devices) {
    const present = {};
    for (const d of devices)
        present[d.path] = true;

    const pruned = {};
    for (const path of Object.keys(attempted || {})) {
        if (present[path])
            pruned[path] = attempted[path];
    }
    return pruned;
}

/// Records that transitioned from unmounted to mounted between two polls —
/// the notify-send trigger. A device absent from `previous` counts as
/// having been unmounted, so a stick that appears already-mounted still
/// fires the notification once.
function newlyMounted(previous, next) {
    const before = {};
    for (const d of previous)
        before[d.path] = d;

    return next.filter(d => {
        const prior = before[d.path];
        const wasUnmounted = !prior || !prior.mountPoint;
        return wasUnmounted && !!d.mountPoint;
    });
}

/// argv for `udisksctl mount`. The path is always its own array element —
/// see previewCommand in qml/launcher/preview.js for why that discipline
/// matters: a label or mountpoint under attacker control is legal ext4/exfat
/// metadata, and it must never be able to reach a shell as text.
function mountCommand(path) {
    return ["udisksctl", "mount", "-b", path, "--no-user-interaction"];
}

/// argv for `udisksctl unmount`. See mountCommand for the argv discipline.
function unmountCommand(path) {
    return ["udisksctl", "unmount", "-b", path, "--no-user-interaction"];
}

/// argv for `udisksctl power-off`. See mountCommand for the argv discipline.
function powerOffCommand(path) {
    return ["udisksctl", "power-off", "-b", path, "--no-user-interaction"];
}

/// The eject sequence for one disk: unmount every one of its mounted
/// devices, then power the disk off. "Its mounted devices" is partitions
/// AND the disk-as-superfloppy case parseDevices also emits — a childless
/// disk with a filesystem directly on it has diskPath equal to its own
/// path and type "disk", not "part", so filtering on type "part" alone
/// skips its unmount and hands udisksctl a power-off for a device that is
/// still mounted. Unmounting a device that was never mounted is a
/// udisksctl error the caller doesn't need, so only mounted ones get a
/// step.
function ejectPlan(devices, diskPath) {
    const mountedOnDisk = devices.filter(d => d.diskPath === diskPath && d.mountPoint);
    const plan = mountedOnDisk.map(d => unmountCommand(d.path));
    plan.push(powerOffCommand(diskPath));
    return plan;
}
