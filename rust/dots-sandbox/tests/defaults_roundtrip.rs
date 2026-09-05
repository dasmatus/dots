//! Parses the real `nix/data/sandbox-policy.json` this repo ships (or will
//! ship — see below) and asserts every app in it maps to a capability
//! vocabulary this binary actually recognizes.
//!
//! `nix/data/sandbox-policy.json` is created by the task *after* this one:
//! the one that wires this crate into the flake. Until that lands, this
//! file does not exist in the checkout, and this test skips cleanly
//! (prints a note, does not fail) rather than treating a not-yet-created
//! file as a bug in this crate. Once the file exists, this test starts
//! actually exercising it on every `cargo test` run without any further
//! changes needed here.

use std::path::PathBuf;

use dots_sandbox::policy;

/// The checkout's `nix/data/sandbox-policy.json`, resolved from this
/// crate's own manifest directory so the test works regardless of the
/// directory `cargo test` happens to be invoked from.
fn sandbox_policy_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../nix/data/sandbox-policy.json")
}

#[test]
fn real_defaults_file_maps_every_app_to_known_capabilities() {
    let path = sandbox_policy_path();
    let Ok(contents) = std::fs::read_to_string(&path) else {
        eprintln!(
            "skipping: {} does not exist yet (it ships with the next task, which wires \
             this crate into the flake) — nothing to check against",
            path.display()
        );
        return;
    };

    let file = policy::parse_policy_file(&path, &contents)
        .unwrap_or_else(|e| panic!("{} failed to parse as a policy file: {e}", path.display()));

    policy::validate_strict(&file).unwrap_or_else(|e| {
        panic!(
            "{} does not validate under defaults semantics: {e}",
            path.display()
        )
    });

    // `validate_strict` already refuses an unknown capability name, but
    // this loop restates the brief's own wording directly: every `caps`
    // entry in every app must parse to a `Capability` this binary knows.
    for (app_id, app) in &file.apps {
        for name in app.caps.keys() {
            assert!(
                policy::Capability::parse(name).is_some(),
                "app `{app_id}` names unrecognized capability `{name}`"
            );
        }
    }
}
