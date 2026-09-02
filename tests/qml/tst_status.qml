// beamenu's status provider, restored — rust/beamenu/src/providers/status.rs
// deleted with the crate. Fixtures below are real captured output from this
// machine (`cat /proc/meminfo` and `df -B1 --output=used,size,avail,pcent
// /home /nix/store`), not invented text: df's column layout and meminfo's
// "kB" suffix are exactly the details a guess gets wrong, and this machine's
// own df header is German ("Benutzt 1B-Blöcke Verf. Verw%"), which is the
// localisation status.js's own header says nothing here ever reads.
//
// Two kinds of fixture below. The real capture proves the parsers survive
// this machine's actual output; a second, synthetic fixture with clean round
// byte counts (syntheticMeminfo/syntheticDf) proves the arithmetic itself —
// formatBytes, percentOf, and every row's rendered subtitle/accessory/run —
// against numbers a human can check by hand, which the real capture's
// fractional GiB values cannot offer without redoing the division here too.
import QtQuick
import QtTest
import "../../nix/home/quickshell/qml/launcher/status.js" as StatusMath

TestCase {
    name: "Status"

    function realMeminfo() {
        return `MemTotal:       15703360 kB
MemFree:          386436 kB
MemAvailable:   11910932 kB
Buffers:            2436 kB
Cached:         10755844 kB
SwapCached:        38376 kB
Active:          1797396 kB
Inactive:       10646028 kB
Active(anon):    1207448 kB
Inactive(anon):   688148 kB
Active(file):     589948 kB
Inactive(file):  9957880 kB
Unevictable:      190164 kB
Mlocked:           25052 kB
SwapTotal:      15728636 kB
SwapFree:       15157788 kB
Zswap:            183944 kB
Zswapped:         505544 kB
Dirty:             91080 kB
Writeback:             0 kB
AnonPages:       1866056 kB
Mapped:           752772 kB
Shmem:            121868 kB
KReclaimable:    1313296 kB
Slab:            1883480 kB
SReclaimable:    1313296 kB
SUnreclaim:       570184 kB
KernelStack:       16544 kB
PageTables:        30868 kB
SecPageTables:      4468 kB
NFS_Unstable:          0 kB
Bounce:                0 kB
WritebackTmp:          0 kB
CommitLimit:    23580316 kB
Committed_AS:    6757564 kB
VmallocTotal:   34359738367 kB
VmallocUsed:       88004 kB
VmallocChunk:          0 kB
Percpu:            17216 kB
HardwareCorrupted:     0 kB
AnonHugePages:         0 kB
ShmemHugePages:        0 kB
ShmemPmdMapped:        0 kB
FileHugePages:         0 kB
FilePmdMapped:         0 kB
CmaTotal:              0 kB
CmaFree:               0 kB
Unaccepted:            0 kB
Balloon:               0 kB
GPUActive:         80192 kB
GPUReclaim:       174604 kB
HugePages_Total:       0
HugePages_Free:        0
HugePages_Rsvd:        0
HugePages_Surp:        0
Hugepagesize:       2048 kB
Hugetlb:               0 kB
DirectMap4k:     1743308 kB
DirectMap2M:    14358528 kB
DirectMap1G:           0 kB
`;
    }

    // `df -B1 --output=used,size,avail,pcent /home /nix/store`, captured on
    // this machine — one header line, then one data row per path, in
    // argument order. The header's own words ("Benutzt", "1B-Blöcke",
    // "Verf.") are German, which is the whole reason parseDf drops the
    // header by position rather than by matching English column names.
    function realDf() {
        return `    Benutzt    1B-Blöcke        Verf. Verw%
71118229504 493837352960 418855088128   15%
71118229504 493837352960 418855088128   15%
`;
    }

    // `df -B1 --output=used,size,avail,pcent /home /nix/store` when /home
    // cannot be reached: one data row, for /nix/store alone, in the same
    // shape df actually prints — the header stays, but the row that would
    // have been /home's is simply absent rather than blank.
    function dfWithHomeMissing() {
        return `    Benutzt    1B-Blöcke        Verf. Verw%
71118229504 493837352960 418855088128   15%
`;
    }

    // GNU df's own English wording for the same failure, captured for
    // comparison against the German fixture below: differently worded, same
    // literal path embedded in the line.
    function dfMissingHomeStderrEnglish() {
        return "df: cannot access '/home': No such file or directory\n";
    }

    // This machine's actual locale (see realDf's own header above) — proof
    // that matching only needs the literal path substring, not any part of
    // the surrounding, localised sentence.
    function dfMissingHomeStderrGerman() {
        return "df: /home: Datei oder Verzeichnis nicht gefunden\n";
    }

    // Round numbers chosen so every derived figure below can be checked by
    // hand: 10 GiB total, 2 GiB available, exactly.
    function syntheticMeminfo() {
        return `MemTotal:       10485760 kB
MemAvailable:    2097152 kB
`;
    }

    // Same idea for df: used, total and avail are exact GiB multiples, and
    // avail is deliberately NOT total - used (5 GiB avail against a 6 GiB
    // total-used gap of 4+10-... i.e. used=4 GiB, total=10 GiB, avail=5 GiB,
    // not the 6 GiB total-used would give) — the same shape a real
    // filesystem's reserved blocks produce, and the detail that catches a
    // regression back to computing free as total - used.
    function syntheticDf() {
        return `header
4294967296 10737418240 5368709120 40%
`;
    }

    function test_parseMeminfo_reads_total_and_available_in_bytes() {
        const memory = StatusMath.parseMeminfo(realMeminfo());

        compare(memory.total, 15703360 * 1024);
        compare(memory.used, (15703360 - 11910932) * 1024);
    }

    function test_parseMeminfo_is_null_without_a_kb_suffix() {
        // MemTotal with no unit at all is not a meminfo line this machine (or
        // any real kernel) ever prints, but the field lookup must not treat
        // an unsuffixed number as kilobytes by accident.
        compare(StatusMath.parseMeminfo("MemTotal: 100\nMemAvailable: 50 kB\n"), null);
    }

    function test_parseMeminfo_is_null_when_a_field_is_missing() {
        compare(StatusMath.parseMeminfo("MemTotal: 100 kB\n"), null);
    }

    function test_parseDf_reads_the_localised_header_by_position_data() {
        return [
            { tag: "home", index: 0, path: "/home" },
            { tag: "nix store", index: 1, path: "/nix/store" }
        ];
    }

    function test_parseDf_reads_the_localised_header_by_position(row) {
        const disks = StatusMath.parseDf(realDf(), "", ["/home", "/nix/store"]);

        compare(disks.length, 2);
        compare(disks[row.index].path, row.path);
        compare(disks[row.index].used, 71118229504);
        compare(disks[row.index].total, 493837352960);
        compare(disks[row.index].avail, 418855088128);
    }

    function test_parseDf_drops_a_path_with_no_matching_row() {
        const disks = StatusMath.parseDf(realDf(), "", ["/home", "/nix/store", "/boot"]);

        compare(disks.length, 2);
    }

    // Motivating bug: matching rows to paths by index alone means a path df
    // fails on early shifts every later path's row up by one. Here /home
    // fails and only one row survives — the fix must attribute it to
    // /nix/store (the path that actually produced it), not silently accept
    // whatever index /nix/store happens to occupy in the paths array.
    function test_parseDf_does_not_mislabel_the_path_after_an_earlier_failure() {
        const disks = StatusMath.parseDf(dfWithHomeMissing(), dfMissingHomeStderrEnglish(), ["/home", "/nix/store"]);

        compare(disks.length, 1);
        compare(disks[0].path, "/nix/store");
        compare(disks[0].used, 71118229504);
    }

    // Same failure, this machine's actual (German) df wording instead of the
    // English one above — proof that association goes through the literal
    // path substring embedded in stderr, not through parsing or recognising
    // any particular error message.
    function test_parseDf_failure_detection_is_locale_independent() {
        const disks = StatusMath.parseDf(dfWithHomeMissing(), dfMissingHomeStderrGerman(), ["/home", "/nix/store"]);

        compare(disks.length, 1);
        compare(disks[0].path, "/nix/store");
    }

    // A path with nothing wrong with it — stderr silent, its row present —
    // must not be affected by an unrelated path elsewhere in the list also
    // being fine. Guards against a fix that only handles exactly one path
    // failing rather than the general case.
    function test_parseDf_unaffected_paths_keep_their_own_row() {
        const disks = StatusMath.parseDf(realDf(), "", ["/home", "/nix/store"]);

        compare(disks.length, 2);
        compare(disks[0].path, "/home");
        compare(disks[1].path, "/nix/store");
    }

    // Direct coverage of the matcher itself, with a title/keyword pair that
    // guarantees no accidental overlap — real row titles and keywords do
    // share substrings ("home" is both a keyword and part of "Disk —
    // /home"), which is exactly what let four of the five keyword tests
    // below pass with their keyword arrays emptied. This cannot pass that
    // way: "gadget" appears nowhere in "Widget".
    function test_answersTo_data() {
        return [
            { tag: "empty query matches everything", query: "", title: "Widget", keywords: [], expected: true },
            { tag: "matches via the title", query: "wid", title: "Widget", keywords: [], expected: true },
            { tag: "matches via a keyword absent from the title", query: "gadget", title: "Widget", keywords: ["gadget", "gizmo"], expected: true },
            { tag: "matches neither", query: "nope", title: "Widget", keywords: ["gadget"], expected: false }
        ];
    }

    function test_answersTo(row) {
        compare(StatusMath.answersTo(row.query, row.title, row.keywords), row.expected);
    }

    // The feature's whole point: typing "ram" has to find a row titled
    // "Memory", and typing "disk" has to find rows titled "Disk — /home" and
    // "Disk — /nix/store" — neither word appears in both places at once.
    function test_statusRows_typing_ram_finds_the_memory_row() {
        const rows = StatusMath.statusRows("ram", realMeminfo(), [], () => {});

        compare(rows.length, 1);
        compare(rows[0].title, "Memory");
        compare(rows[0].provider, "status");
    }

    // "free" is a Memory keyword that is not a substring of "Memory" itself,
    // so unlike "ram" this also exercises answersTo's keyword branch on the
    // real row-building path, not only on the matcher in isolation.
    function test_statusRows_typing_free_finds_the_memory_row_via_keyword() {
        const rows = StatusMath.statusRows("free", realMeminfo(), [], () => {});

        compare(rows.length, 1);
        compare(rows[0].title, "Memory");
    }

    // "disk" is a substring of both row titles ("Disk — /home", "Disk —
    // /nix/store"), so this alone would still pass with DISK_LABELS'
    // keyword arrays emptied — it is kept because it is still real usage,
    // but it is the title branch of answersTo, not the keyword one.
    function test_statusRows_typing_disk_finds_both_disk_rows() {
        const snapshot = StatusMath.parseDf(realDf(), "", ["/home", "/nix/store"]);
        const rows = StatusMath.statusRows("disk", realMeminfo(), snapshot, () => {});

        compare(rows.length, 2);
        compare(rows.map(row => row.title).sort(), ["Disk — /home", "Disk — /nix/store"]);
        verify(rows.every(row => row.provider === "status"));
    }

    // "storage" is a keyword on both disk rows and a substring of neither
    // title, so this is the disk side's genuine keyword-array test — it
    // fails if DISK_LABELS' keywords are emptied, which "disk" above does
    // not catch.
    function test_statusRows_typing_storage_finds_both_disk_rows_via_keyword() {
        const snapshot = StatusMath.parseDf(realDf(), "", ["/home", "/nix/store"]);
        const rows = StatusMath.statusRows("storage", realMeminfo(), snapshot, () => {});

        compare(rows.length, 2);
        compare(rows.map(row => row.title).sort(), ["Disk — /home", "Disk — /nix/store"]);
    }

    // "home" and "store" are themselves substrings of their own row's title
    // ("Disk — /home" contains "home"; "Disk — /nix/store" contains
    // "store"), so these two prove the title branch disambiguates between
    // mounts, not that the keyword arrays are intact — DISK_LABELS names the
    // mount in its title, so a keyword-only equivalent does not exist here.
    function test_statusRows_typing_home_finds_only_the_home_disk() {
        const snapshot = StatusMath.parseDf(realDf(), "", ["/home", "/nix/store"]);
        const rows = StatusMath.statusRows("home", realMeminfo(), snapshot, () => {});

        compare(rows.length, 1);
        compare(rows[0].title, "Disk — /home");
    }

    function test_statusRows_typing_store_finds_only_the_nix_disk() {
        const snapshot = StatusMath.parseDf(realDf(), "", ["/home", "/nix/store"]);
        const rows = StatusMath.statusRows("store", realMeminfo(), snapshot, () => {});

        compare(rows.length, 1);
        compare(rows[0].title, "Disk — /nix/store");
    }

    function test_statusRows_empty_query_returns_every_row() {
        const snapshot = StatusMath.parseDf(realDf(), "", ["/home", "/nix/store"]);
        const rows = StatusMath.statusRows("", realMeminfo(), snapshot, () => {});

        compare(rows.length, 3);
    }

    function test_statusRows_an_unrelated_query_finds_nothing() {
        const snapshot = StatusMath.parseDf(realDf(), "", ["/home", "/nix/store"]);
        const rows = StatusMath.statusRows("firefox", realMeminfo(), snapshot, () => {});

        compare(rows.length, 0);
    }

    // formatBytes on values a human can check: 1 GiB and 1.5 GiB exactly. A
    // mutant dividing by MiB instead of GiB (still labelled "GiB") turns the
    // first into "1024.0 GiB", which this catches immediately.
    function test_formatBytes_data() {
        return [
            { tag: "one GiB", bytes: 1024 * 1024 * 1024, expected: "1.0 GiB" },
            { tag: "one and a half GiB", bytes: 1610612736, expected: "1.5 GiB" },
            { tag: "zero", bytes: 0, expected: "0.0 GiB" }
        ];
    }

    function test_formatBytes(row) {
        compare(StatusMath.formatBytes(row.bytes), row.expected);
    }

    function test_percentOf_data() {
        return [
            { tag: "quarter", used: 25, total: 100, expected: 25 },
            { tag: "asymmetric, catches an inverted division", used: 50, total: 200, expected: 25 },
            { tag: "zero total does not divide by zero", used: 5, total: 0, expected: 0 }
        ];
    }

    function test_percentOf(row) {
        compare(StatusMath.percentOf(row.used, row.total), row.expected);
    }

    // The Memory row's rendered numbers, pinned against syntheticMeminfo's
    // round 10 GiB / 2 GiB reading: 8 GiB used, 80% — not just that a
    // subtitle and an accessory exist, but that they say the right thing.
    function test_memory_row_renders_the_exact_reading() {
        const rows = StatusMath.statusRows("memory", syntheticMeminfo(), [], () => {});

        compare(rows.length, 1);
        compare(rows[0].subtitle, "8.0 GiB used of 10.0 GiB total");
        compare(rows[0].accessory, "80%");
    }

    // Enter's action on an informational row: beamenu's dashboard sidecar has
    // no port here, so the row copies its own reading instead.
    function test_statusRows_memory_row_run_copies_the_reading() {
        const copied = [];
        const rows = StatusMath.statusRows("memory", syntheticMeminfo(), [], text => copied.push(text));

        rows[0].run();

        compare(copied.length, 1);
        compare(copied[0], "80% used (8.0 GiB / 10.0 GiB)");
    }

    // The Disk row's rendered numbers, pinned against syntheticDf's
    // deliberately-not-total-minus-used avail: free must read 5.0 GiB (the
    // avail column), never 6.0 GiB (total - used) and never 4.0 GiB (used
    // reported as free).
    function test_disk_row_renders_the_exact_reading() {
        const snapshot = StatusMath.parseDf(syntheticDf(), "", ["/home"]);
        const rows = StatusMath.statusRows("", "MemTotal: 1 kB\nMemAvailable: 1 kB\n", snapshot, () => {});

        compare(rows.length, 2);
        const disk = rows.find(row => row.title === "Disk — /home");
        compare(disk.subtitle, "5.0 GiB free of 10.0 GiB total");
        compare(disk.accessory, "40% used");
    }

    function test_disk_row_run_copies_the_exact_reading() {
        const snapshot = StatusMath.parseDf(syntheticDf(), "", ["/home"]);
        const copied = [];
        const rows = StatusMath.statusRows("home", "MemTotal: 1 kB\nMemAvailable: 1 kB\n", snapshot, text => copied.push(text));

        rows[0].run();

        compare(copied.length, 1);
        compare(copied[0], "5.0 GiB free of 10.0 GiB");
    }
}
