//! The filter pill bar's model: one pill per ambient provider that currently
//! has rows, keyed by the provider that owns it.

use beamenu::item::{Action, Item};
use beamenu::providers::{self, Provider};
use beamenu::{PillState, Pills};

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

// --- PillState: browsing ---

const BROWSING: bool = false;
const SEARCHING: bool = true;

#[test]
fn a_polled_index_is_resolved_against_the_ids_last_sent() {
    let pills = Pills::new(&providers());
    let mut state = PillState::new();

    let ambient = vec![
        row("apps", "Applications"),
        row("quicklinks", "Quicklinks"),
        row("system", "System"),
    ];
    assert_eq!(state.to_send(&pills.visible(&ambient), BROWSING), 0);

    // Two Tab presses land the C side on index 2, which against the ids this
    // frame sent is system.
    assert!(state.on_poll(2, BROWSING));
    assert_eq!(state.chosen(), Some("system"));
}

#[test]
fn an_index_echoed_back_unchanged_is_not_a_tab_press() {
    let pills = Pills::new(&providers());
    let mut state = PillState::new();

    let ambient = vec![row("apps", "Applications"), row("system", "System")];
    let sent = state.to_send(&pills.visible(&ambient), BROWSING);

    assert!(!state.on_poll(sent, BROWSING));
    assert_eq!(state.chosen(), None);
}

#[test]
fn the_remembered_provider_survives_a_query_that_drops_other_pills() {
    let pills = Pills::new(&providers());
    let mut state = PillState::new();

    let wide = vec![
        row("apps", "Applications"),
        row("quicklinks", "Quicklinks"),
        row("system", "System"),
    ];
    state.to_send(&pills.visible(&wide), BROWSING);
    assert!(state.on_poll(2, BROWSING));
    assert_eq!(state.chosen(), Some("system"));

    // The next keystroke leaves quicklinks with no rows, so system is index 1
    // now. The stale 2 would have filtered to the wrong provider.
    let narrow = vec![row("apps", "Applications"), row("system", "System")];
    let visible = pills.visible(&narrow);
    assert_eq!(state.to_send(&visible, BROWSING), 1);
    assert_eq!(
        Pills::filter_of(&narrow, &visible, 1),
        vec![row("system", "System")]
    );
}

#[test]
fn a_remembered_provider_with_no_rows_falls_back_without_being_forgotten() {
    let pills = Pills::new(&providers());
    let mut state = PillState::new();

    let ambient = vec![row("apps", "Applications"), row("system", "System")];
    state.to_send(&pills.visible(&ambient), BROWSING);
    assert!(state.on_poll(1, BROWSING));
    assert_eq!(state.chosen(), Some("system"));

    // A frame with no system rows falls back to the first visible pill.
    let apps_only = vec![row("apps", "Applications")];
    assert_eq!(state.to_send(&pills.visible(&apps_only), BROWSING), 0);
    assert_eq!(state.chosen(), Some("system"));

    // And system comes back as soon as it has rows again.
    assert_eq!(state.to_send(&pills.visible(&ambient), BROWSING), 1);
}

#[test]
fn a_cleared_bar_ignores_the_polled_zero_index() {
    let pills = Pills::new(&providers());
    let mut state = PillState::new();

    let ambient = vec![row("apps", "Applications"), row("system", "System")];
    state.to_send(&pills.visible(&ambient), BROWSING);
    assert!(state.on_poll(1, BROWSING));

    // The action panel clears the bar, and bm_pills_free resets pill_active to
    // 0. Reading that back as a choice would silently reset the filter.
    state.cleared();
    assert!(!state.on_poll(0, BROWSING));
    assert_eq!(state.chosen(), Some("system"));
}

#[test]
fn an_action_panel_round_trip_keeps_the_remembered_provider() {
    let pills = Pills::new(&providers());
    let mut state = PillState::new();

    let ambient = vec![row("apps", "Applications"), row("system", "System")];
    state.to_send(&pills.visible(&ambient), BROWSING);
    assert!(state.on_poll(1, BROWSING));

    state.cleared();
    assert_eq!(state.to_send(&pills.visible(&ambient), BROWSING), 1);
    assert_eq!(state.chosen(), Some("system"));
}

// --- PillState: searching ---

#[test]
fn a_search_marks_no_pill_active_until_one_is_engaged() {
    let pills = Pills::new(&providers());
    let mut state = PillState::new();

    let ambient = vec![row("apps", "Applications"), row("system", "System")];
    assert_eq!(
        state.to_send(&pills.visible(&ambient), SEARCHING),
        beamenu::view::BM_PILL_NONE
    );
    assert_eq!(state.engaged(), None);
}

#[test]
fn a_search_reports_no_pill_even_when_one_was_chosen_while_browsing() {
    let pills = Pills::new(&providers());
    let mut state = PillState::new();

    let ambient = vec![row("apps", "Applications"), row("system", "System")];
    state.to_send(&pills.visible(&ambient), BROWSING);
    assert!(state.on_poll(1, BROWSING));
    assert_eq!(state.chosen(), Some("system"));

    // The browsing choice must not leak into the search and quietly hide rows
    // the query matched in other providers.
    assert_eq!(
        state.to_send(&pills.visible(&ambient), SEARCHING),
        beamenu::view::BM_PILL_NONE
    );
}

#[test]
fn tab_during_a_search_engages_the_provider_it_lands_on() {
    let pills = Pills::new(&providers());
    let mut state = PillState::new();

    let ambient = vec![row("apps", "Applications"), row("system", "System")];
    state.to_send(&pills.visible(&ambient), SEARCHING);

    assert!(state.on_poll(1, SEARCHING));
    assert_eq!(state.engaged(), Some("system"));

    // Now the search intersects with that provider instead of spanning all.
    assert_eq!(state.to_send(&pills.visible(&ambient), SEARCHING), 1);
}

#[test]
fn editing_the_query_releases_the_engaged_provider() {
    let pills = Pills::new(&providers());
    let mut state = PillState::new();

    let ambient = vec![row("apps", "Applications"), row("system", "System")];
    state.to_send(&pills.visible(&ambient), SEARCHING);
    assert!(state.on_poll(1, SEARCHING));
    assert_eq!(state.engaged(), Some("system"));

    state.on_query_change();
    assert_eq!(state.engaged(), None);
    assert_eq!(
        state.to_send(&pills.visible(&ambient), SEARCHING),
        beamenu::view::BM_PILL_NONE
    );
}

#[test]
fn clearing_the_query_returns_to_the_provider_tab_landed_on() {
    let pills = Pills::new(&providers());
    let mut state = PillState::new();

    let ambient = vec![row("apps", "Applications"), row("system", "System")];
    state.to_send(&pills.visible(&ambient), SEARCHING);
    assert!(state.on_poll(1, SEARCHING));

    // Tab during a search updates the browsing choice too, so deleting the
    // query lands where the user tabbed rather than back at the first pill.
    state.on_query_change();
    assert_eq!(state.to_send(&pills.visible(&ambient), BROWSING), 1);
}

#[test]
fn an_engaged_provider_with_no_rows_reports_no_pill_rather_than_the_first() {
    let pills = Pills::new(&providers());
    let mut state = PillState::new();

    let ambient = vec![row("apps", "Applications"), row("system", "System")];
    state.to_send(&pills.visible(&ambient), SEARCHING);
    assert!(state.on_poll(1, SEARCHING));

    // Falling back to pill 0 here would filter the search to a provider the
    // user never asked for; reporting nothing keeps every match visible.
    let apps_only = vec![row("apps", "Applications")];
    assert_eq!(
        state.to_send(&pills.visible(&apps_only), SEARCHING),
        beamenu::view::BM_PILL_NONE
    );
}

#[test]
fn the_no_pill_sentinel_never_narrows_to_the_first_pill() {
    let pills = Pills::new(&providers());
    let ambient = vec![row("apps", "Applications"), row("system", "System")];
    let visible = pills.visible(&ambient);

    // BM_PILL_NONE means "nothing is filtering". Falling into the
    // out-of-range fallback would silently narrow a search to whichever
    // provider happened to sort first.
    assert_eq!(
        Pills::filter_of(&ambient, &visible, beamenu::view::BM_PILL_NONE),
        ambient
    );
}
