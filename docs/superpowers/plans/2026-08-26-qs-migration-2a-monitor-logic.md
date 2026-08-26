# Quickshell Migration 2a: Monitor Logic Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use
> superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** Port hyprmon's pure planning functions to JS under QtTest, with
the crate still running and still owning the monitors.
**Architecture:** `spec.rs`, `rules.rs`, `matcher.rs`, `plan.rs` and
`overrides.rs` are pure functions over parsed `hyprctl monitors -j`. They
become one `monitors/plan.js` with no QML surface, so all of it is testable
offscreen. Quickshell 0.3, Qt 6.11, QtTest. Needs plan 0.
**Spec:** `docs/superpowers/specs/2026-08-26-quickshell-tui-migration-design.md`

## Global Constraints
- The rules file stays `~/.config/hyprmon/rules.json` in this plan. It is
  renamed in 2b, once nothing reads it from Rust.
- Overrides stay a separate document from rules: `overrides.json` exists so
  a monitor hyprmon got wrong can be fixed without touching the Nix-managed
  ruleset, and merging the two would destroy that property.
- A `MonitorSpec` renders to exactly one `hyprctl keyword monitor` argument
  string. `render()`'s output is the contract 2b shells out with.

---

### Task 1: Parse and match
**Files:** create `qml/monitors/plan.js`, `tests/qml/tst_monitors.qml`.
**Produces** `parseMonitors(json)` -> array of `{name, make, model, serial,
width, height, refresh}`; `matchRule(monitor, rules)` -> the winning rule
or `null`, with the same precedence `matcher.rs` implements.

- [ ] **1** Port the table in `rust/hyprmon/tests/matcher.rs` into
      `tst_monitors.qml` as `test_matchRule_data()` rows, one per case
- [ ] **2** Run QtTest Expected: FAIL, `matchRule` undefined
- [ ] **3** Port `spec.rs`'s parse and `matcher.rs`'s precedence into
      `plan.js`
- [ ] **4** Run QtTest Expected: PASS, every row
- [ ] **5** `git commit -m "port the monitor matcher to the shell"`

### Task 2: Plan and render
**Files:** modify `qml/monitors/plan.js`, `tests/qml/tst_monitors.qml`.
**Consumes** Task 1. **Produces** `planFor(monitors, rules, overrides)` ->
array of `MonitorSpec`; `render(spec)` -> the `hyprctl keyword monitor`
argument string, byte-identical to `spec.rs`'s `render()`.

- [ ] **1** Port `rust/hyprmon/tests/plan.rs` and `tests/spec.rs` into
      `_data()` rows, including the disabled-output case
- [ ] **2** Run QtTest Expected: FAIL
- [ ] **3** Port `plan.rs` and `spec.rs`'s `render`
- [ ] **4** Run QtTest Expected: PASS
- [ ] **5** Capture the real thing: `hyprmon apply` prints one rendered
      spec per line. Assert `render()` reproduces those lines for the
      monitors currently attached
- [ ] **6** `git commit -m "port the monitor planner to the shell"`

### Task 3: Overrides
**Files:** modify `qml/monitors/plan.js`, `tests/qml/tst_monitors.qml`.
**Consumes** Task 2. **Produces** `applyOverrides(specs, overrides)`, the
last stage before render.

- [ ] **1** Port `rust/hyprmon/tests/overrides.rs` into `_data()` rows
- [ ] **2** Run QtTest Expected: FAIL
- [ ] **3** Port `overrides.rs`
- [ ] **4** Run QtTest Expected: PASS
- [ ] **5** `nix run .#nix-lint` Expected: green
- [ ] **6** `git commit -m "port the monitor overrides to the shell"`

### Task 4: Pin the port to the crate
**Files:** create `tests/qml/tst_monitor_parity.qml`.
**Produces** nothing new; this exists so 2b can delete the crate without
the parity evidence going with it.

- [ ] **1** Save `hyprctl monitors -j` and `hyprmon apply`'s output as
      fixtures under `tests/qml/fixtures/`
- [ ] **2** Write the parity test asserting `planFor` + `render` reproduce
      the saved `hyprmon apply` lines from the saved `hyprctl` JSON
- [ ] **3** Run QtTest Expected: PASS
- [ ] **4** `git commit -m "pin the ported monitor plan to the crate"`
