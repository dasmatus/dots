//! The SearXNG provider: the cheap row, the URL it builds, and the mapping
//! from a real response to result rows.
//!
//! The fixture in `tests/fixtures/` was captured from the local instance, so
//! the shapes here are the ones SearXNG actually emits — `publishedDate: null`,
//! a six-element `parsed_url`, and an `engines` array — rather than the ones
//! its documentation implies.

use beamenu::config::Config;
use beamenu::item::{Action, Item};
use beamenu::providers::websearch::{self, SearchResponse};
use beamenu::providers::{self, Ctx, Provider, Trigger};

const FIXTURE: &str = include_str!("fixtures/searxng-rust-ownership.json");

fn ctx() -> Ctx {
    Ctx {
        config: Config::default(),
        config_dir: std::path::PathBuf::from("/nonexistent/config"),
        state_dir: std::path::PathBuf::from("/nonexistent/state"),
    }
}

fn decoded() -> SearchResponse {
    serde_json::from_str(FIXTURE).expect("a captured SearXNG response decodes")
}

#[test]
fn the_keyword_needs_a_word_boundary_so_it_does_not_swallow_ssh() {
    assert_eq!(
        websearch::WebSearch.trigger(),
        Trigger::Prefix("s ".to_string())
    );

    // "ssh" must reach the ambient providers, not the search one.
    let providers = providers::all(std::path::Path::new("/nonexistent"));
    let (_, rank_query) = providers::collect(&providers, &ctx(), "ssh");
    assert_eq!(rank_query, "ssh", "a bare word stays an ambient search");
}

#[test]
fn typing_a_query_offers_the_search_without_making_it() {
    // The whole point of the split: this path runs per keystroke and must not
    // touch the network. A bogus base URL proves it never tried.
    let mut ctx = ctx();
    ctx.config.search_url = "http://127.0.0.1:1/".to_string();

    let rows = websearch::WebSearch.query(&ctx, "rust ownership");

    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].title, "Search the web for “rust ownership”");
    assert_eq!(
        rows[0].action,
        Action::Present {
            provider: "websearch".to_string(),
            query: "rust ownership".to_string(),
        }
    );
}

#[test]
fn the_offer_row_can_fall_back_to_the_browser() {
    let rows = websearch::WebSearch.query(&ctx(), "nixos");
    let (label, action) = &rows[0].alt_actions[0];

    assert_eq!(label, "Open in browser");
    assert_eq!(
        *action,
        Action::OpenUrl("http://127.0.0.1:8888/search?q=nixos".to_string())
    );
}

#[test]
fn an_empty_query_prompts_rather_than_offering_an_empty_search() {
    let rows = websearch::WebSearch.query(&ctx(), "   ");

    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].action, Action::None);
}

#[test]
fn the_query_url_is_percent_encoded_and_asks_for_json() {
    assert_eq!(
        websearch::search_url("http://127.0.0.1:8888", "rust ownership & lifetimes"),
        "http://127.0.0.1:8888/search?q=rust%20ownership%20%26%20lifetimes&format=json"
    );
}

#[test]
fn a_trailing_slash_on_the_base_url_does_not_double_up() {
    assert_eq!(
        websearch::search_url("http://127.0.0.1:8888/", "x"),
        "http://127.0.0.1:8888/search?q=x&format=json"
    );
}

#[test]
fn a_captured_response_becomes_one_row_per_result() {
    let rows = websearch::rows(&decoded(), 12);

    assert!(!rows.is_empty(), "the fixture has results");
    assert!(rows.len() <= 12);
    for row in &rows {
        assert!(matches!(row.action, Action::OpenUrl(_)));
        assert_eq!(row.section.as_deref(), Some("Results"));
    }
}

#[test]
fn a_result_row_shows_the_host_and_which_engines_found_it() {
    let rows = websearch::rows(&decoded(), 12);
    let first = &rows[0];

    let subtitle = first.subtitle.as_deref().expect("a subtitle is set");
    assert!(
        subtitle.starts_with("doc.rust-lang.org"),
        "expected the host to lead the subtitle, got {subtitle:?}"
    );
    assert!(
        first.accessory.is_some(),
        "the engines that returned it should be visible"
    );
}

#[test]
fn the_limit_is_honoured() {
    assert_eq!(websearch::rows(&decoded(), 3).len(), 3);
    assert!(websearch::rows(&decoded(), 0).is_empty());
}

#[test]
fn every_result_row_offers_a_copy_link() {
    for row in websearch::rows(&decoded(), 5) {
        let labels: Vec<&str> = row
            .alt_actions
            .iter()
            .map(|(label, _)| label.as_str())
            .collect();
        assert!(labels.contains(&"Copy link"), "{} lacks Copy link", row.id);
    }
}

#[test]
fn a_long_snippet_is_condensed_onto_one_line() {
    let rows = websearch::rows(&decoded(), 12);
    for row in &rows {
        let subtitle = row.subtitle.as_deref().unwrap_or_default();
        assert!(
            !subtitle.contains('\n'),
            "a row draws one line; {subtitle:?} has a newline"
        );
        assert!(
            subtitle.chars().count() <= 200,
            "subtitle too long to leave room for the accessory: {subtitle:?}"
        );
    }
}

#[test]
fn results_without_a_url_are_dropped_rather_than_shown_as_dead_rows() {
    let response: SearchResponse = serde_json::from_str(
        r#"{"results":[{"title":"no link here"},{"title":"real","url":"https://example.org/"}]}"#,
    )
    .expect("a sparse response decodes");

    let rows = websearch::rows(&response, 12);
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].title, "real");
}

#[test]
fn a_response_missing_optional_fields_still_decodes() {
    // Every field is #[serde(default)] precisely so a template variation or a
    // SearXNG upgrade cannot break the whole search.
    let response: SearchResponse = serde_json::from_str(
        r#"{"results":[{"url":"https://example.org/a","publishedDate":null,"length":null,
             "template":"videos.html","some_future_key":42}]}"#,
    )
    .expect("unknown and null fields are tolerated");

    let rows = websearch::rows(&response, 12);
    assert_eq!(rows.len(), 1);
    assert_eq!(
        rows[0].title, "https://example.org/a",
        "a result with no title falls back to its URL"
    );
    assert_eq!(rows[0].subtitle.as_deref(), Some("example.org"));
}

#[test]
fn a_failure_still_lets_the_user_reach_their_search() {
    let row: Item = websearch::failure_row(
        "http://127.0.0.1:8888",
        "rust ownership",
        "connection refused",
    );

    assert!(row.title.contains("connection refused"));
    assert_eq!(
        row.action,
        Action::OpenUrl("http://127.0.0.1:8888/search?q=rust%20ownership".to_string()),
        "the browser fallback must carry the same query"
    );
}

#[test]
fn an_unreachable_instance_produces_a_failure_row_rather_than_a_panic() {
    let mut ctx = ctx();
    // Port 1 is reserved and nothing listens there.
    ctx.config.search_url = "http://127.0.0.1:1".to_string();
    ctx.config.search_timeout_ms = 300;

    let rows = websearch::WebSearch.present(&ctx, "rust");

    assert_eq!(rows.len(), 1);
    assert!(rows[0].title.starts_with("Could not reach SearXNG"));
    assert!(matches!(rows[0].action, Action::OpenUrl(_)));
}
