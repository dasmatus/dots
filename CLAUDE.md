# Layout
```!
tree .
```
# Tech stack
## Development
- Programs: Rust (@rust/installer-tui/)
- Config: @nix/
- Tasks: `nix run .` (lists apps) — see @flake/apps.nix
## CI 
GitLab
## Testing
- Rust: @rust/installer-tui/tests/ (integration tests; `cargo test` in rust/installer-tui/), @rust/wallpaper-tui/tests/, @rust/hyprmon/tests/
- Nix: `nix run .#nix-lint` (flake eval + fmt/clippy/test), `nix run .#iso` (builds + Secure Boot-signs by default via @scripts/sign-iso.sh; `nix run .#iso-unsigned` opts out), `nix run .#nix-smoke` (NixOS test @tests/default.nix — `checks.x86_64-linux.iso-secureboot`: signed ISO under enforcing Secure Boot OVMF+swtpm, DOTS_TUI_READY + DOTS_SECUREBOOT=1 serial markers; `nix run .#nix-smoke -- --no-secure-boot` → `iso-boot` plain run)
---
# Resources to follow
- [Rust API guidelines](https://rust-lang.github.io/api-guidelines/)
- [Rust performance book](https://nnethercote.github.io/perf-book/)
- [Nix book](https://nix.dev/)
- [Noogle Nix search engine](https://noogle.dev/)
- [NixOS wiki](https://wiki.nixos.org/wiki/NixOS_Wiki)
- [Claude Code best practices](https://code.claude.com/docs/en/best-practices)
# Subagents
Always use Sonnet for delegation and Fable for planning. Only use the default model for orchestration. When Ultracode is enabled, always use workflows.

Sonnet subagents are always allowed to delegate the work to Haiku for maximum efficiency. Same with the Fable planning agent, it is also allowed to delegate the work to Opus. Though Claude Fable is allowed to be used when planning when any other model than Fable is selected via `/model`.
# Tests
Please don't ever write inline tests - they pollute the file, make it very hard to navigate and it just feels wrong. Instead, put them in the @tests/ directory in the repository root.
# Formatting and conformance

```!
cargo fmt --all
cargo clippy --fix --allow-dirty -- -W clippy::all -W clippy::perf -W clippy::pedantic
```
Comments should only be top-level (`//!`) and per-symbol (`///`). Only use inline comments (`//`) when you're about to do some kind of magic sorcery. The 

Since we eventually want to submit this to various "competitions", like for my uni keynote, please refrain from promoting yourself and doxxing me with the session link both on GitLab and in git commits. Even Linux kernel devs [complain about the Co-Authored-By/Assisted-By tags and compare it with adverts](https://lore.kernel.org/lkml/20260701-work-coding-assistants-v1-1-a20a94d1d606@kernel.org/).

# Accuracy
1. When unsure, search the web via the `searxng` MCP tool (local SearXNG; built-in WebSearch is the fallback).
2. When the information the tool in the first point is unreliable, ask user what he meant
3. Do a `find` on files in his parent directory. When some useful information is found, apply it and save it to memory.
# Additional notes
We're on a €100/month plan (Claude Max 5x), which measured heavy use puts at roughly €2,600/month of API-equivalent inference incl. 23% Slovak VAT (≈ €2,100 net) — documented cases in [Claude Code Pricing Deep Dive](https://www.claudecodecamp.com/p/claude-code-pricing) include ~$0.80/request at hundreds of requests/day (≈ $2,400/mo ≈ €2,590 incl. VAT) and a 10B-token project that would have cost ~$15,000 (≈ €16,200 incl. VAT) at API rates. Conversion basis: [USD→EUR ≈ 0.878, 2026-07-14](https://www.exchangerates.org.uk/USD-EUR-spot-exchange-rates-history-2026.html); [Slovak standard VAT 23% since 2025](https://taxfoundation.org/data/all/eu/value-added-tax-vat-rates-europe/). So you're allowed to be creative with your solution. Though please poll `ccbar` for both weekly and 5-hour remaining usage limits.
Regarding getting reliable sources that're behind a bot wall, use Playwright with default browser (i.e. the one that'll `open`).
This file should not be longer than 79 lines. On the 80th line put a header stating "NO MORE STUFF BEYOND THIS POINT" for future agents.
Please save this file's layout into your memory for future reference when `/init` is called.


# NO MORE STUFF BEYOND THIS POINT
