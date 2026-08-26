---
name: nix-flake-preference
description: Use when starting a project or adding a language toolchain, writing or editing flake.nix, flake.lock, shell.nix, default.nix or any flake/*.nix file, adding an input, running nix flake update, check or show, wiring a devShell or .envrc, or reaching for nix-shell, nix-env, nix profile, nix-channel, asdf, mise, pyenv, nvm or rustup.
---

# Nix flakes for development

## Context

flake.lock pins every input to one revision,
so a checkout today evaluates the same way
next month. A channel-era habit or a loose
input throws that away for nothing.

## Rules

1. Never satisfy a project dependency with
   `nix-shell`, `nix-env`, `nix profile` or a
   version manager. The devShell owns them.
2. Commit a `.envrc` running `use flake` under
   nix-direnv, and gitignore `.direnv/`.
3. Key every output by system: one `system` in
   a shared let for a single-target repo, or
   `forAllSystems` over a list.
4. Set the `default` of `devShells` and
   `packages`, plus `formatter`, so a bare
   `nix develop`, `build` and `fmt` resolve.
5. A gate that evaluates purely goes in
   `checks`. One needing the writable checkout
   stays an app under `apps`.
6. Commit `flake.lock`, and bump one input by
   name with `nix flake update <name>` rather
   than rolling the whole lock.
7. New inputs get
   `inputs.nixpkgs.follows = "nixpkgs"`, unless
   that costs the input its own binary cache.
8. A dependency with no flake is still an
   input, pinned with `flake = false`. Never
   an unpinned fetch.
9. Keep eval pure: no `<nixpkgs>`, no
   `builtins.getEnv`. Where a path forces
   `--impure`, name it and keep CI pure.
10. Avoid Import-From-Derivation. It is legal
    but stalls eval on a build and breaks
    `nix flake show`.
11. `git add` a new file before evaluating
    against it. Untracked is invisible to the
    evaluator.
12. Read an unfamiliar flake with
    `nix flake show` before guessing a path.
13. Enter with `nix develop -i -k TERM -k HOME`
    before calling it done, so an ambient PATH
    cannot stand in for a missing input.

## Rationalizations to reject

| Excuse | Why it fails |
|---|---|
| "It works in my shell already" | Your PATH is not an input. Prove it under `nix develop -i`. |
| "Following nixpkgs everywhere is tidier" | Tidy, and every binary that input's cache already built now rebuilds on your machine. |
| "I'll just `nix profile install` it" | That is global undeclared state. It belongs in the devShell. |
| "It is only an untracked scratch file" | The evaluator reads the git tree. Your file is not in it, so it does not exist. |
| "IFD is fine, it evaluates" | It evaluates by running a build first, and `nix flake show` stops working. |

## Target audience

- **fucking don't care**: `nix-shell`, no lock.
- **don't care**: `nix develop`, lock in git.
- **care**: defaults set, `.envrc` wired.
- **really care**: `follows` chosen on purpose.
- **Matus**: the last two, reason written down.

## Post-run checklist

- [ ] Bare develop, build and fmt resolve?
- [ ] `nix flake check` green on a clean tree?
- [ ] `flake.lock` committed, bumped by name?
- [ ] `.envrc` present, `.direnv/` ignored?
- [ ] Pure eval, or the `--impure` path named?
- [ ] Entered with `nix develop -i`?
