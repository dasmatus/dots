//! Turns `AppArmor` denials into reviewable rule proposals.
//!
//! The design rule is that heuristics decide and a model only assists where
//! the heuristics abstain. That is not a cost argument. The signal in a
//! denial record is structural rather than semantic — `operation`, a mask of
//! permission bits, and a path — so nearly all of it lives in the path prefix
//! and the operation class, which a table reads better than a language model
//! does. Determinism is also a security property here: a proposal that varies
//! between runs cannot be diffed or audited, and "matched a `deny_paths`
//! entry" is a reason a reader checks in a second where a classifier score is
//! not.
//!
//! Rule *syntax* generation is deliberately not done here. `aa-logprof` and
//! `aa-genprof` already turn denial logs into `AppArmor` rules, correctly, and
//! both ship on this system. Asking a model to emit a security DSL would be
//! inviting a hallucination into the one place it can do real damage.
//!
//! `Verdict::Unclassified` is a first-class outcome, not a failure. For a tool
//! deciding what a program may touch, honest abstention beats a plausible
//! guess — the same stance `report` takes when it answers `Unavailable`
//! rather than defaulting to "fine".
//!
//! Everything above the assist layer is pure: parsing and classification take
//! `&str` and an injected [`TriageCtx`], never the filesystem, the
//! environment or the clock. That is what makes the whole table testable
//! without an `AppArmor` kernel, a journal, or a loaded profile.

use std::collections::BTreeMap;
use std::fmt;
use std::path::{Path, PathBuf};

use miette::Diagnostic;
use serde::Serialize;

/// One `AppArmor` denial, as parsed from a kernel audit record.
///
/// Fields are optional because the kernel does not emit a fixed set: a
/// `ptrace` record carries a peer rather than a `name`, and a `capable`
/// record carries neither.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Denial {
    pub profile: String,
    pub operation: String,
    pub name: Option<String>,
    pub requested_mask: Option<String>,
    pub denied_mask: Option<String>,
    pub comm: Option<String>,
}

/// What the heuristics concluded.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Verdict {
    Allow,
    Block,
    Unclassified,
}

/// A verdict plus the evidence for it.
///
/// `provenance` distinguishes a deterministic table match from an advisory
/// model opinion, and the UI colours them differently. A reader must never
/// have to guess which one they are looking at, so this is not optional.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Classification {
    pub verdict: Verdict,
    pub provenance: String,
    pub rationale: String,
}

impl Classification {
    fn heuristic(verdict: Verdict, rule: &str, rationale: impl Into<String>) -> Self {
        Self {
            verdict,
            provenance: format!("heuristic:{rule}"),
            rationale: rationale.into(),
        }
    }
}

/// Everything the classifier needs from the outside world, injected rather
/// than read, so the table is a pure function of its inputs.
#[derive(Debug, Clone)]
pub struct TriageCtx {
    pub home: PathBuf,
    pub runtime_dir: PathBuf,
    /// From the resolved policy. These always win; `policy::resolve_all`
    /// already `~`-expanded them.
    pub deny_paths: Vec<PathBuf>,
    /// Known app ids, used to decide whether `~/.config/<x>` is the app's own
    /// state or somebody else's.
    pub app_ids: Vec<String>,
}

/// Operations that are categorically not file access, and are never proposed
/// for an allow rule from a log line alone.
///
/// `ptrace` and `signal` cross a process boundary, `mount` and `pivot_root`
/// rearrange the filesystem, and `capable` is a capability check rather than
/// a path. Granting any of them because it showed up in a complain-mode log
/// would be granting the mechanism a sandbox exists to withhold.
const NEVER_AUTO_ALLOWED: &[&str] = &[
    "ptrace",
    "signal",
    "mount",
    "umount",
    "pivot_root",
    "capable",
    "change_profile",
];

/// Filename shapes that hold credentials regardless of where they sit.
///
/// Matched on the basename so a browser profile directory's random name does
/// not have to be enumerated: `cert9.db` is NSS's certificate and key store
/// wherever Firefox happened to put the profile.
const CREDENTIAL_BASENAMES: &[&str] = &[
    "cert9.db",
    "key4.db",
    "key3.db",
    "cookies.sqlite",
    "logins.json",
    "login.keyring",
    "user.keystore",
    "id_rsa",
    "id_ed25519",
    "shadow",
];

/// Directories whose whole contents are credential material.
const CREDENTIAL_DIRS: &[&str] = &[
    ".gnupg",
    ".ssh",
    ".local/share/keyrings",
    ".password-store",
    ".config/rbw",
];

/// Device nodes that hand over a sensor or the machine itself, with the
/// capability each one really is.
///
/// A device node is not a file in any useful sense: opening `/dev/input/*`
/// is a keylogger, `/dev/video*` is the camera, `/dev/mem` is every
/// process's memory. None of these should ever be proposed as an allow rule
/// because a program touched one in a log — the sandbox exists to withhold
/// exactly this, so each is named and blocked rather than left to fall
/// through as an unremarkable path.
///
/// Prefixes, matched in order, so `/dev/input/event3` is covered without
/// enumerating every event number the kernel happens to have assigned.
const SENSITIVE_DEVICES: &[(&str, &str)] = &[
    ("/dev/input", "keyboard and pointer input, i.e. a keylogger"),
    ("/dev/video", "the camera"),
    ("/dev/snd", "the microphone and audio capture"),
    ("/dev/dri/card", "direct GPU access"),
    (
        "/dev/hidraw",
        "raw USB HID devices, including security keys",
    ),
    ("/dev/kvm", "hardware virtualisation"),
    ("/dev/mem", "all of physical memory"),
    ("/dev/kmem", "kernel memory"),
    ("/dev/port", "raw I/O ports"),
    ("/dev/tpm", "the TPM"),
    ("/dev/tpmrm", "the TPM resource manager"),
    (
        "/dev/uinput",
        "synthetic input injection, i.e. driving the desktop",
    ),
    ("/dev/disk", "raw block devices"),
    ("/dev/sd", "raw block devices"),
    ("/dev/nvme", "raw block devices"),
];

/// Files under `/etc` that are routine to read and hold nothing secret.
///
/// Deliberately an allowlist rather than a denylist. `/etc` mixes
/// `resolv.conf` with `shadow`, and a denylist there fails open — a file
/// nobody thought to list is treated as harmless. This way an unfamiliar
/// `/etc` path becomes a question rather than an assumption.
const ROUTINE_ETC: &[&str] = &[
    "/etc/hosts",
    "/etc/resolv.conf",
    "/etc/nsswitch.conf",
    "/etc/localtime",
    "/etc/machine-id",
    "/etc/os-release",
    "/etc/ssl/certs",
    "/etc/pki",
    "/etc/fonts",
    "/etc/xdg",
    "/etc/profile",
    "/etc/zoneinfo",
];

/// `/etc` paths that are credential or authentication material.
const SENSITIVE_ETC: &[(&str, &str)] = &[
    ("/etc/shadow", "hashed account passwords"),
    ("/etc/gshadow", "hashed group passwords"),
    ("/etc/sudoers", "the sudo policy"),
    ("/etc/ssh", "host keys and the SSH configuration"),
    ("/etc/ssl/private", "private TLS keys"),
    ("/etc/nixos", "this machine's system configuration"),
    ("/etc/shadow-", "a hashed-password backup"),
];

/// Classify one denial. First match wins, and the order is the contract.
#[must_use]
pub fn classify(denial: &Denial, ctx: &TriageCtx) -> Classification {
    // Ahead of everything, including the operation check: a deny_paths hit is
    // the user's own explicit instruction, and nothing later may soften it.
    if let Some(path) = denial.name.as_deref() {
        let candidate = Path::new(path);
        if let Some(denied) = ctx
            .deny_paths
            .iter()
            .find(|deny| candidate.starts_with(deny))
        {
            return Classification::heuristic(
                Verdict::Block,
                "deny-paths",
                format!(
                    "{} is under {}, which the policy's deny_paths marks un-grantable",
                    path,
                    denied.display()
                ),
            );
        }
    }

    if NEVER_AUTO_ALLOWED.contains(&denial.operation.as_str()) {
        return Classification::heuristic(
            Verdict::Block,
            "privileged-operation",
            format!(
                "operation {:?} is not file access and is never proposed from a log line",
                denial.operation
            ),
        );
    }

    let Some(path) = denial.name.as_deref() else {
        return Classification::heuristic(
            Verdict::Unclassified,
            "no-path",
            "the record carries no path, so no path rule can be proposed for it",
        );
    };

    if let Some(hit) = credential_shape(path, &ctx.home) {
        return Classification::heuristic(
            Verdict::Block,
            "credential-shape",
            format!("{path} matches {hit}, which holds credential material"),
        );
    }

    // Device nodes, ahead of the scratch rule so /dev/input is never reached
    // by whatever waves /dev/null through.
    if let Some(card) = device_rule(path) {
        return card;
    }

    if let Some(card) = etc_rule(path, denial.requested_mask.as_deref()) {
        return card;
    }

    // Read-only access to the store. Store paths are immutable and
    // world-readable by construction, so nothing there is a secret worth
    // withholding — but a *write* to one is never legitimate and falls
    // through to Unclassified rather than being waved past.
    if under(path, "/nix/store/") && mask_is_read_only(denial.requested_mask.as_deref()) {
        return Classification::heuristic(
            Verdict::Allow,
            "nix-store-read",
            "read-only access to an immutable, world-readable store path",
        );
    }

    if let Some(app) = owning_app(path, ctx) {
        return Classification::heuristic(
            Verdict::Allow,
            "own-state",
            format!("the app's own state directory for {app}"),
        );
    }

    if under(path, "/tmp/")
        || path == "/dev/null"
        || path == "/dev/urandom"
        || path == "/dev/random"
        || starts_with_path(path, &ctx.runtime_dir)
    {
        return Classification::heuristic(
            Verdict::Allow,
            "scratch",
            "scratch or entropy path holding no durable user data",
        );
    }

    // Every other device node. Named rather than folded into the generic
    // fallthrough, because "some program opened a device node we have no
    // entry for" is a more interesting thing for a reader to see than "no
    // rule matched", and the kernel adds device classes faster than this
    // table grows.
    if under(path, "/dev/") {
        return Classification::heuristic(
            Verdict::Unclassified,
            "unrecognised-device",
            "a device node with no entry in the table; a human decides what it grants",
        );
    }

    Classification::heuristic(
        Verdict::Unclassified,
        "no-rule",
        "no rule matched; a human decides this one",
    )
}

/// The `/dev` rules: a named sensor or machine-level node is blocked, and
/// anything else under `/dev` that is not scratch stays a question.
///
/// Returns `None` for a path outside `/dev`, and for the scratch nodes
/// (`/dev/null` and friends) so the caller's own scratch rule still gets
/// them — this must sit ahead of that rule to keep `/dev/input` away from
/// it, and giving it the scratch decision too would put two allowlists in
/// two places.
fn device_rule(path: &str) -> Option<Classification> {
    if let Some((prefix, grants)) = SENSITIVE_DEVICES
        .iter()
        .find(|(prefix, _)| path.starts_with(prefix))
    {
        return Some(Classification::heuristic(
            Verdict::Block,
            "sensitive-device",
            format!("{path} is {prefix}*, which grants {grants}"),
        ));
    }
    None
}

/// The `/etc` rules.
///
/// Split three ways because `/etc` is not one kind of place: it holds
/// `resolv.conf` next to `shadow`. Sensitive paths are named and blocked,
/// a small allowlist of genuinely routine reads is allowed, and everything
/// else stays unclassified rather than being assumed harmless — a denylist
/// here would fail open on whatever nobody thought to list.
fn etc_rule(path: &str, mask: Option<&str>) -> Option<Classification> {
    if let Some((_, what)) = SENSITIVE_ETC
        .iter()
        .find(|(prefix, _)| path.starts_with(prefix))
    {
        return Some(Classification::heuristic(
            Verdict::Block,
            "sensitive-etc",
            format!("{path} is {what}"),
        ));
    }

    if !under(path, "/etc/") {
        return None;
    }

    // A write to /etc reconfigures the machine, however routine the file
    // looks read-only: /etc/hosts is on the allowlist, and writing it
    // redirects every name lookup on the system.
    if !mask_is_read_only(mask) {
        return Some(Classification::heuristic(
            Verdict::Block,
            "etc-write",
            "writing under /etc reconfigures the system and is never proposed from a log line",
        ));
    }

    if ROUTINE_ETC
        .iter()
        .any(|allowed| path == *allowed || path.starts_with(&format!("{allowed}/")))
    {
        return Some(Classification::heuristic(
            Verdict::Allow,
            "routine-etc",
            "a system configuration file that holds no secret and is read by nearly everything",
        ));
    }

    Some(Classification::heuristic(
        Verdict::Unclassified,
        "unrecognised-etc",
        "an /etc path that is neither on the routine allowlist nor known to be sensitive",
    ))
}

/// Whether `path` sits under a literal directory prefix.
///
/// Compared as a string with the trailing separator included on purpose:
/// `under("/nix/store-evil/x", "/nix/store/")` must be false, and a bare
/// `starts_with("/nix/store")` would call it true.
fn under(path: &str, prefix_with_slash: &str) -> bool {
    path.starts_with(prefix_with_slash)
}

fn starts_with_path(path: &str, prefix: &Path) -> bool {
    Path::new(path).starts_with(prefix)
}

/// The credential test, returning what matched so the rationale can name it.
fn credential_shape(path: &str, home: &Path) -> Option<String> {
    let basename = Path::new(path).file_name()?.to_str()?;
    if CREDENTIAL_BASENAMES.contains(&basename) {
        return Some(format!("the credential filename {basename:?}"));
    }
    for dir in CREDENTIAL_DIRS {
        if Path::new(path).starts_with(home.join(dir)) {
            return Some(format!("the credential directory ~/{dir}"));
        }
    }
    None
}

/// `r`, `m` and `k` read, map and lock. Anything else — `w`, `a`, `c`, `d`,
/// `x`, `l` — mutates or executes and is not covered by the read-only rule.
fn mask_is_read_only(mask: Option<&str>) -> bool {
    match mask {
        Some(m) if !m.is_empty() => m.chars().all(|c| matches!(c, 'r' | 'm' | 'k')),
        // An absent mask is not evidence of a read. Treat it as not-read-only
        // so it falls through to Unclassified instead of being allowed.
        _ => false,
    }
}

/// Whether the path is an app's own per-app state directory.
///
/// Checks the full `<base>/<app-id>` join rather than testing whether the id
/// appears anywhere in the path: `~/.config/zed` must not match for app id
/// `ze`, and a path under `~/.config/other-app` must not match for `zed`.
fn owning_app(path: &str, ctx: &TriageCtx) -> Option<String> {
    let candidate = Path::new(path);
    for base in [".config", ".cache", ".local/share"] {
        for id in &ctx.app_ids {
            if candidate.starts_with(ctx.home.join(base).join(id)) {
                return Some(id.clone());
            }
        }
    }
    None
}

/// Parse the `key=value` / `key="quoted value"` grammar an `AppArmor` audit
/// record uses.
///
/// Written as a scanner rather than a split on whitespace because quoted
/// values legitimately contain spaces — a denied path may have them — and
/// splitting first would truncate exactly the field that matters most.
#[must_use]
pub fn parse_audit_fields(message: &str) -> BTreeMap<String, String> {
    let mut chars = message.char_indices().peekable();
    let mut out = BTreeMap::new();

    // A hand-driven scan rather than a `split_whitespace` chain, because a
    // quoted value legitimately contains spaces — a denied path may have
    // them — and splitting on whitespace first would truncate exactly the
    // field the whole proposal is about. Driven off a peekable iterator
    // rather than an index into a collected `Vec<char>`: no allocation, no
    // bounds check per access, and no chance of indexing a char boundary
    // wrong.
    while let Some(&(start, first)) = chars.peek() {
        if !first.is_ascii_alphabetic() {
            chars.next();
            continue;
        }

        let key_end = take_while_from(&mut chars, |c| c.is_ascii_alphanumeric() || c == '_');
        let key = &message[start..key_end];

        // A bare word with no '=' is not a field. Skip it without consuming
        // the character that follows, so a key immediately after it still
        // gets its own turn.
        if !matches!(chars.peek(), Some(&(_, '='))) {
            continue;
        }
        chars.next();

        let value = match chars.peek() {
            Some(&(_, '"')) => {
                chars.next();
                let open = chars.peek().map_or(message.len(), |&(i, _)| i);
                let close = take_while_from(&mut chars, |c| c != '"');
                chars.next(); // the closing quote
                &message[open..close]
            }
            Some(&(open, _)) => {
                let end = take_while_from(&mut chars, |c| !c.is_whitespace());
                &message[open..end]
            }
            None => "",
        };

        out.insert(key.to_owned(), value.to_owned());
    }
    out
}

/// Advance while `keep` holds, returning the byte offset one past the last
/// accepted character.
///
/// Exists so the scanner above can slice `message` directly instead of
/// building each field up character by character.
fn take_while_from<I>(chars: &mut std::iter::Peekable<I>, keep: impl Fn(char) -> bool) -> usize
where
    I: Iterator<Item = (usize, char)>,
{
    let mut end = 0;
    while let Some(&(index, c)) = chars.peek() {
        if !keep(c) {
            return index;
        }
        end = index + c.len_utf8();
        chars.next();
    }
    end
}

/// Build a [`Denial`] from one audit message, or `None` if it is not a denial.
///
/// `apparmor="STATUS"` records are profile loads and replacements, not
/// denials. They dominate the log volume on a machine that just rebuilt, and
/// treating them as denials would fill the proposal list with noise about
/// `AppArmor`'s own bookkeeping.
#[must_use]
pub fn denial_from_message(message: &str) -> Option<Denial> {
    let fields = parse_audit_fields(message);
    let kind = fields.get("apparmor")?;
    if !matches!(kind.as_str(), "DENIED" | "ALLOWED" | "AUDIT") {
        return None;
    }
    Some(Denial {
        profile: fields.get("profile").cloned().unwrap_or_default(),
        operation: fields.get("operation").cloned().unwrap_or_default(),
        name: fields.get("name").cloned(),
        requested_mask: fields.get("requested_mask").cloned(),
        denied_mask: fields.get("denied_mask").cloned(),
        comm: fields.get("comm").cloned(),
    })
}

/// Extract a denial from one `journalctl -o json` line.
///
/// A line that is not JSON, or carries no MESSAGE, is skipped rather than
/// aborting the scan: one malformed record must not cost the user the whole
/// run. Callers that want to know log it.
#[must_use]
pub fn denial_from_journal_line(line: &str) -> Option<Denial> {
    // Warns only on a line that should have parsed and did not. A record that
    // parses fine and simply is not a denial — every `apparmor="STATUS"`
    // profile-load, of which there are hundreds after a rebuild — returns
    // `None` silently, because logging those would drown the one line that
    // means something.
    let value: serde_json::Value = match serde_json::from_str(line) {
        Ok(value) => value,
        Err(err) => {
            tracing::warn!(error = %err, "skipping a journal line that is not JSON");
            return None;
        }
    };
    let Some(message) = value.get("MESSAGE").and_then(serde_json::Value::as_str) else {
        tracing::warn!("skipping a journal record with no MESSAGE field");
        return None;
    };
    denial_from_message(message)
}

/// Why a proposed search query was refused.
///
/// A `miette::Diagnostic` rather than a bare enum because this text is handed
/// straight back to the model as tool output, and the `help` is what stops it
/// retrying the identical query. `std::error::Error` is written out by hand
/// rather than derived, matching [`crate::error::PolicyError`] and this
/// crate's choice not to pull in `thiserror`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Diagnostic)]
pub enum QueryRejection {
    /// Contains a path separator, in any form.
    #[diagnostic(
        code(dots_sandbox::triage::query_is_a_path),
        help(
            "search for a bare filename or a generic term — `cert9.db nss database`, never a path"
        )
    )]
    LooksLikeAPath,

    /// Names the local user.
    #[diagnostic(
        code(dots_sandbox::triage::query_names_the_user),
        help("strip the username and search for the generic term on its own")
    )]
    NamesTheUser,

    /// Nothing left to search for.
    #[diagnostic(code(dots_sandbox::triage::query_empty))]
    Empty,
}

impl fmt::Display for QueryRejection {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::LooksLikeAPath => "the query contains a path separator",
            Self::NamesTheUser => "the query contains the local username",
            Self::Empty => "the query is empty after normalisation",
        })
    }
}

impl std::error::Error for QueryRejection {}

/// Gate every outbound search query.
///
/// `SearXNG` proxies to real upstream engines, so a query leaves this machine.
/// A denial's `name=` field is a filesystem path, and a model asked to
/// identify one will paste it verbatim — so this is enforced here, in the
/// wrapper, and never by instructing the model. The model is precisely the
/// component that cannot be relied on to honour an instruction.
///
/// The test is deliberately not "does this contain the home directory". That
/// framing loses to percent-encoding, to a homoglyph, and to a path split
/// across two calls. Inverted instead: a legitimate query here looks like
/// `cert9.db nss database` and never needs a separator at all, so anything
/// carrying one is refused without having to recognise what it leaks.
///
/// # Errors
///
/// Returns [`QueryRejection`] when the query may not be sent.
pub fn sanitize_query(query: &str, username: &str) -> Result<String, QueryRejection> {
    /// Every character that renders as, or decodes to, a path separator.
    ///
    /// The Unicode entries are homoglyphs: they look like `/` to a reader and
    /// are not `/` to a substring test. Listed rather than normalised because
    /// the set is small and closed, and a confusables table would be a much
    /// larger dependency for the same four characters.
    const SEPARATORS: &[char] = &[
        '/', '\\', '~', '\u{2044}', // FRACTION SLASH
        '\u{2215}', // DIVISION SLASH
        '\u{FF0F}', // FULLWIDTH SOLIDUS
        '\u{29F8}', // BIG SOLIDUS
    ];

    let decoded = percent_decode(query).to_lowercase();

    if decoded.contains(SEPARATORS) {
        tracing::warn!(
            rejection = "path-separator",
            "refused an outbound search query before it left the machine"
        );
        return Err(QueryRejection::LooksLikeAPath);
    }

    if !username.is_empty() && decoded.contains(&username.to_lowercase()) {
        tracing::warn!(
            rejection = "names-the-user",
            "refused an outbound search query before it left the machine"
        );
        return Err(QueryRejection::NamesTheUser);
    }

    let trimmed = query.trim();
    if trimmed.is_empty() {
        return Err(QueryRejection::Empty);
    }

    // The contract requires every query that actually leaves the machine be
    // auditable. Logged here, at the one gate all of them pass through,
    // rather than at each call site where one could be forgotten.
    tracing::info!(query = trimmed, "issuing an outbound search query");
    Ok(trimmed.to_owned())
}

/// Decode `%2F`-style escapes so the separator test cannot be smuggled past.
///
/// Applied twice, because a double-encoded `%252F` decodes to `%2F` on the
/// first pass and to `/` only on the second.
fn percent_decode(input: &str) -> String {
    /// Hex nibble, on a raw byte rather than a `&str` slice.
    ///
    /// Slicing the string by byte index would panic the moment a `%` is
    /// followed by a UTF-8 continuation byte, which is reachable from
    /// attacker-shaped input.
    fn nibble(byte: u8) -> Option<u8> {
        match byte {
            b'0'..=b'9' => Some(byte - b'0'),
            b'a'..=b'f' => Some(byte - b'a' + 10),
            b'A'..=b'F' => Some(byte - b'A' + 10),
            _ => None,
        }
    }

    fn once(s: &str) -> String {
        // Split on '%' so each escape is the head of its own segment, which
        // turns a two-character lookahead into a slice pattern and removes
        // every index arithmetic and bounds check from the decode.
        //
        // Bytes accumulate into a `Vec<u8>`, never a `String` one char at a
        // time: pushing each byte `as char` reinterprets UTF-8 as latin-1 and
        // destroys every multi-byte character. That is not hypothetical — it
        // silently defeated the homoglyph check, because a fraction slash
        // arrived here as three bytes and left as three unrelated chars.
        let mut segments = s.split('%');
        let mut out: Vec<u8> = segments.next().unwrap_or_default().as_bytes().to_vec();

        for segment in segments {
            let bytes = segment.as_bytes();
            let escape = bytes
                .first()
                .zip(bytes.get(1))
                .and_then(|(hi, lo)| Some(nibble(*hi)? * 16 + nibble(*lo)?));

            if let Some(byte) = escape {
                out.push(byte);
                out.extend_from_slice(&bytes[2..]);
            } else {
                // Not an escape after all, so restore the '%' the split ate.
                out.push(b'%');
                out.extend_from_slice(bytes);
            }
        }
        String::from_utf8_lossy(&out).into_owned()
    }
    once(&once(input))
}

/// One entry in the triage output.
#[derive(Debug, Clone, Serialize)]
pub struct Proposal {
    pub profile: String,
    pub operation: String,
    pub path: Option<String>,
    pub requested: Option<String>,
    pub count: usize,
    #[serde(flatten)]
    pub classification: Classification,
}

/// The whole document `dots-sandbox triage --json` prints.
#[derive(Debug, Clone, Serialize)]
pub struct TriageReport {
    pub version: u32,
    pub proposals: Vec<Proposal>,
    /// Set when the assist layer was asked for but could not be reached, so
    /// the reader knows the unclassified entries were never looked at rather
    /// than looked at and found unremarkable.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub assist_unavailable: Option<String>,
}

/// Group identical denials and classify each group once.
///
/// Grouping first is what makes the output readable: a single missing library
/// produces one record per process start, and a proposal list repeating it
/// four hundred times is one nobody reads.
#[must_use]
pub fn assemble(denials: &[Denial], ctx: &TriageCtx) -> TriageReport {
    let mut groups: BTreeMap<(String, String, Option<String>, Option<String>), usize> =
        BTreeMap::new();
    for denial in denials {
        let key = (
            denial.profile.clone(),
            denial.operation.clone(),
            denial.name.clone(),
            denial.requested_mask.clone(),
        );
        *groups.entry(key).or_insert(0) += 1;
    }

    // The grouped key already owns every field the classifier needs, so the
    // representative `Denial` is built by moving out of it and then
    // dismantled into the `Proposal`. Rebuilding it with `.clone()` on each
    // field, as the obvious version does, copies every path twice for no
    // reason.
    let mut proposals: Vec<Proposal> = groups
        .into_iter()
        .map(|((profile, operation, name, requested_mask), count)| {
            let denial = Denial {
                profile,
                operation,
                name,
                requested_mask,
                denied_mask: None,
                comm: None,
            };
            let classification = classify(&denial, ctx);
            Proposal {
                profile: denial.profile,
                operation: denial.operation,
                path: denial.name,
                requested: denial.requested_mask,
                count,
                classification,
            }
        })
        .collect();

    // Lead with what a human has to decide, then what is blocked, then the
    // routine allows. A list that opens with four hundred store reads buries
    // the one entry that needed attention.
    proposals.sort_by_key(|p| match p.classification.verdict {
        Verdict::Unclassified => 0,
        Verdict::Block => 1,
        Verdict::Allow => 2,
    });

    TriageReport {
        version: 1,
        proposals,
        assist_unavailable: None,
    }
}
