// Pure logic for the launcher's Status provider, restoring
// rust/beamenu/src/providers/status.rs (deleted with the crate). Kept out of
// Providers.qml so tests/qml/tst_status.qml can drive it with real captured
// /proc/meminfo and `df` output and no FileView, Timer or Process anywhere
// near the test.
//
// That deleted file's own header stated the cost split this file exists to
// preserve: /proc is read here and now, on every keystroke, because it is
// microseconds; `df` needs a subprocess, tens of milliseconds, so it is read
// on a timer and handed in as a snapshot instead. Nothing in this file opens
// a file or spawns a process — Providers.qml does both and passes the text
// in, which is what keeps that split honest and this file testable without
// a machine that happens to have a battery, a network or any mounts at all.
.pragma library

// /proc/meminfo's values are kibibytes with a literal "kB" suffix on every
// line; converting to bytes here makes the rest of this file's arithmetic
// ordinary.
const KIB = 1024;

// One "Key:    12345 kB" line's value out of /proc/meminfo's text, or
// undefined if the key is missing or its line does not end in "kB" — meminfo
// keeps every value in kibibytes except a handful of bare counters
// (HugePages_Total and friends), and reading one of those as a memory size
// would be wrong in a way `parseInt` alone would not catch.
function meminfoField(raw, key) {
    for (const line of raw.split("\n")) {
        if (!line.startsWith(key))
            continue;

        const value = line.slice(key.length).trim();
        if (!value.endsWith("kB"))
            return undefined;

        const kib = parseInt(value.slice(0, -2).trim(), 10);
        return Number.isFinite(kib) ? kib * KIB : undefined;
    }

    return undefined;
}

// MemAvailable, not MemFree: MemFree ignores the page cache the kernel would
// hand back under pressure, and would report a desktop that has been up for
// an hour as nearly out of memory.
function parseMeminfo(raw) {
    const total = meminfoField(raw, "MemTotal:");
    const available = meminfoField(raw, "MemAvailable:");
    if (total === undefined || available === undefined)
        return null;

    return { total: total, used: Math.max(0, total - available) };
}

// `df -B1 --output=used,size,pcent <path>...`, one data row per path in the
// same order the paths were given. The header line is dropped unconditionally
// rather than matched by name: it is localised — this machine prints
// "Benutzt 1B-Blöcke Verw%" — so nothing here ever reads its text.
function parseDf(raw, paths) {
    const lines = raw.split("\n").filter(line => line.trim() !== "");
    const rows = lines.slice(1);

    const disks = [];
    for (let index = 0; index < paths.length; index++) {
        const row = rows[index];
        if (!row)
            continue;

        const fields = row.trim().split(/\s+/);
        const used = parseInt(fields[0], 10);
        const total = parseInt(fields[1], 10);
        if (!Number.isFinite(used) || !Number.isFinite(total))
            continue;

        disks.push({ path: paths[index], used: used, total: total });
    }

    return disks;
}

// GiB with one decimal. Every mount this provider names is measured in tens
// or hundreds of gigabytes, and RAM tops out in the same range, so nothing
// here needs a unit ladder.
function formatBytes(bytes) {
    return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GiB`;
}

function percentOf(used, total) {
    return total > 0 ? Math.round((used / total) * 100) : 0;
}

// Title and search keywords for each disk row, keyed by the path `df` was
// asked about. Keywords are beamenu's: "disk"/"storage"/"space"/"df" plus a
// word for the mount itself, so typing "home" or "nix" reaches the row a
// bare "disk" also reaches.
const DISK_LABELS = {
    "/home": {
        title: "Disk — /home",
        keywords: ["disk", "storage", "space", "df", "home"]
    },
    "/nix/store": {
        title: "Disk — /nix/store",
        keywords: ["disk", "storage", "space", "df", "nix", "store"]
    }
};

// Whether `query` (already trimmed) answers to a row's title or any of its
// keywords. This is item.rs's whole point for [`Item::keywords`]: a status
// row's title is what is shown, but typing "ram" has to find "Memory" even
// though the word never appears on screen.
function answersTo(query, title, keywords) {
    if (query === "")
        return true;

    const needle = query.toLowerCase();
    if (title.toLowerCase().includes(needle))
        return true;

    return keywords.some(keyword => keyword.includes(needle));
}

// The Memory row, from a fresh /proc/meminfo read. beamenu's Enter action
// here opened a live dashboard sidecar that has no port in this shell, so
// Enter copies the reading instead — the same fallback every other
// informational row (clipboard, emoji, snippets) already uses.
function memoryRow(meminfoText, query, copy) {
    const memory = parseMeminfo(meminfoText);
    if (memory === null)
        return null;

    const keywords = ["memory", "ram", "mem", "free"];
    if (!answersTo(query, "Memory", keywords))
        return null;

    const percent = percentOf(memory.used, memory.total);
    return {
        title: "Memory",
        subtitle: `${formatBytes(memory.used)} used of ${formatBytes(memory.total)} total`,
        icon: "",
        accessory: `${percent}%`,
        provider: "status",
        run: () => copy(`${percent}% used (${formatBytes(memory.used)} / ${formatBytes(memory.total)})`)
    };
}

// The Disk rows, from whatever the df timer last captured. A mount with no
// entry yet in `snapshot` (nothing has ticked since the launcher opened)
// simply contributes no row, rather than a blank or a stale-looking one.
function diskRows(snapshot, query, copy) {
    const rows = [];

    for (const entry of snapshot) {
        const label = DISK_LABELS[entry.path];
        if (!label)
            continue;

        if (!answersTo(query, label.title, label.keywords))
            continue;

        const free = Math.max(0, entry.total - entry.used);
        const percent = percentOf(entry.used, entry.total);
        rows.push({
            title: label.title,
            subtitle: `${formatBytes(free)} free of ${formatBytes(entry.total)} total`,
            icon: "",
            accessory: `${percent}% used`,
            provider: "status",
            run: () => copy(`${formatBytes(free)} free of ${formatBytes(entry.total)}`)
        });
    }

    return rows;
}

// The provider function proper — query string in, rows out, the same shape
// every other source in Providers.qml uses. `meminfoText` is whatever the
// caller just read inline; `diskSnapshot` is whatever the caller's timer
// last produced. Neither is read here, which is what keeps this file able to
// run in a test with no FileView or Process anywhere near it.
function statusRows(query, meminfoText, diskSnapshot, copy) {
    const rows = [];

    const memory = memoryRow(meminfoText, query, copy);
    if (memory !== null)
        rows.push(memory);

    return rows.concat(diskRows(diskSnapshot, query, copy));
}
