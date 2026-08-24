//! Web search through the local SearXNG instance.
//!
//! The launcher re-queries every provider on every keystroke, and a SearXNG
//! query costs 450 ms warm and a full second cold — it fans out to upstream
//! engines. Searching as you type would therefore stall the panel on every
//! character, and because the loop renders *before* it blocks for the next key,
//! the character you just typed would not even appear until the request came
//! back. Debouncing does not rescue this: there is no way to wake
//! `bm_menu_poll_key` when a late answer arrives.
//!
//! So the work moves off the keystroke path entirely. [`Provider::query`]
//! shows one row offering the search, costing nothing. Enter on that row runs
//! [`Provider::present`], which makes the one request and hands back the
//! results as a fixed list. One round trip per search, not one per character.

use serde::Deserialize;

use crate::item::{Action, Item};
use crate::providers::quicklinks::percent_encode;
use crate::providers::{Ctx, Provider, Trigger};

/// The prefix that reaches this provider. A trailing space, like every other
/// keyworded provider, so `send` and `ssh` are not swallowed.
const KEYWORD: &str = "s ";

pub struct WebSearch;

/// One result, as SearXNG's JSON gives it.
///
/// Every field is optional. SearXNG's `results[]` key set varies by `template`
/// — a video result carries `length`, an image `img_src` — and `publishedDate`
/// and `length` are explicitly `null` on an ordinary web hit. Nothing here is
/// `deny_unknown_fields`, so a SearXNG upgrade that adds a key costs nothing.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct SearchResult {
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub url: String,
    #[serde(default)]
    pub content: Option<String>,
    /// Which upstream engines returned this. Shown so a result's provenance is
    /// visible, which is half the point of running a metasearch instance.
    #[serde(default)]
    pub engines: Vec<String>,
    /// Scheme, host, path, params, query, fragment — always six elements.
    #[serde(default)]
    pub parsed_url: Vec<String>,
}

/// The envelope around them.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct SearchResponse {
    #[serde(default)]
    pub results: Vec<SearchResult>,
}

impl SearchResult {
    /// The host, for the subtitle. Falls back to parsing the URL when
    /// `parsed_url` is absent, and to the whole URL when even that fails.
    #[must_use]
    pub fn host(&self) -> String {
        if let Some(host) = self.parsed_url.get(1) {
            if !host.is_empty() {
                return host.clone();
            }
        }
        self.url
            .split_once("://")
            .map_or(self.url.as_str(), |(_, rest)| {
                rest.split('/').next().unwrap_or(rest)
            })
            .to_string()
    }
}

/// Build the SearXNG query URL for `query`.
///
/// Reuses the quicklink percent-encoder rather than adding a second one; a
/// search term is exactly the "drop this into a query string" case that
/// existed for.
#[must_use]
pub fn search_url(base: &str, query: &str) -> String {
    format!(
        "{}/search?q={}&format=json",
        base.trim_end_matches('/'),
        percent_encode(query)
    )
}

/// The human-facing SearXNG page, for the fallbacks.
#[must_use]
pub fn browser_url(base: &str, query: &str) -> String {
    format!(
        "{}/search?q={}",
        base.trim_end_matches('/'),
        percent_encode(query)
    )
}

/// Turn a decoded response into rows.
///
/// Separate from the request so the mapping is testable against a captured
/// fixture without a SearXNG instance running.
#[must_use]
pub fn rows(response: &SearchResponse, limit: usize) -> Vec<Item> {
    response
        .results
        .iter()
        .filter(|result| !result.url.is_empty())
        .take(limit)
        .enumerate()
        .map(|(index, result)| {
            let title = if result.title.is_empty() {
                result.url.clone()
            } else {
                result.title.clone()
            };

            // The index is part of the id so two engines returning the same URL
            // do not collide in the frecency store.
            let mut item = Item::new(
                format!("websearch:{index}:{}", result.url),
                title,
                Action::OpenUrl(result.url.clone()),
            )
            .section("Results")
            .alt("Copy link", Action::Copy(result.url.clone()));

            let host = result.host();
            item = match result.content.as_deref().map(str::trim) {
                Some(snippet) if !snippet.is_empty() => {
                    item.subtitle(format!("{host} · {}", condense(snippet)))
                }
                _ => item.subtitle(host),
            };

            if !result.engines.is_empty() {
                item = item.accessory(result.engines.join(", "));
            }
            item
        })
        .collect()
}

/// Flatten a snippet onto one line and cut it to something a row can hold.
///
/// SearXNG snippets carry newlines and run to several hundred characters; a row
/// draws one line and clips the rest, so trimming here is what keeps the
/// accessory column visible.
fn condense(snippet: &str) -> String {
    const LIMIT: usize = 120;

    let flat = snippet.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.chars().count() <= LIMIT {
        return flat;
    }
    let cut: String = flat.chars().take(LIMIT).collect();
    // Break on a word boundary rather than mid-word, when one is close enough
    // that the result does not lose most of its length to the trim.
    match cut.rfind(' ') {
        Some(at) if at > LIMIT * 2 / 3 => format!("{}…", &cut[..at]),
        _ => format!("{cut}…"),
    }
}

/// The row shown when the search could not be made.
///
/// A row rather than an error, because the launcher has no way to show one and
/// closing the panel would lose the query. Enter still opens the SearXNG web
/// UI, so a broken JSON path never costs the user their search.
#[must_use]
pub fn failure_row(base: &str, query: &str, reason: &str) -> Item {
    Item::new(
        "websearch:error",
        format!("Could not reach SearXNG — {reason}"),
        Action::OpenUrl(browser_url(base, query)),
    )
    .section("Results")
    .subtitle(format!("Enter to search {base} in the browser instead"))
}

impl Provider for WebSearch {
    fn id(&self) -> &'static str {
        "websearch"
    }

    fn section(&self) -> &'static str {
        "Web Search"
    }

    fn trigger(&self) -> Trigger {
        Trigger::Prefix(KEYWORD.to_string())
    }

    fn query(&self, ctx: &Ctx, query: &str) -> Vec<Item> {
        let query = query.trim();
        if query.is_empty() {
            return vec![
                Item::new("websearch:prompt", "Search the web", Action::None)
                    .subtitle("Type what you are looking for"),
            ];
        }

        vec![Item::new(
            "websearch:run",
            format!("Search the web for “{query}”"),
            Action::Present {
                provider: "websearch".to_string(),
                query: query.to_string(),
            },
        )
        .subtitle(format!("via {}", ctx.config.search_url))
        .accessory("↵ search")
        .alt(
            "Open in browser",
            Action::OpenUrl(browser_url(&ctx.config.search_url, query)),
        )]
    }

    fn present(&self, ctx: &Ctx, query: &str) -> Vec<Item> {
        let query = query.trim();
        let base = &ctx.config.search_url;
        let timeout = std::time::Duration::from_millis(ctx.config.search_timeout_ms);

        let response = match crate::http::get(&search_url(base, query), timeout) {
            Ok(response) if response.status == 200 => response,
            Ok(response) => {
                return vec![failure_row(
                    base,
                    query,
                    &format!("it answered HTTP {}", response.status),
                )]
            }
            Err(err) => return vec![failure_row(base, query, &err.to_string())],
        };

        let decoded: SearchResponse = match serde_json::from_str(&response.body) {
            Ok(decoded) => decoded,
            Err(err) => return vec![failure_row(base, query, &format!("bad JSON: {err}"))],
        };

        let rows = rows(&decoded, ctx.config.search_results);
        if rows.is_empty() {
            return vec![Item::new(
                "websearch:empty",
                format!("No results for “{query}”"),
                Action::OpenUrl(browser_url(base, query)),
            )
            .section("Results")
            .subtitle("Enter to try the same search in the browser")];
        }
        rows
    }
}
