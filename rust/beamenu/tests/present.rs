//! `Provider::present`: the on-demand path a row takes when its answer costs
//! more than a keystroke may.

use beamenu::config::Config;
use beamenu::item::{Action, Item};
use beamenu::providers::{self, Ctx, Provider, Trigger};

fn ctx() -> Ctx {
    Ctx {
        config: Config::default(),
        config_dir: std::path::PathBuf::from("/nonexistent/config"),
        state_dir: std::path::PathBuf::from("/nonexistent/state"),
        apps: beamenu::index::AppCache::default(),
    }
}

/// A provider that says nothing about `present`, to pin the default.
struct Quiet;

impl Provider for Quiet {
    fn id(&self) -> &str {
        "quiet"
    }
    fn section(&self) -> &str {
        "Quiet"
    }
    fn query(&self, _ctx: &Ctx, query: &str) -> Vec<Item> {
        vec![Item::new(
            "quiet:one",
            format!("typed {query}"),
            Action::None,
        )]
    }
}

/// A provider whose two methods differ, the shape every real user of this has:
/// a cheap row that offers the work, and the work itself.
struct Expensive;

impl Provider for Expensive {
    fn id(&self) -> &str {
        "expensive"
    }
    fn section(&self) -> &str {
        "Expensive"
    }
    fn trigger(&self) -> Trigger {
        Trigger::Prefix("x ".into())
    }
    fn query(&self, _ctx: &Ctx, query: &str) -> Vec<Item> {
        vec![Item::new(
            "expensive:run",
            format!("Compute {query}"),
            Action::Present {
                provider: "expensive".into(),
                query: query.to_string(),
            },
        )]
    }
    fn present(&self, _ctx: &Ctx, query: &str) -> Vec<Item> {
        // Deliberately not alphabetical: the order a provider chooses must
        // survive, since a search provider returns rows in relevance order.
        ["zulu", "alpha", "mike"]
            .iter()
            .map(|name| {
                Item::new(
                    format!("expensive:{name}"),
                    format!("{name} for {query}"),
                    Action::None,
                )
            })
            .collect()
    }
}

fn registry() -> Vec<Box<dyn Provider>> {
    vec![Box::new(Quiet), Box::new(Expensive)]
}

#[test]
fn present_defaults_to_query_so_existing_providers_need_no_opinion() {
    let rows = providers::present(&registry(), &ctx(), "quiet", "hello");

    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].title, "typed hello");
}

#[test]
fn present_runs_the_named_providers_own_implementation() {
    let rows = providers::present(&registry(), &ctx(), "expensive", "nixos");

    let titles: Vec<&str> = rows.iter().map(|row| row.title.as_str()).collect();
    assert_eq!(
        titles,
        ["zulu for nixos", "alpha for nixos", "mike for nixos"],
        "present rows keep the order the provider chose"
    );
}

#[test]
fn present_stamps_provider_and_section_the_same_way_collect_does() {
    let rows = providers::present(&registry(), &ctx(), "expensive", "q");

    for row in &rows {
        assert_eq!(row.provider.as_deref(), Some("expensive"));
        assert_eq!(row.section.as_deref(), Some("Expensive"));
    }
}

#[test]
fn an_unknown_provider_id_yields_no_rows_rather_than_panicking() {
    let rows = providers::present(&registry(), &ctx(), "disabled-since", "q");
    assert!(rows.is_empty());
}

#[test]
fn a_keyworded_provider_offers_the_work_without_doing_it() {
    // The point of the split: `x foo` must not run `present`, because this is
    // the per-keystroke path.
    let (rows, rank_query) = providers::collect(&registry(), &ctx(), "x foo");

    assert_eq!(rows.len(), 1, "the cheap row, not the three expensive ones");
    assert_eq!(rows[0].title, "Compute foo");
    assert!(rank_query.is_empty());
    assert_eq!(
        rows[0].action,
        Action::Present {
            provider: "expensive".into(),
            query: "foo".into(),
        }
    );
}

#[test]
fn dispatching_a_present_action_is_inert() {
    // The loop owns the stack and intercepts this; dispatch must not treat a
    // stray one as an error or a spawn.
    assert!(beamenu::dispatch::dispatch(
        &Action::Present {
            provider: "expensive".into(),
            query: "q".into(),
        },
        "kitty",
    )
    .is_ok());
}
