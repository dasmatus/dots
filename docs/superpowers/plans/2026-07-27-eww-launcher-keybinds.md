# eww app launcher + first-boot keyboard help — Implementation Plan

> **Goal:** Replace the rofi-based app launcher (`SUPER + D`) and first-login keybind cheatsheet (`~/.config/rofi/rofi-keybinds.sh`) with eww widgets. The app launcher should visually mirror the macOS Spotlight search bar (rounded, frosted, centered, wide input with a magnifier icon, results below). The keyboard-help screen becomes a frosted centered modal grouped by category. Rofi stays in place for the file manager and power menu.

**Tech Stack:** eww (Elkowars Wacky Widgets), yuck, SCSS, bash + jq + dex, Home Manager.

## Global Constraints

- **No inline tests** — repo rule; tests live under `tests/` at repo root if needed. This change is pure config/scripts, so no new tests are required beyond `nix run .#nix-lint`.
- **Comments:** top-level `//!`/`///`-style in Rust; module docstring + per-symbol docstrings in Python; Nix files use top-level `#` comments. Inline comments (`//`/`#`) only for non-obvious logic.
- **No Co-Authored-By / session-link doxxing** in commits or GitLab text.
- **Package names verified in this flake's nixpkgs:** `pkgs.eww`, `pkgs.jq`, `pkgs.dex`.
- **eww facts (verified from upstream docs):** config lives at `~/.config/eww/eww.yuck` + `~/.config/eww/eww.scss`; `image` widget supports `:icon` for theme icon names; `input` supports `:onchange` and `:onaccept`; `defwindow` supports `:focusable`; `include` can load other yuck files.
- **Rofi remains** for `rofi-files.sh` (file manager) and `rofi-power-menu`; only `tokyonight.rasi` comments may need a wording update to reflect that drun is no longer used.

---

## File Structure

- **Create** `nix/home/eww/default.nix` — install eww, jq, dex; declare `xdg.configFile` for the whole eww config tree.
- **Create** `nix/home/eww/eww.yuck` — main eww config: windows, widgets, variables, `include` of generated keybinds data.
- **Create** `nix/home/eww/eww.scss` — Spotlight-style launcher + frosted keybinds modal.
- **Create** `nix/home/eww/scripts/list-apps.sh` — enumerate `.desktop` entries, filter by query, emit JSON for eww.
- **Create** `nix/home/eww/scripts/launcher.sh` — toggle, search, select, launch, reset.
- **Create** `nix/home/eww/scripts/keybinds.sh` — first-boot sentinel + on-demand toggle.
- **Modify** `nix/home/desktop/keybinds.nix` — stop generating the rofi dmenu script; generate `~/.config/eww/keybinds.yuck` with the keybind list as a JSON `defvar`, and update comments.
- **Modify** `nix/home/desktop/hyprland.nix` — change `SUPER + D` to open the eww launcher; change the first-login exec and `SUPER + /` exec to the new eww keybinds script; bind `Escape` to close any open eww window.
- **Modify** `nix/home/default.nix` — import `nix/home/eww`.
- **Modify** `nix/home/rofi/default.nix` — update comments to clarify rofi is now used only for files/power-menu.
- **Modify** `nix/home/rofi/tokyonight.rasi` — update header comment to drop the "drun" claim.

---

## Design Details

### eww launcher

- **Window:** centered near top (`anchor "top center"`, `y "12%"`), width `680px`, height grows with results (initially just the search bar). `:focusable true`, `:stacking "overlay"`, `:exclusive false`.
- **Visual:** rounded search bar with a translucent dark/glass background (`rgba(26,27,38,0.85)` + `backdrop-filter: blur(20px)` where supported), accent-blue ring on focus, big magnifier glyph on the left, subtle shadow. Results list with rounded rows, selected row highlighted.
- **Interaction model:**
  - Input `:onchange` runs `launcher.sh search {}` → updates `launcher_apps` JSON.
  - Input `:onaccept` runs `launcher.sh launch` → launches the currently selected app (default index 0), then closes the window.
  - Clicking a result launches that app directly.
  - A close button (×) and a `SUPER + D` re-press toggle the window.
  - `Escape` closes any open eww window via a Hyprland bind.
  - Tab/Shift+Tab move GTK focus through results; Enter from a focused result launches it via its own `:onclick`.
- **Selection state:** `launcher_selected` integer; first result is selected by default; mouse hover can update it via `:onclick` setting the index before launching. Up/down arrow keys are not supported in this iteration because eww's `input` widget does not expose key events beyond `onaccept`.
- **App data JSON:** `[{ "name": "…", "icon": "…", "desktop": "…", "exec": "…", "index": 0 }]`. `icon` is the .desktop `Icon` field (theme name); `dex` is used for launching by desktop-file path.

### eww keybinds help

- **Window:** centered modal, frosted background, max width `900px`, max height `80%`, scrollable.
- **Data:** generated as `~/.config/eww/keybinds.yuck` containing `(defvar keybinds_data '[{...}]')` with the existing curated list from `keybinds.nix`, grouped by category.
- **Layout:** title, category sections, each with a key pill on the left and description on the right. Close button + `Escape` + `SUPER + /` to dismiss.
- **First-boot behavior:** `keybinds.sh` writes a sentinel under `$XDG_STATE_HOME/dots/keybinds-shown`; the first-login path sleeps 2 s then opens the window. `--force` skips the sentinel.

---

## Tasks

- [ ] **Task 1:** Create `nix/home/eww/default.nix` with packages and `xdg.configFile` wiring.
- [ ] **Task 2:** Create `nix/home/eww/eww.yuck` and `eww.scss` (launcher + keybinds windows).
- [ ] **Task 3:** Create `nix/home/eww/scripts/list-apps.sh` for dynamic app enumeration.
- [ ] **Task 4:** Create `nix/home/eww/scripts/launcher.sh` with toggle/search/launch/reset.
- [ ] **Task 5:** Create `nix/home/eww/scripts/keybinds.sh` with sentinel and toggle logic.
- [ ] **Task 6:** Rewrite `nix/home/desktop/keybinds.nix` to emit `~/.config/eww/keybinds.yuck` instead of the rofi script.
- [ ] **Task 7:** Update `nix/home/desktop/hyprland.nix` binds and first-login exec for eww.
- [ ] **Task 8:** Add `nix/home/eww` import in `nix/home/default.nix`.
- [ ] **Task 9:** Update rofi comments to reflect its narrowed role.
- [ ] **Task 10:** Run `nix run .#nix-lint` (flake eval + fmt/clippy/test) to validate.
