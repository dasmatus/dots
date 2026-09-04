// The install action list — install.rs::plan(), ported. Pure and
// side-effect-free: planFor only builds the ordered list Runner.qml later
// walks one Process at a time (Runner.qml, plan 3c). Nothing here touches a
// disk, a network socket or the filesystem — the oracle for this port is a
// fixture (tests/qml/fixtures/install-plan.json) captured from install.rs's
// own `plan()` via a temporary `--dump-plan` flag (added, run once, reverted
// — see tst_installer.qml's header), not a hand-transcription of the Rust
// source: that source builds several of these commands from `format!`
// strings with backslash line-continuations, and hand-copying those correctly
// is exactly the kind of transcription mistake an oracle fixture avoids.
//
// Each entry is a flattened `{title, action}` pair — `action.kind` is one of
// install.rs's three `Action` variants (`WriteFile`, `Command`,
// `WriteSecrets`), carrying that variant's fields under camelCase names.
// `Command.capture` is `"Stream"` or `"RecoveryKey"`, install.rs's `Capture`
// enum as a string tag.
.pragma library
.import "config.js" as Config

/// The plaintext LUKS keyfile install.rs writes and later shreds —
/// install.rs::LUKS_PASSFILE.
const LUKS_PASSFILE = "/tmp/dots-luks-pass";
/// The root LV in the `tokyonightvg` VG disko.nix builds — TPM2/recovery
/// enrollment targets this, not a GPT partition by-partlabel —
/// install.rs::LUKS_DEVICE.
const LUKS_DEVICE = "/dev/tokyonightvg/root";
/// Writable staging copy of the flake the ISO's read-only /etc/dots is
/// copied into before `nixos-install` reads it — install.rs::STAGED_FLAKE.
const STAGED_FLAKE = "/tmp/dots-flake";

function command(program, args, capture) {
    return {
        kind: "Command",
        program,
        args,
        stdin: null,
        capture
    };
}

/// The full install sequence — install.rs::plan(). `flakeSrc`/`mnt` default
/// to the same constants `run_dry`/`run_real` hardcode ("/etc/dots", "/mnt");
/// a caller only overrides them in a test.
function planFor(cfg, flakeSrc = "/etc/dots", mnt = "/mnt") {
    const swap = `${cfg.swapSizeGib}G`;
    const unlock = `--unlock-key-file=${LUKS_PASSFILE}`;
    // Nix list literal of the selected disks, e.g. ["/dev/sda" "/dev/sdb"],
    // passed to disko as a non-stringified arg so disko.nix's `disks` list
    // binds to it directly.
    const disksArg = `[ ${cfg.disks.map(d => `"${d}"`).join(" ")} ]`;

    return [
        {
            title: "Write LUKS keyfile",
            action: command("sh", ["-c", `umask 077; head -c 64 /dev/urandom > ${LUKS_PASSFILE}`], "Stream")
        },
        {
            title: "Partition, encrypt and mount (disko)",
            action: command("disko", ["--mode", "destroy,format,mount", "--yes-wipe-all-disks", "--arg", "disks", disksArg, "--argstr", "swapSize", swap, `${flakeSrc}/nix/system/disko.nix`], "Stream")
        },
        {
            title: "Stage flake for install",
            // Copy to a temporary name then mv so a partially-removed previous
            // tree can never leave stale files inside the flake source that
            // nixos-install later evaluates. /etc/dots is a nix-store tree
            // with absolute dangling symlinks (nix/data/settings.nix ->
            // /var/lib/dots/settings.nix): materialise link targets that
            // exist, drop the rest, recreate the intentional settings.nix
            // symlink (WriteFile unlinks it before writing the real file).
            action: command("sh", ["-c", `rm -rf ${STAGED_FLAKE} ${STAGED_FLAKE}.new && mkdir -p ${STAGED_FLAKE}.new && cp -a ${flakeSrc}/. ${STAGED_FLAKE}.new/ && find ${STAGED_FLAKE}.new -type l -exec sh -c 'for link do tgt=$(readlink -f "$link" 2>/dev/null || true); if [ -n "$tgt" ] && [ -e "$tgt" ]; then rm -f "$link" && cp -a "$tgt" "$link"; else rm -f "$link"; fi; done' sh {} + && chmod -R u+w ${STAGED_FLAKE}.new && ln -sfn /var/lib/dots/settings.nix ${STAGED_FLAKE}.new/nix/data/settings.nix && mv ${STAGED_FLAKE}.new ${STAGED_FLAKE}`], "Stream")
        },
        {
            title: "Detect hardware (nixos-facter)",
            action: command("nixos-facter", ["-o", `${STAGED_FLAKE}/nix/data/facter.json`], "Stream")
        },
        {
            title: "Write install answers (settings.nix)",
            action: {
                kind: "WriteFile",
                path: `${STAGED_FLAKE}/nix/data/settings.nix`,
                contents: Config.settingsNix(cfg),
                mode: 420 // 0o644 — install.rs::plan()'s settings.nix mode
            }
        },
        {
            title: "Write password hashes (secrets.nix)",
            action: {
                kind: "WriteSecrets",
                path: `${STAGED_FLAKE}/nix/secrets.nix`,
                userPassword: cfg.userPassword
            }
        },
        {
            title: "Stash install answers on target",
            // Machine-specific answers for the first-login dots-clone
            // service, mirrored onto the persistent /persist subvol
            // (bind-mounted to /var/lib/dots — the root is a tmpfs wiped
            // each boot). secrets.nix is intentionally omitted: install-time
            // only, never restored into the user's clean clone.
            action: command("sh", ["-c", `mkdir -p ${mnt}/persist/var/lib/dots/nix && cp ${STAGED_FLAKE}/nix/data/facter.json ${mnt}/persist/var/lib/dots/ && cp ${STAGED_FLAKE}/nix/data/settings.nix ${mnt}/persist/var/lib/dots/`], "Stream")
        },
        {
            title: "Copy network profiles to target",
            action: command("sh", ["-c", `if [ -d /etc/NetworkManager/system-connections ]; then mkdir -p ${mnt}/persist/etc/NetworkManager && cp -a /etc/NetworkManager/system-connections ${mnt}/persist/etc/NetworkManager/; fi`], "Stream")
        },
        {
            title: "Install NixOS (this takes a while)",
            action: command("nixos-install", ["--root", mnt, "--no-root-passwd", "--flake", `${STAGED_FLAKE}#tokyonight`], "Stream")
        },
        {
            title: "Enroll TPM2 unlock (PCR 7)",
            action: command("systemd-cryptenroll", [unlock, "--tpm2-device=auto", "--tpm2-pcrs=7", LUKS_DEVICE], "Stream")
        },
        {
            title: "Enroll recovery key",
            // The ONLY action carrying RecoveryKey capture — that line is
            // the LUKS recovery key; losing it locks the user out of their
            // own disk, so nothing else may share this capture mode.
            action: command("systemd-cryptenroll", [unlock, "--recovery-key", LUKS_DEVICE], "RecoveryKey")
        },
        {
            title: "Scrub LUKS keyfile",
            action: command("shred", ["-u", LUKS_PASSFILE], "Stream")
        }
    ];
}
