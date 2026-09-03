//! Pins MCP server discovery, which is the half of `mcp.rs` that decides
//! what a raw provider is allowed to call at all.
//!
//! Nothing here starts a server. Discovery reads config files and spawns
//! nothing, which is what makes it safe to run at daemon startup, and this
//! file asserts exactly that: after a `discover` the config is known and no
//! process has been created.
//!
//! Section 5 is the reason this matters. In provider mode the only tools that
//! exist are the ones a server a person already configured exposes, so the
//! set this module produces is the whole of the daemon's reach.

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

use serde_json::json;
use uuid::Uuid;

use ask_daemon::mcp::{servers_from_value, McpPool};

/// A directory that removes itself.
struct Scratch {
    root: PathBuf,
}

impl Scratch {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("dots-ask-mcp-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("temp root is creatable");
        Self { root }
    }

    /// Write one file under this directory, creating parents.
    fn write(&self, name: &str, body: &serde_json::Value) {
        let path = self.root.join(name);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("parent is creatable");
        }
        fs::write(path, serde_json::to_string_pretty(body).expect("json")).expect("file writes");
    }

    fn path(&self) -> &PathBuf {
        &self.root
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        drop(fs::remove_dir_all(&self.root));
    }
}

#[test]
fn a_global_stdio_server_is_discovered() {
    let home = Scratch::new();
    home.write(
        ".claude.json",
        &json!({
            "numStartups": 58,
            "mcpServers": {
                "searxng": {"type": "stdio", "command": "/nix/store/x/bin/searxng-mcp"}
            }
        }),
    );

    let pool = McpPool::discover(home.path(), None);
    assert_eq!(pool.server_names(), vec!["searxng".to_owned()]);
    assert!(!pool.is_empty());
}

#[test]
fn everything_else_in_claude_json_is_ignored() {
    // ~/.claude.json is a large file full of things that are none of this
    // daemon's business, so the config type reads two keys and no more. A
    // strict deserialize would fail on the whole file for a key somebody
    // else added.
    let home = Scratch::new();
    home.write(
        ".claude.json",
        &json!({
            "tipsHistory": {"powerup-onboarding": 1},
            "oauthAccount": {"emailAddress": "someone@example.invalid"},
            "mcpServers": {"memory": {"command": "dots-memory-mcp"}},
            "somethingAddedNextRelease": [1, 2, 3]
        }),
    );
    assert_eq!(
        McpPool::discover(home.path(), None).server_names(),
        vec!["memory".to_owned()]
    );
}

#[test]
fn a_project_entry_is_merged_with_the_global_ones() {
    let home = Scratch::new();
    let project = Scratch::new();
    home.write(
        ".claude.json",
        &json!({
            "mcpServers": {"searxng": {"command": "searxng-mcp"}},
            "projects": {
                project.path().to_str().expect("utf-8 path"): {
                    "mcpServers": {"repo-tool": {"command": "./tool"}}
                }
            }
        }),
    );

    let mut names = McpPool::discover(home.path(), Some(project.path())).server_names();
    names.sort();
    assert_eq!(names, vec!["repo-tool".to_owned(), "searxng".to_owned()]);
}

#[test]
fn a_project_entry_for_another_checkout_is_not_merged() {
    let home = Scratch::new();
    let project = Scratch::new();
    let elsewhere = Scratch::new();
    home.write(
        ".claude.json",
        &json!({
            "projects": {
                elsewhere.path().to_str().expect("utf-8 path"): {
                    "mcpServers": {"not-mine": {"command": "./tool"}}
                }
            }
        }),
    );
    assert!(
        McpPool::discover(home.path(), Some(project.path()))
            .server_names()
            .is_empty(),
        "another checkout's servers are not this thread's"
    );
}

#[test]
fn a_project_mcp_json_wins_over_a_global_entry_of_the_same_name() {
    // Read global first, project last, so the more specific file is the one
    // that survives the merge.
    let home = Scratch::new();
    let project = Scratch::new();
    home.write(
        ".claude.json",
        &json!({"mcpServers": {"tool": {"command": "/global/tool"}}}),
    );
    project.write(
        ".mcp.json",
        &json!({"mcpServers": {"tool": {"command": "/project/tool"}}}),
    );

    let pool = McpPool::discover(home.path(), Some(project.path()));
    assert_eq!(pool.server_names(), vec!["tool".to_owned()]);
}

#[test]
fn a_machine_with_no_claude_config_discovers_nothing_and_does_not_fail() {
    // The normal state on a box with no claude installed. A missing config
    // is not a reason for the daemon not to start.
    let home = Scratch::new();
    let pool = McpPool::discover(home.path(), None);
    assert!(pool.is_empty());
    assert!(pool.server_names().is_empty());
}

#[test]
fn a_config_that_will_not_parse_is_ignored_rather_than_fatal() {
    let home = Scratch::new();
    fs::write(home.path().join(".claude.json"), "{ not json at all").expect("the file writes");
    assert!(McpPool::discover(home.path(), None).is_empty());
}

#[test]
fn a_server_with_no_command_is_skipped_and_the_rest_survive() {
    // claude also accepts sse and http servers, which this daemon has no
    // transport for. One of those in the file must not hide the ones that
    // work.
    let raw: BTreeMap<String, serde_json::Value> = [
        (
            "stdio-one".to_owned(),
            json!({"command": "a", "args": ["--x"]}),
        ),
        (
            "remote".to_owned(),
            json!({"type": "sse", "url": "https://example.invalid/sse"}),
        ),
        ("stdio-two".to_owned(), json!({"command": "b"})),
    ]
    .into_iter()
    .collect();

    let servers = servers_from_value(&raw);
    let mut names: Vec<&String> = servers.keys().collect();
    names.sort();
    assert_eq!(names, vec!["stdio-one", "stdio-two"]);
    assert_eq!(servers["stdio-one"].args, vec!["--x".to_owned()]);
}

#[test]
fn a_server_entry_carries_its_args_and_env() {
    let raw: BTreeMap<String, serde_json::Value> = [(
        "edupage".to_owned(),
        json!({
            "command": "edupage-mcp-keyring",
            "args": ["--stdio"],
            "env": {"EDUPAGE_SUBDOMAIN": "school"}
        }),
    )]
    .into_iter()
    .collect();

    let servers = servers_from_value(&raw);
    let edupage = &servers["edupage"];
    assert_eq!(edupage.command, "edupage-mcp-keyring");
    assert_eq!(edupage.args, vec!["--stdio".to_owned()]);
    assert_eq!(
        edupage.env.get("EDUPAGE_SUBDOMAIN").map(String::as_str),
        Some("school")
    );
}

#[test]
fn an_entry_with_no_args_or_env_still_loads() {
    let raw: BTreeMap<String, serde_json::Value> = [("bare".to_owned(), json!({"command": "x"}))]
        .into_iter()
        .collect();
    let servers = servers_from_value(&raw);
    assert!(servers["bare"].args.is_empty());
    assert!(servers["bare"].env.is_empty());
}

#[test]
fn an_empty_pool_is_what_the_harness_gets() {
    // The claude CLI runs its own MCP servers, so the daemon never calls one
    // on its behalf and the harness backend is handed an empty pool.
    let pool = McpPool::empty();
    assert!(pool.is_empty());
    assert!(pool.server_names().is_empty());
}

#[tokio::test]
async fn a_tool_on_a_server_that_is_not_configured_is_refused_rather_than_run() {
    // The provider-mode rule from section 5, at its narrowest: there is no
    // built-in anything, so a name nothing exposes cannot execute.
    let pool = McpPool::empty();
    let refused = pool
        .call("nowhere", "Bash", &json!({"command": "rm -rf ~"}))
        .await
        .expect_err("an unconfigured server must not run anything");
    assert!(
        refused.contains("nowhere"),
        "the message names the server that is not there: {refused}"
    );
}

#[tokio::test]
async fn an_empty_pool_lists_no_tools() {
    assert!(McpPool::empty().list_tools().await.is_empty());
}
