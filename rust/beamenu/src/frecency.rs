//! Usage-weighted ranking, persisted between runs.
//!
//! Raycast's launcher feels fast mostly because the thing you meant is
//! already first. That is not better fuzzy matching, it is memory: an entry
//! you pick often, and picked recently, outranks a closer string match you
//! never use.
//!
//! The score combines both, in the style of Firefox's frecency: each launch
//! adds a weight that decays with age, so a burst of use last week loses to
//! steady use today without ever dropping an entry off a cliff.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

/// Half-life of a single launch's contribution, in seconds (14 days).
const HALF_LIFE_SECS: f64 = 14.0 * 24.0 * 60.0 * 60.0;
/// Ceiling on the bonus any one entry can contribute to a rank score, so a
/// heavily used entry can still be displaced by an exact title match.
const MAX_BOOST: i64 = 60;
/// Launches kept per entry; older timestamps beyond this are dropped.
const MAX_LAUNCHES: usize = 32;

#[derive(Debug, Default, Clone, Serialize, Deserialize)]
pub struct Frecency {
    /// Item id -> unix timestamps of its launches, oldest first.
    #[serde(default)]
    entries: HashMap<String, Vec<u64>>,
}

fn now_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}

impl Frecency {
    /// Load the store, treating any read or parse failure as "no history".
    ///
    /// A corrupt store must never keep the launcher from opening, so this
    /// deliberately has no error path: the worst case is unranked results.
    #[must_use]
    pub fn load(path: &Path) -> Self {
        std::fs::read_to_string(path)
            .ok()
            .and_then(|raw| serde_json::from_str(&raw).ok())
            .unwrap_or_default()
    }

    /// Write the store back, creating the parent directory if needed.
    ///
    /// # Errors
    /// Fails when the state directory cannot be created or written.
    pub fn save(&self, path: &Path) -> anyhow::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(path, serde_json::to_string(self)?)?;
        Ok(())
    }

    /// Record a launch of `id` at `at` (unix seconds).
    pub fn record_at(&mut self, id: &str, at: u64) {
        let launches = self.entries.entry(id.to_string()).or_default();
        launches.push(at);
        if launches.len() > MAX_LAUNCHES {
            let excess = launches.len() - MAX_LAUNCHES;
            launches.drain(..excess);
        }
    }

    /// Record a launch of `id` now.
    pub fn record(&mut self, id: &str) {
        self.record_at(id, now_secs());
    }

    /// Ranking bonus for `id` as of `at`, in the same units `rank` uses.
    ///
    /// Each launch contributes `0.5 ^ (age / half_life)`, so a launch today
    /// is worth 1.0, one from a fortnight ago 0.5, one from a month ago 0.25.
    #[must_use]
    pub fn boost_at(&self, id: &str, at: u64) -> i64 {
        let Some(launches) = self.entries.get(id) else {
            return 0;
        };

        let weight: f64 = launches
            .iter()
            .map(|&t| {
                // Unix seconds fit f64 exactly until well past year 285000.
                #[allow(clippy::cast_precision_loss)]
                let age = at.saturating_sub(t) as f64;
                0.5f64.powf(age / HALF_LIFE_SECS)
            })
            .sum();

        // Compress with a log so the first few launches matter most and the
        // twentieth barely moves anything.
        let scaled = (1.0 + weight).ln() * 18.0;

        // weight is at most MAX_LAUNCHES, so scaled peaks around 63 and the
        // truncation clippy warns about is unreachable before the clamp.
        #[allow(clippy::cast_possible_truncation)]
        let rounded = scaled.round() as i64;
        rounded.min(MAX_BOOST)
    }

    /// Ranking bonus for `id` as of now.
    #[must_use]
    pub fn boost(&self, id: &str) -> i64 {
        self.boost_at(id, now_secs())
    }
}

/// `$XDG_STATE_HOME/beamenu/frecency.json`, falling back to `~/.local/state`.
#[must_use]
pub fn default_path() -> PathBuf {
    let state = std::env::var_os("XDG_STATE_HOME").map_or_else(
        || PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/state"),
        PathBuf::from,
    );
    state.join("beamenu/frecency.json")
}
