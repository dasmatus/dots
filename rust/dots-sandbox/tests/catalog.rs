//! `catalog --json`'s pure half: [`build_catalog`] against hand-built
//! desktop-file fixtures and hand-built resolved policies, following the
//! shape `tests/report.rs` establishes — no filesystem walk, no real XDG
//! tree, just already-read text in and a [`Catalog`] out.
//!
//! Fixtures live in `tests/fixtures/desktop-entries/`, one small file per
//! subtlety this module's task brief called out by name: a well-formed
//! entry, a `Desktop Action` group that must not contaminate the parse,
//! a file with no `X-Dots-Sandbox-AppId` at all, and a capability name
//! this binary does not recognise.

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

use dots_sandbox::catalog::{build_catalog, CatalogPathEntry};
use dots_sandbox::policy::{
    Capability, PathMode, PolicyState, ResolvedApp, ResolvedPathGrant, ResolvedPolicy,
    ResolvedPolicySet, Tier,
};

fn fixture(name: &str) -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/desktop-entries")
        .join(name);
    fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading fixture {}: {e}", path.display()))
}

/// An empty resolved policy set — the shape a run with no defaults
/// catalog entries at all takes, used by tests that only care about what
/// the desktop-file scan itself contributes.
fn empty_policy() -> ResolvedPolicySet {
    ResolvedPolicySet {
        version: 1,
        deny_paths: Vec::new(),
        apps: BTreeMap::new(),
    }
}

fn policy_with_apps(apps: Vec<(&str, ResolvedApp)>) -> ResolvedPolicySet {
    ResolvedPolicySet {
        version: 1,
        deny_paths: Vec::new(),
        apps: apps
            .into_iter()
            .map(|(id, app)| (id.to_string(), app))
            .collect(),
    }
}

fn sandboxed(tier: Tier, caps: &[(Capability, PolicyState)]) -> ResolvedApp {
    ResolvedApp::Sandboxed(ResolvedPolicy {
        tier,
        capabilities: caps.iter().copied().collect(),
        paths: Vec::new(),
    })
}

/// A well-formed entry: every field the contract's JSON example names
/// must come out populated from the desktop file, and `state` must come
/// from the resolved policy passed in alongside it, not from the file.
#[test]
fn well_formed_entry_merges_desktop_metadata_with_resolved_state() {
    let policy = policy_with_apps(vec![(
        "zed",
        sandboxed(Tier::Vm, &[(Capability::Net, PolicyState::Allow)]),
    )]);
    let source = PathBuf::from("/nix/store/xyz-zed/share/applications/zed.desktop");
    let files = vec![(source.clone(), fixture("well-formed.desktop"))];

    let catalog = build_catalog(&files, &policy);

    assert_eq!(catalog.version, 1);
    assert_eq!(catalog.apps.len(), 1);
    let entry = &catalog.apps[0];
    assert_eq!(entry.app_id, "zed");
    assert_eq!(entry.name.as_deref(), Some("Zed"));
    assert_eq!(entry.icon.as_deref(), Some("zed"));
    assert_eq!(entry.tier, Some(Tier::Vm));
    assert_eq!(entry.caps, vec!["net".to_string()]);
    assert_eq!(
        entry.paths,
        vec![CatalogPathEntry {
            path: "~/Dokumente".to_string(),
            mode: PathMode::Rw,
        }]
    );
    assert_eq!(entry.source.as_deref(), Some(source.to_str().unwrap()));
    assert_eq!(entry.state.get("net"), Some(&PolicyState::Allow));
}

/// The localised `Name[de]=` key in the same fixture must never win over
/// the unlocalised `Name=` this scanner actually wants.
#[test]
fn localised_name_key_is_ignored_in_favour_of_the_plain_name() {
    let files = vec![(PathBuf::from("zed.desktop"), fixture("well-formed.desktop"))];
    let catalog = build_catalog(&files, &empty_policy());

    assert_eq!(catalog.apps[0].name.as_deref(), Some("Zed"));
}

/// A `[Desktop Action foo]` group carries its own `Name=`/`Icon=`/`Exec=`
/// for its own menu entry. None of that may leak into the application's
/// own fields, which must still read from `[Desktop Entry]` alone.
#[test]
fn desktop_action_group_does_not_contaminate_the_parse() {
    let files = vec![(
        PathBuf::from("code.desktop"),
        fixture("with-actions.desktop"),
    )];
    let catalog = build_catalog(&files, &empty_policy());

    assert_eq!(catalog.apps.len(), 1);
    let entry = &catalog.apps[0];
    assert_eq!(entry.app_id, "code");
    assert_eq!(
        entry.name.as_deref(),
        Some("Code"),
        "the action group's own Name=New Window must not shadow the application's"
    );
    assert_eq!(
        entry.icon.as_deref(),
        Some("code"),
        "the action group's own Icon=code-new must not shadow the application's"
    );
    assert_eq!(entry.tier, Some(Tier::Container));
    assert_eq!(entry.caps, vec!["net".to_string(), "repo-read".to_string()]);
}

/// A desktop file with no `X-Dots-Sandbox-AppId` at all is not a
/// sandboxed app's entry and must be ignored outright, not merely
/// stripped of its capabilities.
#[test]
fn a_file_with_no_app_id_is_ignored() {
    let files = vec![(
        PathBuf::from("firefox.desktop"),
        fixture("no-app-id.desktop"),
    )];
    let catalog = build_catalog(&files, &empty_policy());

    assert!(
        catalog.apps.is_empty(),
        "a file with no X-Dots-Sandbox-AppId must contribute nothing, got: {:?}",
        catalog.apps
    );
}

/// A capability name `Capability::parse` does not recognise is dropped
/// from the entry rather than failing the whole file — a foreign or
/// hand-edited desktop file must not hide the rest of a real app's entry
/// over one bad name.
#[test]
fn a_malformed_capability_name_is_dropped_not_fatal() {
    let files = vec![(
        PathBuf::from("broken.desktop"),
        fixture("malformed-caps.desktop"),
    )];
    let catalog = build_catalog(&files, &empty_policy());

    assert_eq!(catalog.apps.len(), 1, "the entry itself must still appear");
    let entry = &catalog.apps[0];
    assert_eq!(entry.app_id, "broken-app");
    assert_eq!(
        entry.caps,
        vec!["net".to_string()],
        "the unparseable `wayland` name must be dropped, leaving only `net`"
    );
}

/// XDG precedence: `$XDG_DATA_HOME` (listed first) must win over a
/// `$XDG_DATA_DIRS` entry (listed later) declaring the same app id —
/// first wins, never last.
#[test]
fn earlier_directory_wins_on_a_duplicate_app_id() {
    let home_path = PathBuf::from("/home/tester/.local/share/applications/zed.desktop");
    let dirs_path = PathBuf::from("/run/current-system/sw/share/applications/zed.desktop");
    let files = vec![
        (home_path.clone(), fixture("precedence-home.desktop")),
        (dirs_path, fixture("precedence-dirs.desktop")),
    ];

    let catalog = build_catalog(&files, &empty_policy());

    assert_eq!(catalog.apps.len(), 1, "both files declare the same app id");
    let entry = &catalog.apps[0];
    assert_eq!(entry.name.as_deref(), Some("Zed (user override)"));
    assert_eq!(entry.source.as_deref(), Some(home_path.to_str().unwrap()));
}

/// The property the flake apps depend on: an app the defaults catalog
/// defines but no desktop file ever names must still appear, with a null
/// source, built entirely from the resolved policy.
#[test]
fn an_app_with_no_desktop_file_still_appears_with_a_null_source() {
    let policy = policy_with_apps(vec![(
        "nix-lint",
        sandboxed(
            Tier::Container,
            &[
                (Capability::RepoWrite, PolicyState::Allow),
                (Capability::NixDaemon, PolicyState::Allow),
                (Capability::Net, PolicyState::Allow),
            ],
        ),
    )]);

    let catalog = build_catalog(&[], &policy);

    assert_eq!(catalog.apps.len(), 1);
    let entry = &catalog.apps[0];
    assert_eq!(entry.app_id, "nix-lint");
    assert_eq!(entry.name, None);
    assert_eq!(entry.icon, None);
    assert_eq!(entry.source, None, "no desktop file means a null source");
    assert_eq!(entry.tier, Some(Tier::Container));
    assert_eq!(entry.state.get("net"), Some(&PolicyState::Allow));
    assert_eq!(entry.state.get("nix-daemon"), Some(&PolicyState::Allow));
    assert_eq!(entry.state.get("repo-write"), Some(&PolicyState::Allow));
}

/// The same property, but for a path grant rather than a capability: a
/// policy-only app's resolved path grants must still surface somewhere,
/// since there is no desktop file to have declared them instead.
#[test]
fn a_policy_only_app_s_resolved_paths_are_still_reported() {
    let policy = policy_with_apps(vec![(
        "nix-lint",
        ResolvedApp::Sandboxed(ResolvedPolicy {
            tier: Tier::Container,
            capabilities: [(Capability::RepoWrite, PolicyState::Allow)]
                .into_iter()
                .collect(),
            paths: vec![ResolvedPathGrant {
                path: PathBuf::from("/home/tester/.cargo"),
                mode: PathMode::Rw,
                state: PolicyState::Allow,
            }],
        }),
    )]);

    let catalog = build_catalog(&[], &policy);

    let entry = &catalog.apps[0];
    assert_eq!(
        entry.paths,
        vec![CatalogPathEntry {
            path: "/home/tester/.cargo".to_string(),
            mode: PathMode::Rw,
        }]
    );
}

/// An `unconfined` app (no desktop file, since `wrapSandboxed` returns
/// those packages untouched) still appears in the catalog rather than
/// vanishing, with no tier or capabilities to show.
#[test]
fn an_unconfined_policy_only_app_appears_with_no_capabilities() {
    let policy = policy_with_apps(vec![(
        "kitty",
        ResolvedApp::Unconfined {
            reason: "a terminal; whatever it launches inherits the sandbox anyway".to_string(),
        },
    )]);

    let catalog = build_catalog(&[], &policy);

    assert_eq!(catalog.apps.len(), 1);
    let entry = &catalog.apps[0];
    assert_eq!(entry.app_id, "kitty");
    assert_eq!(entry.source, None);
    assert_eq!(entry.tier, None);
    assert!(entry.caps.is_empty());
    assert!(entry.state.is_empty());
}

/// A file's discovered app id and a policy-only app id can appear in the
/// same run without colliding — each `app_id` in the union of both sources
/// gets exactly one entry.
#[test]
fn discovered_and_policy_only_apps_coexist_without_duplication() {
    let policy = policy_with_apps(vec![
        (
            "zed",
            sandboxed(Tier::Vm, &[(Capability::Net, PolicyState::Allow)]),
        ),
        (
            "nix-lint",
            sandboxed(
                Tier::Container,
                &[(Capability::RepoWrite, PolicyState::Allow)],
            ),
        ),
    ]);
    let files = vec![(PathBuf::from("zed.desktop"), fixture("well-formed.desktop"))];

    let catalog = build_catalog(&files, &policy);

    let mut app_ids: Vec<&str> = catalog.apps.iter().map(|e| e.app_id.as_str()).collect();
    app_ids.sort_unstable();
    assert_eq!(app_ids, vec!["nix-lint", "zed"]);

    let zed = catalog.apps.iter().find(|e| e.app_id == "zed").unwrap();
    assert!(zed.source.is_some());
    let nix_lint = catalog
        .apps
        .iter()
        .find(|e| e.app_id == "nix-lint")
        .unwrap();
    assert!(nix_lint.source.is_none());
}
