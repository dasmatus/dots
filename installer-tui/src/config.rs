//! Install answers + validation + rendering of nix/settings.nix.

#[derive(Debug, Clone, Default)]
pub struct InstallConfig {
    /// Target disks spanning the LVM volume group (≥1). `disko.nix` puts a
    /// PV on each and builds `tokyonightvg` across them.
    pub disks: Vec<String>,
    pub hostname: String,
    pub username: String,
    pub root_password: String,
    pub user_password: String,
    pub swap_size_gib: u64,
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
            "{{\n  username = \"{}\";\n  hostname = \"{}\";\n  disks = [ {} ];\n  swapSize = \"{}G\";\n}}\n",
            self.username, self.hostname, disks, self.swap_size_gib
        )
    }
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
