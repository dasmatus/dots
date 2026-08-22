//! The plugin manifest schema (binding, shared with the launcher and the
//! plugin workers) and `{query}` substitution into a command's `exec` argv.

use std::path::Path;

use anyhow::Context;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Manifest {
    pub name: String,
    pub title: String,
    #[serde(default)]
    pub icon: Option<String>,
    #[serde(default)]
    pub keyword: Option<String>,
    pub commands: Vec<Command>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Command {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub description: Option<String>,
    pub mode: Mode,
    #[serde(default)]
    pub ui: Ui,
    pub exec: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    Exec,
    Terminal,
    Copy,
    View,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Ui {
    Log,
    Rpc,
}

impl Default for Ui {
    fn default() -> Self {
        Self::Log
    }
}

/// Something went wrong loading or reading a manifest.
#[derive(Debug)]
pub enum ManifestError {
    Parse(serde_json::Error),
    CommandNotFound(String),
}

impl std::fmt::Display for ManifestError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Parse(err) => write!(f, "invalid plugin manifest: {err}"),
            Self::CommandNotFound(id) => write!(f, "no command '{id}' in manifest"),
        }
    }
}

impl std::error::Error for ManifestError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Parse(err) => Some(err),
            Self::CommandNotFound(_) => None,
        }
    }
}

impl Manifest {
    /// Parse a manifest from its already-read JSON text.
    ///
    /// # Errors
    /// Fails when `raw` doesn't match the manifest schema.
    pub fn parse(raw: &str) -> Result<Self, ManifestError> {
        serde_json::from_str(raw).map_err(ManifestError::Parse)
    }

    /// Read and parse the manifest at `path`.
    ///
    /// # Errors
    /// Fails when the file can't be read or doesn't match the schema.
    pub fn load(path: &Path) -> anyhow::Result<Self> {
        let raw = std::fs::read_to_string(path)
            .with_context(|| format!("reading manifest {}", path.display()))?;
        Self::parse(&raw).with_context(|| format!("parsing manifest {}", path.display()))
    }

    /// Find a command by id.
    #[must_use]
    pub fn find_command(&self, id: &str) -> Option<&Command> {
        self.commands.iter().find(|command| command.id == id)
    }

    /// Find a command by id, or a descriptive error naming it.
    ///
    /// # Errors
    /// Fails when no command in the manifest has this id.
    pub fn command(&self, id: &str) -> Result<&Command, ManifestError> {
        self.find_command(id)
            .ok_or_else(|| ManifestError::CommandNotFound(id.to_string()))
    }
}

/// Substitute `{query}` into every element of `argv`.
///
/// A missing query substitutes the empty string, matching a command invoked
/// with no `--query`. Every occurrence in an argv element is replaced, not
/// just the first.
#[must_use]
pub fn substitute_query(argv: &[String], query: Option<&str>) -> Vec<String> {
    let query = query.unwrap_or("");
    argv.iter()
        .map(|arg| arg.replace("{query}", query))
        .collect()
}
