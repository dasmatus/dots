//! The loopback artifact server: what it serves, what it refuses, and the
//! containment header every answer carries.
//!
//! `answer` is driven directly with hand-built requests rather than over a
//! socket. That is deliberate: the interesting cases are hostile paths, and a
//! test that has to spell them into a real HTTP client spends its effort on
//! the client rather than on the guard.
//!
//! No browser is involved and none is needed. What a browser does with the
//! CSP is the browser's job; what this daemon must do is send it, refuse
//! everything outside the artifact root, and move the revision when a page is
//! rewritten. All three are checked here.

use std::fs;
use std::path::PathBuf;

use http_body_util::{BodyExt, Full};
use hyper::body::Bytes;
use hyper::{Request, Response, StatusCode};
use uuid::Uuid;

use ask_daemon::artifact::serve::{answer, clean_segments, inject, CSP};
use ask_daemon::artifact::ArtifactStore;

/// The authority every request in this file claims, and the one the server is
/// told it bound.
const AUTHORITY: &str = "127.0.0.1:41234";

/// A scratch state root that goes away with the guard.
struct Scratch {
    root: PathBuf,
}

impl Scratch {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("dots-ask-serve-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("temp root is creatable");
        Self { root }
    }

    fn store(&self) -> ArtifactStore {
        ArtifactStore::open(&self.root).expect("the artifact root opens")
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        drop(fs::remove_dir_all(&self.root));
    }
}

/// One GET with a well-formed Host, which is what the daemon's own URLs look
/// like.
fn get(path: &str) -> Request<()> {
    Request::builder()
        .method("GET")
        .uri(path)
        .header("host", AUTHORITY)
        .body(())
        .expect("the request builds")
}

/// The body of one answer, as text.
///
/// `Full` is a body that is already in memory, so collecting it never waits
/// on anything. A one-shot current-thread runtime is the cheapest way to say
/// that in a test that has no other reason to be async.
fn body_of(response: Response<Full<Bytes>>) -> String {
    let bytes = tokio::runtime::Builder::new_current_thread()
        .build()
        .expect("a current-thread runtime builds")
        .block_on(response.into_body().collect())
        .expect("a Full body always collects")
        .to_bytes();
    String::from_utf8_lossy(&bytes).into_owned()
}

/// The status and body of one answer.
fn ask(store: &ArtifactStore, request: &Request<()>) -> (StatusCode, String) {
    let response = answer(store, AUTHORITY, request);
    let status = response.status();
    (status, body_of(response))
}

/// The named header off one answer.
fn header(store: &ArtifactStore, request: &Request<()>, name: &str) -> String {
    answer(store, AUTHORITY, request)
        .headers()
        .get(name)
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
        .to_owned()
}

#[test]
fn a_written_page_comes_back_with_the_reload_shim() {
    let scratch = Scratch::new();
    let store = scratch.store();
    let conversation = Uuid::new_v4();
    let written = store
        .write(conversation, "<html><body><h1>hi</h1></body></html>")
        .expect("the page writes");

    let (status, body) = ask(
        &store,
        &get(&format!("/{conversation}/{}", written.artifact)),
    );
    assert_eq!(status, StatusCode::OK);
    assert!(body.contains("<h1>hi</h1>"), "the page itself: {body}");
    assert!(
        body.contains(&format!("/_dots/rev/{}", written.artifact)),
        "the shim polls its own revision: {body}"
    );
    assert!(
        body.contains("location.reload()"),
        "a reload, not a relaunch: {body}"
    );
}

#[test]
fn a_rewrite_moves_the_number_the_shim_polls() {
    // This is the whole reload signal, and it needs no browser to check: the
    // shim compares the number it was served with the number this endpoint
    // reports, and reloads when they differ.
    let scratch = Scratch::new();
    let store = scratch.store();
    let conversation = Uuid::new_v4();
    let written = store.write(conversation, "<p>one</p>").expect("writes");

    let poll = get(&format!("/_dots/rev/{}", written.artifact));
    assert_eq!(ask(&store, &poll), (StatusCode::OK, "1".to_owned()));

    store.write(conversation, "<p>two</p>").expect("rewrites");
    assert_eq!(ask(&store, &poll), (StatusCode::OK, "2".to_owned()));

    // And the page a fresh load gets now carries the new number, so a window
    // opened after the rewrite does not immediately reload itself.
    let (_, body) = ask(
        &store,
        &get(&format!("/{conversation}/{}", written.artifact)),
    );
    assert!(body.contains("var at=\"2\""), "{body}");
    assert!(body.contains("<p>two</p>"), "{body}");
}

#[test]
fn the_file_on_disk_never_gains_the_shim() {
    // The transcript's `code_block` says what the model wrote. If the daemon
    // edited the file, the two would disagree about it.
    let scratch = Scratch::new();
    let store = scratch.store();
    let conversation = Uuid::new_v4();
    let written = store
        .write(conversation, "<html><body>x</body></html>")
        .expect("writes");
    drop(ask(
        &store,
        &get(&format!("/{conversation}/{}", written.artifact)),
    ));
    assert_eq!(
        fs::read_to_string(&written.path).expect("the file is there"),
        "<html><body>x</body></html>",
        "serving must not rewrite the artifact"
    );
}

#[test]
fn a_traversal_path_serves_nothing_outside_the_artifact_root() {
    // The required path-traversal case. A file with a recognisable body is
    // put where a `..` walk would land, and every spelling of the walk is
    // tried. Nothing may come back but a refusal, and the secret must not
    // appear in any body.
    let scratch = Scratch::new();
    let store = scratch.store();
    let conversation = Uuid::new_v4();
    let written = store.write(conversation, "<p>real</p>").expect("writes");

    let secret = scratch.root.join("secret.html");
    fs::write(&secret, "<p>THE-SECRET</p>").expect("the bait writes");

    let hostile = [
        "/../secret.html",
        "/../../etc/passwd",
        &format!("/{conversation}/../../secret.html"),
        &format!("/{conversation}/..%2f..%2fsecret.html"),
        "/%2e%2e/%2e%2e/secret.html",
        "/....//secret.html",
        &format!("/{conversation}/./{}", written.artifact),
        "/_dots/rev/../../secret.html",
        &format!("/{conversation}/{}/../../secret.html", written.artifact),
        "//secret.html",
        "/artifacts/secret.html",
    ];
    for path in hostile {
        let (status, body) = ask(&store, &get(path));
        assert!(
            status.is_client_error(),
            "{path} must be refused, got {status}"
        );
        assert!(
            !body.contains("THE-SECRET"),
            "{path} served a file outside the artifact root"
        );
    }

    // The honest control: the real URL still works, so the refusals above are
    // the guard rather than a server that answers nothing.
    let (status, body) = ask(
        &store,
        &get(&format!("/{conversation}/{}", written.artifact)),
    );
    assert_eq!(status, StatusCode::OK);
    assert!(body.contains("<p>real</p>"));
}

#[test]
fn a_registered_symlink_out_of_the_root_is_refused_rather_than_followed() {
    // This is the case the containment check exists for, and the one that
    // would leak without it. The token lookup is a map, so a hostile URL
    // cannot invent a path; a symlink can, because a page's own file name is
    // a path the store adopts at startup. Canonicalizing both sides before
    // comparing is what turns that into a refusal.
    let scratch = Scratch::new();
    let conversation = Uuid::new_v4();
    let token = {
        let store = scratch.store();
        store
            .write(conversation, "<p>real</p>")
            .expect("writes")
            .artifact
    };

    let secret = scratch.root.join("secret.html");
    fs::write(&secret, "<p>THE-SECRET</p>").expect("the bait writes");
    let page = scratch
        .root
        .join("artifacts")
        .join(conversation.to_string())
        .join(format!("{token}.html"));
    fs::remove_file(&page).expect("the real page goes away");
    std::os::unix::fs::symlink(&secret, &page).expect("the symlink is made");

    // A restart adopts whatever is in the directory, symlink included.
    let reopened = scratch.store();
    assert!(
        reopened.locate(conversation, &token).is_none(),
        "a page resolving outside the artifact root must not be served"
    );
    let (status, body) = ask(&reopened, &get(&format!("/{conversation}/{token}")));
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert!(!body.contains("THE-SECRET"), "{body}");
}

#[test]
fn a_request_from_a_rebound_host_is_refused() {
    // DNS rebinding is the one attack a loopback listener gets for free: a
    // page the user is browsing resolves its own name to 127.0.0.1, loads
    // this port under its own origin and reads the answer. Checking Host is
    // what stops it, and it costs one comparison.
    let scratch = Scratch::new();
    let store = scratch.store();
    let conversation = Uuid::new_v4();
    let written = store.write(conversation, "<p>real</p>").expect("writes");
    let path = format!("/{conversation}/{}", written.artifact);

    for host in ["evil.example", "evil.example:41234", "localhost:41234", ""] {
        let request = Request::builder()
            .method("GET")
            .uri(path.as_str())
            .header("host", host)
            .body(())
            .expect("the request builds");
        let (status, body) = ask(&store, &request);
        assert_eq!(
            status,
            StatusCode::MISDIRECTED_REQUEST,
            "Host {host:?} must be refused"
        );
        assert!(!body.contains("<p>real</p>"), "Host {host:?} was served");
    }
}

#[test]
fn nothing_but_get_and_head_is_answered() {
    let scratch = Scratch::new();
    let store = scratch.store();
    let conversation = Uuid::new_v4();
    let written = store.write(conversation, "<p>real</p>").expect("writes");
    let path = format!("/{conversation}/{}", written.artifact);

    for method in ["POST", "PUT", "DELETE", "PATCH", "OPTIONS"] {
        let request = Request::builder()
            .method(method)
            .uri(path.as_str())
            .header("host", AUTHORITY)
            .body(())
            .expect("the request builds");
        let (status, _) = ask(&store, &request);
        assert_eq!(status, StatusCode::METHOD_NOT_ALLOWED, "{method} answered");
    }
}

#[test]
fn every_answer_carries_the_containment_header() {
    // Including the refusals, so a probe learns nothing from the difference.
    let scratch = Scratch::new();
    let store = scratch.store();
    let conversation = Uuid::new_v4();
    let written = store.write(conversation, "<p>real</p>").expect("writes");

    for path in [
        format!("/{conversation}/{}", written.artifact),
        "/nothing/here".to_owned(),
    ] {
        let policy = header(&store, &get(&path), "content-security-policy");
        for directive in [
            "default-src 'none'",
            "connect-src 'self'",
            "form-action 'none'",
            "frame-ancestors 'none'",
            "base-uri 'none'",
            "sandbox allow-same-origin allow-scripts",
        ] {
            assert!(policy.contains(directive), "{path}: {policy}");
        }
        assert!(
            !policy.contains("unsafe-eval"),
            "{path} allows eval: {policy}"
        );
        assert!(
            !policy.contains("script-src 'self'") && !policy.contains("script-src 'unsafe-inline'"),
            "{path} lets model script run: {policy}"
        );
        assert_eq!(
            header(&store, &get(&path), "x-content-type-options"),
            "nosniff"
        );
        assert_eq!(
            header(&store, &get(&path), "referrer-policy"),
            "no-referrer"
        );
        assert_eq!(
            header(&store, &get(&path), "cross-origin-resource-policy"),
            "same-origin"
        );
    }
}

#[test]
fn the_script_nonce_is_fresh_on_every_response() {
    // A nonce a page could learn once and then reuse would be no nonce at
    // all: the model's own markup could carry it on the next load.
    let scratch = Scratch::new();
    let store = scratch.store();
    let conversation = Uuid::new_v4();
    let written = store.write(conversation, "<p>real</p>").expect("writes");
    let request = get(&format!("/{conversation}/{}", written.artifact));

    let first = header(&store, &request, "content-security-policy");
    let second = header(&store, &request, "content-security-policy");
    assert_ne!(first, second, "the nonce must not repeat");
    assert!(!first.contains("{nonce}"), "the template was not filled in");
    assert!(
        !second.contains("{nonce}"),
        "the template was not filled in"
    );

    // And the shim's own tag carries the nonce the same response sent, or the
    // browser refuses to run it and the reload never fires.
    let response = answer(&store, AUTHORITY, &request);
    let policy = response
        .headers()
        .get("content-security-policy")
        .and_then(|value| value.to_str().ok())
        .expect("the policy is there")
        .to_owned();
    let body = body_of(response);
    let nonce = policy
        .split("'nonce-")
        .nth(1)
        .and_then(|rest| rest.split('\'').next())
        .expect("the policy names a nonce");
    assert!(
        body.contains(&format!("<script nonce=\"{nonce}\">")),
        "the shim must carry this response's nonce"
    );
}

#[test]
fn the_policy_template_names_a_nonce_and_no_blanket_script_source() {
    // Pinned as a constant rather than only through a response, because this
    // is the sentence the whole artifact design rests on: model script does
    // not run, and only a nonce this process minted does.
    assert!(CSP.contains("script-src 'nonce-{nonce}'"), "{CSP}");
    assert!(!CSP.contains("'unsafe-inline'; script"), "{CSP}");
    assert!(CSP.contains("img-src 'self' data:"), "{CSP}");
}

#[test]
fn a_path_with_a_percent_escape_or_a_dot_segment_is_not_a_path() {
    // The daemon builds every URL it hands out and none needs an escape, so
    // one is refused rather than decoded. Decoding would be the first half of
    // a traversal bug.
    assert!(clean_segments("/a/b").is_some());
    assert!(clean_segments("a/b").is_none(), "must start with a slash");
    assert!(clean_segments("/a/../b").is_none());
    assert!(clean_segments("/a/./b").is_none());
    assert!(clean_segments("/a//b").is_none());
    assert!(clean_segments("/a/%2e%2e/b").is_none());
    assert!(clean_segments("/a\\b").is_none());
    assert!(clean_segments("/").is_none());
}

#[test]
fn a_page_with_no_body_tag_still_gets_the_shim() {
    // A model that emits a fragment rather than a document is normal, and a
    // fragment that never reloads would be a silent half-feature.
    let shimmed = inject(
        "<h1>bare</h1>",
        "abc",
        "0123456789abcdef0123456789abcdef",
        3,
    );
    assert!(shimmed.starts_with("<h1>bare</h1>"));
    assert!(shimmed.contains("<script nonce=\"abc\">"));

    let document = inject(
        "<html><body><p>x</p></body></html>",
        "abc",
        "0123456789abcdef0123456789abcdef",
        1,
    );
    assert!(
        document.ends_with("</body></html>"),
        "the shim goes inside the body: {document}"
    );
    assert!(document.contains("<script nonce=\"abc\">"));
}
