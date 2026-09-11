# VM tests — NixOS test framework

The LiveISO boot oracle is a flake check built on
[`pkgs.testers.runNixOSTest`](https://nixos.org/manual/nixos/unstable/#sec-nixos-tests):
a hermetic `nix build` that boots the (plain, unsigned) ISO under OVMF +
swtpm — no libvirt, no host packages, no root. Defined in
[`default.nix`](default.nix), wired into `checks.x86_64-linux` in the flake.

| Check | What it proves |
|-------|----------------|
| `session-units` | eval-only, no VM, no build (see [`session-units.nix`](session-units.nix)): a standalone home-manager evaluation of the Hyprland/session refactor (`nix/home/desktop/session/actions.nix`, `nix/home/desktop/session/default.nix`, `nix/home/desktop/hyprland.nix`) never produces a relative `ExecStart`, gives every `app`/`action` bind a `dots-<name>@.service` template rather than a plain unit, strands no non-dispatch action without a unit or a `dots.session.commands` entry, keeps the rendered `hyprland.lua` free of any command line that isn't a `systemctl` call (and free of the old `hyprland.start` exec-once hook), keeps the eight portable session variables separate from the two the Hyprland module owns, and gives every `dots-screenshot-*` unit `KillMode = "process"` so hyprshot's backgrounded capture is not killed by cgroup teardown the moment its foreground watcher exits |
| `session-boot` | the Phase 0 boot oracle (see [`session-boot.nix`](session-boot.nix)): a real `runNixOSTest` — not eval-only — boots the actual Hyprland/UWSM/Quickshell desktop stack (the real `desktop.nix`, `hardening.nix`, `apparmor.nix`/`apparmor-store.nix`, and home-manager session, on a hand-built module list standing in only for `nixosConfigurations.tokyonight`'s disk/boot-chain modules) and asserts greetd comes up without restart-looping, the `hyprland-uwsm` session reaches `graphical-session.target`, `quickshell` is active (not silently condition-skipped), `hyprctl layers` shows the bar's bound layer-shell surface, and no user unit is failed or stuck auto-restarting. This is the gate every later hardening phase (XWayland removal, kernel lockdown, AppArmor enforcement) has to keep green — see `docs/superpowers/specs/2026-09-08-hardening-design.md` |
| `iso-boot` | the LiveISO (`.#iso`) boots through plain OVMF UEFI with an emulated TPM 2.0 and the cage kiosk's Quickshell session reaches tty1 — `DOTS_UI_READY` on the serial console |
| `userborn-reboot-login` | under userborn + mutable `/etc` (with `passwordFilesLocation` pinned to `/var/lib/nixos`), the yescrypt hash in the persisted shadow survives a cold restart (login still works after reboot) |
| `limine-install-home` | `nix/modules/system/limine-install.nix`'s HOME-provisioning fix (see [`limine-home.nix`](limine-home.nix)): with `$HOME` unset, or set to a directory a different user owns, the wrapper invokes the real `mktemp` binary and exports the owned temp dir it prints; with `$HOME` already owned by the caller, the wrapper leaves it alone |
| `limine-install-boot` | the installer plan (disko + `nixos-install` + TPM2 enroll) runs in a VM and the installed disk boots via Limine, asserting the TPM2-unlocked LUKS root reaches `multi-user.target` — proves `nixos-install` no longer aborts on `/etc/machine-id` under impermanence |

Also in `checks`: `nix-lint`-fast eval checks (`settings-eval`,
`facter-*-eval`, `hm-activation-eval`, `shell-service-eval`) and the
`dots-installer` package build — see `flake.nix`.

`hm-activation-eval` is the odd one out and worth knowing about.
home-manager concatenates every `home.activation` entry into a single bash
script, so an `exit` in any one of them ends the run — `linkGeneration`
included, which is the step that puts `~/.config` on disk. The script still
exits 0 and systemd still reports success, and `home.packages` still switch
because `useUserPackages` installs those through the NixOS closure instead.
That combination once left the Quickshell config sitting in the store, with
`qs` on `$PATH` and no `shell.qml` for it to read, while `~/.config` went on
tracking a generation from days earlier. The check reads the activation DAG
at eval time and fails on any entry that calls `exit`, naming it;
`checkLinkTargets` is exempt, because stopping on a file collision before
anything is linked is the whole job of that one.

`shell-service-eval` guards the other half of the same story: how the shell
gets *started*. `hyprland.start` fires once at compositor boot, so a `qs`
launched from that hook cannot come back on a rebuild — it sits dead until
the next login while the new QML waits in `~/.config`. The shell is a
systemd user unit for that reason, and the check asserts the parts that make
it work: wanted by `graphical-session.target` (starts it at login), the
config tree named in `X-Restart-Triggers` (nothing else in the unit changes
when the QML does, so without it sd-switch sees an identical file and
restarts only on a quickshell package bump), a bare `ExecStart` with no
`--path` (the instance has to be keyed to `~/.config/quickshell/shell.qml`,
which is where `qs ipc call` clients look), and no `hl.exec_cmd("qs")` left
in the hook to race a second shell onto the same socket at login.

## QML unit tests — `qml/`

[QtTest](https://doc.qt.io/qt-6/qtquicktest-index.html) over the arithmetic
behind the shell, run by `qmltestrunner` as the second step of `nix run
.#nix-lint`. Offscreen QPA, because the runner wants a platform plugin even
with nothing to draw.

`qmllint` type-checks the QML and still cannot see a unit error, which is what
these catch. The battery pill read Quickshell's `UPowerDevice.percentage`, a
0-1 fraction, as UPower's raw 0-100 D-Bus property, so a half-full battery
rounded to `0` and drew an empty red pill. Both values are a `double`, so only
a test tells them apart.

| File | Covers |
|------|--------|
| `tst_battery.qml` | `bar/battery.js` — fraction to whole percent, the eleven-glyph ramp index, waybar's 30/15 colour thresholds |
| `tst_preview.qml` | `launcher/preview.js` — file/image/directory kind, `file:` URL encoding, size formatting, and that a previewed path travels in argv rather than inside the shell script |

Those `.js` libraries hold pure functions only, so the tests need no
compositor, no D-Bus and no palette. `qmltestrunner` cannot instantiate a
component that inherits a Quickshell type, which is why the arithmetic lives
beside `Battery.qml` and `PreviewPane.qml` instead of inside them.

```
nix run .#nix-lint                     # qmllint, then these, then flake check
```

## Running

```
nix run .#nix-smoke                    # = nix build -L .#checks.x86_64-linux.iso-boot
nix run .#nix-smoke-interactive        # test driver Python REPL (see below)
```

Prerequisites: `nix` (flakes) and `/dev/kvm`. Without KVM, QEMU falls back
to TCG software emulation — works, but takes ages (that's what CI does).

The built check (`result/`) contains the test driver log and the full
serial transcript.

## Debugging

`nix run .#nix-smoke-interactive` drops you into the driver's Python REPL
with the boot VM defined
(`nix run .#checks.x86_64-linux.iso-boot.driverInteractive`):

```python
>>> machine.start()
>>> machine.wait_for_console_text("DOTS_UI_READY")
```

The booted ISO has **no test instrumentation** (no backdoor shell), so
assertions are console-only — `wait_for_console_text`, not
`wait_for_unit`/`succeed`. The interactive driver leaves `*.qcow2` /
`vm-state-*` behind in the cwd; `nix run .#clean` removes them.

## How it works (`default.nix`)

- **Boot** (`iso-boot`): `virtualisation.directBoot.enable = false` +
  `useEFIBoot` boot real OVMF firmware instead of the test driver's default
  `-kernel` shortcut; the ISO is attached as an IDE CD with `bootindex=0`
  (the blank 20 G root disk — a stand-in install target — carries
  `bootindex=1`). A swtpm TPM 2.0 is attached via `virtualisation.tpm.enable`
  — the installed system unlocks the LUKS root via a TPM2 token on PCR 7, so
  the chip the boot chain needs is emulated.
- **`userborn-reboot-login`** is a separate `runNixOSTest` (not ISO-based):
  it boots a minimal userborn + mutable-`/etc` system (with
  `passwordFilesLocation` pinned to `/var/lib/nixos`, mirroring production)
  using a declarative yescrypt `initialHashedPassword`, asserts `/etc/shadow`
  is a symlink into `/var/lib/nixos`, then shuts down and cold-starts the same
  persistent qcow2 to prove the hash survived.
- **`limine-install-boot`** is a two-node `runNixOSTest`: an `installer` node
  (test-instrumented VM — NOT the `installation-device` profile, which clashes
  with `runNixOSTest`'s read-only `nixpkgs.overlays`; it pulls
  `nixos-install-tools` directly — with swtpm + `mountHostNixStore`) runs
  `install.rs::plan()` — disko, `nixos-install` (with `/etc/machine-id`
  truncated to mirror the impermanence LiveISO, so a systemd-boot installer
  would abort and only Limine completes), and `systemd-cryptenroll
  --tpm2-device=auto` (no PCR policy — see below) + `--recovery-key` — on a
  blank `/dev/vda`; the installer roots on a blank `/dev/vdb` auto-formatted
  in the initrd (`auto-format-root-device.nix`). After `installer.shutdown()`,
  a `target` node reuses the same qcow2 + swtpm state
  (`target.state_dir = installer.state_dir`, plus a shared `system.name` so
  the swtpm state dir matches) and boots the installed disk via Limine. The
  TPM2 token is enrolled WITHOUT `--tpm2-pcrs`: the installer
  direct-kernel-boots (PCR 7 = 0) while the target boots via OVMF (PCR 7 ≠ 0),
  so a PCR-7-bound token could not unseal across the two VMs; PCR-7 binding is
  a bootloader-independent firmware-measurement property covered upstream by
  nixpkgs' `systemd-initrd-luks-tpm2.nix`. The test-settings tokyonight closure
  is pre-built (`mkTokyonight testSettings`) and placed in `extraDependencies`
  so `nixos-install` substitutes it from the host store with no network. The
  `dots` ISO is not used as the installer medium because it has no test
  instrumentation (no backdoor shell); the install steps are identical to the
  real installer. Joins the weekly/manual vm CI lane (heavy: full closure
  build + disko + `nixos-install` + reboot).

## CI

`.forgejo/workflows/ci.yml` (Codeberg Forgejo Actions) runs two lanes:

- **lint** (every push + PR): `nix flake check --no-build` + the cheap eval
  checks, and `cargo fmt/clippy/test` for `rust/installer-tui/`. Runs on the hosted
  `codeberg-medium` runner inside `nixos/nix` / `rust` containers.
- **vm** (weekly + manual): builds the boot check with
  `--option system-features "… kvm"`. Codeberg's hosted runners have no
  `/dev/kvm`, so these jobs target a `self-hosted, kvm` runner — until one is
  registered they stay pending and don't block the lint lane. Serial/driver
  logs are kept as job artifacts either way.
