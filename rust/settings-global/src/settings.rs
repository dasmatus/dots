//! Lossless key/value store over the settings.nix attrset: unknown keys and
//! their order survive edits, so the CLI can never destroy install answers.
//! The parser covers exactly the flat-attrset shape the installer writes
//! (one `{ }` level, `key = value;` bindings, values possibly spanning
//! lines); nested attrsets are out of scope.

use std::fs;
use std::path::Path;

/// Ordered `key = raw-nix-value` pairs of one flat attrset.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Settings {
    entries: Vec<(String, String)>,
}

/// Load/parse/save failure with a human-readable message.
#[derive(Debug)]
pub struct Error(String);

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

impl Settings {
    /// Parse the flat `{ key = value; }` attrset the installer writes.
    ///
    /// # Errors
    /// Returns an error naming the offending line when a non-empty line is
    /// neither a lone brace nor part of a `key = value;` binding.
    pub fn parse(src: &str) -> Result<Self, Error> {
        let mut entries = Vec::new();
        let mut pending: Option<(usize, String)> = None;
        for (idx, raw_line) in src.lines().enumerate() {
            let line = raw_line.trim();
            if let Some((start, stmt)) = pending.take() {
                let stmt = format!("{stmt} {line}");
                pending = Some((start, stmt));
            } else {
                if line.is_empty() || line == "{" || line == "}" {
                    continue;
                }
                pending = Some((idx + 1, line.to_string()));
            }
            if let Some((start, stmt)) = &pending {
                if let Some(body) = stmt.strip_suffix(';') {
                    let (key, value) = body.split_once(" = ").ok_or_else(|| {
                        Error(format!(
                            "line {start}: expected `key = value;`, got `{stmt}`"
                        ))
                    })?;
                    let key = key.trim().to_string();
                    // A repeated binding is invalid Nix ("attribute already
                    // defined"), and get/set only touch the first match — so
                    // silently keeping both would let an edit render a file
                    // that no longer evaluates. Refuse it up front instead.
                    if entries.iter().any(|(k, _)| k == &key) {
                        return Err(Error(format!("line {start}: duplicate key `{key}`")));
                    }
                    entries.push((key, value.trim().to_string()));
                    pending = None;
                }
            }
        }
        if let Some((start, stmt)) = pending {
            return Err(Error(format!(
                "line {start}: unterminated binding `{stmt}` (missing `;`)"
            )));
        }
        Ok(Self { entries })
    }

    /// Render back to the exact installer format.
    #[must_use]
    pub fn render(&self) -> String {
        let mut out = String::from("{\n");
        for (key, value) in &self.entries {
            out.push_str("  ");
            out.push_str(key);
            out.push_str(" = ");
            out.push_str(value);
            out.push_str(";\n");
        }
        out.push_str("}\n");
        out
    }

    /// Raw Nix value for `key`, verbatim.
    #[must_use]
    pub fn get_raw(&self, key: &str) -> Option<&str> {
        self.entries
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
    }

    /// Unquoted string value, or `None` if missing or not a `"..."` literal.
    #[must_use]
    pub fn get_str(&self, key: &str) -> Option<String> {
        let raw = self.get_raw(key)?;
        let inner = raw.strip_prefix('"')?.strip_suffix('"')?;
        let mut result = String::with_capacity(inner.len());
        let mut chars = inner.chars();
        while let Some(c) = chars.next() {
            if c == '\\' {
                result.push(chars.next()?);
            } else if c == '"' {
                return None;
            } else {
                result.push(c);
            }
        }
        Some(result)
    }

    /// Boolean value, or `None` if missing or not `true`/`false`.
    #[must_use]
    pub fn get_bool(&self, key: &str) -> Option<bool> {
        match self.get_raw(key)? {
            "true" => Some(true),
            "false" => Some(false),
            _ => None,
        }
    }

    /// Set `key` to a quoted, escaped string (appends if missing).
    pub fn set_str(&mut self, key: &str, value: &str) {
        self.set_raw(key, format!("\"{}\"", nix_escape(value)));
    }

    /// Set `key` to `true`/`false` (appends if missing).
    pub fn set_bool(&mut self, key: &str, value: bool) {
        self.set_raw(key, value.to_string());
    }

    fn set_raw(&mut self, key: &str, raw: String) {
        match self.entries.iter_mut().find(|(k, _)| k == key) {
            Some((_, v)) => *v = raw,
            None => self.entries.push((key.to_string(), raw)),
        }
    }

    /// Read and parse `path`.
    ///
    /// # Errors
    /// Returns an error when the file cannot be read or does not parse.
    pub fn load(path: &Path) -> Result<Self, Error> {
        let src = fs::read_to_string(path)
            .map_err(|e| Error(format!("cannot read {}: {e}", path.display())))?;
        Self::parse(&src)
    }

    /// Atomically replace `path` (write sibling tmp, then rename).
    ///
    /// # Errors
    /// Returns an error when the temp file cannot be written or renamed —
    /// e.g. without root for the /var/lib/dots default.
    pub fn save(&self, path: &Path) -> Result<(), Error> {
        let mut tmp = path.as_os_str().to_owned();
        tmp.push(".tmp");
        let tmp = Path::new(&tmp);
        fs::write(tmp, self.render())
            .map_err(|e| Error(format!("cannot write {}: {e}", tmp.display())))?;
        fs::rename(tmp, path).map_err(|e| {
            // Don't leave the rendered content sitting in a sibling `.tmp`
            // next to the real config on a failed rename.
            let _ = fs::remove_file(tmp);
            Error(format!("cannot replace {}: {e}", path.display()))
        })
    }
}

/// Escape for a Nix `"..."` literal. Backslash first so the escapes added for
/// `"` and `$` are not themselves doubled. `$` matters because `${...}` is Nix
/// string interpolation: an unescaped value would be evaluated (as root, on
/// the next rebuild), so `\$` keeps it a literal.
fn nix_escape(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('$', "\\$")
}

/// RFC 1123 host label — mirrors rust/installer-tui/src/config.rs.
///
/// # Errors
/// Returns the reason the label is invalid.
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

/// Git user.name sanity check — mirrors rust/installer-tui/src/config.rs.
///
/// # Errors
/// Returns the reason the name is invalid.
pub fn validate_git_name(s: &str) -> Result<(), String> {
    if s.trim().is_empty() {
        return Err("git name must not be empty".into());
    }
    if s.chars().any(|c| c == '\n' || c == '\r') {
        return Err("git name must not contain newlines".into());
    }
    if s.chars().count() > 128 {
        return Err("git name must be at most 128 characters".into());
    }
    Ok(())
}

/// Address shape shared by every e-mail field. `label` opens each message, so
/// the callers below blame the field the user was actually editing while the
/// rules stay in one place.
fn validate_email(label: &str, s: &str) -> Result<(), String> {
    if s.is_empty() {
        return Err(format!("{label} must not be empty"));
    }
    if s.chars().any(char::is_whitespace) {
        return Err(format!("{label} must not contain whitespace"));
    }
    if s.matches('@').count() != 1 {
        return Err(format!("{label} must contain exactly one '@'"));
    }
    let (local, domain) = s.split_once('@').unwrap_or(("", ""));
    if local.is_empty() {
        return Err(format!("{label} local part must not be empty"));
    }
    if domain.is_empty() || !domain.contains('.') {
        return Err(format!("{label} domain must contain a '.'"));
    }
    Ok(())
}

/// Git user.email sanity check — mirrors rust/installer-tui/src/config.rs.
///
/// # Errors
/// Returns the reason the email is invalid.
pub fn validate_git_email(s: &str) -> Result<(), String> {
    validate_email("git email", s)
}

/// Proton account address, the login the settings panel's Proton page reuses
/// for both the rclone remote and the proton-cli session.
///
/// # Errors
/// Returns the reason the email is invalid.
pub fn validate_proton_email(s: &str) -> Result<(), String> {
    validate_email("proton email", s)
}
