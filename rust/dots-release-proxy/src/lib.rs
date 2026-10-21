//! A loopback HTTP server that shows a repository's GitHub releases to
//! systemd-sysupdate as one `url-file` directory per channel:
//!
//! ```text
//! GET /updates/<channel>/<arch>/SHA256SUMS   every matching release's sums, merged
//! GET /updates/<channel>/<arch>/<file>       that file, from whichever release has it
//! ```
//!
//! The same path the `LosOS` Desktop proxy answers for GHCR, and for the same
//! reason: sysupdate reads one directory, while every GitHub release is a
//! directory of its own. The other half is size. A release asset stops at
//! 2 GiB and the full `LiveISO` does not, so the weekly release carries it as
//! `<file>.part000`, `<file>.part001`, … and this server streams the parts
//! back to back as `<file>`. sysupdate checks the joined bytes against the
//! whole-file line in `SHA256SUMS`, so a missing or reordered part fails the
//! download instead of installing.
//!
//! A channel is a tag prefix: `weekly` is every `weekly-*` release, newest
//! first, and any other channel is the one release tagged with its name
//! (`nightly`). `<arch>` is accepted and ignored; every release is `x86_64`.

use std::collections::{HashSet, VecDeque};
use std::io::{self, Read};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use serde::Deserialize;

/// The suffix the weekly release splits a file with, before its part number.
pub const PART: &str = ".part";

/// One downloadable file of a release.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct Asset {
    pub name: String,
    pub size: u64,
    #[serde(rename = "browser_download_url")]
    pub url: String,
}

/// One GitHub release, as much of it as this server reads.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct Release {
    #[serde(rename = "tag_name")]
    pub tag: String,
    #[serde(default)]
    pub draft: bool,
    #[serde(default)]
    pub assets: Vec<Asset>,
}

/// What a request path asks for.
#[derive(Debug, PartialEq, Eq)]
pub enum Route<'a> {
    Sums { channel: &'a str },
    File { channel: &'a str, name: &'a str },
    NotFound,
}

/// Where a file's bytes come from.
#[derive(Debug, PartialEq, Eq)]
pub enum Source<'a> {
    /// A single asset, handed over as a redirect.
    Whole(&'a Asset),
    /// Numbered parts, joined in order.
    Parts(Vec<&'a Asset>),
}

impl Source<'_> {
    /// The joined length, which is what `Content-Length` promises.
    #[must_use]
    pub fn size(&self) -> u64 {
        match self {
            Source::Whole(asset) => asset.size,
            Source::Parts(parts) => parts.iter().map(|p| p.size).sum(),
        }
    }
}

fn safe(segment: &str) -> bool {
    !segment.is_empty()
        && segment != "."
        && segment != ".."
        && segment
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-+~".contains(&b))
}

/// Parse a request path (query string already stripped).
#[must_use]
pub fn route(path: &str) -> Route<'_> {
    let mut segments = path.trim_start_matches('/').split('/');
    let (Some("updates"), Some(channel), Some(arch), Some(name), None) = (
        segments.next(),
        segments.next(),
        segments.next(),
        segments.next(),
        segments.next(),
    ) else {
        return Route::NotFound;
    };
    if !safe(channel) || !safe(arch) || !safe(name) {
        return Route::NotFound;
    }
    if name == "SHA256SUMS" {
        Route::Sums { channel }
    } else {
        Route::File { channel, name }
    }
}

/// Whether a release tag belongs to a channel.
#[must_use]
pub fn in_channel(channel: &str, tag: &str) -> bool {
    tag == channel
        || tag
            .strip_prefix(channel)
            .and_then(|rest| rest.strip_prefix('-'))
            .is_some_and(|rest| !rest.is_empty())
}

/// The releases of a channel, newest tag first. Weekly tags carry an ISO
/// week (`weekly-2026.43`), so the tag order is the release order.
#[must_use]
pub fn channel<'a>(releases: &'a [Release], name: &str) -> Vec<&'a Release> {
    let mut out: Vec<&Release> = releases
        .iter()
        .filter(|r| !r.draft && in_channel(name, &r.tag))
        .collect();
    out.sort_by(|a, b| b.tag.cmp(&a.tag));
    out
}

/// Find `name` in the newest release of the channel that has it, whole or
/// in parts. Parts must be numbered from zero without a gap; a release that
/// is missing one is skipped rather than served short.
#[must_use]
pub fn locate<'a>(releases: &[&'a Release], name: &str) -> Option<Source<'a>> {
    let stem = format!("{name}{PART}");
    for release in releases {
        if let Some(asset) = release.assets.iter().find(|a| a.name == name) {
            return Some(Source::Whole(asset));
        }
        let mut parts: Vec<(usize, &Asset)> = release
            .assets
            .iter()
            .filter_map(|a| {
                let n = a.name.strip_prefix(&stem)?;
                if n.is_empty() || !n.bytes().all(|b| b.is_ascii_digit()) {
                    return None;
                }
                Some((n.parse().ok()?, a))
            })
            .collect();
        if parts.is_empty() {
            continue;
        }
        parts.sort_by_key(|(n, _)| *n);
        if parts.iter().enumerate().all(|(i, (n, _))| i == *n) {
            return Some(Source::Parts(parts.into_iter().map(|(_, a)| a).collect()));
        }
    }
    None
}

/// Merge `SHA256SUMS` files, newest first: a file name keeps the first line
/// that names it, and anything that is not a sums line is dropped.
#[must_use]
pub fn merge_sums<'a>(sums: impl IntoIterator<Item = &'a str>) -> String {
    let mut seen = HashSet::new();
    let mut out = String::new();
    for text in sums {
        for line in text.lines() {
            let Some((hash, name)) = line.split_once(' ') else {
                continue;
            };
            let name = name.trim_start_matches([' ', '*']);
            if hash.len() != 64 || !hash.bytes().all(|b| b.is_ascii_hexdigit()) || !safe(name) {
                continue;
            }
            if seen.insert(name.to_owned()) {
                out.push_str(hash);
                out.push_str("  ");
                out.push_str(name);
                out.push('\n');
            }
        }
    }
    out
}

/// Where to read releases from.
#[derive(Debug, Clone)]
pub struct Config {
    /// `owner/name`.
    pub repository: String,
    /// The GitHub API root, `https://api.github.com` outside the tests.
    pub api: String,
    /// Optional token, for the API's higher rate limit.
    pub token: Option<String>,
    /// How long a release listing is reused before it is fetched again.
    pub ttl: Duration,
}

struct State {
    config: Config,
    agent: ureq::Agent,
    cache: Mutex<Option<(Instant, Arc<Vec<Release>>)>>,
}

impl State {
    fn releases(&self) -> Result<Arc<Vec<Release>>, String> {
        let mut cache = self.cache.lock().map_err(|_| "cache poisoned".to_owned())?;
        if let Some((at, releases)) = cache.as_ref() {
            if at.elapsed() < self.config.ttl {
                return Ok(Arc::clone(releases));
            }
        }
        let url = format!(
            "{}/repos/{}/releases?per_page=100",
            self.config.api.trim_end_matches('/'),
            self.config.repository
        );
        let mut request = self
            .agent
            .get(&url)
            .set("accept", "application/vnd.github+json")
            .set("user-agent", "dots-release-proxy");
        if let Some(token) = &self.config.token {
            request = request.set("authorization", &format!("Bearer {token}"));
        }
        let releases: Vec<Release> = request
            .call()
            .map_err(|e| format!("releases: {e}"))?
            .into_json()
            .map_err(|e| format!("releases: {e}"))?;
        let releases = Arc::new(releases);
        *cache = Some((Instant::now(), Arc::clone(&releases)));
        Ok(releases)
    }

    fn open(&self, url: &str) -> io::Result<Box<dyn Read + Send + Sync>> {
        self.agent
            .get(url)
            .set("user-agent", "dots-release-proxy")
            .call()
            .map(ureq::Response::into_reader)
            .map_err(|e| io::Error::other(format!("{url}: {e}")))
    }
}

/// Reads parts one after another, opening each only once the one before it
/// is spent, so a 6 GiB join holds one connection at a time.
struct Joined {
    state: Arc<State>,
    urls: VecDeque<String>,
    current: Option<Box<dyn Read + Send + Sync>>,
}

impl Read for Joined {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        loop {
            if self.current.is_none() {
                let Some(url) = self.urls.pop_front() else {
                    return Ok(0);
                };
                self.current = Some(self.state.open(&url)?);
            }
            let n = self.current.as_mut().map_or(Ok(0), |r| r.read(buf))?;
            if n > 0 || buf.is_empty() {
                return Ok(n);
            }
            self.current = None;
        }
    }
}

type Reply = tiny_http::Response<Box<dyn Read + Send>>;

fn header(name: &str, value: &str) -> tiny_http::Header {
    tiny_http::Header::from_bytes(name.as_bytes(), value.as_bytes())
        .unwrap_or_else(|()| unreachable!("header {name} is ASCII"))
}

fn text(status: u16, body: String) -> Reply {
    let len = body.len();
    tiny_http::Response::new(
        status.into(),
        vec![header("content-type", "text/plain; charset=utf-8")],
        Box::new(io::Cursor::new(body.into_bytes())),
        Some(len),
        None,
    )
}

fn answer(state: &Arc<State>, method: &tiny_http::Method, url: &str) -> Reply {
    let head = *method == tiny_http::Method::Head;
    if !head && *method != tiny_http::Method::Get {
        return text(405, "GET or HEAD\n".into());
    }
    let path = url.split('?').next().unwrap_or_default();
    let (channel_name, name) = match route(path) {
        Route::NotFound => return text(404, "not an updates path\n".into()),
        Route::Sums { channel } => (channel, None),
        Route::File { channel, name } => (channel, Some(name)),
    };
    let releases = match state.releases() {
        Ok(r) => r,
        Err(e) => return text(502, format!("{e}\n")),
    };
    let releases = channel(&releases, channel_name);

    let Some(name) = name else {
        let mut bodies = Vec::new();
        for release in &releases {
            let Some(asset) = release.assets.iter().find(|a| a.name == "SHA256SUMS") else {
                continue;
            };
            let mut body = String::new();
            match state
                .open(&asset.url)
                .and_then(|mut r| r.read_to_string(&mut body))
            {
                Ok(_) => bodies.push(body),
                Err(e) => return text(502, format!("{}: {e}\n", release.tag)),
            }
        }
        if bodies.is_empty() {
            return text(404, format!("{channel_name} has no releases\n"));
        }
        return text(200, merge_sums(bodies.iter().map(String::as_str)));
    };

    let Some(source) = locate(&releases, name) else {
        return text(404, format!("{channel_name} has no {name}\n"));
    };
    let size = source.size();
    let urls: VecDeque<String> = match source {
        Source::Whole(asset) => {
            // GitHub hands the bytes out from its own storage; send the
            // client there instead of carrying them.
            return tiny_http::Response::new(
                302.into(),
                vec![header("location", &asset.url)],
                Box::new(io::empty()),
                Some(0),
                None,
            );
        }
        Source::Parts(parts) => parts.iter().map(|p| p.url.clone()).collect(),
    };
    let headers = vec![header("content-type", "application/octet-stream")];
    let body: Box<dyn Read + Send> = if head {
        Box::new(io::empty())
    } else {
        Box::new(Joined {
            state: Arc::clone(state),
            urls,
            current: None,
        })
    };
    let len = usize::try_from(size).unwrap_or(usize::MAX);
    tiny_http::Response::new(200.into(), headers, body, Some(len), None)
}

/// Answer requests on `server` until it is dropped, one thread each.
pub fn serve(server: &tiny_http::Server, config: Config) {
    let state = Arc::new(State {
        agent: ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(30))
            .timeout_read(Duration::from_mins(2))
            .build(),
        config,
        cache: Mutex::new(None),
    });
    for request in server.incoming_requests() {
        let state = Arc::clone(&state);
        thread::spawn(move || {
            let reply = answer(&state, request.method(), request.url());
            // A client that hangs up mid-join is not this server's error.
            let _ = request.respond(reply);
        });
    }
}
