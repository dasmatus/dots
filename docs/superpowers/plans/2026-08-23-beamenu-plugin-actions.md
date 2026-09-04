# beamenu Plugin Actions + Utility Ports Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Plugin-manifest commands gain Raycast-style Ctrl+K actions, and every
desktop-facing custom utility gets a beamenu plugin surface.

**Architecture:** `Command` becomes shallowly recursive (`actions:
Vec<Command>`, one level honored) in both manifest parsers; `PluginProvider`
maps actions into the existing `Item.alt_actions` panel machinery; utilities
land as declarative `programs.beamenu.plugins` contributions from the nix
module that owns each tool.

**Tech Stack:** Rust (serde), Nix Home Manager modules.

**Spec:** `docs/superpowers/specs/2026-08-23-beamenu-actions-daemon-design.md`
(Parts A and B; Part C is a separate plan.)

## Global Constraints

- Comments: only `//!` module-level and `///` per-symbol; inline `//` only for
  genuine sorcery (CLAUDE.md).
- Tests: integration tests in `rust/<crate>/tests/*.rs`; never inline
  `#[cfg(test)]` modules.
- Format/lint gate per Rust task, run from the crate dir:
  `nix shell nixpkgs#rustfmt -c cargo fmt --all` then
  `cargo clippy --all-targets -- -D warnings -W clippy::all -W clippy::perf -W clippy::pedantic`.
- `rust/beamenu` builds/tests only with the patched C library visible:
  `export BMV=$(nix build /home/matus/Dokumente/codeberg/personal/dots#beamenu-view --no-link --print-out-paths --impure)`
  then prefix cargo commands with
  `PKG_CONFIG_PATH="$BMV/lib/pkgconfig" LD_LIBRARY_PATH="$BMV/lib"`.
- All nix eval/build commands need `--impure` (nix/data/settings.nix is an absolute
  symlink) and new files must be `git add`ed first (flake filesets copy
  tracked files only).
- Never touch `rust/wallpaper-tui/tests/tint.rs` (unrelated uncommitted user
  change) and never commit it.
- Commit messages: plain, no Co-Authored-By / session links / AI trailers.
- `nix run .#nix-lint` may die at its `nix build .#abstracttui` step
  (pre-existing scaffolding breakage). If it does, run the per-crate
  fmt/clippy/test steps from `flake/apps.nix:85-97` manually and note it.

---

### Task 1: `Command.actions` in the beamenu manifest parser

**Files:**
- Modify: `rust/beamenu/src/providers/plugins.rs`
- Test: `rust/beamenu/tests/plugins.rs`

**Interfaces:**
- Consumes: existing `Command`, `Mode`, `expand`, `shell_join`,
  `Item::alt(label, action)` (`rust/beamenu/src/item.rs:127`).
- Produces: `Command { …, actions: Vec<Command> }` (serde-default empty);
  `PluginProvider` items whose `alt_actions[i] == (action.title,
  resolved Action)`. Task 4's nix schema and Task 5's manifests rely on the
  JSON field being named `actions`.

- [ ] **Step 1: Write the failing tests** (append to
  `rust/beamenu/tests/plugins.rs`, reusing its `ctx`/`write_manifest` helpers)

```rust
#[test]
fn command_actions_default_to_empty_when_absent() {
    let json = r#"{
        "name": "quick", "title": "Quick",
        "commands": [ { "id": "run", "title": "Run", "mode": "exec", "exec": ["true"] } ]
    }"#;
    let manifest: Manifest = serde_json::from_str(json).expect("old manifests still parse");
    assert!(manifest.commands[0].actions.is_empty());
}

#[test]
fn actions_become_alt_actions_with_the_same_query_expansion() {
    let dir = tempfile::tempdir().unwrap();
    write_manifest(
        dir.path(),
        "wp.json",
        r#"{
            "name": "wp", "title": "Wallpaper", "keyword": "wp",
            "commands": [{
                "id": "pick", "title": "Pick", "mode": "terminal",
                "exec": ["wallpaper-tui"],
                "actions": [
                    { "id": "restore", "title": "Restore", "mode": "exec",
                      "exec": ["wallpaper-tui", "--restore", "{query}"] }
                ]
            }]
        }"#,
    );
    let providers = load_all(dir.path());
    let items = providers[0].query(&ctx(dir.path()), "monet");

    assert_eq!(
        items[0].alt_actions,
        vec![(
            "Restore".to_string(),
            Action::Launch {
                exec: "'wallpaper-tui' '--restore' 'monet'".to_string(),
                terminal: false,
            },
        )]
    );
}

#[test]
fn view_mode_actions_carry_the_action_id_not_the_command_id() {
    let dir = tempfile::tempdir().unwrap();
    let path = write_manifest(
        dir.path(),
        "docs.json",
        r#"{
            "name": "docs", "title": "Docs",
            "commands": [{
                "id": "open", "title": "Open", "mode": "exec", "exec": ["true"],
                "actions": [
                    { "id": "help", "title": "Help", "mode": "view",
                      "ui": "log", "exec": ["man", "beamenu"] }
                ]
            }]
        }"#,
    );
    let providers = load_all(dir.path());
    let items = providers[0].query(&ctx(dir.path()), "x");

    assert_eq!(
        items[0].alt_actions[0].1,
        Action::View { manifest: path, command: "help".to_string(), query: "x".to_string() }
    );
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from `rust/beamenu`, with the `BMV` env prefix from Global Constraints):
`cargo test --test plugins`
Expected: FAIL — no field `actions` on `Command`.

- [ ] **Step 3: Implement.** In `rust/beamenu/src/providers/plugins.rs`:

Add to `Command` (after `exec`):

```rust
    /// Extra rows for the Ctrl+K panel. One level deep: an action's own
    /// `actions` are ignored, since the panel is a flat list. Reusing
    /// [`Command`] rather than a trimmed twin keeps this parser and the
    /// canvas's deliberate duplicate from drifting apart field-by-field.
    #[serde(default)]
    pub actions: Vec<Command>,
```

Refactor `PluginProvider::item` so the mode match is shared:

```rust
    /// Translate one command's (or action's) mode into an [`Action`], with
    /// `{query}` already expanded. `id` matters for `Mode::View`: the canvas
    /// looks the id up in the manifest itself, so an action's row must carry
    /// the action's id, not its parent command's.
    fn resolve(&self, id: &str, mode: Mode, exec: &[String], query: &str) -> Action {
        match mode {
            Mode::Exec => Action::Launch {
                exec: shell_join(&expand(exec, query)),
                terminal: false,
            },
            Mode::Terminal => Action::Launch {
                exec: shell_join(&expand(exec, query)),
                terminal: true,
            },
            Mode::Copy => Action::Copy(shell_join(&expand(exec, query))),
            Mode::View => Action::View {
                manifest: self.path.clone(),
                command: id.to_string(),
                query: query.to_string(),
            },
        }
    }

    /// Build the row for one command, given the already-stripped query text.
    fn item(&self, command: &Command, query: &str) -> Item {
        let action = self.resolve(&command.id, command.mode, &command.exec, query);

        let mut item = Item::new(
            format!("plugin:{}:{}", self.manifest.name, command.id),
            command.title.clone(),
            action,
        )
        .icon(self.manifest.icon.clone().map(PathBuf::from));

        if let Some(description) = &command.description {
            item = item.subtitle(description.clone());
        }

        for sub in &command.actions {
            item = item.alt(
                sub.title.clone(),
                self.resolve(&sub.id, sub.mode, &sub.exec, query),
            );
        }

        item
    }
```

(Existing construction sites of `Command` in tests don't name `actions`
because of `serde(default)`; any non-serde literal constructions must gain
`actions: Vec::new()`.)

- [ ] **Step 4: Run tests to verify they pass**

`cargo test --test plugins` (with `BMV` prefix). Expected: PASS, including all
pre-existing tests.

- [ ] **Step 5: fmt + clippy per Global Constraints, fix anything raised**

- [ ] **Step 6: Commit**

```bash
git add rust/beamenu/src/providers/plugins.rs rust/beamenu/tests/plugins.rs
git commit -m "feat(beamenu): plugin commands can declare Ctrl+K actions"
```

---

### Task 2: `actions` in the canvas manifest parser + lookup fallback

**Files:**
- Modify: `rust/beamenu-canvas/src/manifest.rs`
- Test: `rust/beamenu-canvas/tests/manifest.rs`

**Interfaces:**
- Consumes: canvas's own `Manifest`, `Command`,
  `find_command(&self, id: &str) -> Option<&Command>`
  (`rust/beamenu-canvas/src/manifest.rs:100`), `command(&self, id)` which
  wraps it in `ManifestError`.
- Produces: canvas `Command { …, actions: Vec<Command> }`; `find_command`
  resolves a top-level command first, then any command's one-level `actions`
  entry; first match wins.

- [ ] **Step 1: Write the failing tests** (append to
  `rust/beamenu-canvas/tests/manifest.rs`, matching its existing style)

```rust
#[test]
fn command_actions_default_to_empty_when_absent() {
    let manifest = Manifest::parse(
        r#"{ "name": "p", "title": "P",
             "commands": [ { "id": "a", "title": "A", "mode": "exec", "exec": ["true"] } ] }"#,
    )
    .expect("old manifests still parse");
    assert!(manifest.commands[0].actions.is_empty());
}

#[test]
fn find_command_falls_back_to_action_ids() {
    let manifest = Manifest::parse(
        r#"{ "name": "p", "title": "P",
             "commands": [ { "id": "a", "title": "A", "mode": "exec", "exec": ["true"],
                             "actions": [ { "id": "b", "title": "B", "mode": "view",
                                            "exec": ["worker"] } ] } ] }"#,
    )
    .unwrap();
    assert_eq!(manifest.find_command("b").expect("action id resolves").title, "B");
}

#[test]
fn top_level_commands_win_over_same_named_actions() {
    let manifest = Manifest::parse(
        r#"{ "name": "p", "title": "P",
             "commands": [
               { "id": "a", "title": "A", "mode": "exec", "exec": ["true"],
                 "actions": [ { "id": "dup", "title": "Nested", "mode": "exec", "exec": ["false"] } ] },
               { "id": "dup", "title": "Top", "mode": "exec", "exec": ["true"] } ] }"#,
    )
    .unwrap();
    assert_eq!(manifest.find_command("dup").unwrap().title, "Top");
}
```

- [ ] **Step 2: Run to verify failure**

From `rust/beamenu-canvas`: `cargo test --test manifest`
Expected: FAIL — no field `actions`.

- [ ] **Step 3: Implement.** Mirror Task 1's field on the canvas `Command`
(same `///` doc, same `#[serde(default)]`), then extend the lookup:

```rust
    /// Find `id` among the top-level commands, then among every command's
    /// one-level `actions`. Top level wins so an action can never shadow a
    /// command; within a level, first match wins (loading stays tolerant).
    pub fn find_command(&self, id: &str) -> Option<&Command> {
        self.commands
            .iter()
            .find(|command| command.id == id)
            .or_else(|| {
                self.commands
                    .iter()
                    .flat_map(|command| command.actions.iter())
                    .find(|action| action.id == id)
            })
    }
```

- [ ] **Step 4: Run to verify pass:** `cargo test` (whole crate). Expected: PASS.

- [ ] **Step 5: fmt + clippy per Global Constraints**

- [ ] **Step 6: Commit**

```bash
git add rust/beamenu-canvas/src/manifest.rs rust/beamenu-canvas/tests/manifest.rs
git commit -m "feat(beamenu-canvas): resolve view targets nested in command actions"
```

---

### Task 3: built-in alternates for quicklinks and script commands

**Files:**
- Modify: `rust/beamenu/src/providers/quicklinks.rs:83-108`,
  `rust/beamenu/src/providers/scripts.rs:102-123`
- Test: `rust/beamenu/tests/providers.rs`

**Interfaces:**
- Consumes: `Item::alt`, `Action::{Copy, Launch}`.
- Produces: quicklink rows with one alternate ("Copy URL" or, for
  `command: true` links, "Copy command"); script rows with alternate
  "Run in terminal".

- [ ] **Step 1: Write the failing tests** (append to
  `rust/beamenu/tests/providers.rs`, reusing its existing Ctx/tempdir helpers
  — read the file first and match how it writes `quicklinks.json` and script
  files)

```rust
#[test]
fn quicklinks_offer_a_copy_alternate() {
    // Arrange a quicklinks.json with one URL link exactly the way the
    // file's existing quicklink tests do.
    // let items = Quicklinks.query(&ctx, "gh nixpkgs");
    // assert alt_actions == [("Copy URL", Action::Copy(<expanded url>))]
}

#[test]
fn command_quicklinks_label_the_copy_alternate_as_command() {
    // command: true link; expect ("Copy command", Action::Copy(<expanded>)).
}

#[test]
fn scripts_offer_a_terminal_alternate() {
    // Arrange an annotated executable script the way the file's existing
    // script tests do; expect
    // [("Run in terminal", Action::Launch { exec: <quoted path>, terminal: true })].
}
```

The comment bodies above are the behaviour contract; write them as real
assertions against the file's existing helpers (the helpers already exist —
do not invent new scaffolding, and remember the ETXTBSY rule: tests must not
write+exec their own script files; the existing script-provider tests only
need the executable bit, they never exec the file).

- [ ] **Step 2: Run to verify failure:** `cargo test --test providers` (with
`BMV` prefix). Expected: FAIL on empty `alt_actions`.

- [ ] **Step 3: Implement.** In `quicklinks.rs`, replace the closure tail:

```rust
                let label = if link.command { "Copy command" } else { "Copy URL" };
                Item::new(
                    format!("quicklink:{}", link.name),
                    link.name.clone(),
                    action,
                )
                .subtitle(target.clone())
                .icon(link.icon.map(std::path::PathBuf::from))
                .alt(label, Action::Copy(target))
```

In `scripts.rs`, after the `Item::new(…, Action::Shell(quoted))` builder gains
a binding, add:

```rust
                let mut item = Item::new(
                    format!("script:{}", path.display()),
                    title,
                    Action::Shell(quoted.clone()),
                )
                .icon(meta.icon.map(PathBuf::from))
                .alt(
                    "Run in terminal",
                    Action::Launch { exec: quoted, terminal: true },
                );
```

- [ ] **Step 4: Run to verify pass:** `cargo test` (whole crate, `BMV`
prefix). Expected: PASS.

- [ ] **Step 5: fmt + clippy per Global Constraints**

- [ ] **Step 6: Commit**

```bash
git add rust/beamenu/src/providers/quicklinks.rs rust/beamenu/src/providers/scripts.rs rust/beamenu/tests/providers.rs
git commit -m "feat(beamenu): copy and terminal alternates for quicklinks and scripts"
```

---

### Task 4: nix option schema for command actions

**Files:**
- Modify: `nix/home/beamenu.nix` (commands submodule, `:296-351`)

**Interfaces:**
- Consumes: existing `programs.beamenu.plugins.<name>.commands` submodule.
- Produces: `commands[*].actions` option (default `[]`) rendering into the
  manifest JSON field `actions` Task 1 parses. Tasks 5–8 use it.

- [ ] **Step 1: Add the option** inside the commands submodule's `options`,
after `exec`:

```nix
                    actions = lib.mkOption {
                      type = lib.types.listOf (
                        lib.types.submodule {
                          options = {
                            id = lib.mkOption {
                              type = lib.types.str;
                              description = ''
                                Stable identity within the plugin. Shares the
                                command id namespace: `mode = "view"` actions
                                are resolved by the canvas through the same
                                lookup, top-level commands winning ties.
                              '';
                            };
                            title = lib.mkOption {
                              type = lib.types.str;
                              description = "Action-panel row label.";
                            };
                            mode = lib.mkOption {
                              type = lib.types.enum [
                                "exec"
                                "terminal"
                                "copy"
                                "view"
                              ];
                              description = "Same semantics as a command's `mode`.";
                            };
                            ui = lib.mkOption {
                              type = lib.types.enum [
                                "log"
                                "rpc"
                              ];
                              default = "log";
                              description = "Sidecar renderer used when `mode = \"view\"`.";
                            };
                            exec = lib.mkOption {
                              type = lib.types.listOf lib.types.str;
                              description = "Argv, `{query}`-substituted like a command's.";
                            };
                          };
                        }
                      );
                      default = [ ];
                      description = ''
                        Ctrl+K panel actions for this command. One level:
                        actions cannot nest further.
                      '';
                    };
```

- [ ] **Step 2: Eval-check the module.** From the repo root:

```bash
host=tokyonight   # named, not discovered: the first attr is live-iso, which has no Home Manager
nix eval --impure ".#nixosConfigurations.$host.config.system.build.toplevel.drvPath" > /dev/null
```

Expected: evaluates with no error (build not required).

- [ ] **Step 3: Commit**

```bash
git add nix/home/beamenu.nix
git commit -m "feat(nix/beamenu): actions list on plugin commands"
```

---

### Task 5: shared plugin identities + wallpaper plugin

**Files:**
- Modify: `nix/home/beamenu.nix` (inside `config = lib.mkIf cfg.enable`,
  beside the existing `programs.beamenu.plugins.calc`)
- Modify: `nix/home/wallpaper-tui.nix` (inside its enabled-config block)
- Modify: `nix/home/random_wp.nix` (inside its enabled-config block)

**Interfaces:**
- Consumes: Task 4's `actions` option; list-option merging across modules.
- Produces: plugin identities `wallpaper`/`dots`/`net` (title+keyword,
  commands contributed elsewhere); the full `wallpaper` command set.

- [ ] **Step 1: Declare multi-owner plugin identities** in `beamenu.nix`
(commands stay empty here; owning modules contribute them — nix list options
merge by concatenation, the same mechanism `settings-menu.nix` uses to add a
whole plugin from outside this file):

```nix
    # Identity-only declarations for plugins whose commands are contributed
    # by the module that owns each tool (wallpaper-tui.nix, random_wp.nix,
    # proton.nix, waybar.nix, bitwarden.nix). Keeping title+keyword here
    # means a contributing module can be disabled without leaving commands
    # orphaned on a title-less plugin, which would fail module eval.
    programs.beamenu.plugins.wallpaper = {
      title = "Wallpaper";
      keyword = "wp";
    };
    programs.beamenu.plugins.dots = {
      title = "Dots";
      keyword = "dots";
    };
    programs.beamenu.plugins.net = {
      title = "Network";
      keyword = "net";
    };
```

Also add the `dots` cheatsheet command here (the eww script ships with this
desktop setup, same availability as today's SUPER+/ bind):

```nix
    programs.beamenu.plugins.dots.commands = [
      {
        id = "keybinds";
        title = "Keybinds Cheatsheet";
        description = "Show the eww keybind overlay";
        mode = "exec";
        exec = [ "${config.xdg.configHome}/eww/scripts/keybinds.sh" "--force" ];
      }
    ];
```

- [ ] **Step 2: Contribute wallpaper commands.** In `wallpaper-tui.nix`'s
enabled config block (adapt `cfg` to that file's actual option root — read it
first):

```nix
    programs.beamenu.plugins.wallpaper.commands = [
      {
        id = "pick";
        title = "Pick Wallpaper";
        description = "Interactive picker (terminal)";
        mode = "terminal";
        exec = [ "wallpaper-tui" ];
        actions = [
          {
            id = "restore";
            title = "Restore Last Wallpaper";
            mode = "exec";
            exec = [
              "wallpaper-tui"
              "--restore"
            ];
          }
          {
            id = "cache-previews";
            title = "Rebuild Preview Cache";
            mode = "exec";
            exec = [
              "wallpaper-tui"
              "--cache-previews"
            ];
          }
        ];
      }
    ];
```

In `random_wp.nix`'s config block (the script name must match the
`writeShellScriptBin` name at `random_wp.nix:8`):

```nix
    programs.beamenu.plugins.wallpaper.commands = [
      {
        id = "random";
        title = "Random Wallpaper";
        description = "Fetch a random Wallhaven wallpaper and apply it";
        mode = "exec";
        exec = [ "wallhaven-random-wallpaper" ];
      }
    ];
```

- [ ] **Step 3: Eval-check** (same two commands as Task 4 Step 2), then
render-check the merged manifest:

```bash
user=matus
nix eval --impure --raw ".#nixosConfigurations.$host.config.home-manager.users.$user.xdg.configFile.\"beamenu/plugins/wallpaper.json\".text" | nix run nixpkgs#jq -- .
```

Expected: valid JSON, `commands` containing both contributions, `pick`
carrying two `actions`.

- [ ] **Step 4: Commit**

```bash
git add nix/home/beamenu.nix nix/home/wallpaper-tui.nix nix/home/random_wp.nix
git commit -m "feat(nix): wallpaper plugin and shared plugin identities for beamenu"
```

---

### Task 6: monitors plugin (hyprmon)

**Files:**
- Modify: `nix/home/hyprmon.nix` (inside its enabled config block, following
  the whole-plugin-in-owning-module pattern of `settings-menu.nix:30-46`)

**Interfaces:**
- Consumes: Task 4's schema.
- Produces: `programs.beamenu.plugins.monitors`.

- [ ] **Step 1: Add the plugin** (single-owner, so identity lives here):

```nix
    programs.beamenu.plugins.monitors = {
      title = "Monitors";
      keyword = "mon";
      commands = [
        {
          id = "apply";
          title = "Apply Monitor Layout";
          description = "Re-run hyprmon's auto-detection";
          mode = "exec";
          exec = [
            "hyprmon"
            "apply"
          ];
        }
        {
          id = "override";
          title = "Monitor Override Editor";
          description = "Edit per-monitor overrides (terminal)";
          mode = "terminal";
          exec = [
            "hyprmon"
            "override"
          ];
        }
      ];
    };
```

- [ ] **Step 2: Eval-check** (Task 4 Step 2 commands). Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add nix/home/hyprmon.nix
git commit -m "feat(nix): hyprmon monitors plugin for beamenu"
```

---

### Task 7: dots vault-keys command (bitwarden)

**Files:**
- Modify: `nix/home/apps/bitwarden.nix` (in the same config block that puts
  `dots-keys` into `home.packages`, `bitwarden.nix:119`)

**Interfaces:**
- Consumes: `dots` plugin identity from Task 5.
- Produces: the `dots` plugin's second command.

- [ ] **Step 1: Contribute the command**

```nix
    programs.beamenu.plugins.dots.commands = [
      {
        id = "vault-keys";
        title = "Bootstrap Vault Keys";
        description = "Unlock rbw and install SSH/signing keys (terminal)";
        mode = "terminal";
        exec = [ "dots-keys" ];
      }
    ];
```

- [ ] **Step 2: Eval-check + render-check `dots.json`** (as Task 5 Step 3 but
for `beamenu/plugins/dots.json`). Expected: both `keybinds` and `vault-keys`
present.

- [ ] **Step 3: Commit**

```bash
git add nix/home/apps/bitwarden.nix
git commit -m "feat(nix): vault-keys bootstrap reachable from beamenu"
```

---

### Task 8: net plugin commands (proton + waybar modules)

**Files:**
- Modify: `nix/home/proton/proton.nix` (VPN + bridge commands, beside its
  `protonvpn-app.service` config)
- Modify: `nix/home/waybar.nix` (NetworkManager commands, beside the pill
  scripts they mirror)

**Interfaces:**
- Consumes: `net` plugin identity from Task 5.
- Produces: four `net` commands.

- [ ] **Step 1: Verify the bridge unit name.** Read
`nix/home/waybar.nix:30-40,180-185` — the restart command must target exactly
the unit the bridge pill watches (expected `protonmail-bridge.service`; use
what the file actually says).

- [ ] **Step 2: Contribute from `proton.nix`:**

```nix
    programs.beamenu.plugins.net.commands = [
      {
        id = "vpn-status";
        title = "VPN Status";
        description = "Active connections, VPN first";
        mode = "view";
        exec = [
          "nmcli"
          "connection"
          "show"
          "--active"
        ];
      }
      {
        id = "bridge-restart";
        title = "Restart Mail Bridge";
        description = "Bounce the ProtonMail bridge user service";
        mode = "exec";
        exec = [
          "systemctl"
          "--user"
          "restart"
          "protonmail-bridge.service"
        ];
      }
    ];
```

- [ ] **Step 3: Contribute from `waybar.nix`:**

```nix
    programs.beamenu.plugins.net.commands = [
      {
        id = "status";
        title = "Network Status";
        description = "NetworkManager device overview";
        mode = "view";
        exec = [
          "nmcli"
          "device"
          "status"
        ];
      }
      {
        id = "wifi-list";
        title = "Wi-Fi Networks";
        description = "Scan and list visible networks";
        mode = "view";
        exec = [
          "nmcli"
          "device"
          "wifi"
          "list"
        ];
      }
    ];
```

(`mode = "view"` with default `ui = "log"` pipes stdout into the canvas —
the right shape for read-only status output.)

- [ ] **Step 4: Eval-check + render-check `net.json`.** Expected: four
commands after merge.

- [ ] **Step 5: Commit**

```bash
git add nix/home/proton/proton.nix nix/home/waybar.nix
git commit -m "feat(nix): network and proton commands for beamenu"
```

---

### Task 9: sweep — full gates and cheatsheet wording

**Files:**
- Possibly modify: `nix/home/desktop/keybinds.nix:22` (only if wording needs it)

- [ ] **Step 1:** Run the full per-crate gate for all three beamenu crates
(fmt --check, clippy `-D warnings`, test; `BMV` prefix for `rust/beamenu`) and
the eval-check from Task 4. All green.

- [ ] **Step 2:** Try `nix run --impure .#nix-lint`; if it dies at
`nix build .#abstracttui`, record that as the known pre-existing failure and
rely on Step 1.

- [ ] **Step 3:** Read `nix/home/desktop/keybinds.nix:22`. The entry already reads
"Launcher (beamenu) — apps, settings, system, plugins"; it still covers the
new plugins, so change nothing unless a mismatch is found. If changed, commit:

```bash
git add nix/home/desktop/keybinds.nix
git commit -m "docs(nix): refresh launcher cheatsheet entry"
```
