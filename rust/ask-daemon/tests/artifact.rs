//! The artifact store: where a page lands, how it is addressed, how a
//! rewrite is seen, and what a restart can rebuild.

use std::fs;
use std::path::PathBuf;

use uuid::Uuid;

use ask_daemon::artifact::{is_artifact_language, is_token, ArtifactStore, MAX_ARTIFACT_BYTES};
use ask_daemon::AskError;

/// A scratch state root that goes away with the guard.
struct Scratch {
    root: PathBuf,
}

impl Scratch {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("dots-ask-art-{}", Uuid::new_v4()));
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

#[test]
fn only_html_leaves_the_pane() {
    // Markdown, code, SVG and images all render in a QML Text. Sending any of
    // them to a browser window would trade a working renderer for a window
    // and a security question.
    assert!(is_artifact_language(Some("html")));
    assert!(is_artifact_language(Some("HTML")));
    assert!(is_artifact_language(Some("htm")));
    assert!(!is_artifact_language(Some("rust")));
    assert!(!is_artifact_language(Some("svg")));
    assert!(!is_artifact_language(Some("markdown")));
    assert!(!is_artifact_language(None));
}

#[test]
fn a_written_page_is_on_disk_and_locatable() {
    let scratch = Scratch::new();
    let store = scratch.store();
    let conversation = Uuid::new_v4();

    let written = store
        .write(conversation, "<h1>hello</h1>")
        .expect("the page writes");
    assert_eq!(written.revision, 1);
    assert_eq!(written.bytes, 14);
    assert!(is_token(&written.artifact), "{}", written.artifact);
    assert_eq!(
        fs::read_to_string(&written.path).expect("the file is there"),
        "<h1>hello</h1>"
    );

    let found = store
        .locate(conversation, &written.artifact)
        .expect("the token resolves");
    assert_eq!(found.path, written.path);
    assert_eq!(found.revision, 1);
}

#[test]
fn a_rewrite_keeps_the_url_and_raises_the_revision() {
    // The whole reload story rests on this: an already-open window is at one
    // URL, so a regenerated page has to land on the same one and only the
    // revision may move.
    let scratch = Scratch::new();
    let store = scratch.store();
    let conversation = Uuid::new_v4();

    let first = store
        .write(conversation, "<p>one</p>")
        .expect("first write");
    let second = store
        .write(conversation, "<p>two</p>")
        .expect("second write");

    assert_eq!(first.artifact, second.artifact, "the token must not move");
    assert_eq!(first.path, second.path, "the file must not move");
    assert_eq!(second.revision, 2);
    assert_eq!(
        store.revision(&second.artifact),
        Some(2),
        "the reload endpoint reports the new revision"
    );
    assert_eq!(
        fs::read_to_string(&second.path).expect("the file is there"),
        "<p>two</p>"
    );
}

#[test]
fn two_threads_get_two_tokens() {
    let scratch = Scratch::new();
    let store = scratch.store();
    let one = store.write(Uuid::new_v4(), "<p>a</p>").expect("writes");
    let two = store.write(Uuid::new_v4(), "<p>b</p>").expect("writes");
    assert_ne!(one.artifact, two.artifact);
    assert_ne!(one.path, two.path);
}

#[test]
fn a_token_does_not_resolve_under_another_conversation() {
    // The path is `/<conversation>/<token>`, and both halves have to match.
    // A client that knows one thread's token must not be able to walk it
    // onto another thread.
    let scratch = Scratch::new();
    let store = scratch.store();
    let mine = Uuid::new_v4();
    let theirs = Uuid::new_v4();
    let written = store.write(mine, "<p>mine</p>").expect("writes");

    assert!(store.locate(mine, &written.artifact).is_some());
    assert!(
        store.locate(theirs, &written.artifact).is_none(),
        "a token must not resolve under a thread it does not belong to"
    );
}

#[test]
fn a_token_that_was_never_written_does_not_resolve() {
    let scratch = Scratch::new();
    let store = scratch.store();
    let conversation = Uuid::new_v4();
    store.write(conversation, "<p>x</p>").expect("writes");
    assert!(store
        .locate(conversation, "00000000000000000000000000000000")
        .is_none());
    assert_eq!(store.revision("00000000000000000000000000000000"), None);
}

#[test]
fn a_page_over_the_cap_is_refused_rather_than_written() {
    // The write happens inside the hub's critical section, so an unbounded
    // one would hold every other conversation for as long as the disk took.
    let scratch = Scratch::new();
    let store = scratch.store();
    let huge = "x".repeat(MAX_ARTIFACT_BYTES + 1);
    match store.write(Uuid::new_v4(), &huge) {
        Err(AskError::ArtifactTooLarge { bytes, cap }) => {
            assert_eq!(bytes, MAX_ARTIFACT_BYTES + 1);
            assert_eq!(cap, MAX_ARTIFACT_BYTES);
        }
        other => panic!("a page over the cap must be refused: {other:?}"),
    }
}

#[test]
fn a_restart_finds_the_pages_a_previous_run_wrote() {
    // A replayed `artifact` event carries a token and no URL, so the token
    // has to keep resolving across a restart or every old artifact in a
    // thread becomes unopenable.
    let scratch = Scratch::new();
    let conversation = Uuid::new_v4();
    let written = {
        let store = scratch.store();
        store.write(conversation, "<p>kept</p>").expect("writes")
    };

    let reopened = scratch.store();
    let found = reopened
        .locate(conversation, &written.artifact)
        .expect("the token still resolves after a restart");
    assert_eq!(found.path, written.path);
}

#[test]
fn deleting_a_thread_takes_its_pages_with_it() {
    let scratch = Scratch::new();
    let store = scratch.store();
    let conversation = Uuid::new_v4();
    let written = store.write(conversation, "<p>gone</p>").expect("writes");

    store.forget(conversation).expect("the thread is forgotten");

    assert!(!written.path.exists(), "the file must be gone");
    assert!(
        store.locate(conversation, &written.artifact).is_none(),
        "the token must stop resolving"
    );
    // Twice is not an error: a delete that already ran leaves nothing to do.
    store.forget(conversation).expect("a second forget is fine");
}

#[test]
fn a_title_comes_off_the_page_and_a_missing_one_is_null() {
    let scratch = Scratch::new();
    let store = scratch.store();
    let titled = store
        .write(
            Uuid::new_v4(),
            "<html><head><TITLE>Sales dashboard</TITLE></head><body></body></html>",
        )
        .expect("writes");
    assert_eq!(titled.title.as_deref(), Some("Sales dashboard"));

    let bare = store
        .write(Uuid::new_v4(), "<p>no head at all</p>")
        .expect("writes");
    assert_eq!(bare.title, None);

    let empty = store
        .write(Uuid::new_v4(), "<title>   </title>")
        .expect("writes");
    assert_eq!(empty.title, None, "whitespace is not a title");
}

#[test]
fn a_token_is_thirty_two_hex_characters_and_nothing_else() {
    // This is the shape check the request path is tested against before any
    // lookup runs, so what it rejects is load-bearing.
    assert!(is_token("9c2b4d1e7a0f4b6c8d3e5f7a1b2c3d4e"));
    assert!(!is_token(""));
    assert!(!is_token(".."));
    assert!(!is_token("9c2b4d1e7a0f4b6c8d3e5f7a1b2c3d4"));
    assert!(!is_token("9c2b4d1e7a0f4b6c8d3e5f7a1b2c3d4ee"));
    assert!(!is_token("../../../../etc/passwd/aaaaaaaaa"));
    assert!(!is_token("9c2b4d1e7a0f4b6c8d3e5f7a1b2c3d4z"));
}
