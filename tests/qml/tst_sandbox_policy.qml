// sandbox/policy.js — the pure logic behind settings/pages/security.qml
// and sandbox/Prompt.qml, neither of which qmltestrunner can instantiate
// directly (both reach Quickshell.Io's Process/FileView — see
// tests/README.md).
//
// The first test below is the one the task brief calls out explicitly:
// `unavailable` must render visibly differently from `fail`, because
// rust/dots-sandbox/src/report.rs's own module doc comment exists
// specifically to keep "the kernel was never built with this feature" from
// reading as "someone turned this feature off" — a distinction a later
// refactor collapsing this switch back into "anything not ok is red" would
// erase silently, with every other test in this file still green.
import QtQuick
import QtTest
import "../../nix/home/desktop/quickshell/qml/sandbox/policy.js" as Policy

TestCase {
    name: "SandboxPolicy"

    function test_unavailable_renders_differently_from_fail() {
        verify(Policy.toneFor("unavailable") !== Policy.toneFor("fail"), "an absent feature must not paint the same colour as a real failure");
        verify(Policy.statusLabel("unavailable") !== Policy.statusLabel("fail"), "an absent feature must not be labelled the same as a real failure");
    }

    function test_tone_for_every_status_data() {
        return [
            { tag: "ok", status: "ok", expected: "green" },
            { tag: "warn", status: "warn", expected: "yellow" },
            { tag: "fail", status: "fail", expected: "red" },
            { tag: "unavailable", status: "unavailable", expected: "dim" },
            // A status name this module has never seen degrades to "dim",
            // the same as unavailable — never to "red", which would read as
            // a confirmed failure this collector never actually reported.
            { tag: "unknown", status: "something-new", expected: "dim" }
        ];
    }

    function test_tone_for_every_status(row) {
        compare(Policy.toneFor(row.status), row.expected);
    }

    function test_status_label_reads_as_a_sentence_not_a_shout() {
        compare(Policy.statusLabel("ok"), "OK");
        compare(Policy.statusLabel("warn"), "Warning");
        compare(Policy.statusLabel("fail"), "Failing");
        compare(Policy.statusLabel("unavailable"), "Unavailable");
    }

    // `capabilityGroups` is the permissions section's own top level now —
    // one entry per capability `policy.rs` knows, in its declared order
    // (never alphabetical: "net" before "nix-daemon" is Capability::ALL's
    // own order, not "kvm" first), each carrying how many catalog apps
    // actually declared it.
    function test_capability_groups_lists_the_vocabulary_the_catalog_supplied() {
        // The vocabulary arrives in `catalog --json`'s own `capabilities`
        // array, built by catalog.rs's `capability_vocabulary()` from
        // policy.rs's `Capability::ALL`. Order is that enum's declaration
        // order, not alphabetical — "net" before "nix-daemon", never "kvm"
        // first — and it is preserved rather than re-sorted here.
        const catalogSet = {
            version: 1,
            apps: [],
            capabilities: [
                { name: "net", label: "Network", description: "Reach the internet" },
                { name: "kvm", label: "Hardware virtualisation", description: "Use /dev/kvm" }
            ]
        };
        const groups = Policy.capabilityGroups(catalogSet);
        compare(groups.map(g => g.name), ["net", "kvm"]);
        compare(groups[0].label, "Network");
        verify(groups.every(g => g.count === 0));
    }

    // The anti-drift assertion, and the reason the old version of this test
    // was deleted rather than adapted.
    //
    // It used to call `capabilityGroups(null)` and expect all seven
    // capabilities back, which only worked because policy.js kept its own
    // hardcoded name+label table. That table is a second source of truth:
    // renaming a capability in policy.rs left it stale and nothing failed.
    // With the table gone, an unread catalog yields nothing — and it must
    // NOT quietly fall back to a built-in list, because a fallback is the
    // same drift wearing a different name.
    function test_an_unread_catalog_yields_no_vocabulary_rather_than_a_fallback() {
        compare(Policy.capabilityGroups(null).length, 0);
        compare(Policy.capabilityGroups({}).length, 0);
        compare(Policy.capabilityGroups({ version: 1, apps: [] }).length, 0);
    }

    function test_capability_groups_counts_only_apps_that_declared_it() {
        const catalogSet = {
            version: 1,
            capabilities: [
                { name: "net", label: "Network", description: "Reach the internet" },
                { name: "repo-read", label: "Repository (read)", description: "Read the checkout" },
                { name: "kvm", label: "Hardware virtualisation", description: "Use /dev/kvm" }
            ],
            apps: [
                { appId: "zed", name: "Zed", icon: "zed", tier: "vm", caps: ["net", "repo-read"], paths: [], source: "/nix/store/zed.desktop", state: { net: "allow", "repo-read": "allow" } },
                { appId: "nix-lint", name: "nix-lint", icon: null, tier: "container", caps: ["net"], paths: [], source: null, state: { net: "ask" } },
                // Unconfined: no tier, no declared caps — must contribute to
                // NO capability's count, even though a bug that forgot the
                // unconfined check would otherwise count it under nothing
                // anyway (its own caps array is empty), so this fixture
                // pins the shape rather than the (currently vacuous) count.
                { appId: "bitwarden", name: "Bitwarden", icon: null, tier: null, caps: [], paths: [], source: null, state: {}, reason: "the secret broker other things connect to" }
            ]
        };
        const groups = Policy.capabilityGroups(catalogSet);
        compare(groups.find(g => g.name === "net").count, 2);
        compare(groups.find(g => g.name === "repo-read").count, 1);
        compare(groups.find(g => g.name === "kvm").count, 0);
    }

    function test_apps_for_capability_returns_only_matching_apps_with_their_own_state() {
        const catalogSet = {
            version: 1,
            apps: [
                { appId: "zed", name: "Zed", icon: "zed", tier: "vm", caps: ["net", "repo-read"], paths: [], source: "/nix/store/zed.desktop", state: { net: "allow", "repo-read": "deny" } },
                { appId: "nix-lint", name: "nix-lint", icon: null, tier: "container", caps: ["net"], paths: [], source: null, state: { net: "ask" } },
                { appId: "firefox", name: "Firefox", icon: "firefox", tier: "vm", caps: ["repo-read"], paths: [], source: "/nix/store/firefox.desktop", state: { "repo-read": "allow" } }
            ]
        };
        const netApps = Policy.appsForCapability(catalogSet, "net");
        compare(netApps.length, 2);
        // Sorted by name, not appId or declaration order.
        compare(netApps[0].name, "nix-lint");
        compare(netApps[0].state, "ask");
        compare(netApps[1].name, "Zed");
        compare(netApps[1].state, "allow");

        const repoReadApps = Policy.appsForCapability(catalogSet, "repo-read");
        compare(repoReadApps.length, 2);
        compare(repoReadApps.find(a => a.appId === "zed").state, "deny");
    }

    // A hole in the resolved state map (the catalog declared the
    // capability but the state object is silent about it) must read as
    // "ask" — a place to prompt, never a guessed "allow" or "deny".
    function test_apps_for_capability_defaults_missing_state_to_ask() {
        const catalogSet = {
            version: 1,
            apps: [{ appId: "clean", name: "clean", icon: null, tier: "container", caps: ["kvm"], paths: [], source: null, state: {} }]
        };
        compare(Policy.appsForCapability(catalogSet, "kvm")[0].state, "ask");
    }

    // A name the catalog never mentions, or an app with no icon, falls
    // back rather than showing "undefined" or a broken image request.
    function test_apps_for_capability_falls_back_to_app_id_and_empty_icon() {
        const catalogSet = {
            version: 1,
            apps: [{ appId: "nix-lint", name: null, icon: null, tier: "container", caps: ["net"], paths: [], source: null, state: { net: "allow" } }]
        };
        const entry = Policy.appsForCapability(catalogSet, "net")[0];
        compare(entry.name, "nix-lint");
        compare(entry.icon, "");
    }

    function test_apps_for_capability_handles_nothing_to_show() {
        compare(Policy.appsForCapability(null, "net").length, 0);
        compare(Policy.appsForCapability({}, "net").length, 0);
        compare(Policy.appsForCapability({ apps: [] }, "net").length, 0);
    }

    // An app the resolved policy exempts outright surfaces in the catalog
    // with no tier and no declared capabilities (`entry_from_policy_only`'s
    // `Unconfined` arm) — that shape, not a `kind`/`unconfined` tag `policy
    // dump` used to carry, is what `unconfinedEntries` has to detect.
    function test_unconfined_entries_detects_no_tier_and_no_caps() {
        const catalogSet = {
            version: 1,
            apps: [
                { appId: "bitwarden", name: "Bitwarden", icon: null, tier: null, caps: [], paths: [], source: null, state: {} },
                { appId: "zed", name: "Zed", icon: "zed", tier: "vm", caps: ["net"], paths: [], source: "/nix/store/zed.desktop", state: { net: "allow" } }
            ]
        };
        const entries = Policy.unconfinedEntries(catalogSet);
        compare(entries.length, 1);
        compare(entries[0].appId, "bitwarden");
        compare(entries[0].name, "Bitwarden");
    }

    // A null tier alone is not enough: an app resolved as sandboxed but
    // never wrapped (a flake app run only via `nix run .#foo` — see
    // catalog.rs's own `entry_from_policy_only` doc comment) still always
    // carries `Some(tier)` for that path, so this only exists to prove a
    // real declared-caps entry is never misfiled as unconfined even if
    // some future bug dropped its tier.
    function test_unconfined_entries_requires_empty_caps_too() {
        const catalogSet = {
            version: 1,
            apps: [{ appId: "weird", name: "weird", icon: null, tier: null, caps: ["net"], paths: [], source: null, state: { net: "allow" } }]
        };
        compare(Policy.unconfinedEntries(catalogSet).length, 0);
    }

    // `reason` is read defensively (`app.reason || ""`) because
    // `CatalogEntry` does not carry one yet — see this function's own
    // comment in policy.js. Pinned here so a future reader who DOES add
    // the field can flip this fixture and watch the assertion start
    // meaning something.
    // The case that matters: an exempt app's reason reaches the row.
    //
    // This replaces a test that asserted the reason is ALWAYS the empty
    // string. That assertion passed, and it was pinning a defect in place —
    // `CatalogEntry` carried no `reason` field at all, so every exemption
    // rendered as a bare "Unsandboxed" badge with no explanation, and the
    // test certified that as correct.
    function test_unconfined_entries_carry_the_policys_reason() {
        const catalogSet = {
            version: 1,
            apps: [{
                appId: "bitwarden", name: "Bitwarden", icon: null, tier: null,
                caps: [], paths: [], source: null, state: {},
                reason: "the secret broker other things connect to"
            }]
        };
        compare(Policy.unconfinedEntries(catalogSet)[0].reason,
                "the secret broker other things connect to");
    }

    // An older binary emits no `reason` field. Degrading to an empty string
    // is right; inventing text would not be. Kept as the DEGRADE case only,
    // never as the expected shape of a current catalog.
    function test_a_missing_reason_degrades_to_empty_rather_than_fabricated() {
        const catalogSet = {
            version: 1,
            apps: [{ appId: "bitwarden", name: "Bitwarden", icon: null, tier: null, caps: [], paths: [], source: null, state: {} }]
        };
        compare(Policy.unconfinedEntries(catalogSet)[0].reason, "");
    }

    function test_unconfined_entries_handles_nothing_to_show() {
        compare(Policy.unconfinedEntries(null).length, 0);
        compare(Policy.unconfinedEntries({}).length, 0);
        compare(Policy.unconfinedEntries({ apps: [] }).length, 0);
    }

    // rust/dots-sandbox/src/argv.rs turns every one of the seven known
    // capabilities into either a network-namespace flag or a plain bind
    // mount, both spawn-time-only — see this function's own comment in
    // policy.js. Every one of them needs a relaunch today, and this test
    // pins that for the whole known vocabulary at once rather than one
    // capability at a time, so a future capability nobody remembered to
    // add to CAPABILITIES still gets checked here regardless.
    function test_every_known_capability_needs_a_relaunch_data() {
        return [
            { tag: "net", capability: "net" },
            { tag: "nix-daemon", capability: "nix-daemon" },
            { tag: "repo-read", capability: "repo-read" },
            { tag: "repo-write", capability: "repo-write" },
            { tag: "postgres", capability: "postgres" },
            { tag: "settings-ro", capability: "settings-ro" },
            { tag: "kvm", capability: "kvm" }
        ];
    }

    function test_every_known_capability_needs_a_relaunch(row) {
        verify(Policy.needsRelaunch(row.capability), `${row.capability} must be marked as needing a relaunch — none of rust/dots-sandbox's seven capabilities can change on an already-running sandbox`);
    }

    function test_with_capability_override_narrows_rather_than_replaces() {
        const existing = {
            version: 1,
            apps: {
                "nix-lint": { tier: "container", caps: { "net": "allow", "repo-write": "allow" } }
            },
            denyPaths: ["/home/user/.ssh"]
        };

        const merged = Policy.withCapabilityOverride(existing, "nix-lint", "net", "deny");

        // The one named pair changed…
        compare(merged.apps["nix-lint"].caps.net, "deny");
        // …but the app's other capability, its tier, every OTHER app this
        // override file already knew about, and denyPaths all survive
        // untouched — a caller that replaced the whole apps object instead
        // of narrowing it would silently drop all three.
        compare(merged.apps["nix-lint"].caps["repo-write"], "allow");
        compare(merged.apps["nix-lint"].tier, "container");
        compare(merged.denyPaths.length, 1);
        compare(merged.denyPaths[0], "/home/user/.ssh");
    }

    function test_with_capability_override_creates_a_bare_app_entry_when_new() {
        const existing = { version: 1, apps: {}, denyPaths: [] };
        const merged = Policy.withCapabilityOverride(existing, "firefox", "net", "allow");

        compare(merged.apps["firefox"].caps.net, "allow");
        // No `tier`/`unconfined` invented for an app overrides.json never
        // mentioned before — rust/dots-sandbox/src/policy.rs's merge reads
        // those from whichever layer actually sets them, defaults included,
        // so an override entry that speaks to only one capability is
        // exactly the narrow shape its own rules expect.
        verify(!("tier" in merged.apps["firefox"]), "a brand-new override entry must not invent a tier the defaults layer already owns");
    }

    function test_with_capability_override_returns_a_new_object() {
        const existing = { version: 1, apps: { "clean": { caps: { "repo-write": "allow" } } }, denyPaths: [] };
        const merged = Policy.withCapabilityOverride(existing, "clean", "repo-write", "deny");

        // The caller (Prompt.qml's allowAlways, security.qml's
        // setCapability) hands this straight to
        // `overridesFile.setText(JSON.stringify(merged))` — QML never
        // notices an in-place mutation of a property it already read, so
        // this has to be a genuinely different object, not the same one
        // with a field poked in.
        verify(merged !== existing, "withCapabilityOverride must return a new object, never mutate its argument");
        compare(existing.apps["clean"].caps["repo-write"], "allow", "the original object must be left untouched");
    }
}
