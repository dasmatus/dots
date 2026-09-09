---
version: "0.1.2"
level: copilot
processes:
  design: copilot
  implementation: copilot
  testing: copilot
  documentation: copilot
  review: copilot
  deployment: assist
components:
  Wallpapers: none
  flake.lock: none
  nix/data/facter.json: none
  rust/settings-global/flake.lock: none
  rust/dots-memory-derive/Cargo.lock: none
  rust/dots-memory-mcp/Cargo.lock: none
  rust/dots-sandbox/Cargo.lock: none
  rust/installer-tui/Cargo.lock: none
  rust/pg-agentmem/Cargo.lock: none
  rust/settings-global/Cargo.lock: none
---

This format is based on [AI-DECLARATION.md](https://ai-declaration.md/en/0.1.2).

## Notes

An agent writes most of what lands here, working a whole task at a time and
stopping at the points that need a human decision. `nix/home/ai/claude.nix`
configures it. Permissions default to auto over an enumerated allowlist, which
is not the same as a narrow one: `Bash(git *)` and `Bash(python3 *)` cover a lot
of ground with no prompt. Auto mode skips the per-command confirmation, not the
questions that change what gets built. Five of the six stages sit at that level.
Deployment sits below it.

- **Implementation and testing are `copilot`.** An agent wrote the ratatui
  installer under `rust/installer-tui/`, the Quickshell session in
  `nix/home/desktop/quickshell/` and the QML suite in `tests/qml/`, a task at a
  time, against a plan a human approved before the work started.
- **Design and documentation are `copilot`.** The specs and plans under
  `docs/superpowers/` exist because a human answers the agent's questions before
  the agent writes anything. The prose in this repo went through the same loop.
- **Review is `copilot`, with no second human in it.** This is a solo repo that
  commits straight to `main`, so a review pass is one agent re-reading another
  agent's work. That catches real defects. It is not independent the way a pull
  request is.
- **Deployment is `assist` because there is no CD.** `.forgejo/workflows/ci.yml`
  lints and tests. Putting a config on real hardware is still a manual
  `nixos-rebuild switch` or a LiveISO booted by hand, and the installer makes
  you type `ERASE` before it touches a disk.
- **The `none` entries are about provenance, not about who typed them.**
  `Wallpapers/wh/` holds wallhaven downloads. The SVG sets under
  `Wallpapers/night/` and the four rasters in `Wallpapers/misc/` came from
  elsewhere and their origins are not recorded. Nix, cargo and the installer
  generate the lockfiles and `nix/data/facter.json`, whose committed copy is a
  `{}` stub. `REUSE.toml` covers the licensing side.
- **The patch under `nix/patches/chromaleon/` is derivative of upstream work.**
  The hunks originate here. The code they apply to came from upstream, and
  `REUSE.toml` names the authors who hold copyright on it.
- **Commits carry no AI attribution trailers, by policy.**
  `skills/dodging-cdb/SKILL.md` sets that rule out, and `CLAUDE.md` asks for the
  same thing about session links. A clean log is therefore not evidence of
  authorship either way. This file is where the question gets an answer instead.
