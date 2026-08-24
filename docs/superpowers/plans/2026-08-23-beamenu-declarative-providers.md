# Declarative Provider Registry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Nothing about *which* providers exist, in *what order*, under *what
keyword*, or under *what heading* is written in Rust any more. All four are
configuration, rendered by Home Manager into `config.json`.

**Architecture:** The `Provider` trait splits. What a provider *does* stays in
Rust as a narrow `Source` trait with a single `query` method. What a provider
*is* becomes data: a `Provider` struct carrying id, section and trigger
alongside its boxed `Source`. `providers::all` stops being a hand-written list
and instead walks the configured provider specs, resolving each id through one
factory function, then appends the plugin manifests as before.

**Tech Stack:** Rust (serde), Nix Home Manager modules.

**Spec:** none — this is a follow-up refactor to
`docs/superpowers/specs/2026-08-23-beamenu-actions-daemon-design.md`, requested
directly: providers must not be hardcoded.

## Global Constraints

- Comments: only `//!` module-level and `///` per-symbol; inline `//` only for
  genuine subtlety (CLAUDE.md). Em dashes are this repo's house style; keep
  writing the way the surrounding code reads.
- Tests: integration tests in `rust/beamenu/tests/*.rs`. No inline
  `#[cfg(test)]`. Never write-then-exec a script file from a test (ETXTBSY).
- Every cargo command in `rust/beamenu` needs:
  `PKG_CONFIG_PATH=/nix/store/920c2lqhyl2zwrixdpsxi5x38dfaqhz9-beamenu-view-0.6.23/lib/pkgconfig`
  and `LD_LIBRARY_PATH=/nix/store/920c2lqhyl2zwrixdpsxi5x38dfaqhz9-beamenu-view-0.6.23/lib`
  (re-derive with `nix build --impure .#beamenu-view --no-link --print-out-paths`).
- Gate per task: `nix shell nixpkgs#rustfmt -c cargo fmt --all`, then
  `cargo clippy --all-targets -- -D warnings -W clippy::all -W clippy::perf -W clippy::pedantic`,
  then `cargo test`.
- Nix eval check: `nix eval --impure '.#nixosConfigurations.tokyonight.config.system.build.toplevel.drvPath'`.
  The host is `tokyonight` and the user is `matus`; do not discover them, the
  first `nixosConfigurations` attr is `live-iso` and has no Home Manager.
- **Behaviour must not change when `config.json` says nothing about
  providers.** The serde default reproduces today's registry exactly: order
  calc, apps, quicklinks, snippets, scripts, window, clipboard, files, emoji,
  system; keywords `=`, `w `, `c `, `f `, `:`; today's headings.
- Do not commit; the orchestrator owns the commit series.

---

### Task 1: split the trait into what a provider is and what it does

**Files:**
- Modify: `rust/beamenu/src/providers/mod.rs`
- Modify: every provider impl — `calc.rs`, `apps.rs`, `quicklinks.rs`,
  `snippets.rs`, `scripts.rs`, `window.rs`, `clipboard.rs`, `files.rs`,
  `emoji.rs`, `system.rs`, `plugins.rs`
- Modify: `rust/beamenu/src/lib.rs` (`App`, `Pills`)
- Test: `rust/beamenu/tests/providers.rs`, `rust/beamenu/tests/plugins.rs`,
  `rust/beamenu/tests/pills.rs`

**Interfaces:**
- Produces:
  - `pub trait Source { fn query(&self, ctx: &Ctx, query: &str) -> Vec<Item>; }`
    — the only thing a provider implementation still writes.
  - `pub struct Provider { pub id: String, pub section: String, pub trigger: Trigger, source: Box<dyn Source> }`
    with `Provider::new(id, section, trigger, source)` and
    `Provider::query(&self, ctx, query) -> Vec<Item>`.
  - `collect(providers: &[Provider], ctx: &Ctx, query: &str) -> (Vec<Item>, String)`
    and `decorate` keep their behaviour, retyped.
  - `Pills::new(providers: &[Provider])` retyped; it reads `p.trigger`,
    `p.id`, `p.section` as fields now.
  Task 2 constructs `Provider` values from config.

- [ ] **Step 1: Write the failing test** (append to `rust/beamenu/tests/providers.rs`)

```rust
#[test]
fn a_providers_identity_comes_from_its_registration_not_its_impl() {
    let tmp = tempfile::tempdir().unwrap();
    let provider = Provider::new(
        "renamed",
        "A Different Heading",
        Trigger::Prefix("zz ".to_string()),
        Box::new(System),
    );

    assert_eq!(provider.id, "renamed");
    assert_eq!(provider.section, "A Different Heading");
    assert_eq!(provider.trigger, Trigger::Prefix("zz ".to_string()));
    assert!(
        !provider.query(&ctx(tmp.path()), "").is_empty(),
        "the wrapped source still answers"
    );
}
```

- [ ] **Step 2: Run to verify failure.** `cargo test --test providers`.
Expected: FAIL, no `Provider::new`.

- [ ] **Step 3: Implement.** In `providers/mod.rs`, replace the `Provider`
trait with:

```rust
/// What a provider does: answer a query. Everything a provider *is* — its id,
/// its heading, the keyword that reaches it — is registration data now, held
/// by [`Provider`], because all three are things a user should be able to
/// change without a rebuild.
pub trait Source {
    fn query(&self, ctx: &Ctx, query: &str) -> Vec<Item>;
}

/// One registered provider: a [`Source`] plus the identity it was registered
/// under.
pub struct Provider {
    pub id: String,
    pub section: String,
    pub trigger: Trigger,
    source: Box<dyn Source>,
}

impl Provider {
    #[must_use]
    pub fn new(
        id: impl Into<String>,
        section: impl Into<String>,
        trigger: Trigger,
        source: Box<dyn Source>,
    ) -> Self {
        Self { id: id.into(), section: section.into(), trigger, source }
    }

    #[must_use]
    pub fn query(&self, ctx: &Ctx, query: &str) -> Vec<Item> {
        self.source.query(ctx, query)
    }
}
```

Then in each provider file, delete its `fn id`, `fn section` and `fn trigger`,
and change `impl Provider for X` to `impl Source for X`. Keep every `fn query`
body byte-identical. `plugins::PluginProvider` keeps its own `query` and also
becomes a `Source`; its id/section/keyword move to the `Provider` built around
it in `load_all`'s caller (see Task 2), so `keyword_trigger` moves to
`providers/mod.rs` as `pub fn keyword_trigger`.

Update `collect`, `decorate`, `Pills::new`, `Pills::visible` and `App` for the
retyping: `p.trigger()` becomes `p.trigger`, `p.id()` becomes `&p.id`,
`p.section()` becomes `&p.section`, `Box<dyn Provider>` becomes `Provider`.

- [ ] **Step 4: Run to verify pass.** `cargo test` (whole crate). Every
pre-existing test must still pass, including all of `tests/pills.rs`.

- [ ] **Step 5: fmt + clippy per Global Constraints.**

---

### Task 2: build the registry from configuration

**Files:**
- Modify: `rust/beamenu/src/config.rs`
- Modify: `rust/beamenu/src/providers/mod.rs` (`all`)
- Modify: `rust/beamenu/src/lib.rs` (`App::with_cache` passes the config)
- Test: `rust/beamenu/tests/registry.rs` (new)

**Interfaces:**
- Consumes: Task 1's `Provider`/`Source`.
- Produces:
  - `config::ProviderSpec { id: String, section: Option<String>, keyword: Option<String> }`
  - `Config.providers: Vec<ProviderSpec>`, `#[serde(default = "default_providers")]`
  - `providers::source_for(id: &str) -> Option<Box<dyn Source>>` — the one
    place a built-in id maps to its implementation.
  - `providers::default_section(id: &str) -> &'static str`
  - `providers::all(config_dir: &Path, config: &Config) -> Vec<Provider>`

- [ ] **Step 1: Write the failing tests** (`rust/beamenu/tests/registry.rs`)

```rust
//! The provider registry is configuration, not code: which providers exist,
//! their order, their keywords and their headings all come from config.json.

use beamenu::config::{Config, ProviderSpec};
use beamenu::providers::{all, source_for, Trigger};

fn spec(id: &str, keyword: Option<&str>) -> ProviderSpec {
    ProviderSpec {
        id: id.to_string(),
        section: None,
        keyword: keyword.map(str::to_string),
    }
}

#[test]
fn an_empty_config_reproduces_the_registry_that_used_to_be_hardcoded() {
    let tmp = tempfile::tempdir().unwrap();
    let config = Config::default();
    let ids: Vec<String> = all(tmp.path(), &config).into_iter().map(|p| p.id).collect();

    assert_eq!(
        ids,
        vec![
            "calc", "apps", "quicklinks", "snippets", "scripts",
            "window", "clipboard", "files", "emoji", "system",
        ]
    );
}

#[test]
fn the_configured_order_is_the_registry_order() {
    let tmp = tempfile::tempdir().unwrap();
    let config = Config {
        providers: vec![spec("system", None), spec("apps", None)],
        ..Config::default()
    };
    let ids: Vec<String> = all(tmp.path(), &config).into_iter().map(|p| p.id).collect();

    assert_eq!(ids, vec!["system", "apps"], "order follows the config, not the source");
}

#[test]
fn omitting_a_provider_leaves_it_out_entirely() {
    let tmp = tempfile::tempdir().unwrap();
    let config = Config {
        providers: vec![spec("apps", None)],
        ..Config::default()
    };
    let ids: Vec<String> = all(tmp.path(), &config).into_iter().map(|p| p.id).collect();

    assert_eq!(ids, vec!["apps"]);
}

#[test]
fn a_keyword_can_be_reassigned_without_touching_rust() {
    let tmp = tempfile::tempdir().unwrap();
    let config = Config {
        providers: vec![spec("files", Some("find "))],
        ..Config::default()
    };
    let providers = all(tmp.path(), &config);

    assert_eq!(providers[0].trigger, Trigger::Prefix("find ".to_string()));
}

#[test]
fn dropping_a_keyword_makes_a_keyworded_provider_ambient() {
    let tmp = tempfile::tempdir().unwrap();
    let config = Config {
        providers: vec![spec("clipboard", None)],
        ..Config::default()
    };

    assert_eq!(all(tmp.path(), &config)[0].trigger, Trigger::Ambient);
}

#[test]
fn a_heading_can_be_renamed_without_touching_rust() {
    let tmp = tempfile::tempdir().unwrap();
    let config = Config {
        providers: vec![ProviderSpec {
            id: "apps".to_string(),
            section: Some("Programs".to_string()),
            keyword: None,
        }],
        ..Config::default()
    };

    assert_eq!(all(tmp.path(), &config)[0].section, "Programs");
}

#[test]
fn an_unknown_id_is_skipped_rather_than_fatal() {
    let tmp = tempfile::tempdir().unwrap();
    let config = Config {
        providers: vec![spec("not-a-provider", None), spec("apps", None)],
        ..Config::default()
    };
    let ids: Vec<String> = all(tmp.path(), &config).into_iter().map(|p| p.id).collect();

    assert_eq!(ids, vec!["apps"], "one bad id costs one provider, not the launcher");
    assert!(source_for("not-a-provider").is_none());
}

#[test]
fn a_keyword_without_a_trailing_space_still_gets_one() {
    let tmp = tempfile::tempdir().unwrap();
    let config = Config {
        providers: vec![spec("window", Some("win"))],
        ..Config::default()
    };

    assert_eq!(
        all(tmp.path(), &config)[0].trigger,
        Trigger::Prefix("win ".to_string()),
        "the word-boundary rule is the registry's, not each provider's"
    );
}
```

Note the last one deliberately differs from today: a single-character keyword
like `=` or `:` must NOT gain a space. Implement `keyword_trigger` so a
keyword that is entirely non-alphanumeric (`=`, `:`) is used verbatim, and an
alphanumeric one gets a trailing space if it lacks one. Add a test asserting
`spec("calc", Some("="))` yields `Trigger::Prefix("=")`.

- [ ] **Step 2: Run to verify failure.** `cargo test --test registry`.

- [ ] **Step 3: Implement.** In `config.rs`:

```rust
/// One entry of the provider registry.
///
/// `section` and `keyword` are options rather than required fields so a spec
/// can name a provider and accept its defaults, which is what almost every
/// entry does.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProviderSpec {
    pub id: String,
    #[serde(default)]
    pub section: Option<String>,
    #[serde(default)]
    pub keyword: Option<String>,
}
```

Add to `Config`:

```rust
    /// The provider registry: which providers exist, in what order, under
    /// which keyword and heading. Rust supplies the implementations and
    /// nothing else; a rebuild is not how you reorder your launcher.
    #[serde(default = "default_providers")]
    pub providers: Vec<ProviderSpec>,
```

`default_providers()` returns the ten built-ins in today's order with today's
keywords, so a `config.json` without the key behaves exactly as before.

In `providers/mod.rs`, replace `all`'s body with a walk over
`config.providers`, resolving each through `source_for` and falling back to
`default_section(id)` when the spec names no section, then extend with the
plugin manifests exactly as today. `source_for` is the single `match id`
that maps an id to a boxed implementation; keep it directly above `all` so
the two read together.

- [ ] **Step 4: Run to verify pass.** `cargo test` (whole crate).

- [ ] **Step 5: fmt + clippy per Global Constraints.**

---

### Task 3: the Nix surface

**Files:**
- Modify: `nix/home/beamenu.nix`

**Interfaces:**
- Consumes: Task 2's `ProviderSpec` JSON shape.
- Produces: `programs.beamenu.providers`, rendered into `config.json`.

- [ ] **Step 1: Add the option**, defaulting to the same ten entries in the
same order, so an unconfigured system is unchanged:

```nix
    providers = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            id = lib.mkOption {
              type = lib.types.str;
              description = "Built-in provider to register. An unknown id is skipped.";
            };
            section = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Heading override; null keeps the provider's own.";
            };
            keyword = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                Prefix that reaches this provider. Null means ambient, so
                dropping a keyword folds a keyworded provider into the root
                list. An alphanumeric keyword gains a trailing space so it
                matches at a word boundary; a punctuation one like `=` or `:`
                is used as written.
              '';
            };
          };
        }
      );
      default = [
        { id = "calc"; keyword = "="; }
        { id = "apps"; }
        { id = "quicklinks"; }
        { id = "snippets"; }
        { id = "scripts"; }
        { id = "window"; keyword = "w"; }
        { id = "clipboard"; keyword = "c"; }
        { id = "files"; keyword = "f"; }
        { id = "emoji"; keyword = ":"; }
        { id = "system"; }
      ];
      description = ''
        The provider registry: which providers the launcher has, in what
        order, under which keyword and heading. Reordering the list reorders
        the sections and the filter pills; omitting an entry removes that
        provider, which is what `disabledProviders` does more briefly.
      '';
    };
```

Render it into `configJson` as `providers = cfg.providers;`. Keep
`disabledProviders` working: it now subtracts from this list, so express that
in `configJson` with
`providers = builtins.filter (p: !(builtins.elem p.id cfg.disabledProviders)) cfg.providers;`
and say so in `disabledProviders`' description.

- [ ] **Step 2: Eval-check** per Global Constraints, then render and inspect:

```bash
nix eval --impure --raw '.#nixosConfigurations.tokyonight.config.home-manager.users.matus.xdg.configFile."beamenu/config.json".text' | nix run nixpkgs#jq -- '.providers'
```

Expected: ten entries in the documented order.

- [ ] **Step 3: Prove the round trip.** Write that rendered JSON to a temp
`config.json`, load it with `beamenu::config::Config::load`, pass it to
`providers::all`, and assert the ten ids come back in order. Put this in
`rust/beamenu/tests/registry.rs` using an inline JSON literal copied from the
render above, so the test does not depend on nix at run time.

---

### Task 4: sweep

- [ ] **Step 1:** Full gate on all three beamenu crates (fmt, pedantic clippy,
tests), plus the nix eval check.
- [ ] **Step 2:** `git add -A` then
  `nix build --impure .#beamenu` (the fileset copies tracked files only).
- [ ] **Step 3:** Report what changed, with the rendered `providers` array.
