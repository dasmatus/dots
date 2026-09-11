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
// answers that bit "no", since it is a fixed drive that merely lives behind
// a USB bridge, while the NVMe boot disk's EFI System Partition answers
// "hotplug" false and sits there with a filesystem and no mountpoint,
// looking exactly like a candidate to offer up for mounting. "hotplug" is
// the bit that means "arrived after boot, on a bus meant for that"; "rm" is
// a different question this menu never asks. Filtering on rm would drop the
// real USB disk; filtering on fstype-without-mountpoint instead of hotplug
// would try to mount the ESP. Both are here as fixture-backed regression
// tests, not as a hypothetical.
//
// Two different questions get asked of the same tree, and they get two
// different walkers on purpose. "What should this shell offer to mount" is
// narrow: walk() pushes only a partition or a childless disk, because an
// LVM logical volume or a LUKS mapping is plumbing a user never picks off
// a menu. "What has to come unmounted before this disk loses power" is
// broad: walkMounts() pushes anything with a mountpoint, whatever its
// type, because a logical volume mounted on a hotplug USB disk is exactly
// as mounted as a plain partition, and udisksctl power-off does not care
// which kind of node was sitting on the filesystem it just cut power to.
// Answering the second question from the first walker's narrow output is
// how a live LUKS or LVM external drive used to get powered off with its
// filesystem still mounted.
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
/// disk that owns the partition, not whichever node sits one level up.
/// Relevant for a logical partition nested inside an extended one.
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
/// partitions and hotplug superfloppy disks. Everything else, internal
/// disks, the ESP, loop and rom devices, LVM/crypt plumbing, is left out.
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

/// Depth-first walk collecting every mounted node under one top-level disk,
/// whatever its type. `diskHotplug` is the top-level disk's own flag,
/// carried down unchanged the same way walk() carries it, and deliberately
/// not read off each node's own hotplug flag: lsblk reports a
/// device-mapper node (crypt, lvm) as hotplug:false regardless of what bus
/// the disk underneath sits on, so a mounted logical volume three levels
/// under a hotplug USB disk would otherwise look, to this function's
/// caller, like it belongs to a fixed drive.
function walkMounts(node, diskPath, diskHotplug, out) {
    if (orNull(node.mountpoint) !== null) {
        out.push({
            path: node.path,
            diskPath: diskPath,
            mountPoint: node.mountpoint,
            type: node.type,
            hotplug: diskHotplug
        });
    }

    if (Array.isArray(node.children)) {
        for (const child of node.children)
            walkMounts(child, diskPath, diskHotplug, out);
    }
}

/// Every mounted node under each top-level disk, whatever its type,
/// whatever its own hotplug flag: a logical volume or an unlocked LUKS
/// mapping sitting on a hotplug USB disk is exactly as mounted as a plain
/// partition, and ejectPlan needs to find all of them, not only the ones
/// parseDevices() would also have offered for automount. Loop and rom
/// devices are not excluded here either, for the same reason: mounted
/// under the target disk means unmount it before that disk loses power,
/// full stop. Malformed input yields an empty list rather than throwing,
/// same as parseDevices, so a bad lsblk read never turns into a plan that
/// silently unmounts nothing.
function parseMounts(text) {
    let root;
    try {
        root = JSON.parse(text);
    } catch (e) {
        return [];
    }

    const top = root && Array.isArray(root.blockdevices) ? root.blockdevices : [];
    const out = [];
    for (const disk of top)
        walkMounts(disk, disk.path, flag(disk.hotplug), out);
    return out;
}

/// label, else vendor+model trimmed (lsblk right-pads vendor to 8 columns),
/// else the kernel name. Always something to put on the menu row.
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

/// Every device observed mounted counts as already attempted, whether this
/// shell is the one that mounted it or not. `attempted` used to gain an
/// entry only from mount() and eject(), both of which act on a device this
/// singleton itself decided to touch, so a device already mounted the first
/// time a scan ever saw it, left over from a previous session or mounted by
/// some other tool before the debounce fired, had no entry at all. A later
/// `udisksctl unmount` run by hand then looked, to mountCandidates, exactly
/// like a stick that had simply never been offered: unmounted, hotplug,
/// carrying an fstype, absent from `attempted`, and got mounted straight
/// back. Folding every currently-mounted path into `attempted` on every scan
/// closes that gap: the mark lands while the device is still mounted, so it
/// is already there by the time anyone unmounts it, and only pruneAttempts,
/// which fires on unplugging, ever removes it again.
function seedAttempts(attempted, devices) {
    const seeded = Object.assign({}, attempted);
    for (const d of devices) {
        if (d.mountPoint)
            seeded[d.path] = true;
    }
    return seeded;
}

/// Records that transitioned from unmounted to mounted between two polls,
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

/// argv for `udisksctl mount`. The path is always its own array element.
/// See previewCommand in qml/launcher/preview.js for why that discipline
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
/// nodes, then power the disk off. `mounts` must come from parseMounts(),
/// not parseDevices(): parseDevices() only ever emits partitions and
/// superfloppy disks, the narrow list automount needs, so an LVM logical
/// volume or an unlocked LUKS mapping mounted on a hotplug external drive
/// was never in it, EVEN WHILE MOUNTED. Filtering that narrow list here
/// found nothing mounted on such a drive and handed back a plan whose only
/// entry was a power-off against a disk with a live, possibly dirty
/// filesystem. Unmounting a node that was never mounted is a udisksctl
/// error the caller doesn't need, so only mounted ones get a step.
///
/// GUARD: the power-off step is appended only when `diskHotplug` is the
/// literal value `true`. That is the whole check, and no inference from
/// `mounts` is involved. `diskHotplug` used to be inferred from whichever
/// mounted nodes happened to match diskPath: a diskPath that matched
/// nothing at all, a wrong path or a stale one, carried no evidence
/// either way under that scheme and was read as permission to proceed
/// anyway. Requiring the caller to state the fact closes that: an
/// omitted argument and an explicit `false` both fail closed, the same
/// as a diskPath nothing in `mounts` supports. This is the one thing
/// stopping a wrong diskPath, or a future caller that doesn't know
/// better, from asking udisksctl to power off the machine's own NVMe:
/// unmounting a live root filesystem is recoverable in a way that the
/// boot disk losing power mid-session is not.
function ejectPlan(mounts, diskPath, diskHotplug) {
    const mountedOnDisk = mounts.filter(d => d.diskPath === diskPath && d.mountPoint);
    const plan = mountedOnDisk.map(d => unmountCommand(d.path));

    if (diskHotplug === true)
        plan.push(powerOffCommand(diskPath));

    return plan;
}
