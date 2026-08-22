//! The filter pill bar's model: `All` plus one pill per ambient provider.

use beamenu::item::{Action, Item};
use beamenu::providers::{self, Provider};
use beamenu::Pills;

fn item(section: &str) -> Item {
    Item::new(format!("{section}:x"), "row", Action::None).section(section)
}

/// Every provider, scanned from an empty scratch directory so there are no
/// plugin manifests to pick up: only the built-in registry order matters
/// here.
fn providers() -> Vec<Box<dyn Provider>> {
    let dir = tempfile::tempdir().expect("a scratch dir");
    providers::all(dir.path())
}

#[test]
fn pills_follow_registry_order_and_skip_prefix_providers() {
    let pills = Pills::new(&providers());

    // providers::all()'s registration order is calc, apps, quicklinks,
    // snippets, scripts, window, clipboard, files, emoji, system. Only the
    // ambient ones (no Trigger::Prefix) earn a pill, in that same order.
    assert_eq!(
        pills.labels(),
        [
            "Applications",
            "Quicklinks",
            "Snippets",
            "Script Commands",
            "System"
        ]
    );
}

#[test]
fn spec_reports_the_all_total_then_one_label_count_pair_per_pill_in_order() {
    let pills = Pills::new(&providers());

    let ambient = vec![
        item("Applications"),
        item("Applications"),
        item("System"),
        item("Quicklinks"),
    ];

    assert_eq!(
        pills.spec(&ambient),
        "All:4\u{1f}Applications:2\u{1f}Quicklinks:1\u{1f}Snippets:0\u{1f}Script Commands:0\u{1f}System:1"
    );
}

#[test]
fn spec_on_an_empty_result_set_is_still_every_pill_at_zero() {
    let pills = Pills::new(&providers());
    assert_eq!(
        pills.spec(&[]),
        "All:0\u{1f}Applications:0\u{1f}Quicklinks:0\u{1f}Snippets:0\u{1f}Script Commands:0\u{1f}System:0"
    );
}

#[test]
fn pill_zero_is_all_the_ambient_mix_unfiltered() {
    let pills = Pills::new(&providers());
    let ambient = vec![item("Applications"), item("System")];
    assert_eq!(pills.filter(&ambient, 0), ambient);
}

#[test]
fn a_named_pill_keeps_only_its_own_section() {
    let pills = Pills::new(&providers());
    let ambient = vec![item("Applications"), item("System"), item("Applications")];

    // Pill 1 is "Applications", the first label after "All".
    let shown = pills.filter(&ambient, 1);
    assert_eq!(shown.len(), 2);
    assert!(shown
        .iter()
        .all(|i| i.section.as_deref() == Some("Applications")));
}

#[test]
fn a_named_pill_with_no_matches_is_an_empty_list_not_all() {
    let pills = Pills::new(&providers());
    let ambient = vec![item("Applications")];

    // Pill 3 is "Snippets"; none of the ambient rows are in that section.
    assert_eq!(pills.filter(&ambient, 3), Vec::new());
}

#[test]
fn an_out_of_range_pill_index_falls_back_to_all() {
    let pills = Pills::new(&providers());
    let ambient = vec![item("Applications"), item("System")];
    assert_eq!(pills.filter(&ambient, 99), ambient);
}
