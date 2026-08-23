//! The filter pill bar's model: one pill per ambient provider that currently
//! has rows, keyed by the provider that owns it.

use beamenu::item::{Action, Item};
use beamenu::providers::{self, Provider};
use beamenu::Pills;

/// A row as `providers::decorate` hands it over: carrying both the id of the
/// provider that produced it and the heading it is grouped under.
fn row(provider: &str, section: &str) -> Item {
    Item::new(format!("{provider}:x"), "row", Action::None)
        .section(section)
        .provider(provider)
}

/// Every provider, scanned from an empty scratch directory so there are no
/// plugin manifests to pick up: only the built-in registry order matters
/// here.
fn providers() -> Vec<Box<dyn Provider>> {
    let dir = tempfile::tempdir().expect("a scratch dir");
    providers::all(dir.path())
}

/// Every provider, scanned from a scratch directory holding the given ambient
/// plugin manifests (a title, no keyword) under `plugins/`, so they take their
/// place after the built-in providers the same way `providers::all()` does.
fn providers_with_ambient_plugins(manifests: &[(&str, &str)]) -> Vec<Box<dyn Provider>> {
    let dir = tempfile::tempdir().expect("a scratch dir");
    let plugins_dir = dir.path().join("plugins");
    std::fs::create_dir_all(&plugins_dir).expect("a plugins dir");
    for (name, title) in manifests {
        std::fs::write(
            plugins_dir.join(format!("{name}.json")),
            format!(r#"{{"name":"{name}","title":"{title}","commands":[]}}"#),
        )
        .expect("a manifest file");
    }
    providers::all(dir.path())
}

// --- the registry ---

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
    assert_eq!(
        pills.ids(),
        ["apps", "quicklinks", "snippets", "scripts", "system"]
    );
}

#[test]
fn every_plugin_earns_its_own_pill_even_when_two_share_a_title() {
    let pills = Pills::new(&providers_with_ambient_plugins(&[
        ("notes-a", "Notes"),
        ("notes-b", "Notes"),
    ]));

    // Two manifests, two pills. The heading they display is the same, but the
    // pill is keyed by the manifest's name, so neither plugin loses its own.
    assert_eq!(
        pills.ids(),
        [
            "apps",
            "quicklinks",
            "snippets",
            "scripts",
            "system",
            "notes-a",
            "notes-b"
        ]
    );
    assert_eq!(pills.labels()[5..], ["Notes", "Notes"]);

    // And each filters to its own rows rather than to the shared heading.
    let ambient = vec![row("notes-a", "Notes"), row("notes-b", "Notes")];
    assert_eq!(pills.filter(&ambient, 0), vec![row("notes-a", "Notes")]);
    assert_eq!(pills.filter(&ambient, 1), vec![row("notes-b", "Notes")]);
}

// --- which pills reach the bar ---

#[test]
fn visible_drops_the_providers_with_no_rows() {
    let pills = Pills::new(&providers());
    let ambient = vec![
        row("apps", "Applications"),
        row("apps", "Applications"),
        row("system", "System"),
        row("quicklinks", "Quicklinks"),
    ];

    let visible = pills.visible(&ambient);
    assert_eq!(
        visible.iter().map(|p| p.id).collect::<Vec<_>>(),
        ["apps", "quicklinks", "system"]
    );
    assert_eq!(
        visible.iter().map(|p| p.count).collect::<Vec<_>>(),
        [2, 1, 1]
    );
}

#[test]
fn spec_lists_only_the_providers_with_rows_in_registry_order() {
    let pills = Pills::new(&providers());
    let ambient = vec![
        row("apps", "Applications"),
        row("apps", "Applications"),
        row("system", "System"),
        row("quicklinks", "Quicklinks"),
    ];

    assert_eq!(
        pills.spec(&ambient),
        "Applications:2\u{1f}Quicklinks:1\u{1f}System:1"
    );
}

#[test]
fn spec_on_an_empty_result_set_is_empty_and_clears_the_bar() {
    let pills = Pills::new(&providers());
    assert_eq!(pills.spec(&[]), "");
    assert!(pills.visible(&[]).is_empty());
}

#[test]
fn a_keyword_providers_rows_claim_no_pill_and_so_clear_the_bar() {
    let pills = Pills::new(&providers());

    // `=2+2` reaches calc, a prefix provider, which never earned a pill.
    // Nothing is visible, so the bar goes away.
    let ambient = vec![row("calc", "Calculator")];
    assert_eq!(pills.spec(&ambient), "");
}

// --- filtering ---

#[test]
fn pill_zero_is_the_first_visible_provider_not_all() {
    let pills = Pills::new(&providers());
    let ambient = vec![row("apps", "Applications"), row("system", "System")];
    assert_eq!(pills.filter(&ambient, 0), vec![row("apps", "Applications")]);
}

#[test]
fn a_named_pill_keeps_only_its_own_rows() {
    let pills = Pills::new(&providers());
    let ambient = vec![
        row("apps", "Applications"),
        row("system", "System"),
        row("apps", "Applications"),
    ];

    // Visible is [apps, system]; pill 1 is system.
    assert_eq!(pills.filter(&ambient, 1), vec![row("system", "System")]);
}

#[test]
fn a_pill_index_counts_only_visible_providers_when_empty_ones_drop_out() {
    let pills = Pills::new(&providers());

    // system is the fifth registered pill either way, but its *index* depends
    // entirely on which providers have rows alongside it. Nothing may carry an
    // index across a change in the visible set.
    let wide = vec![
        row("apps", "Applications"),
        row("quicklinks", "Quicklinks"),
        row("system", "System"),
    ];
    assert_eq!(pills.filter(&wide, 2), vec![row("system", "System")]);

    let narrow = vec![row("apps", "Applications"), row("system", "System")];
    assert_eq!(pills.filter(&narrow, 1), vec![row("system", "System")]);

    // The same index against the narrower set is a different provider.
    assert_eq!(pills.filter(&narrow, 2), vec![row("apps", "Applications")]);
}

#[test]
fn an_out_of_range_pill_index_falls_back_to_the_first_visible_provider() {
    let pills = Pills::new(&providers());
    let ambient = vec![row("apps", "Applications"), row("system", "System")];
    assert_eq!(
        pills.filter(&ambient, 99),
        vec![row("apps", "Applications")]
    );
}

#[test]
fn filtering_with_nothing_visible_passes_the_rows_through() {
    let pills = Pills::new(&providers());

    // No ambient row claims a pill, so there is no filter to honour and the
    // keyword provider's own rows must survive.
    let ambient = vec![row("calc", "Calculator")];
    assert_eq!(pills.filter(&ambient, 0), ambient);
}

#[test]
fn a_plugin_manifest_earns_a_pill_that_filters_to_its_own_rows() {
    let pills = Pills::new(&providers_with_ambient_plugins(&[("notes", "Notes")]));

    // providers::all() appends plugin providers after the built-in ones, so
    // the manifest lands last, following the same five ambient built-ins as
    // pills_follow_registry_order_and_skip_prefix_providers.
    assert_eq!(
        pills.ids(),
        [
            "apps",
            "quicklinks",
            "snippets",
            "scripts",
            "system",
            "notes"
        ]
    );

    // Visible is [apps, system, notes]; pill 2 is notes.
    let ambient = vec![
        row("apps", "Applications"),
        row("notes", "Notes"),
        row("system", "System"),
    ];
    assert_eq!(pills.filter(&ambient, 2), vec![row("notes", "Notes")]);
}
