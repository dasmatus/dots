//! Install answers + validation + rendering of nix/settings.nix.

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Variant {
    #[default]
    Intel,
    Amd,
}

impl Variant {
    pub fn flake_attr(&self) -> &'static str {
        match self {
            Variant::Intel => "tokyonight-intel",
            Variant::Amd => "tokyonight-amd",
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct InstallConfig {
    pub disk: String,
    pub hostname: String,
    pub username: String,
    pub root_password: String,
    pub user_password: String,
    pub variant: Variant,
    pub swap_size_gib: u64,
}

impl InstallConfig {
    /// Render the nix/settings.nix the flake consumes on the target.
    pub fn settings_nix(&self) -> String {
        format!(
            "{{\n  username = \"{}\";\n  hostname = \"{}\";\n  disk = \"{}\";\n  swapSize = \"{}G\";\n}}\n",
            self.username, self.hostname, self.disk, self.swap_size_gib
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn settings_nix_renders_all_answers() {
        let cfg = InstallConfig {
            disk: "/dev/vda".into(),
            hostname: "myhost".into(),
            username: "alice".into(),
            swap_size_gib: 16,
            variant: Variant::Amd,
            ..Default::default()
        };
        let out = cfg.settings_nix();
        assert!(out.contains(r#"username = "alice";"#), "{out}");
        assert!(out.contains(r#"hostname = "myhost";"#), "{out}");
        assert!(out.contains(r#"disk = "/dev/vda";"#), "{out}");
        assert!(out.contains(r#"swapSize = "16G";"#), "{out}");
        assert!(out.trim_start().starts_with('{') && out.trim_end().ends_with('}'));
    }

    #[test]
    fn settings_nix_never_contains_passwords() {
        let cfg = InstallConfig {
            root_password: "rootsecret".into(),
            user_password: "usersecret".into(),
            ..Default::default()
        };
        let out = cfg.settings_nix();
        assert!(!out.contains("rootsecret"));
        assert!(!out.contains("usersecret"));
    }

    #[test]
    fn hostname_accepts_rfc1123_labels() {
        assert!(validate_hostname("tokyonight").is_ok());
        assert!(validate_hostname("my-host2").is_ok());
    }

    #[test]
    fn hostname_rejects_bad_labels() {
        assert!(validate_hostname("").is_err());
        assert!(validate_hostname("-leading").is_err());
        assert!(validate_hostname("trailing-").is_err());
        assert!(validate_hostname("Upper").is_err());
        assert!(validate_hostname("under_score").is_err());
        assert!(validate_hostname(&"a".repeat(64)).is_err());
    }

    #[test]
    fn username_accepts_posix_names() {
        assert!(validate_username("matus").is_ok());
        assert!(validate_username("_svc").is_ok());
        assert!(validate_username("m-user_9").is_ok());
    }

    #[test]
    fn username_rejects_bad_names() {
        assert!(validate_username("").is_err());
        assert!(validate_username("9lives").is_err());
        assert!(validate_username("Matus").is_err());
        assert!(validate_username("with space").is_err());
        assert!(validate_username(&"a".repeat(32)).is_err());
        assert!(validate_username("root").is_err(), "reserved name");
    }

    #[test]
    fn variant_maps_to_flake_attr() {
        assert_eq!(Variant::Intel.flake_attr(), "tokyonight-intel");
        assert_eq!(Variant::Amd.flake_attr(), "tokyonight-amd");
    }
}
