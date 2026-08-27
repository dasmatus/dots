// Pins qml/installer/config.js and disks.js against installer-tui's own
// tests: rust/installer-tui/tests/config.rs and tests/disks.rs, run over the
// same checked-in rust/installer-tui/tests/fixtures/lsblk.json (read here,
// not copied — one fixture, not a second one that can drift from the first).
//
// Reading that fixture needs QML_XHR_ALLOW_FILE_READ=1 (flake/apps.nix sets
// it on the qmltestrunner invocation); without it readFixture below throws
// "Invalid state" instead of returning file contents.
import QtQuick
import QtTest
import "../../nix/home/quickshell/qml/installer/config.js" as Config
import "../../nix/home/quickshell/qml/installer/disks.js" as Disks

TestCase {
    name: "Installer"

    function readFixture(path) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl(path), false);
        xhr.send();
        compare(xhr.status, 200, "fixture " + path + " must be readable (needs QML_XHR_ALLOW_FILE_READ=1)");
        return xhr.responseText;
    }

    function throws(fn) {
        try {
            fn();
        } catch (e) {
            return true;
        }
        return false;
    }

    // --- config.js: settingsNix -------------------------------------------

    function test_settings_nix_renders_all_answers() {
        const cfg = Object.assign(Config.defaults(), {
            disks: ["/dev/vda", "/dev/vdb"],
            hostname: "myhost",
            username: "alice",
            gitName: "Alice Q",
            gitEmail: "alice@example.org",
            swapSizeGib: 16
        });
        const out = Config.settingsNix(cfg);
        verify(out.includes('username = "alice";'), out);
        verify(out.includes('hostname = "myhost";'), out);
        verify(out.includes('disks = [ "/dev/vda" "/dev/vdb" ];'), out);
        verify(out.includes('swapSize = "16G";'), out);
        verify(out.includes('gitName = "Alice Q";'), out);
        verify(out.includes('gitEmail = "alice@example.org";'), out);
        verify(out.startsWith("{") && out.endsWith("}\n"));
    }

    function test_settings_nix_never_contains_passwords() {
        const cfg = Object.assign(Config.defaults(), { userPassword: "usersecret" });
        verify(!Config.settingsNix(cfg).includes("usersecret"));
    }

    function test_settings_nix_escapes_quotes_and_backslashes_in_git_identity() {
        const cfg = Object.assign(Config.defaults(), {
            gitName: 'Alice "bo" \\o/',
            gitEmail: 'a\\b"e"@example.org'
        });
        const out = Config.settingsNix(cfg);
        verify(out.includes('gitName = "Alice \\"bo\\" \\\\o/";'), out);
        verify(out.includes('gitEmail = "a\\\\b\\"e\\"@example.org";'), out);
    }

    function test_settings_nix_escapes_dollar_interpolation_in_git_identity() {
        const cfg = Object.assign(Config.defaults(), { gitName: "${builtins.readFile /etc/shadow}" });
        const out = Config.settingsNix(cfg);
        verify(out.includes('gitName = "\\${builtins.readFile /etc/shadow}";'), out);
    }

    function test_settings_nix_renders_disks_placeholder_when_empty() {
        // Rust's `disks.join(" ")` on an empty Vec is "", so the surrounding
        // "[ {} ]" collapses to two spaces, not one — this is the byte the
        // Confirm screen must show unchanged when autodetection failed and
        // nothing was picked yet.
        const out = Config.settingsNix(Config.defaults());
        verify(out.includes("disks = [  ];"), out);
    }

    // --- config.js: validators ---------------------------------------------

    function test_hostname_accepts_rfc1123_labels_data() {
        return [
            { tag: "plain", value: "tokyonight" },
            { tag: "hyphen-digit", value: "my-host2" }
        ];
    }

    function test_hostname_accepts_rfc1123_labels(row) {
        verify(Config.validateHostname(row.value) === null);
    }

    function test_hostname_rejects_bad_labels_data() {
        return [
            { tag: "empty", value: "" },
            { tag: "leading hyphen", value: "-leading" },
            { tag: "trailing hyphen", value: "trailing-" },
            { tag: "uppercase", value: "Upper" },
            { tag: "underscore", value: "under_score" },
            { tag: "too long", value: "a".repeat(64) }
        ];
    }

    function test_hostname_rejects_bad_labels(row) {
        verify(Config.validateHostname(row.value) !== null);
    }

    function test_username_accepts_posix_names_data() {
        return [
            { tag: "plain", value: "matus" },
            { tag: "leading underscore", value: "_svc" },
            { tag: "mixed", value: "m-user_9" }
        ];
    }

    function test_username_accepts_posix_names(row) {
        verify(Config.validateUsername(row.value) === null);
    }

    function test_username_rejects_bad_names_data() {
        return [
            { tag: "empty", value: "" },
            { tag: "leading digit", value: "9lives" },
            { tag: "uppercase", value: "Matus" },
            { tag: "space", value: "with space" },
            { tag: "too long", value: "a".repeat(32) },
            { tag: "reserved", value: "root" }
        ];
    }

    function test_username_rejects_bad_names(row) {
        verify(Config.validateUsername(row.value) !== null);
    }

    function test_git_name_accepts_real_names_data() {
        return [
            { tag: "plain", value: "Matus Mastena" },
            { tag: "apostrophe", value: "O'Brien" },
            { tag: "unicode", value: "\u7530\u4e2d" },
            { tag: "128 chars", value: "a".repeat(128) }
        ];
    }

    function test_git_name_accepts_real_names(row) {
        verify(Config.validateGitName(row.value) === null);
    }

    function test_git_name_rejects_empty_newlines_and_too_long_data() {
        return [
            { tag: "empty", value: "" },
            { tag: "whitespace only", value: "   " },
            { tag: "newline", value: "with\nnewline" },
            { tag: "carriage return", value: "carriage\rreturn" },
            { tag: "129 chars", value: "a".repeat(129) }
        ];
    }

    function test_git_name_rejects_empty_newlines_and_too_long(row) {
        verify(Config.validateGitName(row.value) !== null);
    }

    function test_git_email_accepts_well_formed_data() {
        return [
            { tag: "plain", value: "alice@example.org" },
            { tag: "plus tag + subdomain", value: "a.b+c@sub.example.org" },
            { tag: "short tld-like domain", value: "user@my.co" }
        ];
    }

    function test_git_email_accepts_well_formed(row) {
        verify(Config.validateGitEmail(row.value) === null);
    }

    function test_git_email_rejects_malformed_data() {
        return [
            { tag: "empty", value: "" },
            { tag: "no at sign", value: "no-at-sign.example.org" },
            { tag: "no domain", value: "local-only@" },
            { tag: "no local", value: "@example.org" },
            { tag: "double at", value: "two@@at.example.org" },
            { tag: "no dot in domain", value: "no-dot@example" },
            { tag: "whitespace", value: "space in @example.org" }
        ];
    }

    function test_git_email_rejects_malformed(row) {
        verify(Config.validateGitEmail(row.value) !== null);
    }

    // --- disks.js: parseLsblk / autodetectDisk against the real fixture ---

    property string fixture: ""

    function initTestCase() {
        fixture = readFixture("../../rust/installer-tui/tests/fixtures/lsblk.json");
    }

    function test_keeps_only_writable_physical_disks() {
        const disks = Disks.parseLsblk(fixture);
        compare(disks.map(d => d.path), ["/dev/nvme0n1", "/dev/sda"]);
    }

    function test_parses_model_and_removable_flag() {
        const disks = Disks.parseLsblk(fixture);
        compare(disks[0].model, "Samsung SSD 980");
        verify(!disks[0].removable);
        verify(disks[1].removable, 'string "1" rm field parses as removable');
    }

    function test_human_size_renders_gib() {
        compare(Disks.humanSize({ sizeBytes: 512110190592 }), "476.9 GiB");
    }

    function test_rejects_garbage_json() {
        verify(throws(() => Disks.parseLsblk("not json")));
    }

    function test_parent_disk_strips_partition_suffixes_data() {
        return [
            { tag: "sata", value: "/dev/sda1", expected: "/dev/sda" },
            { tag: "nvme", value: "/dev/nvme0n1p2", expected: "/dev/nvme0n1" },
            { tag: "mmc", value: "/dev/mmcblk0p1", expected: "/dev/mmcblk0" },
            { tag: "already whole (vda)", value: "/dev/vda", expected: "/dev/vda" },
            { tag: "already whole (nvme)", value: "/dev/nvme0n1", expected: "/dev/nvme0n1" }
        ];
    }

    function test_parent_disk_strips_partition_suffixes(row) {
        compare(Disks.parentDisk(row.value), row.expected);
    }

    function test_autodetects_the_only_fixed_disk() {
        const disks = Disks.parseLsblk(fixture);
        compare(Disks.autodetectDisk(disks, 8).path, "/dev/nvme0n1");
    }

    function test_required_gib_sums_esp_swap_and_root_data() {
        return [
            { tag: "no swap", swapGib: 0, expected: 22 },
            { tag: "8G swap", swapGib: 8, expected: 30 },
            { tag: "16G swap", swapGib: 16, expected: 38 }
        ];
    }

    function test_required_gib_sums_esp_swap_and_root(row) {
        compare(Disks.requiredGib(row.swapGib), row.expected);
    }

    function test_autodetection_rejects_ambiguous_fixed_disks() {
        const disks = [
            { path: "/dev/vda", sizeBytes: 64 * 1024 * 1024 * 1024, removable: false },
            { path: "/dev/vdb", sizeBytes: 64 * 1024 * 1024 * 1024, removable: false }
        ];
        let message = "";
        try {
            Disks.autodetectDisk(disks, 8);
        } catch (e) {
            message = e.message;
        }
        verify(message.includes("ambiguous"), message);
    }

    function test_autodetection_rejects_disks_that_are_too_small() {
        const disks = [{ path: "/dev/vda", sizeBytes: 20 * 1024 * 1024 * 1024, removable: false }];
        let message = "";
        try {
            Disks.autodetectDisk(disks, 8);
        } catch (e) {
            message = e.message;
        }
        verify(message.includes("required 30 GiB"), message);
    }
}
