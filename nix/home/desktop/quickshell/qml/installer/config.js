// Install answers + validation + rendering of nix/data/settings.nix.
//
// Ported from rust/installer-tui/src/config.rs; `settingsNix` must stay
// byte-for-byte identical to that file's `settings_nix` (proved by
// tests/qml/tst_installer.qml against the same cases installer-tui's own
// tests/config.rs carries), since it feeds nixEscape into the same format
// string the target flake reads.
//
// Username validation is NOT one of the three `settings-global` validators
// (hostname/git-name/git-email). This repeats installer-tui's own
// `validate_username` (config.rs), which settings-global never had reason to
// carry since it edits an already-installed system's settings, not a fresh
// login name. Dropping it here would let the Username screen accept a reserved
// or malformed name that later breaks `users.users.<name>`.
.pragma library

const RESERVED_USERNAMES = ["root", "nixos", "nobody", "daemon", "messagebus"];

/// Escape a string for safe interpolation into a Nix double-quoted string.
/// Backslash first so the escapes added for `"` and `$` are not doubled; `$`
/// needs escaping because `${...}` is Nix string interpolation.
function nixEscape(s) {
    // split/join rather than replaceAll: QJSEngine's JS runtime predates
    // ES2021 and has no String.prototype.replaceAll.
    return s.split("\\").join("\\\\").split("\"").join("\\\"").split("$").join("\\$");
}

/// RFC 1123 host label: lowercase alphanumerics and inner hyphens, 1-63 chars.
/// Returns null on success, an error string otherwise, the JS stand-in for
/// config.rs's `Result<(), String>`.
function validateHostname(s) {
    if (s.length === 0)
        return "hostname must not be empty";
    if (s.length > 63)
        return "hostname must be at most 63 characters";
    if (s.startsWith("-") || s.endsWith("-"))
        return "hostname must not start or end with '-'";
    for (const c of s) {
        const ok = (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c === "-";
        if (!ok)
            return "hostname may only contain a-z, 0-9 and '-'";
    }
    return null;
}

/// POSIX-ish login name: starts [a-z_], then [a-z0-9_-], max 31 chars.
function validateUsername(s) {
    if (s.length === 0)
        return "username must not be empty";
    if (s.length > 31)
        return "username must be at most 31 characters";
    const first = s.charAt(0);
    if (!((first >= "a" && first <= "z") || first === "_"))
        return "username must start with a-z or '_'";
    for (const c of s) {
        const ok = (c >= "a" && c <= "z") || (c >= "0" && c <= "9") || c === "_" || c === "-";
        if (!ok)
            return "username may only contain a-z, 0-9, '_' and '-'";
    }
    if (RESERVED_USERNAMES.includes(s))
        return `'${s}' is a reserved name`;
    return null;
}

/// Git user.name: non-empty, <= 128 chars, no newlines, not only whitespace.
function validateGitName(s) {
    if (s.length === 0)
        return "git name must not be empty";
    for (const c of s) {
        if (c === "\n" || c === "\r")
            return "git name must not contain newlines";
    }
    // Array.from splits on Unicode code points, matching Rust's chars().count()
    // rather than a UTF-16 code-unit length. 田中 is 2, not 2 either way here,
    // but a surrogate-pair emoji would over-count under plain .length.
    if (Array.from(s).length > 128)
        return "git name must be at most 128 characters";
    if (s.trim().length === 0)
        return "git name must not be only whitespace";
    return null;
}

/// Git user.email: non-empty, single `@`, non-empty local/domain, domain has
/// a `.`. A pragmatic subset of RFC 5321, not a full parser.
function validateGitEmail(s) {
    if (s.length === 0)
        return "git email must not be empty";
    for (const c of s) {
        if (/\s/.test(c))
            return "git email must not contain whitespace";
    }
    const at = s.indexOf("@");
    if (at === -1)
        return "git email must contain exactly one '@'";
    const local = s.slice(0, at);
    const domain = s.slice(at + 1);
    if (local.length === 0)
        return "git email local part must not be empty";
    if (domain.length === 0)
        return "git email domain must not be empty";
    if (!domain.includes("."))
        return "git email domain must contain a '.'";
    if ((s.match(/@/g) || []).length !== 1)
        return "git email must contain exactly one '@'";
    return null;
}

/// installer-tui/src/install.rs::swap_size_from_meminfo: ceil(MemTotal kB /
/// 1 GiB in kB), floored at 1 so a swapless-looking /proc/meminfo read never
/// yields a zero-size swap file.
function swapSizeGibFromMeminfo(meminfo) {
    const line = meminfo.split("\n").find(l => l.startsWith("MemTotal:"));
    let kb = 0;
    if (line) {
        const parts = line.trim().split(/\s+/);
        const v = parts.length > 1 ? parseInt(parts[1], 10) : NaN;
        if (!Number.isNaN(v))
            kb = v;
    }
    return Math.max(Math.ceil(kb / (1024 * 1024)), 1);
}

/// The answer object the wizard fills in, installer-tui's `InstallConfig`,
/// camelCased. `aiClaude`/`aiCodex`/`aiOllama` default to `true` here (not
/// left to a bare `{}` default) for the same reason `App::new` sets them
/// explicitly rather than deriving `Default`: `Default` would flip AI tooling
/// off, and the Ai screen exists to let the user turn it off, not on.
function defaults() {
    return {
        disks: [],
        hostname: "",
        username: "",
        gitName: "",
        gitEmail: "",
        userPassword: "",
        swapSizeGib: 0,
        aiClaude: true,
        aiCodex: true,
        aiOllama: true,
    };
}

/// Render the nix/data/settings.nix the flake consumes on the target. Must
/// match config.rs::settings_nix byte for byte (see tst_installer.qml).
function settingsNix(cfg) {
    const disks = cfg.disks.map(d => `"${d}"`).join(" ");
    return `{\n  username = "${cfg.username}";\n  hostname = "${cfg.hostname}";\n  disks = [ ${disks} ];\n  swapSize = "${cfg.swapSizeGib}G";\n  gitName = "${nixEscape(cfg.gitName)}";\n  gitEmail = "${nixEscape(cfg.gitEmail)}";\n  aiClaude = ${cfg.aiClaude};\n  aiCodex = ${cfg.aiCodex};\n  aiOllama = ${cfg.aiOllama};\n}\n`;
}
