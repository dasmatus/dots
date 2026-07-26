//! Monitor → rule matching. A rule matches a monitor when every present
//! regex (`match_name`, `match_description`) matches; a rule with neither
//! regex is the fallback (`name == "*"`) and matches anything. Rules are
//! tried in list order; the first match wins, so the fallback must be last.

use regex::Regex;

use crate::rules::{Rule, Rules};
use crate::spec::Monitor;

/// The match result for one monitor: the winning rule (or `None` if no rule
/// matched and there's no fallback). Owns clones of the monitor and the rule
/// so the planner can be called without keeping the source slices alive —
/// rules are tiny and monitors carry only the fields the planner needs.
#[derive(Debug, Clone, PartialEq)]
pub struct Matched {
    pub monitor: Monitor,
    pub rule: Rule,
}

/// Match every monitor against `rules`. Monitors with no matching rule are
/// dropped from the result (the planner only lays out matched monitors); the
/// fallback rule (`name == "*"`, no regexes) catches anything if present.
///
/// Regex compilation is memoized per rule: a rule with `match_name =
/// "^DP-"` compiles once and is reused across all monitors, rather than
/// recompiling per monitor. A rule with an invalid regex never matches
/// (logged to stderr, not fatal) so a typo in the rules file can't take the
/// whole layout down.
#[must_use]
pub fn match_monitors(monitors: &[Monitor], rules: &Rules) -> Vec<Matched> {
    let compiled: Vec<CompiledRule> = rules.rules.iter().map(CompiledRule::new).collect();
    monitors
        .iter()
        .filter_map(|m| {
            compiled.iter().zip(&rules.rules).find_map(|(c, r)| {
                c.matches(m).then(|| Matched {
                    monitor: m.clone(),
                    rule: r.clone(),
                })
            })
        })
        .collect()
}

/// One rule with its regexes pre-compiled. `name_present`/`desc_present`
/// track whether the rule *carried* the field at all, separate from whether
/// compilation succeeded — so a present-but-invalid regex fails to match
/// (rather than being silently treated as "absent").
struct CompiledRule {
    name: Option<Regex>,
    name_present: bool,
    desc: Option<Regex>,
    desc_present: bool,
}

impl CompiledRule {
    fn new(rule: &Rule) -> Self {
        let (name, name_present) = compile(&rule.match_name);
        let (desc, desc_present) = compile(&rule.match_description);
        Self {
            name,
            name_present,
            desc,
            desc_present,
        }
    }

    fn matches(&self, m: &Monitor) -> bool {
        let n = match (&self.name, self.name_present) {
            (Some(r), _) => r.is_match(&m.name),
            (None, true) => false, // present but failed to compile → no match
            (None, false) => true, // absent → don't constrain
        };
        let d = match (&self.desc, self.desc_present) {
            (Some(r), _) => r.is_match(&m.description),
            (None, true) => false,
            (None, false) => true,
        };
        n && d
    }
}

fn compile(pat: &Option<String>) -> (Option<Regex>, bool) {
    match pat {
        Some(p) => match Regex::new(p) {
            Ok(r) => (Some(r), true),
            Err(e) => {
                eprintln!("hyprmon: bad regex {p:?}: {e}");
                (None, true)
            }
        },
        None => (None, false),
    }
}
