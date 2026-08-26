---
name: writing-good-installer
description: Use when touching anything on the install path, meaning the installer TUI in rust/installer-tui, the LiveISO, tests/default.nix, or any Nix module the ISO pulls in, and before claiming an installer change works. Applies to installers for any OS, not just this repo's.
---

# Writing a good installer

## Context

Every agent turned loose on an installer has
broken the install flow, because a change
that compiles is not a change that installs.
So the flow gets walked in a VM after every
change, never reasoned about instead.

## Rules

1. Build the ISO with `nix run .#iso`
   before and after the change.
2. Boot it in a VM whose disk size, CPU
   count and RAM come from `$RANDOM`, so no
   single sizing gets to be the lucky one.
3. Run the VM inside a nested compositor.
   The host session is in active use and
   must not be grabbed.
4. Walk the whole installer in that VM
   after every change, not once at the end.
5. If the flow breaks, fix it before moving
   on to anything else.
6. Drive the walkthrough from a script,
   preferably a Nix app beside `nix-smoke`,
   never by hand.
7. Capture every install stage, and the
   trigger that advanced it, as the script
   goes.
8. Skip the confirm page. It already works
   and adds nothing to the capture.
9. `nix run .#nix-smoke` stays green; it is
   the ISO-boots assertion, not the flow.
10. Never mark installer work done on a
    green build alone. Evidence is the
    captured walkthrough.
11. Installer tests live in `tests/`, never
    inline in the TUI source.

## Rationalizations to reject

| Excuse | Why it fails |
|---|---|
| "The ISO built, so the installer works" | Building an ISO exercises none of the install flow. |
| "I only touched the TUI" | The TUI is the install flow. |
| "Fixed sizing is more reproducible" | Fixed sizing hides the bugs only odd sizing finds. |
| "Nested compositors are fiddly, I'll just run it" | Then the VM steals the user's keyboard mid-install. |
| "I'll walk it manually this once" | A manual walk captures nothing and cannot be rerun. |

## Target audience

- **fucking don't care**: ships on a green
  build.
- **don't care**: boots the ISO once.
- **care**: installs by hand in a VM.
- **really care**: scripts the install and
  keeps the capture.
- **Matus**: the last two, on hardware that
  has to come back up afterwards.

## Post-run checklist

- [ ] ISO rebuilt after the change?
- [ ] VM disk, CPU and RAM randomized?
- [ ] Ran in a nested compositor?
- [ ] Every stage and its trigger captured?
- [ ] `nix run .#nix-smoke` green?
