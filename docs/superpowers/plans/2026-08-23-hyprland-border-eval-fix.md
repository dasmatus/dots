# Hyprland Border Eval Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make wallpaper-driven Hyprland border tinting actually work by replacing the retired `hyprctl keyword` IPC with `hyprctl eval 'hl.config({...})'` and surfacing spawn/exit failures into `Status::borders` instead of discarding them.

**Architecture:** `hyprland_border_commands_for` (rust/wallpaper-tui/src/tint.rs:152) stays a pure argv builder — it now emits one `hyprctl eval` call using the flat dotted-string-key `hl.config` form that Hyprland 0.56.2's own Lua stub declares (`['general.col.active_border']`). The orchestrator `apply_tint_ctx` runs the commands with the instance signature from `TintCtx.his` pinned into the child's environment (so tests can target a nonexistent instance without ever touching the live session) and writes `"ok"` / `"error: …"` into the existing `Status.borders` field, which `apply_tint` already prints.

**Tech Stack:** Rust (wallpaper-tui crate), `std::process::Command`, integration tests in `rust/wallpaper-tui/tests/tint.rs`, Hyprland 0.56.2 Lua config IPC.

**Spec:** docs/superpowers/specs/2026-08-23-system-palette-single-source-design.md

## Global Constraints

- Phase 2 of the spec, self-contained: touches only `rust/wallpaper-tui/src/tint.rs` and `rust/wallpaper-tui/tests/tint.rs`. No Nix changes, no palette.json.
- The correct call form is `hyprctl eval 'hl.config({ ["general.col.active_border"] = "rgba(RRGGBBff)" })'` — flat dotted string keys, the `HL.ConfigKey` vocabulary `hl.get_config` reads back per Hyprland's own `hl.meta.lua` stub (line 1078). `hl.config`'s declared parameter type, `HL.ConfigOpt`, is actually nested (`general? -> col? -> active_border?`, line 1314); both forms have been verified to work at runtime on Hyprland 0.56.2, and the flat form is used here for simplicity. Never the `keyword` subcommand.
- `rgba()` takes bare hex: strip the leading `#` from the extracted accent (`extract_accent` returns `#RRGGBB`).
- `hyprland_border_commands_for` stays pure: `his` is an explicit parameter; tests never mutate process env.
- Never run hyprctl against the live session from tests: every spawned border command gets `HYPRLAND_INSTANCE_SIGNATURE` set from `ctx.his`, and tests use a bogus signature, which cannot reach any real compositor. The exact failure mode (hyprctl absent from PATH → spawn error; hyprctl present + bogus signature → nonzero exit) was NOT executed while planning, but the assertion is `starts_with("error:")`, which holds for both, so the test is robust either way.
- `hl.get_config` read-back verification: **YAGNI.** `hyprctl eval`'s exit status already distinguishes failure (hyprmon's `LiveHyprCtl` relies on exactly this), a read-back would need a live compositor so it could never run under `cargo test`, and visual confirmation belongs to the nested-headless-Hyprland/grim smoke procedure, not this code path. Do not add it.
- Tests live only in `rust/wallpaper-tui/tests/` — no inline `#[cfg(test)]`. Comments are `//!` / `///` only; inline `//` only where already present in the touched blocks.
- Gates per task, run from `rust/wallpaper-tui`: `nix shell nixpkgs#rustfmt -c cargo fmt --all` (rustfmt is NOT on ambient PATH) and `cargo clippy --fix --allow-dirty -- -W clippy::all -W clippy::perf -W clippy::pedantic`.
- Do NOT gate on `nix run .#nix-lint`: it is pre-existing broken at `nix build .#abstracttui` (`flake/apps.nix:81` references a package `flake/packages.nix` does not define). Gate on `cargo test` in `rust/wallpaper-tui` instead. Any `nix` command in this checkout also needs `--impure`, since `nix/data/settings.nix` is a symlink to `/var/lib/dots/settings.nix`.
- Commit messages: plain `fix:` style, no Co-Authored-By, no session links.
- Task 1 (error surfacing) lands before Task 2 (eval form) deliberately: while the retired no-op `keyword` argv is still emitted, Task 1's failing-test run is harmless even if a stray spawn inherits the real session env; once env pinning is in, Task 2's live-capable `eval` form can never reach the real compositor from tests.

---

### Task 1: Surface border-command failures into `Status::borders`

**Files:**
- Modify: `rust/wallpaper-tui/src/tint.rs` — replace the borders block at lines 412-425; add one private helper after `select_icon_theme` (after line 356).
- Test: `rust/wallpaper-tui/tests/tint.rs` — add one test after `apply_tint_generates_all_targets` (lines 184-210; its closing `}` is line 210).

**Interfaces:**
- Consumes: `pub struct TintCtx { pub his: Option<String>, … }` (tint.rs:35-51, fields already `pub`), `hyprland_border_commands_for(his: Option<&str>, accent: &str, accent_dark: &str) -> Option<Vec<Vec<String>>>` (tint.rs:152, unchanged in this task), test fixtures `tint_ctx` / `wallpaper` from `tests/common/mod.rs`.
- Produces: `fn run_border_commands(his: &str, cmds: &[Vec<String>]) -> String` (private, returns `"ok"` or `"error: …"`); `Status.borders` now carries `"skipped"` / `"ok"` / `"error: …"`.

- [ ] **Step 1: Write the failing test**

  Append to `rust/wallpaper-tui/tests/tint.rs`, directly after `apply_tint_generates_all_targets`, i.e. after its closing `}` on line 210 and the blank line 211 — immediately BEFORE the `#[test]` on line 212 that begins `apply_tint_caches_svg_trees_on_same_accent`. Do NOT insert at line 213: that is the next test's `fn` signature line, and inserting there would nest the new test inside it:

  ```rust
  #[test]
  fn apply_tint_surfaces_border_failure() {
      let d = tempdir().unwrap();
      let mut ctx = tint_ctx(d.path(), None, None);
      ctx.his = Some("wallpaper-tui-test-no-such-instance".into());
      let wp = wallpaper(d.path());
      let s = apply_tint_ctx(&ctx, wp.to_str().unwrap(), false, TintBackend::Internal).unwrap();
      assert!(
          s.borders.starts_with("error:"),
          "hyprctl against a nonexistent instance must surface into borders, got {:?}",
          s.borders
      );
  }
  ```

- [ ] **Step 2: Run test to verify it fails**

  ```
  cd /home/matus/Dokumente/codeberg/personal/dots/.claude/worktrees/swirling-plotting-yao/rust/wallpaper-tui && cargo test --test tint apply_tint_surfaces_border_failure
  ```

  Expected: 1 failed — `hyprctl against a nonexistent instance must surface into borders, got "ok"` (current code sets `s.borders = "ok"` unconditionally after `let _ =`-ing each spawn; the spawned command is still the retired `keyword` no-op, so this run cannot change the live session).

- [ ] **Step 3: Write minimal implementation**

  In `rust/wallpaper-tui/src/tint.rs`, add after `select_icon_theme` (after line 356):

  ```rust
  /// Spawn each border command with the instance signature pinned into the
  /// child's environment (so tests can target a nonexistent instance without
  /// touching the live session). The first failure short-circuits into an
  /// `error:` status; success is `"ok"`.
  fn run_border_commands(his: &str, cmds: &[Vec<String>]) -> String {
      for c in cmds {
          let run = Command::new(&c[0])
              .args(&c[1..])
              .env("HYPRLAND_INSTANCE_SIGNATURE", his)
              .stdout(std::process::Stdio::null())
              .stderr(std::process::Stdio::null())
              .status();
          match run {
              Ok(st) if st.success() => {}
              Ok(st) => return format!("error: {} exited {}", c[0], st.code().unwrap_or(-1)),
              Err(e) => return format!("error: spawn {}: {e}", c[0]),
          }
      }
      "ok".into()
  }
  ```

  Replace the borders block (lines 412-425, from `// Hyprland borders — runtime hyprctl keyword, always re-apply.` through its closing `}`):

  ```rust
      // Hyprland borders — spawned per apply; the first failure surfaces.
      s.borders = match ctx.his.as_deref() {
          None => "skipped".into(),
          Some(his) => match hyprland_border_commands_for(Some(his), &accent, &accent_dark) {
              None => "skipped".into(),
              Some(cmds) => run_border_commands(his, &cmds),
          },
      };
  ```

- [ ] **Step 4: Run test to verify it passes**

  ```
  cd /home/matus/Dokumente/codeberg/personal/dots/.claude/worktrees/swirling-plotting-yao/rust/wallpaper-tui && cargo test --test tint && nix shell nixpkgs#rustfmt -c cargo fmt --all && cargo clippy --fix --allow-dirty -- -W clippy::all -W clippy::perf -W clippy::pedantic
  ```

  Expected: all tint tests pass, including the existing `apply_tint_generates_all_targets` (`his: None` → `borders == "skipped"`, unchanged) and the new failure test (bogus signature → exit 4 → `error: hyprctl exited 4`, or a spawn error in a PATH-less sandbox — both start with `error:`). fmt and clippy clean.

- [ ] **Step 5: Commit**

  ```
  cd /home/matus/Dokumente/codeberg/personal/dots/.claude/worktrees/swirling-plotting-yao && git add rust/wallpaper-tui/src/tint.rs rust/wallpaper-tui/tests/tint.rs && git commit -m "fix: surface hyprctl border failures in tint status"
  ```

---

### Task 2: Emit `hyprctl eval 'hl.config({...})'` instead of the retired `keyword` IPC

**Files:**
- Modify: `rust/wallpaper-tui/src/tint.rs` — replace the doc comment and body of `hyprland_border_commands_for` (lines 148-172 pre-Task-1 numbering). The env wrapper `hyprland_border_commands` (lines 174-182) is untouched.
- Test: `rust/wallpaper-tui/tests/tint.rs` — replace `hyprland_borders_emit_two_keywords` (lines 68-97); `hyprland_borders_skip_without_hyprland` (line 64) stays as-is.

**Interfaces:**
- Consumes: nothing new.
- Produces: same signature — `pub fn hyprland_border_commands_for(his: Option<&str>, accent: &str, accent_dark: &str) -> Option<Vec<Vec<String>>>` — now returning a single argv `["hyprctl", "eval", "hl.config({ [\"general.col.active_border\"] = \"rgba(<hex>ff)\", [\"general.col.inactive_border\"] = \"rgba(<hex>ff)\" })"]`.

- [ ] **Step 1: Write the failing test**

  In `rust/wallpaper-tui/tests/tint.rs`, delete `hyprland_borders_emit_two_keywords` (lines 68-97) and put in its place (note `ACCENT = "#ff00aa"`, `ACCENT_DARK = "#330044"` from lines 22-23 — the `#` must be stripped in the output):

  ```rust
  #[test]
  fn hyprland_borders_emit_single_hl_config_eval() {
      let cmds = hyprland_border_commands_for(Some("deadbeef"), ACCENT, ACCENT_DARK).unwrap();
      assert_eq!(cmds.len(), 1, "one eval call sets both borders");
      assert_eq!(cmds[0][0], "hyprctl");
      assert_eq!(cmds[0][1], "eval");
      let lua = &cmds[0][2];
      assert!(lua.starts_with("hl.config({"), "flat-dotted hl.config call, got {lua}");
      assert!(lua.contains(r#"["general.col.active_border"] = "rgba(ff00aaff)""#));
      assert!(lua.contains(r#"["general.col.inactive_border"] = "rgba(330044ff)""#));
      assert!(!lua.contains('#'), "rgba() takes bare hex, no leading '#': {lua}");
  }

  #[test]
  fn hyprland_borders_never_use_retired_keyword_ipc() {
      let cmds = hyprland_border_commands_for(Some("deadbeef"), ACCENT, ACCENT_DARK).unwrap();
      assert!(
          cmds.iter().flatten().all(|arg| arg != "keyword"),
          "hyprctl keyword is a silent no-op under the Lua parser (0.55+)"
      );
  }
  ```

- [ ] **Step 2: Run test to verify it fails**

  ```
  cd /home/matus/Dokumente/codeberg/personal/dots/.claude/worktrees/swirling-plotting-yao/rust/wallpaper-tui && cargo test --test tint hyprland_borders
  ```

  Expected: `hyprland_borders_emit_single_hl_config_eval` fails at `assert_eq!(cmds.len(), 1)` with `left: 2, right: 1`; `hyprland_borders_never_use_retired_keyword_ipc` fails its `all(|arg| arg != "keyword")` assertion; `hyprland_borders_skip_without_hyprland` still passes. Pure function — nothing is spawned.

- [ ] **Step 3: Write minimal implementation**

  In `rust/wallpaper-tui/src/tint.rs`, replace the doc comment and body of `hyprland_border_commands_for` (the block that starts `/// \`hyprctl keyword\` argv for the border colors…` and ends with the closing `}` of the function):

  ```rust
  /// `hyprctl eval` argv setting both border colors through one
  /// `hl.config({...})` call with flat dotted string keys, the shape
  /// Hyprland's own `hl.meta.lua` stub declares for `HL.ConfigOpt`. The
  /// hyprlang `keyword` IPC was retired for the Lua parser in 0.55+ (exits 0,
  /// changes nothing), same as the `hyprctl keyword monitor` case hyprmon
  /// already migrated off. `rgba()` takes bare hex, so the accents' leading
  /// `#` is stripped. Returns `None` when Hyprland is not running (`his` is
  /// `None`). Pure: takes the Hyprland instance signature explicitly so
  /// tests don't mutate process-global env.
  #[must_use]
  pub fn hyprland_border_commands_for(
      his: Option<&str>,
      accent: &str,
      accent_dark: &str,
  ) -> Option<Vec<Vec<String>>> {
      his?;
      let active = accent.trim_start_matches('#');
      let inactive = accent_dark.trim_start_matches('#');
      Some(vec![vec![
          "hyprctl".into(),
          "eval".into(),
          format!(
              "hl.config({{ [\"general.col.active_border\"] = \"rgba({active}ff)\", \
               [\"general.col.inactive_border\"] = \"rgba({inactive}ff)\" }})"
          ),
      ]])
  }
  ```

- [ ] **Step 4: Run test to verify it passes**

  ```
  cd /home/matus/Dokumente/codeberg/personal/dots/.claude/worktrees/swirling-plotting-yao/rust/wallpaper-tui && cargo test --test tint && nix shell nixpkgs#rustfmt -c cargo fmt --all && cargo clippy --fix --allow-dirty -- -W clippy::all -W clippy::perf -W clippy::pedantic
  ```

  Expected: full tint suite green — including Task 1's `apply_tint_surfaces_border_failure`, which now exercises the eval form against the bogus pinned signature (exit 4, never the live session). fmt and clippy clean.

- [ ] **Step 5: Commit**

  ```
  cd /home/matus/Dokumente/codeberg/personal/dots/.claude/worktrees/swirling-plotting-yao && git add rust/wallpaper-tui/src/tint.rs rust/wallpaper-tui/tests/tint.rs && git commit -m "fix: apply wallpaper border tint via hyprctl eval hl.config"
  ```
