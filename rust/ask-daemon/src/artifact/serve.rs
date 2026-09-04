//! The loopback HTTP server that artifacts open from, and the containment
//! every response carries.
//!
//! **Why http and not `file://`.** A `file:` document has an opaque origin, so
//! `'self'` in a CSP means nothing there, `fetch` is blocked outright, and
//! Chromium's rules about what one local file may read from another vary with
//! flags that are not this daemon's to set. Serving from loopback gives the
//! page a real origin, which is what makes `connect-src 'self'` and
//! `Cross-Origin-Resource-Policy` say something, and it means the reload shim
//! below can work at all. It also keeps the browser from ever being pointed at
//! the filesystem: `--app=file:///…` would open a window whose document sits
//! in the same scheme as every file on this machine, and this one does not.
//!
//! **Why a hand-written router over hyper rather than a framework.** hyper is
//! already in the dependency graph under `reqwest`, so the server side costs
//! two feature flags and no new crate. There are exactly two routes and both
//! answer from a map, so a router, an extractor stack and a middleware tower
//! would be scaffolding around eleven lines of matching.
//!
//! # What an artifact may do
//!
//! Written out because it is a decision rather than a default, and because
//! `render.rs`'s tag allowlist does **not** cover this. That allowlist exists
//! because a QML `Text` runs no script; a page here runs in Chromium, where
//! script does run and `fetch` works. Nothing about the pane's escaping
//! carries over, and the two must not be read as one guard.
//!
//! - **It runs no script of its own.** `script-src` names a per-response
//!   nonce and nothing else. The reload shim carries that nonce; markup the
//!   model wrote cannot, because the value is minted after the file was
//!   written and is different on every request.
//! - **It reaches no host but the one that served it.** `default-src 'none'`
//!   with `connect-src 'self'` denies every remote fetch, image, font,
//!   stylesheet, frame and worker. An `<img src="https://…/?leak">` is the
//!   cheapest exfiltration a page can attempt and it is refused.
//! - **It cannot navigate away.** This is the hole CSP's fetch directives do
//!   not cover: there is no `navigate-to` directive in any shipped browser, so
//!   `location = "https://…"` and `<meta http-equiv="refresh">` would both
//!   leave, and a URL the model chose is a channel. The `sandbox` directive
//!   closes it, because a sandboxed document without `allow-top-navigation`
//!   cannot navigate itself and without `allow-popups` cannot open a window.
//!   `allow-scripts` is there for the shim and `allow-same-origin` so that
//!   `'self'` keeps meaning the loopback origin rather than an opaque one.
//! - **It cannot be framed, and its bytes cannot be read cross-origin.**
//!   `frame-ancestors 'none'` plus `Cross-Origin-Resource-Policy: same-origin`
//!   and `Cross-Origin-Opener-Policy: same-origin`.
//! - **It cannot post a form anywhere**, including back here: `form-action
//!   'none'`.
//!
//! # What guards the server itself
//!
//! The port is not a secret. Every process on this machine can connect to a
//! loopback listener and can find it by scanning, so nothing here depends on
//! the port being unknown. Four things do the work instead.
//!
//! 1. **The path is a token, not a filename.** A request resolves through
//!    [`ArtifactStore::locate`], which is a map lookup. No filesystem path is
//!    ever built from request bytes, so there is no concatenation for a `..`
//!    to travel through. [`clean_segments`] still refuses `.`, `..`, an empty
//!    segment and any percent escape before the lookup runs, and the store
//!    re-checks that the path it holds is inside the artifact root.
//! 2. **The token is unguessable**: 122 random bits, minted per thread, and
//!    only ever sent over the 0600 unix socket.
//! 3. **The `Host` header must be the loopback authority this run bound.**
//!    Without that check a web page the user is browsing could point
//!    `evil.example` at 127.0.0.1, load this port under its own origin and
//!    read the response, which is DNS rebinding and the one attack a loopback
//!    server gets for free.
//! 4. **Only `GET` and `HEAD`.** Nothing here writes, so nothing here accepts
//!    a method that implies writing.

use std::convert::Infallible;
use std::fs;
use std::net::{Ipv4Addr, SocketAddr, TcpListener as StdListener};
use std::sync::Arc;
use std::time::Duration;

use http_body_util::Full;
use hyper::body::Bytes;
use hyper::header::{HeaderValue, HOST};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::{TokioIo, TokioTimer};
use tokio::net::TcpListener;
use uuid::Uuid;

use super::{is_token, ArtifactStore};
use crate::AskError;

/// The Content-Security-Policy every artifact response carries, with
/// `{nonce}` still in it.
///
/// Read the module header for what each directive is doing and why the
/// `sandbox` one is not decoration.
pub const CSP: &str = "default-src 'none'; \
img-src 'self' data:; \
style-src 'self' 'unsafe-inline'; \
font-src 'self' data:; \
media-src 'self' data:; \
script-src 'nonce-{nonce}'; \
connect-src 'self'; \
form-action 'none'; \
frame-ancestors 'none'; \
base-uri 'none'; \
sandbox allow-same-origin allow-scripts";

/// The prefix the reload endpoint answers under.
const REVISION_PREFIX: &str = "/_dots/rev/";

/// How long the shim waits between revision checks.
///
/// A poll rather than an event stream. The whole exchange is two loopback
/// packets and a map lookup, and the alternative is a long-lived connection
/// per open window that the daemon then has to age out. A second is below
/// what a person notices between asking for a change and seeing it.
const POLL_MS: u32 = 1000;

/// How long a connection may take to send its request headers.
///
/// Without this a local process could open connections and never speak,
/// holding a task each. With it they are reaped.
const HEADER_TIMEOUT: Duration = Duration::from_secs(10);

/// A bound artifact server: the base URL clients join paths to, and the
/// listener that has not started accepting yet.
pub struct Bound {
    base: String,
    authority: String,
    listener: TcpListener,
    store: Arc<ArtifactStore>,
}

impl Bound {
    /// The base URL, for example `http://127.0.0.1:41234`.
    ///
    /// This is what `ready.artifact_base` carries. It is not persisted
    /// anywhere, because the port is picked fresh on every start.
    #[must_use]
    pub fn base(&self) -> &str {
        &self.base
    }

    /// Accept until the process ends.
    pub async fn serve(self) {
        tracing::info!(base = %self.base, "serving artifacts on loopback");
        loop {
            let Ok((stream, _)) = self.listener.accept().await else {
                // The same reasoning as the unix listener's accept loop: a
                // descriptor limit or a peer that vanished clears on its own,
                // and neither is a reason to stop serving artifacts.
                tokio::time::sleep(Duration::from_millis(200)).await;
                continue;
            };
            let store = Arc::clone(&self.store);
            let authority = self.authority.clone();
            tokio::spawn(async move {
                let service = service_fn(move |request: Request<hyper::body::Incoming>| {
                    let store = Arc::clone(&store);
                    let authority = authority.clone();
                    async move { Ok::<_, Infallible>(answer(&store, &authority, &request)) }
                });
                let mut builder = http1::Builder::new();
                // The timer is not optional. hyper panics on the first request
                // when a timeout is set without one, and it panics inside the
                // connection task rather than at bind, so the daemon comes up
                // healthy and every artifact fetch resets instead.
                builder.timer(TokioTimer::new());
                builder.header_read_timeout(HEADER_TIMEOUT);
                if let Err(err) = builder
                    .serve_connection(TokioIo::new(stream), service)
                    .await
                {
                    tracing::debug!(error = %err, "an artifact connection ended badly");
                }
            });
        }
    }
}

/// Bind an artifact server on a loopback port the kernel picks.
///
/// `127.0.0.1` rather than `0.0.0.0` or `[::]`, so the listener exists on no
/// interface another machine can reach. Port 0 rather than a fixed one,
/// because a predictable port is one more thing a local program can find
/// without looking, and nothing here depends on the port being stable: the
/// client learns it from `ready`.
///
/// Bound synchronously so the caller has the port before the unix socket
/// exists, which is what lets the very first `ready` carry a real base.
///
/// # Errors
///
/// [`AskError::ArtifactBind`] when the loopback port cannot be taken.
pub fn bind(store: Arc<ArtifactStore>) -> Result<Bound, AskError> {
    let wanted = SocketAddr::from((Ipv4Addr::LOCALHOST, 0));
    let listener = StdListener::bind(wanted).map_err(|source| AskError::ArtifactBind {
        addr: wanted,
        source,
    })?;
    listener
        .set_nonblocking(true)
        .map_err(|source| AskError::ArtifactBind {
            addr: wanted,
            source,
        })?;
    let addr = listener
        .local_addr()
        .map_err(|source| AskError::ArtifactBind {
            addr: wanted,
            source,
        })?;
    let listener = TcpListener::from_std(listener)
        .map_err(|source| AskError::ArtifactBind { addr, source })?;
    let authority = format!("{}:{}", Ipv4Addr::LOCALHOST, addr.port());
    Ok(Bound {
        base: format!("http://{authority}"),
        authority,
        listener,
        store,
    })
}

/// Answer one request.
///
/// Split out of the connection loop so `tests/artifact_serve.rs` can drive it
/// with a hand-built request and no socket at all, which is what lets the
/// path-traversal cases be tests rather than a manual check.
#[must_use]
pub fn answer<B>(
    store: &ArtifactStore,
    authority: &str,
    request: &Request<B>,
) -> Response<Full<Bytes>> {
    if request.method() != Method::GET && request.method() != Method::HEAD {
        return refuse(StatusCode::METHOD_NOT_ALLOWED);
    }
    if !host_matches(request.headers().get(HOST), authority) {
        // Rebinding, or a client that built its own URL. Either way this is
        // not a request the daemon handed out.
        tracing::warn!("refusing an artifact request whose Host is not the loopback authority");
        return refuse(StatusCode::MISDIRECTED_REQUEST);
    }
    let path = request.uri().path();
    let Some(segments) = clean_segments(path) else {
        return refuse(StatusCode::BAD_REQUEST);
    };

    if let Some(token) = path.strip_prefix(REVISION_PREFIX) {
        return revision(store, token);
    }
    let [conversation, token] = segments.as_slice() else {
        return refuse(StatusCode::NOT_FOUND);
    };
    let Ok(conversation) = Uuid::parse_str(conversation) else {
        return refuse(StatusCode::NOT_FOUND);
    };
    if !is_token(token) {
        return refuse(StatusCode::NOT_FOUND);
    }
    let Some(found) = store.locate(conversation, token) else {
        return refuse(StatusCode::NOT_FOUND);
    };
    // Read synchronously, the same call `store.rs` makes for the same reason:
    // the file is capped, it is local, and an async filesystem API would buy
    // nothing but a second way to be wrong about ordering.
    let Ok(html) = fs::read_to_string(&found.path) else {
        return refuse(StatusCode::NOT_FOUND);
    };
    let nonce = mint_nonce();
    let body = inject(&html, &nonce, token, found.revision);
    let mut response = Response::new(Full::new(Bytes::from(body)));
    harden(&mut response, &nonce);
    set(&mut response, "content-type", "text/html; charset=utf-8");
    response
}

/// Answer the reload shim's poll with the revision the token stands at.
fn revision(store: &ArtifactStore, token: &str) -> Response<Full<Bytes>> {
    if !is_token(token) {
        return refuse(StatusCode::NOT_FOUND);
    }
    let Some(revision) = store.revision(token) else {
        return refuse(StatusCode::NOT_FOUND);
    };
    let mut response = Response::new(Full::new(Bytes::from(revision.to_string())));
    harden(&mut response, "");
    set(&mut response, "content-type", "text/plain; charset=utf-8");
    response
}

/// A body-less refusal. Every one of them carries the same hardening headers
/// as a hit, so a probe learns nothing from the difference.
fn refuse(status: StatusCode) -> Response<Full<Bytes>> {
    let mut response = Response::new(Full::new(Bytes::new()));
    *response.status_mut() = status;
    harden(&mut response, "");
    response
}

/// Put the containment on a response.
fn harden(response: &mut Response<Full<Bytes>>, nonce: &str) {
    set(
        response,
        "content-security-policy",
        &CSP.replace("{nonce}", nonce),
    );
    set(response, "x-content-type-options", "nosniff");
    set(response, "referrer-policy", "no-referrer");
    set(response, "cross-origin-opener-policy", "same-origin");
    set(response, "cross-origin-resource-policy", "same-origin");
    set(response, "cache-control", "no-store");
}

/// Set one header, dropping it rather than panicking on a value that will not
/// encode. Every value here is ASCII this module built, so the fallback never
/// fires; it exists so a header cannot take the daemon down.
fn set(response: &mut Response<Full<Bytes>>, name: &'static str, value: &str) {
    if let Ok(value) = HeaderValue::from_str(value) {
        response.headers_mut().insert(name, value);
    }
}

/// Whether the request's `Host` is the loopback authority this run bound.
fn host_matches(header: Option<&HeaderValue>, authority: &str) -> bool {
    header.and_then(|value| value.to_str().ok()) == Some(authority)
}

/// Split a request path into segments, refusing anything that is not a plain
/// path of plain segments.
///
/// Percent escapes are refused rather than decoded. The daemon builds every
/// URL it hands out and none of them needs an escape, so a request carrying
/// one is either a probe or a client that invented a path, and decoding it
/// would be the first half of a traversal bug.
#[must_use]
pub fn clean_segments(path: &str) -> Option<Vec<String>> {
    if !path.starts_with('/') || path.contains('%') || path.contains('\\') {
        return None;
    }
    let mut segments = Vec::new();
    for segment in path.split('/').skip(1) {
        if segment.is_empty() || segment == "." || segment == ".." {
            return None;
        }
        segments.push(segment.to_owned());
    }
    Some(segments)
}

/// A fresh script nonce, 32 hex characters from a v4 uuid.
///
/// Minted per response, never stored, so markup written before the request
/// cannot carry it and a page cannot learn one from a previous load.
fn mint_nonce() -> String {
    Uuid::new_v4().simple().to_string()
}

/// Put the reload shim into a page.
///
/// The file on disk is never touched: what the model wrote is what the
/// transcript's `code_block` says it wrote, and adding a script to it would
/// make those two disagree. The shim exists only in the response.
///
/// Injected before `</body>` when there is one, appended otherwise. Both land
/// in the body once the parser is done, and appending is what a fragment with
/// no `<body>` at all needs.
#[must_use]
pub fn inject(html: &str, nonce: &str, token: &str, revision: u32) -> String {
    let shim = format!(
        "<script nonce=\"{nonce}\">\
(function(){{var at=\"{revision}\";setInterval(function(){{\
fetch(\"{REVISION_PREFIX}{token}\",{{cache:\"no-store\"}})\
.then(function(r){{return r.text();}})\
.then(function(v){{if(v!==at)location.reload();}})\
.catch(function(){{}});}},{POLL_MS});}})();\
</script>"
    );
    match html.to_ascii_lowercase().rfind("</body>") {
        Some(at) => format!("{}{shim}{}", &html[..at], &html[at..]),
        None => format!("{html}{shim}"),
    }
}
