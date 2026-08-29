// beamenu's status provider, restored — rust/beamenu/src/providers/status.rs
// deleted with the crate. Fixtures below are real captured output from this
// machine (`cat /proc/meminfo` and `df -B1 --output=used,size,pcent /home
// /nix/store`), not invented text: df's column layout and meminfo's "kB"
// suffix are exactly the details a guess gets wrong, and this machine's own
// df header is German ("Benutzt 1B-Blöcke Verw%"), which is the localisation
// status.js's own header says nothing here ever reads.
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

    // `df -B1 --output=used,size,pcent /home /nix/store`, captured on this
    // machine — one header line, then one data row per path, in argument
    // order. The header's own words ("Benutzt", "1B-Blöcke") are German,
    // which is the whole reason parseDf drops the header by position rather
    // than by matching English column names.
    function realDf() {
        return `    Benutzt    1B-Blöcke Verw%
70056599552 493837352960   15%
70056599552 493837352960   15%
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
        const disks = StatusMath.parseDf(realDf(), ["/home", "/nix/store"]);

        compare(disks.length, 2);
        compare(disks[row.index].path, row.path);
        compare(disks[row.index].used, 70056599552);
        compare(disks[row.index].total, 493837352960);
    }

    function test_parseDf_drops_a_path_with_no_matching_row() {
        const disks = StatusMath.parseDf(realDf(), ["/home", "/nix/store", "/boot"]);

        compare(disks.length, 2);
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

    function test_statusRows_typing_disk_finds_both_disk_rows() {
        const snapshot = StatusMath.parseDf(realDf(), ["/home", "/nix/store"]);
        const rows = StatusMath.statusRows("disk", realMeminfo(), snapshot, () => {});

        compare(rows.length, 2);
        compare(rows.map(row => row.title).sort(), ["Disk — /home", "Disk — /nix/store"]);
        verify(rows.every(row => row.provider === "status"));
    }

    function test_statusRows_typing_home_finds_only_the_home_disk() {
        const snapshot = StatusMath.parseDf(realDf(), ["/home", "/nix/store"]);
        const rows = StatusMath.statusRows("home", realMeminfo(), snapshot, () => {});

        compare(rows.length, 1);
        compare(rows[0].title, "Disk — /home");
    }

    function test_statusRows_typing_store_finds_only_the_nix_disk() {
        const snapshot = StatusMath.parseDf(realDf(), ["/home", "/nix/store"]);
        const rows = StatusMath.statusRows("store", realMeminfo(), snapshot, () => {});

        compare(rows.length, 1);
        compare(rows[0].title, "Disk — /nix/store");
    }

    function test_statusRows_empty_query_returns_every_row() {
        const snapshot = StatusMath.parseDf(realDf(), ["/home", "/nix/store"]);
        const rows = StatusMath.statusRows("", realMeminfo(), snapshot, () => {});

        compare(rows.length, 3);
    }

    function test_statusRows_an_unrelated_query_finds_nothing() {
        const snapshot = StatusMath.parseDf(realDf(), ["/home", "/nix/store"]);
        const rows = StatusMath.statusRows("firefox", realMeminfo(), snapshot, () => {});

        compare(rows.length, 0);
    }

    // Enter's action on an informational row: beamenu's dashboard sidecar has
    // no port here, so the row copies its own reading instead.
    function test_statusRows_memory_row_run_copies_the_reading() {
        const copied = [];
        const rows = StatusMath.statusRows("memory", realMeminfo(), [], text => copied.push(text));

        rows[0].run();

        compare(copied.length, 1);
        verify(copied[0].includes("%"));
    }
}
