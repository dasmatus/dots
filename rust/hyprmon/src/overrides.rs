//! Forced overrides — a hand-edited escape hatch for when the planner gets a
//! monitor wrong. Lives at `~/.config/hyprmon/overrides.json`, separate from
//! the Nix-managed `rules.json` so a flake rebuild never clobbers a local
//! fix. Each entry pins any subset of the monitor spec fields; pinned fields
//! replace the planned value, unpinned ones fall through to the rule/plan.
//!
//! Matching is name-first, description-fallback: an entry with a `name` pins
//! a specific connector; an entry with no `name` (but a `description`) matches
//! the monitor by its model+serial on any port — the replug-stable form.
//! Hyprland's monitor `description` includes the serial, so it's a unique ID.

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::rules::Vrr;
use crate::spec::{Monitor, MonitorSpec};

/// One forced override. `name` / `description` are the match keys (both
/// optional); the remaining fields are the override payload, each optional so
/// a partial override only replaces what it sets.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct OverrideEntry {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolution: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub position: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scale: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transform: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub vrr: Option<Vrr>,
}

/// The override file: an ordered list of entries. First match wins.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Overrides {
    #[serde(default)]
    pub entries: Vec<OverrideEntry>,
}

/// `$XDG_CONFIG_HOME/hyprmon/overrides.json` — the hand-edited override file,
/// sibling of the Nix-managed `rules.json`.
#[must_use]
pub fn overrides_file() -> PathBuf {
    let base =
        std::env::var("XDG_CONFIG_HOME").map_or_else(|_| home_dir().join(".config"), PathBuf::from);
    base.join("hyprmon").join("overrides.json")
}

fn home_dir() -> PathBuf {
    std::env::var("HOME").map_or_else(|_| PathBuf::from("/"), PathBuf::from)
}

impl Overrides {
    /// Load from the default path; missing/garbage → empty (the planner then
    /// behaves as if no overrides exist, so a corrupt file can't take the
    /// layout down).
    #[must_use]
    pub fn load() -> Self {
        Self::load_from(overrides_file())
    }

    #[must_use]
    pub fn load_from(path: PathBuf) -> Self {
        match fs::read_to_string(&path) {
            Ok(text) => serde_json::from_str(&text).unwrap_or_else(|e| {
                eprintln!("hyprmon: ignoring bad overrides at {}: {e}", path.display());
                Self::default()
            }),
            Err(_) => Self::default(),
        }
    }

    /// Serialize to pretty JSON, creating the parent dir if needed.
    ///
    /// # Errors
    ///
    /// Returns an error if serialization or the directory create/write fails.
    pub fn save_to(&self, path: &Path) -> anyhow::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).ok();
        }
        let mut json = serde_json::to_string_pretty(self)?;
        json.push('\n');
        fs::write(path, json)
            .map_err(|e| anyhow::anyhow!("saving overrides to {}: {e}", path.display()))
    }

    /// Upsert by name: replace the first existing entry pinned to the same
    /// `name`, else push. Entries with no `name` (description-only) are always
    /// pushed — there's no single key to dedupe them on.
    pub fn upsert(&mut self, entry: OverrideEntry) {
        if let Some(name) = &entry.name {
            if let Some(slot) = self
                .entries
                .iter_mut()
                .find(|e| e.name.as_ref() == Some(name))
            {
                *slot = entry;
                return;
            }
        }
        self.entries.push(entry);
    }

    /// Remove the first entry pinned to `name`. Returns whether one was
    /// removed. Description-only entries are untouched (clear them via the
    /// TUI or by editing the file).
    pub fn remove_by_name(&mut self, name: &str) -> bool {
        let before = self.entries.len();
        if let Some(idx) = self
            .entries
            .iter()
            .position(|e| e.name.as_deref() == Some(name))
        {
            self.entries.remove(idx);
        }
        self.entries.len() != before
    }
}

/// Find the override entry that applies to `monitor`, or `None`. Name pins
/// take priority over description fallbacks; within each pass the first
/// matching entry in list order wins.
#[must_use]
pub fn match_override<'a>(
    monitor: &Monitor,
    overrides: &'a Overrides,
) -> Option<&'a OverrideEntry> {
    if let Some(entry) = overrides
        .entries
        .iter()
        .find(|e| e.name.as_deref() == Some(monitor.name.as_str()))
    {
        return Some(entry);
    }
    overrides.entries.iter().find(|e| {
        e.name.is_none() && e.description.as_deref() == Some(monitor.description.as_str())
    })
}

/// Apply overrides to a planned set of specs. For each spec, the matching
/// override entry (looked up via the original monitor list, since the spec
/// carries the name but not the description needed for the fallback) replaces
/// whichever fields it sets. Returns a new spec list.
#[must_use]
pub fn apply_overrides(
    mut specs: Vec<MonitorSpec>,
    monitors: &[Monitor],
    overrides: &Overrides,
) -> Vec<MonitorSpec> {
    for spec in &mut specs {
        let Some(monitor) = monitors.iter().find(|m| m.name == spec.name) else {
            continue;
        };
        let Some(entry) = match_override(monitor, overrides) else {
            continue;
        };
        if let Some(r) = &entry.resolution {
            spec.resolution = r.clone();
        }
        if let Some(p) = &entry.position {
            spec.position = p.clone();
        }
        if let Some(scale) = entry.scale {
            spec.scale = crate::plan::render_scale(scale);
        }
        if let Some(transform) = entry.transform {
            spec.transform = Some(transform);
        }
        if let Some(vrr) = entry.vrr {
            spec.vrr = vrr.token();
        }
    }
    specs
}
