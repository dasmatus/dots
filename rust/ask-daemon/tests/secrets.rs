//! Pins the deadline on a keyring lookup, driven by a fake lookup command
//! rather than by the real keyring.
//!
//! The timeout is the whole point of `secrets.rs`. `secret-tool lookup`
//! unlocks the collection unconditionally, libsecret's synchronous resolve
//! carries no deadline, and this machine logs in through greetd, which does
//! not unlock the keyring. So on a cold boot the lookup blocks on a dialog
//! nobody is watching, and without a cap it blocks forever.
//!
//! `a_lookup_that_would_block_gives_up_rather_than_hanging` is the test that
//! matters. It uses a shell script that sleeps far longer than the deadline,
//! so if the cap ever stops working the test hangs and the suite says so,
//! which is the same failure a user would see.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use uuid::Uuid;

use ask_daemon::secrets::{Secret, SecretStore, DEFAULT_TIMEOUT, SERVICE};

/// The deadline the two timeout tests give a lookup.
///
/// Short, so a test that has to wait one out finishes in a blink. It is only
/// used where the deadline firing is the thing under test.
const SHORT_TIMEOUT: Duration = Duration::from_millis(300);

/// The deadline every other test gives a lookup.
///
/// Generous on purpose. Those tests are about what a lookup returns, not
/// about the clock, and a fork plus an `sh` startup can take a surprising
/// while when nine test binaries are running at once. A tight budget there
/// buys nothing and produces a test that fails under load and passes alone,
/// which is worse than no test.
const PATIENT_TIMEOUT: Duration = Duration::from_secs(30);

/// A directory holding a fake lookup command, removed on drop.
struct FakeKeyring {
    root: PathBuf,
    program: PathBuf,
}

impl FakeKeyring {
    /// Write a shell script that stands in for `secret-tool`.
    ///
    /// A real script rather than a mocking framework, because what is under
    /// test is process handling: the exit status, the stdout, and whether a
    /// child that never exits gets killed.
    fn new(body: &str) -> Self {
        let root = std::env::temp_dir().join(format!("dots-ask-secrets-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("temp root is creatable");
        let program = root.join("fake-secret-tool");
        fs::write(&program, format!("#!/bin/sh\n{body}\n")).expect("the script writes");
        fs::set_permissions(&program, fs::Permissions::from_mode(0o755))
            .expect("the script is executable");
        Self { root, program }
    }

    /// A store pointed at this fake, with a deadline that will not fire.
    fn store(&self) -> SecretStore {
        SecretStore::new(&self.program, PATIENT_TIMEOUT)
    }

    /// A store pointed at this fake, with a deadline that will.
    fn impatient_store(&self) -> SecretStore {
        SecretStore::new(&self.program, SHORT_TIMEOUT)
    }

    /// Where the script wrote down what it was called with.
    fn call_log(&self) -> Option<String> {
        fs::read_to_string(self.root.join("argv.log")).ok()
    }

    /// The scratch directory, so a script can write into it.
    fn root(&self) -> &Path {
        &self.root
    }
}

impl Drop for FakeKeyring {
    fn drop(&mut self) {
        drop(fs::remove_dir_all(&self.root));
    }
}

#[tokio::test]
async fn a_lookup_that_would_block_gives_up_rather_than_hanging() {
    // A locked collection with an unanswered unlock dialog behind it. Sixty
    // seconds is far past the deadline, so this test hangs for a minute if
    // the cap is ever removed, which is the failure a user sees on a cold
    // boot.
    let keyring = FakeKeyring::new("sleep 60");
    let store = keyring.impatient_store();

    let started = Instant::now();
    let found = store.lookup("anthropic-api-key").await;
    let waited = started.elapsed();

    assert!(
        matches!(found, Secret::Missing(_)),
        "a lookup that ran out the clock is unavailable, not a hang: {found:?}"
    );
    assert!(
        waited < SHORT_TIMEOUT * 8,
        "the deadline did not fire: waited {waited:?}"
    );
    let detail = found.detail().expect("a miss carries its reason");
    assert!(
        detail.contains("did not answer"),
        "the reason names the timeout: {detail}"
    );
    assert!(
        detail.contains("unlock"),
        "and says what to do about it: {detail}"
    );
}

#[tokio::test]
async fn a_lookup_that_times_out_leaves_no_child_running() {
    // kill_on_drop is what makes this true. Without it, a cold boot with
    // several providers configured would leave a fan of blocked secret-tool
    // processes behind, each holding an unlock prompt open.
    let keyring = FakeKeyring::new(concat!(
        "here=\"$(dirname \"$0\")\"\n",
        "echo started > \"$here/started\"\n",
        "sleep 60\n",
        "echo finished > \"$here/finished\"",
    ));
    let store = keyring.impatient_store();
    assert!(matches!(
        store.lookup("anthropic-api-key").await,
        Secret::Missing(_)
    ));
    assert!(
        keyring.root().join("started").exists(),
        "the fake really did run, so the next assertion means something"
    );
    tokio::time::sleep(SHORT_TIMEOUT * 2).await;
    assert!(
        !keyring.root().join("finished").exists(),
        "the child ran to completion, so it was never killed"
    );
}

#[tokio::test]
async fn a_key_that_is_there_comes_back() {
    let keyring = FakeKeyring::new("printf 'sk-ant-secret\\n'");
    let store = keyring.store();
    let found = store.lookup("anthropic-api-key").await;
    assert_eq!(
        found.value(),
        Some("sk-ant-secret"),
        "the trailing newline secret-tool prints is stripped"
    );
    assert_eq!(found.detail(), None);
}

#[tokio::test]
async fn a_key_that_is_not_there_is_unavailable_rather_than_fatal() {
    // secret-tool exits non-zero and prints nothing for a missing item.
    let keyring = FakeKeyring::new("exit 1");
    let store = keyring.store();
    let found = store.lookup("anthropic-api-key").await;
    assert!(matches!(found, Secret::Missing(_)));
    let detail = found.detail().expect("a miss carries its reason");
    assert!(
        detail.contains("anthropic-api-key"),
        "the reason names the attribute so a person can store it: {detail}"
    );
}

#[tokio::test]
async fn an_empty_key_counts_as_missing() {
    let keyring = FakeKeyring::new("printf ''");
    let store = keyring.store();
    assert!(matches!(
        store.lookup("anthropic-api-key").await,
        Secret::Missing(_)
    ));
}

#[tokio::test]
async fn a_machine_with_no_secret_tool_degrades_rather_than_panicking() {
    let store = SecretStore::new("/nonexistent/secret-tool", PATIENT_TIMEOUT);
    let found = store.lookup("anthropic-api-key").await;
    assert!(matches!(found, Secret::Missing(_)));
    assert!(
        found
            .detail()
            .expect("a miss carries its reason")
            .contains("cannot run"),
        "the reason says the program is not there"
    );
}

#[tokio::test]
async fn a_lookup_asks_for_the_attribute_under_the_dots_ask_service() {
    let keyring = FakeKeyring::new("echo \"$@\" > \"$(dirname \"$0\")/argv.log\"\nprintf 'v\\n'");
    let store = keyring.store();
    assert_eq!(store.lookup("openai-api-key").await.value(), Some("v"));

    let argv = keyring.call_log().expect("the fake recorded its argv");
    assert_eq!(
        argv.trim(),
        format!("lookup service {SERVICE} attribute openai-api-key"),
        "the argv is the one nix/home/edupage-mcp.nix uses"
    );
}

#[tokio::test]
async fn a_lookup_runs_at_most_once_per_attribute() {
    // The cache is what keeps laziness from costing a ten-second wait per
    // send. It caches a miss too, which is why the second call here still
    // reports a miss without re-running the script.
    let keyring = FakeKeyring::new(
        "log=\"$(dirname \"$0\")/argv.log\"\nprintf 'x' >> \"$log\"\nprintf 'v\\n'",
    );
    let store = keyring.store();
    for _ in 0..3 {
        assert_eq!(store.lookup("openai-api-key").await.value(), Some("v"));
    }
    assert_eq!(
        keyring.call_log().expect("the fake recorded its runs"),
        "x",
        "three lookups, one process"
    );
}

#[tokio::test]
async fn nothing_is_cached_before_a_lookup_runs() {
    // This is the laziness rule as the registry sees it: `cached` never
    // causes a lookup, so a backend list can be built without touching the
    // keyring at all.
    let keyring = FakeKeyring::new("printf 'v\\n'");
    let store = keyring.store();
    assert_eq!(
        store.cached("anthropic-api-key"),
        None,
        "asking what is cached must not cause a lookup"
    );
    assert!(
        keyring.call_log().is_none(),
        "and must not run the program at all"
    );

    store.lookup("anthropic-api-key").await;
    assert!(
        store.cached("anthropic-api-key").is_some(),
        "after a real lookup the answer is there for the registry to read"
    );
}

#[test]
fn the_default_deadline_is_the_one_the_nix_wrapper_established() {
    assert_eq!(
        DEFAULT_TIMEOUT,
        Duration::from_secs(10),
        "nix/home/edupage-mcp.nix:160 caps every lookup at ten seconds, and this is the same cap"
    );
}
