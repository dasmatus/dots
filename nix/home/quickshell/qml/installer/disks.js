// Enumerate installable target disks by parsing `lsblk -J`.
//
// Ported from rust/installer-tui/src/disks.rs; parseLsblk/autodetectDisk are
// exercised against the same checked-in rust/installer-tui/tests/fixtures/
// lsblk.json in tests/qml/tst_installer.qml, so a change here that disagrees
// with the Rust parser fails the same way a change to disks.rs would.
.pragma library

/// One GiB in bytes.
const GIB = 1024 * 1024 * 1024;
/// ESP/boot partition size in the disko layout.
const ESP_GIB = 2;
/// Floor for the btrfs root: the desktop closure alone is ~12 GiB.
const ROOT_GIB = 20;

/// Minimum target disk size for the disko layout (ESP + swap + root), in GiB.
function requiredGib(swapGib) {
    return ESP_GIB + swapGib + ROOT_GIB;
}

/// lsblk emits native booleans (util-linux >= 2.37) or "0"/"1" strings.
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

/// Parse `lsblk -J -b -d -o NAME,PATH,SIZE,MODEL,RM,TYPE,RO` output. Keeps
/// writable physical disks only: excludes non-"disk" types (rom, loop),
/// read-only devices, and zram. Throws on malformed input, matching
/// disks.rs's `Result` return via `anyhow::anyhow!`.
function parseLsblk(json) {
    let root;
    try {
        root = JSON.parse(json);
    } catch (e) {
        throw new Error("lsblk output is not valid JSON");
    }
    const devices = root && Array.isArray(root.blockdevices) ? root.blockdevices : null;
    if (!devices)
        throw new Error("lsblk output missing 'blockdevices'");

    const disks = [];
    for (const dev of devices) {
        if (dev.type !== "disk")
            continue;
        const name = dev.name || "";
        if (name.startsWith("zram") || flag(dev.ro))
            continue;
        const sizeBytes = "size" in dev ? sizeOf(dev.size) : 0;
        if (sizeBytes === 0)
            continue;
        const path = typeof dev.path === "string" ? dev.path : `/dev/${name}`;
        const model = (typeof dev.model === "string" ? dev.model : "").trim();
        disks.push({
            path,
            sizeBytes,
            model,
            removable: flag(dev.rm),
        });
    }
    return disks;
}

/// Choose one sufficiently large target, preferring the sole fixed disk.
/// Throws when no disk qualifies or more than one candidate remains — the
/// caller (Network.qml) catches this to fall back to the manual DiskSelect
/// screen, exactly as `main.rs` falls back on an `Err` from this function.
function autodetectDisk(disks, swapGib) {
    const need = requiredGib(swapGib);
    const eligible = disks.filter(d => d.sizeBytes >= need * GIB);
    const fixed = eligible.filter(d => !d.removable);
    const candidates = fixed.length === 0 ? eligible : fixed;

    if (candidates.length === 0)
        throw new Error(`no installable disk has the required ${need} GiB capacity`);
    if (candidates.length !== 1)
        throw new Error(`disk autodetection is ambiguous: ${candidates.map(d => d.path).join(", ")}`);
    return candidates[0];
}

/// "476.9 GiB" style rendering.
function humanSize(disk) {
    const gib = disk.sizeBytes / GIB;
    return `${gib.toFixed(1)} GiB`;
}

/// Strip a partition suffix: /dev/sda1 -> /dev/sda, /dev/nvme0n1p2 -> /dev/nvme0n1.
/// Heuristic fallback for excluding the live medium — the QML port's
/// findmnt/lsblk PKNAME lookup prefers the authoritative PKNAME column and
/// only falls back to this when that lookup comes back empty, same as
/// disks.rs's `live_medium_disk`.
function parentDisk(path) {
    let stripped = path;
    while (stripped.length > 0 && /[0-9]/.test(stripped[stripped.length - 1])) {
        stripped = stripped.slice(0, -1);
    }
    if (stripped.length === path.length || stripped === "/dev/")
        return path;

    // Digit-named disks (nvme0n1, mmcblk0) use a 'p' separator before the
    // partition number; only a trailing pN may be stripped from them.
    if (stripped.endsWith("p")) {
        const pre = stripped.slice(0, -1);
        if (pre.length > 0 && /[0-9]/.test(pre[pre.length - 1]))
            return pre;
    }

    // A remaining inner digit (nvme0n[1]) means the "suffix" was part of the
    // disk name itself, not a partition number.
    const base = stripped.includes("/") ? stripped.slice(stripped.lastIndexOf("/") + 1) : stripped;
    if (/[0-9]/.test(base))
        return path;
    return stripped;
}
