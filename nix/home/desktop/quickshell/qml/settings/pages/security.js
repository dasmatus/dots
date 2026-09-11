// Pure transforms for security.qml's "Global permissions" section — the
// Flatpak-override and AppArmor-mode parsers, kept here so
// qmltestrunner (tst_security_wiring.qml) can load and exercise them
// without instantiating a Process or FileView, neither of which the test
// runner can construct. Mirrors the shape the deleted sandbox/policy.js
// used for the same reason (see git history) — this file is its
// Flatpak/AppArmor-era replacement, not a revival of that module.
.pragma library

// Splits `flatpak override --show`'s ini-shaped stdout into a flat list of
// { section, key, value } rows, in the order they appear. `flatpak
// override --show` (no app id) prints the resolved GLOBAL override;
// `--show <appid>` prints that one app's own override, merged over the
// global baseline the same way the real sandbox resolves it — this parser
// does not care which of the two produced its input, since the shape is
// identical either way.
//
// A key with no `=` (malformed input, or a genuinely empty override with
// nothing but blank lines) is skipped rather than thrown on: this feeds a
// settings page, and a page that goes blank on one unparsable line is a
// worse failure than a page that quietly drops that one line.
function parseOverrideShow(text) {
    if (typeof text !== "string" || text.trim() === "") {
        return [];
    }
    const rows = [];
    let section = "";
    for (const rawLine of text.split("\n")) {
        const line = rawLine.trim();
        if (line === "" || line.startsWith("#")) {
            continue;
        }
        const sectionMatch = line.match(/^\[(.+)\]$/);
        if (sectionMatch) {
            section = sectionMatch[1];
            continue;
        }
        const eq = line.indexOf("=");
        if (eq <= 0) {
            continue;
        }
        rows.push({
            section: section,
            key: line.slice(0, eq).trim(),
            value: line.slice(eq + 1).trim()
        });
    }
    return rows;
}

// Parses `flatpak list --app --columns=application,name` into
// { appId, name } entries. Tab-separated, per `flatpak list`'s own
// `--columns` documentation; a row with no tab (name genuinely empty) still
// yields an entry with name falling back to the appId, rather than being
// dropped — an app with a grant is worth showing even unnamed.
function parseFlatpakList(text) {
    if (typeof text !== "string" || text.trim() === "") {
        return [];
    }
    return text.split("\n").filter(line => line.trim() !== "").map(line => {
        const parts = line.split("\t");
        const appId = (parts[0] || "").trim();
        const name = (parts[1] || "").trim();
        return { appId: appId, name: name !== "" ? name : appId };
    }).filter(entry => entry.appId !== "");
}

// The AppArmor profiles this build declares against a real store path
// (nix/modules/system/apparmor.nix's `apps` attrset, plus
// nix/modules/desktop/steam.nix's own `dots-steam`) — restated here rather
// than read from either module at run time, the same restating tradeoff
// wrap.nix's own (deleted, see git history) `legalCapabilities` comment
# already made for this codebase's Nix/QML boundary: no cheap way to ask
// Nix a value at Quickshell run time, so a name added on the Nix side needs
// a matching addition here to appear on this page. The failure mode is
// narrow — a new profile is simply invisible on this page until this list
// catches up, never misreported.
function knownProfiles() {
    return [
        { id: "dots-claude-desktop", label: "Claude Desktop" },
        { id: "dots-haveno", label: "Haveno" },
        { id: "dots-steam", label: "Steam" },
        { id: "dots-brave", label: "Brave (Flatpak now — see below)" },
        { id: "dots-librewolf", label: "LibreWolf (Flatpak now — see below)" },
        { id: "dots-zed", label: "Zed (Flatpak now — see below)" },
        { id: "dots-electron", label: "Obsidian/Electron (Flatpak now — see below)" }
    ];
}

// Parses `/sys/kernel/security/apparmor/profiles`'s own format, one
// `<name> (<mode>)` pair per line, into { name: mode } — mirrors
// rust/dots-secreport/src/report.rs's own apparmor card, which reads the
// identical file for a COUNT rather than per-profile detail; this is that
// same file's other half. An absent or unreadable file (the read needs
// CAP_MAC_ADMIN despite the file's own world-readable mode bits — the exact
// gap that card's own comment already documents) yields an empty map, which
// modeFor below reports as "unknown" rather than "not loaded": those are
// different facts, and only the caller that also knows whether the read
// itself failed can tell them apart.
function parseApparmorProfiles(text) {
    const modes = {};
    if (typeof text !== "string") {
        return modes;
    }
    for (const rawLine of text.split("\n")) {
        const match = rawLine.trim().match(/^(\S+)\s+\(([a-z]+)\)$/);
        if (match) {
            modes[match[1]] = match[2];
        }
    }
    return modes;
}

// profileModes: parseApparmorProfiles' own output. readOk: whether the
// profiles file was actually read (distinguishes "read fine, this profile
// just is not loaded" from "could not read the file at all").
function modeFor(profileModes, readOk, profileId) {
    if (Object.prototype.hasOwnProperty.call(profileModes, profileId)) {
        return profileModes[profileId];
    }
    return readOk ? "not loaded" : "unknown (needs a privileged read)";
}

// Tone lookup mirroring security.qml's own toneColor/Policy.toneFor pair
// for the dashboard cards above, so an enforce/complain/unknown row reads
// with the same green/yellow/red vocabulary as the rest of the page.
function toneForMode(mode) {
    switch (mode) {
    case "enforce":
        return "green";
    case "complain":
        return "yellow";
    case "not loaded":
        return "red";
    default:
        return "dim";
    }
}
