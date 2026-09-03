//! Pins the approval rules: deny by default, and what a decision covers.
//!
//! Two of these are the brief's own acceptance criteria: an unknown tool is
//! denied without asking anything, and an allow-always decision survives a
//! reload. The rest hold the key down, because the key is where "allow
//! always" could quietly become "allow more than the person meant".

use std::fs;
use std::path::PathBuf;

use serde_json::json;
use uuid::Uuid;

use ask_daemon::policy::{Policy, PolicyKey, Verdict};
use ask_daemon::proto::{PermissionDecision, PermissionScope};

/// A directory that removes itself.
struct Scratch {
    root: PathBuf,
}

impl Scratch {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("dots-ask-policy-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("temp root is creatable");
        Self { root }
    }

    /// Where `policy.json` goes in this scratch directory.
    fn path(&self) -> PathBuf {
        self.root.join("policy.json")
    }

    /// A policy loaded from this scratch directory.
    fn open(&self) -> Policy {
        Policy::open(self.path()).expect("a policy file loads")
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        drop(fs::remove_dir_all(&self.root));
    }
}

/// The key a `Bash(ls)` call in one checkout produces.
fn bash_ls() -> PolicyKey {
    PolicyKey::new(
        "ollama",
        "Bash",
        &PathBuf::from("/home/matus/dots"),
        &json!({"command": "ls"}),
    )
}

#[test]
fn nothing_is_allowed_by_default() {
    let scratch = Scratch::new();
    let policy = scratch.open();
    assert_eq!(
        policy.decide(Uuid::new_v4(), &bash_ls()),
        Verdict::Ask,
        "with no rule, the daemon asks rather than assuming"
    );
}

#[test]
fn an_unknown_tool_is_denied_without_asking_anything() {
    let scratch = Scratch::new();
    let mut policy = scratch.open();
    // This is what mcp.rs discovered: two tools, and nothing else exists.
    policy.declare_tools([
        "searxng__web_search".to_owned(),
        "memory__recall".to_owned(),
    ]);

    let conversation = Uuid::new_v4();
    let unknown = PolicyKey::new("ollama", "Bash", &PathBuf::from("/tmp"), &json!({}));
    assert_eq!(
        policy.decide(conversation, &unknown),
        Verdict::Deny,
        "a tool no configured MCP server exposes is refused, not prompted"
    );

    // And an allow-always rule written for that name does not rescue it,
    // because there is still nothing to run.
    policy
        .remember(
            conversation,
            unknown.clone(),
            PermissionDecision::Allow,
            PermissionScope::Forever,
        )
        .expect("the rule writes");
    assert_eq!(
        policy.decide(conversation, &unknown),
        Verdict::Deny,
        "the tool-name gate sits in front of the rule store, not behind it"
    );
}

#[test]
fn a_declared_tool_is_still_asked_about() {
    let scratch = Scratch::new();
    let mut policy = scratch.open();
    policy.declare_tools(["searxng__web_search".to_owned()]);
    let known = PolicyKey::new(
        "ollama",
        "searxng__web_search",
        &PathBuf::from("/tmp"),
        &json!({"query": "nixos"}),
    );
    assert_eq!(
        policy.decide(Uuid::new_v4(), &known),
        Verdict::Ask,
        "existing is not the same as permitted"
    );
}

#[test]
fn an_allow_always_decision_survives_a_reload() {
    let scratch = Scratch::new();
    let conversation = Uuid::new_v4();

    let mut policy = scratch.open();
    policy
        .remember(
            conversation,
            bash_ls(),
            PermissionDecision::Allow,
            PermissionScope::Forever,
        )
        .expect("the rule writes");
    assert_eq!(policy.decide(conversation, &bash_ls()), Verdict::Allow);
    drop(policy);

    // A different daemon run, and a different conversation, because a
    // forever rule is not scoped to the thread that wrote it.
    let reloaded = scratch.open();
    assert_eq!(reloaded.forever_len(), 1, "the rule came back off disk");
    assert_eq!(
        reloaded.decide(Uuid::new_v4(), &bash_ls()),
        Verdict::Allow,
        "an allow-always decision survives a restart"
    );
}

#[test]
fn a_forever_rule_is_json_a_person_can_read() {
    // Section 5 promises this outright, so it is a test rather than a
    // comment: a person has to be able to open the file and delete a line.
    let scratch = Scratch::new();
    let mut policy = scratch.open();
    policy
        .remember(
            Uuid::new_v4(),
            bash_ls(),
            PermissionDecision::Allow,
            PermissionScope::Forever,
        )
        .expect("the rule writes");

    let text = fs::read_to_string(scratch.path()).expect("policy.json exists");
    assert!(text.contains("\"backend\": \"ollama\""), "readable: {text}");
    assert!(text.contains("\"tool\": \"Bash\""), "readable: {text}");
    assert!(
        text.contains("/home/matus/dots"),
        "the cwd is in the file: {text}"
    );
    assert!(
        text.contains("command"),
        "and so are the arguments it matched: {text}"
    );
    assert!(text.contains("\"decision\": \"allow\""), "readable: {text}");
}

#[test]
fn a_session_decision_does_not_reach_disk() {
    let scratch = Scratch::new();
    let conversation = Uuid::new_v4();
    let mut policy = scratch.open();
    policy
        .remember(
            conversation,
            bash_ls(),
            PermissionDecision::Allow,
            PermissionScope::Session,
        )
        .expect("a session rule needs no disk");
    assert_eq!(policy.decide(conversation, &bash_ls()), Verdict::Allow);

    assert!(
        !scratch.path().exists(),
        "a session rule must not write policy.json"
    );
    assert_eq!(
        scratch.open().decide(conversation, &bash_ls()),
        Verdict::Ask,
        "and it must not survive the daemon"
    );
}

#[test]
fn a_once_decision_does_not_outlive_the_call() {
    let scratch = Scratch::new();
    let conversation = Uuid::new_v4();
    let mut policy = scratch.open();
    policy
        .remember(
            conversation,
            bash_ls(),
            PermissionDecision::Allow,
            PermissionScope::Once,
        )
        .expect("a once rule stores nothing");
    assert_eq!(
        policy.decide(conversation, &bash_ls()),
        Verdict::Ask,
        "once means the call in flight and nothing after it"
    );
}

#[test]
fn a_session_rule_does_not_leak_into_another_thread() {
    let scratch = Scratch::new();
    let mut policy = scratch.open();
    let mine = Uuid::new_v4();
    policy
        .remember(
            mine,
            bash_ls(),
            PermissionDecision::Allow,
            PermissionScope::Session,
        )
        .expect("a session rule needs no disk");
    assert_eq!(policy.decide(mine, &bash_ls()), Verdict::Allow);
    assert_eq!(
        policy.decide(Uuid::new_v4(), &bash_ls()),
        Verdict::Ask,
        "another thread has decided nothing"
    );
}

#[test]
fn a_deleted_thread_takes_its_session_rules_with_it() {
    let scratch = Scratch::new();
    let mut policy = scratch.open();
    let conversation = Uuid::new_v4();
    policy
        .remember(
            conversation,
            bash_ls(),
            PermissionDecision::Allow,
            PermissionScope::Session,
        )
        .expect("a session rule needs no disk");
    policy.forget_session(conversation);
    assert_eq!(policy.decide(conversation, &bash_ls()), Verdict::Ask);
}

#[test]
fn allowing_one_command_does_not_allow_a_different_one() {
    // The reason the arguments are in the key. Without them, approving
    // `Bash(ls)` once would approve `Bash(rm -rf ~)` forever.
    let scratch = Scratch::new();
    let conversation = Uuid::new_v4();
    let mut policy = scratch.open();
    policy
        .remember(
            conversation,
            bash_ls(),
            PermissionDecision::Allow,
            PermissionScope::Forever,
        )
        .expect("the rule writes");

    let dangerous = PolicyKey::new(
        "ollama",
        "Bash",
        &PathBuf::from("/home/matus/dots"),
        &json!({"command": "rm -rf ~"}),
    );
    assert_eq!(
        policy.decide(conversation, &dangerous),
        Verdict::Ask,
        "a different command is a different rule"
    );
}

#[test]
fn an_approval_does_not_carry_into_another_checkout() {
    // Section 5 names this case: an approval granted in one checkout must
    // not carry into another.
    let scratch = Scratch::new();
    let conversation = Uuid::new_v4();
    let mut policy = scratch.open();
    policy
        .remember(
            conversation,
            bash_ls(),
            PermissionDecision::Allow,
            PermissionScope::Forever,
        )
        .expect("the rule writes");

    let elsewhere = PolicyKey::new(
        "ollama",
        "Bash",
        &PathBuf::from("/home/matus/somebody-elses-repo"),
        &json!({"command": "ls"}),
    );
    assert_eq!(policy.decide(conversation, &elsewhere), Verdict::Ask);
}

#[test]
fn a_rule_written_for_one_backend_does_not_apply_to_another() {
    let scratch = Scratch::new();
    let conversation = Uuid::new_v4();
    let mut policy = scratch.open();
    policy
        .remember(
            conversation,
            bash_ls(),
            PermissionDecision::Allow,
            PermissionScope::Forever,
        )
        .expect("the rule writes");

    let other_backend = PolicyKey::new(
        "claude-code",
        "Bash",
        &PathBuf::from("/home/matus/dots"),
        &json!({"command": "ls"}),
    );
    assert_eq!(policy.decide(conversation, &other_backend), Verdict::Ask);
}

#[test]
fn argument_order_does_not_open_a_second_rule() {
    // The normalization. Two spellings of the same arguments are one rule,
    // or a model could re-ask by shuffling its own JSON.
    let scratch = Scratch::new();
    let conversation = Uuid::new_v4();
    let mut policy = scratch.open();
    let cwd = PathBuf::from("/home/matus/dots");

    let one = PolicyKey::new(
        "ollama",
        "Write",
        &cwd,
        &json!({"a": 1, "b": 2, "path": "/tmp/x"}),
    );
    let other = PolicyKey::new(
        "ollama",
        "Write",
        &cwd,
        &json!({"path": "/tmp/x", "b": 2, "a": 1}),
    );
    assert_eq!(one, other, "key order must not make two keys");

    policy
        .remember(
            conversation,
            one,
            PermissionDecision::Allow,
            PermissionScope::Forever,
        )
        .expect("the rule writes");
    assert_eq!(policy.decide(conversation, &other), Verdict::Allow);
}

#[test]
fn a_deny_rule_refuses_without_asking_again() {
    let scratch = Scratch::new();
    let conversation = Uuid::new_v4();
    let mut policy = scratch.open();
    policy
        .remember(
            conversation,
            bash_ls(),
            PermissionDecision::Deny,
            PermissionScope::Forever,
        )
        .expect("the rule writes");
    assert_eq!(policy.decide(conversation, &bash_ls()), Verdict::Deny);
    assert_eq!(
        scratch.open().decide(conversation, &bash_ls()),
        Verdict::Deny
    );
}

#[test]
fn a_session_decision_overrides_an_older_forever_one() {
    // The more recent thing the person said wins, which is what lets someone
    // revoke a standing approval for the rest of a conversation.
    let scratch = Scratch::new();
    let conversation = Uuid::new_v4();
    let mut policy = scratch.open();
    policy
        .remember(
            conversation,
            bash_ls(),
            PermissionDecision::Allow,
            PermissionScope::Forever,
        )
        .expect("the rule writes");
    policy
        .remember(
            conversation,
            bash_ls(),
            PermissionDecision::Deny,
            PermissionScope::Session,
        )
        .expect("a session rule needs no disk");
    assert_eq!(policy.decide(conversation, &bash_ls()), Verdict::Deny);
    assert_eq!(
        scratch.open().decide(conversation, &bash_ls()),
        Verdict::Allow,
        "and the standing rule is still on disk for the next run"
    );
}

#[test]
fn a_missing_policy_file_is_not_an_error() {
    let scratch = Scratch::new();
    let policy = scratch.open();
    assert_eq!(policy.forever_len(), 0);
    assert_eq!(policy.path(), scratch.path());
}

#[test]
fn a_policy_file_that_will_not_parse_refuses_to_load() {
    // Starting empty would silently revoke every approval a person granted,
    // with no sign of it, so this is deliberately loud.
    let scratch = Scratch::new();
    fs::write(scratch.path(), "{ this is not json").expect("the file writes");
    let failed = Policy::open(scratch.path());
    assert!(failed.is_err(), "a corrupt rule store is not an empty one");
}
