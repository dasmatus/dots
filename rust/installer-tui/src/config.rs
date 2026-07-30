//! Install answers + validation + rendering of nix/settings.nix.

#[derive(Debug, Clone, Default)]
pub struct InstallConfig {
    /// Target disks spanning the LVM volume group (≥1). `disko.nix` puts a
    /// PV on each and builds `tokyonightvg` across them.
    pub disks: Vec<String>,
    pub hostname: String,
    pub username: String,
    /// Git identity consumed by nix/home/git.nix via dots.gitName.
    pub git_name: String,
    /// Git identity consumed by nix/home/git.nix via dots.gitEmail.
    pub git_email: String,
    pub user_password: String,
    pub swap_size_gib: u64,
    /// AI screen toggles → settings.aiClaude / aiCodex / aiOllama, bridged to
    /// options.dots.ai.* by nix/modules/dots.nix. Default to `true` (set in
    /// `App::new`, not `Default` — `Default` would flip them to `false`).
    pub ai_claude: bool,
    pub ai_codex: bool,
    pub ai_ollama: bool,
}

impl InstallConfig {
    /// Render the nix/settings.nix the flake consumes on the target.
    #[must_use]
    pub fn settings_nix(&self) -> String {
        let disks = self
            .disks
            .iter()
            .map(|d| format!("\"{d}\""))
            .collect::<Vec<_>>()
            .join(" ");
        format!(
            "{{\n  username = \"{}\";\n  hostname = \"{}\";\n  disks = [ {} ];\n  swapSize = \"{}G\";\n  gitName = \"{}\";\n  gitEmail = \"{}\";\n  aiClaude = {};\n  aiCodex = {};\n  aiOllama = {};\n}}\n",
            self.username,
            self.hostname,
            disks,
            self.swap_size_gib,
            nix_escape(&self.git_name),
            nix_escape(&self.git_email),
            self.ai_claude,
            self.ai_codex,
            self.ai_ollama,
        )
    }
}

/// Escape a string for safe interpolation into a Nix double-quoted string.
/// Backslash and double-quote are the only characters that need escaping in a
/// Nix `"..."` literal; everything else (including `$`, which has no special
/// meaning inside Nix double quotes) passes through verbatim.
fn nix_escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

/// RFC 1123 host label: lowercase alphanumerics and inner hyphens, 1-63 chars.
pub fn validate_hostname(s: &str) -> Result<(), String> {
    if s.is_empty() {
        return Err("hostname must not be empty".into());
    }
    if s.len() > 63 {
        return Err("hostname must be at most 63 characters".into());
    }
    if s.starts_with('-') || s.ends_with('-') {
        return Err("hostname must not start or end with '-'".into());
    }
    if !s
        .chars()
        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
    {
        return Err("hostname may only contain a-z, 0-9 and '-'".into());
    }
    Ok(())
}

const RESERVED_USERNAMES: &[&str] = &["root", "nixos", "nobody", "daemon", "messagebus"];

/// POSIX-ish login name: starts [a-z_], then [a-z0-9_-], max 31 chars.
pub fn validate_username(s: &str) -> Result<(), String> {
    if s.is_empty() {
        return Err("username must not be empty".into());
    }
    if s.len() > 31 {
        return Err("username must be at most 31 characters".into());
    }
    if !s.starts_with(|c: char| c.is_ascii_lowercase() || c == '_') {
        return Err("username must start with a-z or '_'".into());
    }
    if !s
        .chars()
        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
    {
        return Err("username may only contain a-z, 0-9, '_' and '-'".into());
    }
    if RESERVED_USERNAMES.contains(&s) {
        return Err(format!("'{s}' is a reserved name"));
    }
    Ok(())
}

/// Git user.name: non-empty, ≤ 128 chars, no newlines. Git itself is
/// permissive (it will happily store almost anything), so this only rejects
/// the obviously useless values that would produce broken commit metadata.
pub fn validate_git_name(s: &str) -> Result<(), String> {
    if s.is_empty() {
        return Err("git name must not be empty".into());
    }
    if s.chars().any(|c| c == '\n' || c == '\r') {
        return Err("git name must not contain newlines".into());
    }
    if s.chars().count() > 128 {
        return Err("git name must be at most 128 characters".into());
    }
    if s.trim().is_empty() {
        return Err("git name must not be only whitespace".into());
    }
    Ok(())
}

/// Git user.email: non-empty, single `@`, non-empty local and domain parts,
/// domain contains at least one `.`. A pragmatic subset of RFC 5321 — good
/// enough to catch typos without dragging in a full email parser.
pub fn validate_git_email(s: &str) -> Result<(), String> {
    if s.is_empty() {
        return Err("git email must not be empty".into());
    }
    if s.chars().any(char::is_whitespace) {
        return Err("git email must not contain whitespace".into());
    }
    let (local, domain) = s
        .split_once('@')
        .ok_or_else(|| "git email must contain exactly one '@'".to_string())?;
    if local.is_empty() {
        return Err("git email local part must not be empty".into());
    }
    if domain.is_empty() {
        return Err("git email domain must not be empty".into());
    }
    if !domain.contains('.') {
        return Err("git email domain must contain a '.'".into());
    }
    if s.matches('@').count() != 1 {
        return Err("git email must contain exactly one '@'".into());
    }
    Ok(())
}
