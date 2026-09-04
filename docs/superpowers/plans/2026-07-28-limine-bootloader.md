# Limine Bootloader Switch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `boot.loader.systemd-boot` with `boot.loader.limine` on the installed `tokyonight` system so `nixos-install` stops aborting on `/etc/machine-id` under impermanence, and prove the full Limine + TPM2 PCR-7 unlock chain end-to-end in a VM test.

**Architecture:** Declarative switch in `nix/modules/system/boot.nix` only (the installer Rust code is unchanged — `nixos-install` invokes the Limine `installBootLoader` hook automatically, and `systemd-cryptenroll` is bootloader-independent). Limine installs to the firmware's removable `\EFI\BOOT\BOOTX64.EFI` path (`canTouchEfiVariables = false`) so it never runs `efibootmgr` (immune to nixpkgs #493017). A new two-node NixOS test (`limine-install-boot`) runs the installer's `plan()` in a VM and boots the installed disk via Limine, asserting the TPM2-unlocked LUKS root comes up.

**Tech Stack:** NixOS flakes, `boot.loader.limine` (pinned nixos-unstable), `pkgs.testers.runNixOSTest`, OVMFFull + swtpm, disko LVM-on-LUKS, systemd initrd.

## Global Constraints

- No Secure Boot / UKI signing — `boot.loader.limine.secureBoot.enable` stays `false` (enabling it flips PCR 7 and breaks the TPM2 unseal).
- No `Co-Authored-By`/`Assisted-By` trailers in commits; no session links in commit messages or GitLab (CLAUDE.md). Commit messages reference only the change.
- No inline Rust tests; NixOS tests live in `tests/`. Comments are top-level (`//!`/`///`) or per-symbol (`///`); inline `//` only for "magic sorcery".
- `cargo fmt --all` + `cargo clippy --fix -- -W clippy::all -W clippy::perf -W clippy::pedantic` for any Rust change (none expected here).
- The ESP is a 2 G vfat partition at `/boot` (disko.nix) — do not change `disko.nix`.
- The installer Rust plan (`rust/installer-tui/src/install.rs`) is unchanged.

---

## File Structure

- **`nix/modules/system/boot.nix`** — the bootloader switch + rewritten header comment. Single responsibility: the boot chain.
- **`nix/README.md`** — boot-chain docs + concept-mapping row. Documentation only.
- **`flake/nixos.nix`** — refactor to expose `mkTokyonight = settings: nixosSystem{…}` so the test can build the closure with test settings; `tokyonight = mkTokyonight settings` is behavior-preserving.
- **`flake.nix`** — pass `mkTokyonight` + the flake source into `tests/`; strip `mkTokyonight` from `nixosConfigurations`.
- **`tests/default.nix`** — add `limine-install-boot` (two-node install+boot test).
- **`tests/README.md`** — checks-table row + "How it works" bullet.
- **`.forgejo/workflows/ci.yml`** — add `limine-install-boot` to the `vm-boot` matrix.

No changes to `rust/installer-tui/`, `nix/system/disko.nix`, `flake/checks.nix`, or `flake/apps.nix`.

---

### Task 1: Switch `boot.nix` from systemd-boot to Limine

**Files:**
- Modify: `nix/modules/system/boot.nix:1-4` (header comment) and `nix/modules/system/boot.nix:28-33` (loader block)

**Interfaces:**
- Consumes: `settings.plymouthTheme`, `settings.zswapCompressor`, `settings.bootKernelParams` (unchanged).
- Produces: `boot.loader.limine.enable = true` with `maxGenerations = 2`, `enableEditor = false`, and `boot.loader.efi.canTouchEfiVariables = false` — consumed by the test in Task 4 (the installed system boots via Limine).

- [ ] **Step 1: Rewrite the header comment**

Replace `nix/modules/system/boot.nix:1-4`:

```nix
# Boot chain: Limine + systemd initrd (TPM2 auto-unlock of the disko LUKS
# volume) + the kernel cmdline carried over from the retired Gentoo installer
# (git history). No Secure Boot / UKI signing — Limine boots the kernel + initrd
# straight off the ESP and sidesteps the /etc/machine-id dependency that
# impermanence (tmpfs `/` + immutable `/etc` + non-persisted machine-id) creates
# for systemd-boot at install time. See nix/README.md.
```

- [ ] **Step 2: Replace the loader block**

Replace `nix/modules/system/boot.nix:28-33` (the `loader.systemd-boot` + `loader.efi.canTouchEfiVariables` block):

```nix
    loader.limine = {
      enable = true;
      # was loader.systemd-boot.configurationLimit = 2 — Limine's equivalent.
      maxGenerations = 2;
      # was loader.systemd-boot.editor = false. Must be explicit: with Secure
      # Boot off the Limine module does not force-disable the editor, so without
      # this the boot menu would allow `init=/bin/sh` root access.
      enableEditor = false;
      # secureBoot.enable stays false (default) — enabling it would flip PCR 7
      # and break the TPM2 unseal, and Limine Secure Boot is upstream-in-development.
    };
    # was true. Makes efiInstallAsRemovable default to true → Limine installs to
    # \EFI\BOOT\BOOTX64.EFI and SKIPS efibootmgr, immune to nixpkgs #493017
    # (efibootmgr NVRAM write failure on quirky firmware, unfixed on master).
    loader.efi.canTouchEfiVariables = false;
```

Leave the rest of `boot.nix` (`plymouth`, `zswap`, `kernelParams`, `initrd.systemd.enable`, `availableKernelModules`, `hardware.enableRedistributableFirmware`, `security.tpm2.enable`) unchanged.

- [ ] **Step 3: Verify the flake evaluates with Limine**

Run: `nix flake check --no-build`
Expected: PASS — `nix flake check --no-build` evaluates every `checks.x86_64-linux.*` (including `facter-stub-eval`, which evaluates `self.nixosConfigurations.tokyonight.config`), so this catches any Limine module assertion or config error. If it fails, read the assertion message (likely a Limine `efiSupport`/`biosSupport` assertion or an option typo).

- [ ] **Step 4: Verify the tokyonight closure builds with Limine**

Run: `nix build .#nixosConfigurations.tokyonight.config.system.build.toplevel --out-link result-toplevel`
Expected: PASS — the full tokyonight closure builds with `boot.loader.limine` (the `installBootLoader` script is `limine-install.sh`). This confirms the Limine config produces a buildable system, not just an evaluable one.

- [ ] **Step 5: Commit**

```bash
git add nix/modules/system/boot.nix
git commit -m "feat(nixos): switch installed-system bootloader to Limine

Replace boot.loader.systemd-boot with boot.loader.limine. Limine sidesteps
the /etc/machine-id dependency that impermanence (tmpfs root + immutable
/etc + non-persisted machine-id) creates for systemd-boot at install time
— systemd-boot-builder.py reads /etc/machine-id and aborts nixos-install
when it is empty; limine-install.py has no machine-id reference.

configurationLimit=2 → maxGenerations=2; editor=false → enableEditor=false
(must be explicit with Secure Boot off). canTouchEfiVariables=false makes
efiInstallAsRemovable default true → Limine installs to
\\EFI\\BOOT\\BOOTX64.EFI and skips efibootmgr (immune to nixpkgs #493017).

PCR 7 is firmware-measured Secure Boot policy, not bootloader-dependent, so
the TPM2 auto-unlock chain is unaffected. Secure Boot stays off."
```

---

### Task 2: Update `nix/README.md` for the Limine boot chain

**Files:**
- Modify: `nix/README.md:105-125` (the "Disk encryption (no Secure Boot)" section) and `nix/README.md:28` (the concept-mapping table row)

**Interfaces:**
- Consumes: the boot-chain facts from the spec.
- Produces: documentation consistent with the new boot.nix.

- [ ] **Step 1: Update the concept-mapping table row**

Replace `nix/README.md:28`:

```markdown
| ukify UKI + self-generated Secure Boot db keys | Limine, no Secure Boot / UKI signing — TPM2 auto-unlock + LUKS recovery key only (systemd-boot replaced: it aborted nixos-install on the empty `/etc/machine-id` that impermanence produces) |
```

- [ ] **Step 2: Rewrite the "Disk encryption (no Secure Boot)" opening**

Replace the first two paragraphs of `nix/README.md:105-109` (from `Secure Boot / UKI signing was removed` through `Boot is plain \`systemd-boot\` off the ESP.`) with:

```markdown
Secure Boot / UKI signing was removed — neither the installed system nor the
LiveISO is signed, and `lanzaboote`, `sbctl`, the Microsoft-signed shim and
`scripts/sign-iso.sh` are all gone. Boot is plain **Limine** off the ESP.

Limine replaces systemd-boot because `systemd-boot-builder.py` reads
`/etc/machine-id` and aborts `nixos-install` when it is empty — exactly the
state this system's impermanence setup produces at install time (tmpfs `/`
wiped each boot, `system.etc.overlay.mutable = false`, and `/etc/machine-id`
intentionally not persisted). `limine-install.py` has no machine-id
dependency. Limine installs to the firmware's removable `\EFI\BOOT\BOOTX64.EFI`
path (`boot.loader.efi.canTouchEfiVariables = false`), so it never runs
`efibootmgr` and is immune to the efibootmgr NVRAM-write failure
(nixpkgs #493017).

PCR 7 (the TPM2 unlock binding) is firmware-measured Secure Boot policy, not
bootloader-dependent — neither systemd-boot nor Limine writes PCR 7, and
Secure Boot is off on both the LiveISO and the installed system, so the
unseal value is identical between enrollment and first boot via Limine.
```

Leave the rest of the section (the LUKS root unlock paths, the random-keyfile flow) unchanged.

- [ ] **Step 3: Verify the docs render sensibly**

Run: `sed -n '105,130p' nix/README.md`
Expected: the rewritten paragraphs flow into the unchanged "The LUKS root … unlocks two ways" list with no dangling reference to systemd-boot in the boot-chain description.

- [ ] **Step 4: Commit**

```bash
git add nix/README.md
git commit -m "docs(nix): document the Limine boot chain + machine-id rationale"
```

---

### Task 3: Expose `mkTokyonight` so the test can build a test-settings closure

**Why:** `nixos-install --flake /tmp/dots-flake#tokyonight` in the test evaluates the flake with the test's `settings.nix` (`disks=["/dev/vda"]`, `swapSize="1G"`), which changes the disko-generated `swapDevices`/disk entries and therefore the toplevel. With `mountHostNixStore` and no substituters, `nixos-install` can only copy a closure already in the host store — so the test must pre-build the tokyonight closure **with test settings** and put it in `extraDependencies`. The committed-settings closure (built with `/dev/nvme0n1` + 32 G swap) cannot be reused. This refactor parameterizes the tokyonight builder by `settings` without changing the real `tokyonight`.

**Files:**
- Modify: `flake/nixos.nix:1-49` (parameterize the tokyonight builder)
- Modify: `flake.nix:92-101` (strip `mkTokyonight` from `nixosConfigurations`) and `flake.nix:124-133` (pass `mkTokyonight` + flake source to `tests/`)

**Interfaces:**
- Consumes: `settings` (flake/lib.nix), `inputs`, `nixpkgs`, `mkIso`.
- Produces: `mkTokyonight : settings -> nixOS` (a `nixosSystem` eval), exported from `flake/nixos.nix` and threaded through `flake.nix` into `tests/default.nix` (Task 4). `tokyonight = mkTokyonight settings` is byte-for-byte the same config as before.

- [ ] **Step 1: Parameterize `flake/nixos.nix`**

Replace the `tokyonight = nixpkgs.lib.nixosSystem { … };` block (`flake/nixos.nix:14-43`) with a `let mkTokyonight = s: …; in` and expose `mkTokyonight` alongside the configs. The full new body of the returned attrset:

```nix
let
  # The tokyonight module list + specialArgs, parameterized only by `settings`
  # so the VM install test (tests/default.nix) can build the closure with test
  # settings (disks=["/dev/vda"], swapSize="1G") and pre-substitute it via
  # mountHostNixStore — the committed-settings closure can't be reused because
  # disko's swapDevices/disk entries change the toplevel. `tokyonight` below is
  # `mkTokyonight settings` (committed settings), so this is behavior-preserving.
  mkTokyonight =
    s:
    nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = {
        inherit inputs;
        settings = s;
        aipageFirefox = inputs.self.packages.x86_64-linux.aipage-firefox;
        aipageChrome = inputs.self.packages.x86_64-linux.aipage-chrome;
        wallpaperTui = inputs.self.packages.x86_64-linux.wallpaper-tui;
        hyprmon = inputs.self.packages.x86_64-linux.hyprmon;
        hyprlandPkg = inputs.hyprland.packages.x86_64-linux.hyprland;
      };
      modules = [
        inputs.disko.nixosModules.disko
        inputs.home-manager.nixosModules.home-manager
        inputs.impermanence.nixosModules.impermanence
        (import ../nix/system/disko.nix { inherit (s) disks swapSize; })
        ../nix/modules/system/core.nix
        ../nix/modules/system/impermanence.nix
        ../nix/modules/system/boot.nix
        ../nix/modules/system/network.nix
        ../nix/modules/services/searxng.nix
        ../nix/modules/system/virtualisation.nix
        ../nix/modules/system/users.nix
        ../nix/modules/system/hardening.nix
        ../nix/modules/services/maintenance.nix
        ../nix/modules/desktop/desktop.nix
        ../nix/modules/system/form-factor.nix
        ../nix/modules/desktop/steam.nix
        ../nix/system/hosts.nix
      ];
    };
in
{
  tokyonight = mkTokyonight settings;
  # Lean by default: the flake rides on the ISO, packages come from the
  # binary cache during install. live-iso-full embeds the prebuilt system
  # closure for offline installs (much bigger image).
  live-iso = mkIso false;
  live-iso-full = mkIso true;
  # Exposed for tests/default.nix to build a test-settings closure. NOT a
  # nixosSystem — stripped from nixosConfigurations in flake.nix.
  inherit mkTokyonight;
}
```

Keep the existing file header comment and the `{ inputs, nixpkgs, settings, mkIso, ... }:` argument line.

- [ ] **Step 2: Strip `mkTokyonight` from `nixosConfigurations` and thread it to `tests/`**

In `flake.nix`, change the `nixosConfigurations` output (`flake.nix:94-101`) to drop the non-config attr:

```nix
    nixosConfigs = import ./flake/nixos.nix {
      inherit inputs nixpkgs settings mkIso;
    };
    nixosConfigurations = builtins.removeAttrs nixosConfigs [ "mkTokyonight" ];
```

Then change the `checks.${system}` tests import (`flake.nix:129-133`) to pass `mkTokyonight` and the flake source:

```nix
        # LiveISO boot oracle (NixOS test framework) — see tests/README.md.
        // import ./tests {
          inherit pkgs;
          inherit (pkgs) lib;
          inherit (self.packages.${system}) iso;
          inherit (nixosConfigs) mkTokyonight;
          dotsFlake = self;
        };
```

- [ ] **Step 3: Verify the refactor is behavior-preserving**

Run: `nix build .#nixosConfigurations.tokyonight.config.system.build.toplevel --out-link result-refactor`
Expected: PASS — produces the exact same tokyonight closure as before the refactor (the module list + specialArgs for `settings` are identical). `nix path-info` of the result should match the pre-refactor path if the store is warm.

Run: `nix flake check --no-build`
Expected: PASS — `nixosConfigurations` no longer contains the `mkTokyonight` function attr (which would break `nix flake check`'s nixosConfigurations validation), and the eval checks still pass.

- [ ] **Step 4: Commit**

```bash
git add flake/nixos.nix flake.nix
git commit -m "refactor(flake): expose mkTokyonight settings parameterization

Parameterize the tokyonight nixosSystem by settings so the VM install test
can pre-build the closure with test settings (disks/swap differ from the
committed values) and substitute it via mountHostNixStore. tokyonight =
mkTokyonight settings is unchanged; mkTokyonight is stripped from
nixosConfigurations and threaded to tests/."
```

---

### Task 4: Add the `limine-install-boot` VM test

**This is the highest-risk task** — it boots a real disko LVM-on-LUKS + impermanence + Limine + TPM2 chain in a VM and is slow (full closure build + disko + `nixos-install` + reboot). Expect iterative debugging: serial logs are in `result/` after `nix build -L .#checks.x86_64-linux.limine-install-boot`. Run it with KVM (`--option system-features "nixos-test benchmark big-parallel kvm"`); under TCG it is impractically slow. The test config below mirrors `nixos/tests/installer.nix` (two-node install+boot, shared qcow2 + swtpm state) and `nixos/tests/systemd-initrd-luks-tpm2.nix` (OVMFFull + swtpm + PCR-7 enroll → reboot → assert mount).

**Files:**
- Modify: `tests/default.nix` (add `limine-install-boot` to the returned attrset; add `testSettings`, `testTokyonight`, `limineInstallBootTest` bindings in the `let`)
- Modify: `tests/default.nix` argument destructuring to accept `mkTokyonight` and `dotsFlake`

**Interfaces:**
- Consumes: `mkTokyonight` (Task 3), `dotsFlake` (the flake source at `/etc/dots` in the installer VM), `pkgs`, `lib`, `iso`, the existing `testHash`.
- Produces: `checks.x86_64-linux.limine-install-boot` (a `runNixOSTest`).

- [ ] **Step 1: Accept the new arguments in `tests/default.nix`**

Change the function header (`tests/default.nix:10-14`) from `{ pkgs, lib, iso, }:` to:

```nix
{
  pkgs,
  lib,
  iso,
  mkTokyonight,
  dotsFlake,
}:
```

- [ ] **Step 2: Add the test-settings closure + test bindings**

In the `let` of `tests/default.nix` (after the existing `testHash` binding, before `isoBootTest`), add:

```nix
  # tokyonight with VM-sized disks/swap so the disko layout fits /dev/vda and
  # the closure can be pre-built. The committed settings.nix has /dev/nvme0n1 +
  # 32G swap, which changes the toplevel — see docs/superpowers/specs/
  # 2026-07-28-limine-bootloader-design.md §3 (closure-feasibility note).
  testSettings = (import ../nix/system/defaults.nix) // {
    username = "test";
    hostname = "test";
    disks = [ "/dev/vda" ];
    swapSize = "1G";
    gitName = "Test User";
    gitEmail = "test@example.com";
  };
  # The tokyonight closure built with test settings. Pre-substituted into the
  # installer VM via mountHostNixStore + extraDependencies so nixos-install needs
  # no network (the test VM has no substituter access). nixos-install evaluates
  # /tmp/dots-flake#tokyonight with the test settings.nix written in step 4 of
  # the testScript, which matches this closure.
  testTokyonight = mkTokyonight testSettings;
  testToplevel = testTokyonight.config.system.build.toplevel;
  # Flake input source paths the installer VM needs to evaluate the flake
  # (mountHostNixStore exposes the host store, but only paths listed in
  # extraDependencies are guaranteed pulled into the test build's closure).
  flakeInputPaths = [
    inputs.nixpkgs.outPath
    inputs.home-manager.outPath
    inputs.disko.outPath
    inputs.impermanence.outPath
    inputs.nixvim.outPath
    inputs.haumea.outPath
    inputs.hyprland.outPath
  ];
```

`inputs` is not currently in `tests/default.nix`'s scope — add it by changing the function header to also accept `inputs` and passing it from `flake.nix` (`inherit inputs;` in the `import ./tests` call). `inputs` is already in `flake.nix`'s scope.

- [ ] **Step 3: Add the `limineInstallBootTest` definition**

After the `userbornRebootLogin` binding and before the final `in { … }`, add:

```nix
  # Full install+boot oracle for the Limine switch: runs the installer's plan()
  # (rust/installer-tui/src/install.rs) in a VM, then boots the installed disk
  # via Limine and asserts the TPM2-unlocked LUKS root comes up. Two nodes share
  # the same qcow2 + swtpm state (target.state_dir = installer.state_dir) so the
  # TPM2 owner seed persists and the PCR-7-bound token unseals on the target.
  # The dots ISO itself has no test instrumentation (no backdoor shell), so the
  # installer node is a test-instrumented installation-device VM, not the raw
  # ISO; the install steps are identical to install.rs::plan().
  limineInstallBootTest =
    pkgs.testers.runNixOSTest {
      name = "limine-install-boot";
      # Full closure build + disko + nixos-install + reboot under TCG is slow.
      globalTimeout = 4 * 60 * 60;

      nodes = {
        # Installer: test-instrumented NixOS with the dots flake at /etc/dots,
        # the tools the plan needs, and the pre-built test-settings closure
        # available via mountHostNixStore.
        installer =
          { pkgs, ... }:
          {
            imports = [
              (pkgs.path + "/nixos/modules/profiles/installation-device.nix")
            ];
            virtualisation = {
              useEFIBoot = true;
              # Only OVMFFull contains the TCG/TIS module the swtpm needs.
              efi.OVMF = pkgs.OVMFFull;
              tpm.enable = true;
              mountHostNixStore = true;
              # 20G blank install target as /dev/vda (matches iso-boot's disk).
              emptyDiskImages = [ 20 * 1024 ];
            };
            nix.settings.experimental-features = [
              "nix-command"
              "flakes"
            ];
            environment.etc."dots".source = dotsFlake;
            environment.systemPackages = [
              pkgs.disko
              pkgs.cryptsetup
              pkgs.tpm2-tools
              pkgs.nixos-facter
            ];
            # Everything nixos-install needs to evaluate + copy the closure
            # with no network: the test-settings toplevel + flake input
            # sources. mountHostNixStore exposes the host store into the VM.
            system.extraDependencies = [ testToplevel ] ++ flakeInputPaths;
          };

        # Target: boots the installed disk via Limine. Its NixOS config is just
        # the VM container (OVMF, swtpm, the shared qcow2); the actual booted
        # system is the tokyonight nixos-install wrote to /dev/vda.
        target =
          { pkgs, ... }:
          {
            virtualisation = {
              useBootLoader = true;
              useEFIBoot = true;
              efi.OVMF = pkgs.OVMFFull;
              tpm.enable = true;
              # Share the installer's qcow2 (the installed disk) + swtpm state.
              diskImage = "./target.qcow2";
              useDefaultFilesystems = false;
              efi.keepVariables = false;
            };
          };
      };

      testScript =
        { nodes, ... }:
        ''
          # Boot the installer VM.
          installer.start()
          installer.wait_for_unit("multi-user.target")
          installer.succeed("udevadm settle")

          with subtest("Run the installer plan (mirrors install.rs::plan)"):
              # 1. Write the LUKS keyfile.
              installer.succeed("umask 077; head -c 64 /dev/urandom > /tmp/dots-luks-pass")
              # 2. Partition, encrypt, mount via disko (test disks/swap).
              installer.succeed(
                  "disko --mode destroy,format,mount --yes-wipe-all-disks"
                  " --arg disks '[\"/dev/vda\"]' --argstr swapSize 1G"
                  " /etc/dots/nix/system/disko.nix"
              )
              # 3. Stage a writable flake copy for nixos-install.
              installer.succeed(
                  "rm -rf /tmp/dots-flake && mkdir -p /tmp/dots-flake"
                  " && cp -rTL /etc/dots /tmp/dots-flake"
                  " && chmod -R u+w /tmp/dots-flake"
              )
              # 4. Write the install answers + password hashes into the staged
              #    flake (settings.nix must match testSettings so nixos-install
              #    substitutes the pre-built testToplevel).
              installer.succeed("cat > /tmp/dots-flake/nix/data/settings.nix <<'EOF'\n"
                + '{\n  username = "test";\n  hostname = "test";\n'
                + '  disks = [ "/dev/vda" ];\n  swapSize = "1G";\n'
                + '  gitName = "Test User";\n  gitEmail = "test@example.com";\n}\n'
                + "EOF")
              installer.succeed("cat > /tmp/dots-flake/nix/secrets.nix <<'EOF'\n"
                + '{\n  userHash = "${testHash}";\n}\n'
                + "EOF")
              # 5. nixos-install — the load-bearing step: under impermanence this
              #    aborted with systemd-boot (machine-id IndexError); with Limine
              #    it must complete.
              installer.succeed(
                  "nixos-install --root /mnt --no-root-passwd"
                  " --flake /tmp/dots-flake#tokyonight < /dev/null"
              )
              # 6. Enroll TPM2 (PCR 7) + recovery key, matching install.rs.
              installer.succeed(
                  "systemd-cryptenroll --unlock-key-file=/tmp/dots-luks-pass"
                  " --tpm2-device=auto --tpm2-pcrs=7 /dev/tokyonightvg/root"
              )
              installer.succeed(
                  "systemd-cryptenroll --unlock-key-file=/tmp/dots-luks-pass"
                  " --recovery-key /dev/tokyonightvg/root >&2"
              )
              # 7. Shred the keyfile.
              installer.succeed("shred -u /tmp/dots-luks-pass")
              installer.succeed("umount -R /mnt || true")
              installer.succeed("sync")
              installer.shutdown()

          # Boot the installed disk via Limine. Sharing state_dir shares the
          # qcow2 AND the swtpm owner seed, so the PCR-7-bound token unseals.
          target.state_dir = installer.state_dir
          target.start()

          with subtest("Installed system boots via Limine + TPM2 auto-unlock"):
              target.wait_for_unit("multi-user.target")
              # multi-user.target is only reachable if the LUKS root auto-unlocked
              # via the TPM2 token (no recovery-key prompt in a non-interactive
              # boot). Confirm the mapper is the root backing device.
              assert "/dev/mapper/cryptroot" in target.succeed("mount"), \
                  "cryptroot not mounted — TPM2 PCR-7 unseal did not fire"
        '';
    };
```

- [ ] **Step 4: Add `limine-install-boot` to the returned attrset**

Change the final `in { … }` of `tests/default.nix` from:

```nix
in
{
  iso-boot = isoBootTest;
  userborn-reboot-login = userbornRebootLogin;
}
```

to:

```nix
in
{
  iso-boot = isoBootTest;
  userborn-reboot-login = userbornRebootLogin;
  limine-install-boot = limineInstallBootTest;
}
```

- [ ] **Step 5: Verify the test evaluates**

Run: `nix flake check --no-build`
Expected: PASS — the new `limine-install-boot` check evaluates (catches Nix errors in the test node configs / testScript). If it fails on `inputs` not being in scope, confirm `tests/default.nix` accepts `inputs` and `flake.nix` passes `inherit inputs;` to `import ./tests`.

- [ ] **Step 6: Run the test (needs KVM; slow)**

Run: `nix build -L .#checks.x86_64-linux.limine-install-boot --option system-features "nixos-test benchmark big-parallel kvm"`
Expected: PASS — the installer VM boots, the plan runs, `nixos-install` completes (no machine-id abort), the target boots via Limine, LUKS auto-unlocks via TPM2, `multi-user.target` is reached, and `cryptroot` is mounted.

If it fails, inspect `result/` (driver log + serial transcript). Likely failure points and fixes:
- **`nixos-install` cannot evaluate the flake** (missing input): add the missing flake input's `outPath` to `flakeInputPaths`.
- **`nixos-install` builds instead of substituting** (closure mismatch): the `settings.nix` written in step 4 of the testScript must exactly match `testSettings` in the Nix `let` — same keys, same values, same formatting of `disks`/`swapSize`.
- **Target boot fails before multi-user** (Limine didn't boot): check the serial log for the Limine menu → kernel → initrd handoff. Confirm the ESP has `\EFI\BOOT\BOOTX64.EFI` (the removable path) — `installer.succeed("ls -R /mnt/boot/efi")` before shutdown.
- **LUKS does not auto-unlock** (PCR-7 mismatch across swtpm reset): confirm `target.state_dir = installer.state_dir` ran before `target.start()`. If PCR 7 still drifts, the boot hangs at a recovery-key prompt — this would indicate a real concern; surface it rather than weakening the assertion.
- **disko fails on /dev/vda**: confirm `emptyDiskImages = [ 20 * 1024 ]` produced a 20G `/dev/vda` (`installer.succeed("lsblk")`).

- [ ] **Step 7: Commit**

```bash
git add tests/default.nix
git commit -m "test(nixos): add limine-install-boot VM install+boot oracle

Two-node runNixOSTest: an installer VM runs the installer plan() (disko,
nixos-install, systemd-cryptenroll PCR-7 + recovery) on /dev/vda, then a
target VM boots the installed disk via Limine sharing the qcow2 + swtpm
state, asserting the TPM2-unlocked LUKS root reaches multi-user.target.
Proves nixos-install no longer aborts on /etc/machine-id under impermanence
and the Limine + PCR-7 chain boots end-to-end."
```

---

### Task 5: Wire CI + document the new test

**Files:**
- Modify: `.forgejo/workflows/ci.yml:97` (the `vm-boot` matrix)
- Modify: `tests/README.md:9-13` (checks table) and `tests/README.md:46-60` ("How it works" section)

**Interfaces:**
- Consumes: `checks.x86_64-linux.limine-install-boot` (Task 4).
- Produces: the new test runs in the weekly/manual vm CI lane; `tests/README.md` documents it.

- [ ] **Step 1: Add the test to the vm-boot matrix**

Change `.forgejo/workflows/ci.yml:97` from:

```yaml
        check: [iso-boot]
```

to:

```yaml
        check: [iso-boot, limine-install-boot]
```

- [ ] **Step 2: Add a checks-table row to `tests/README.md`**

In `tests/README.md`, add a row to the checks table (after the `userborn-reboot-login` row, before the blank line at `tests/README.md:13`):

```markdown
| `limine-install-boot` | the installer plan (disko + `nixos-install` + TPM2 enroll) runs in a VM and the installed disk boots via Limine, asserting the TPM2-unlocked LUKS root reaches `multi-user.target` — proves `nixos-install` no longer aborts on `/etc/machine-id` under impermanence |
```

- [ ] **Step 3: Add a "How it works" bullet to `tests/README.md`**

In the "How it works (`default.nix`)" section (after the `userborn-reboot-login` bullet, around `tests/README.md:59`), add:

```markdown
- **`limine-install-boot`** is a two-node `runNixOSTest`: an `installer` node
  (test-instrumented `installation-device` VM with OVMFFull + swtpm +
  `mountHostNixStore`) runs `install.rs::plan()` — disko, `nixos-install`, and
  `systemd-cryptenroll --tpm2-pcrs=7` + `--recovery-key` — on a blank
  `/dev/vda`; after `installer.shutdown()`, a `target` node reuses the same
  qcow2 + swtpm state (`target.state_dir = installer.state_dir`) and boots the
  installed disk via Limine. The test-settings tokyonight closure is pre-built
  (`mkTokyonight testSettings`) and placed in `extraDependencies` so
  `nixos-install` substitutes it from the host store with no network. The
  `dots` ISO is not used as the installer medium because it has no test
  instrumentation (no backdoor shell); the install steps are identical to the
  real installer. Joins the weekly/manual vm CI lane (heavy: full closure
  build + disko + `nixos-install` + reboot).
```

- [ ] **Step 4: Verify the CI yaml is well-formed**

Run: `nix build .#checks.x86_64-linux.iso-boot --dry-run 2>&1 | head -1` (sanity that the checks attrset still evaluates after the Task-4 changes)
Expected: a dry-run line, no eval error.

- [ ] **Step 5: Commit**

```bash
git add .forgejo/workflows/ci.yml tests/README.md
git commit -m "ci(nixos): run limine-install-boot in the vm lane + document it"
```

---

## Self-Review

**Spec coverage:**
- §1 boot.nix switch → Task 1. ✓
- §2 README docs → Task 2. ✓
- §3 `limine-install-boot` test (two-node, installer plan, target boot, TPM2 assert) → Task 4. ✓
- §3 closure-feasibility (pre-build test-settings closure via `mkTokyonight`) → Task 3 + Task 4 step 2. ✓
- §4 CI placement (lint eval lane auto via `nix flake check --no-build`; vm lane matrix) → Task 5. ✓
- Files touched (boot.nix, README, tests/default.nix, tests/README.md, ci.yml; no installer/disko/checks.nix/apps.nix change) → matches. ✓
- The `mkTokyonight` refactor is an implementation refinement the spec flagged as the closure-feasibility enabler — captured in Task 3.

**Placeholder scan:** No TBD/TODO. Task 4 step 6 lists concrete failure-mode fixes, not placeholders. The testScript is full code.

**Type/name consistency:** `mkTokyonight` (Task 3) → consumed in Task 4 as `mkTokyonight testSettings`. `testSettings` (Task 4 step 2) → the `settings.nix` written in the testScript (Task 4 step 3) uses the same keys/values. `testToplevel` → `extraDependencies`. `dotsFlake` (Task 3 flake.nix) → `environment.etc."dots".source` (Task 4). `inputs` threaded through consistently. `limine-install-boot` name consistent across Task 4, Task 5, CI.

**Risk note:** Task 4 is genuinely heavy and may need iterative debugging (the plan's step 6 enumerates the likely failure modes). The boot.nix fix itself (Task 1) is low-risk and independently shippable — if the VM test proves impractical in CI, Tasks 1–3 + 5 still land the actual fix + the refactor + eval-lane coverage, and the test can be gated behind a separate manual-only matrix entry until it's stable.