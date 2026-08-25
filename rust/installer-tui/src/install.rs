//! Install plan + runner. `plan()` produces the full declarative step list
//! (unit-tested); `run()` executes it on a worker thread, streaming output
//! lines back to the UI over an mpsc channel.

use std::sync::mpsc::Sender;

use crate::config::InstallConfig;

/// Events the runner sends to the UI thread.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// 1-based step index, total steps, human title.
    StepStarted(usize, usize, String),
    Log(String),
    RecoveryKey(String),
    Finished,
    Failed(String),
}

/// How a command's stdout is treated.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Capture {
    /// Stream lines to the log pane.
    Stream,
    /// The last non-empty stdout line is the LUKS recovery key.
    RecoveryKey,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action {
    WriteFile {
        path: String,
        contents: String,
        mode: u32,
    },
    Command {
        program: String,
        args: Vec<String>,
        stdin: Option<String>,
        capture: Capture,
    },
    /// Hash the user install password with `mkpasswd -m yescrypt --stdin`
    /// (plaintext piped via stdin, never argv — no /proc leak) and write
    /// `nix/secrets.nix` into the staged flake. `nixos-install` then evaluates
    /// the flake with the hash present so userborn creates the account with
    /// it on first boot (nix/modules/users.nix reads this file via
    /// `builtins.pathExists` and sets `initialHashedPassword`). The file is
    /// install-time-only: it is NOT stashed to /var/lib/dots, so the
    /// dots-clone Home Manager service never restores it into the user's git
    /// clone — a yescrypt hash is offline-crackable. On rebuild from the clean
    /// user clone the file is absent, the hash is null, and userborn's
    /// `shadow::Entry::update(None)` leaves the existing /var/lib/nixos shadow
    /// entry alone (`mutableUsers = true`). The root account is intentionally
    /// NOT given a password: `nixos-install --no-root-passwd` leaves it
    /// locked, so the only login is the wheel user (with sudo).
    WriteSecrets { path: String, user_password: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Step {
    pub title: String,
    pub action: Action,
}

pub const LUKS_PASSFILE: &str = "/tmp/dots-luks-pass";
/// The root logical volume in the `tokyonightvg` VG (see nix/disko.nix):
/// disko puts LUKS on this LV, so TPM2/recovery enrollment targets it
/// instead of a GPT partition by-partlabel.
pub const LUKS_DEVICE: &str = "/dev/tokyonightvg/root";
/// Writable staging copy of the flake on the live system, used by
/// `nixos-install` — the ISO's `/etc/dots` is a read-only store path. Lives
/// on ISO tmpfs and is gone after reboot.
pub const STAGED_FLAKE: &str = "/tmp/dots-flake";

/// Round `MemTotal` up to whole GiB — parity with `config.ram_gib()` in the
/// Gentoo installer (swap sized = RAM).
#[must_use]
pub fn swap_size_from_meminfo(meminfo: &str) -> u64 {
    let kb: u64 = meminfo
        .lines()
        .find(|l| l.starts_with("MemTotal:"))
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    kb.div_ceil(1024 * 1024).max(1)
}

fn cmd(program: &str, args: &[&str], stdin: Option<String>, capture: Capture) -> Action {
    Action::Command {
        program: program.into(),
        args: args.iter().map(std::string::ToString::to_string).collect(),
        stdin,
        capture,
    }
}

/// The full install sequence. `flake_src` is where the ISO carries the flake
/// (/etc/dots); the plan stages a writable copy at [`STAGED_FLAKE`] and
/// installs from there, then stashes the two machine-specific answer files
/// at `{mnt}/persist/var/lib/dots` (facter.json at the top level,
/// settings.nix under `nix/`) — on the persistent /persist subvol, since the
/// root is a tmpfs wiped each boot (nix/modules/impermanence.nix) and
/// nixos-impermanence bind-mounts /persist/var/lib/dots → /var/lib/dots so
/// the first-login `dots-clone` user service can pick them up. The repo
/// itself is never copied onto the target — `mnt` is only the installation
/// mount root (/mnt). `NetworkManager` profiles created by the Wi-Fi screen
/// (credentials included, root-only 0600 keyfiles) are copied so the
/// installed system comes up online on first boot; a no-op when nothing was
/// connected.
#[must_use]
pub fn plan(cfg: &InstallConfig, flake_src: &str, mnt: &str) -> Vec<Step> {
    let swap = format!("{}G", cfg.swap_size_gib);
    let unlock = format!("--unlock-key-file={LUKS_PASSFILE}");
    // Nix list literal of the selected disks, e.g. ["/dev/sda" "/dev/sdb"],
    // passed to disko as a non-stringified arg so disko.nix's `disks` list
    // binds to it directly.
    let disks_arg = format!(
        "[ {} ]",
        cfg.disks
            .iter()
            .map(|d| format!("\"{d}\""))
            .collect::<Vec<_>>()
            .join(" ")
    );

    vec![
        Step {
            title: "Write LUKS keyfile".into(),
            action: cmd(
                "sh",
                &[
                    "-c",
                    &format!("umask 077; head -c 64 /dev/urandom > {LUKS_PASSFILE}"),
                ],
                None,
                Capture::Stream,
            ),
        },
        Step {
            title: "Partition, encrypt and mount (disko)".into(),
            action: cmd(
                "disko",
                &[
                    "--mode",
                    "destroy,format,mount",
                    "--yes-wipe-all-disks",
                    "--arg",
                    "disks",
                    &disks_arg,
                    "--argstr",
                    "swapSize",
                    &swap,
                    &format!("{flake_src}/nix/disko.nix"),
                ],
                None,
                Capture::Stream,
            ),
        },
        Step {
            title: "Stage flake for install".into(),
            // Copy to a temporary name then mv so a partially-removed previous
            // tree (open file, immutable bit, …) can never leave stale files
            // inside the flake source that nixos-install later evaluates.
            //
            // Do NOT dereference (-L): the ISO flake ships dangling symlinks
            // for nix/facter.json and nix/settings.nix (filled in by later
            // steps). cp -L would fail with "cannot stat". -P preserves the
            // symlinks; the WriteFile / nixos-facter steps then replace them
            // with real files. -T makes the dest become a faithful copy of
            // the source rather than nesting it; cp creates the dest itself.
            action: cmd(
                "sh",
                &[
                    "-c",
                    &format!(
                        "rm -rf {STAGED_FLAKE} {STAGED_FLAKE}.new \
                         && cp -rPT {flake_src} {STAGED_FLAKE}.new \
                         && chmod -R u+w {STAGED_FLAKE}.new \
                         && mv {STAGED_FLAKE}.new {STAGED_FLAKE}"
                    ),
                ],
                None,
                Capture::Stream,
            ),
        },
        Step {
            title: "Detect hardware (nixos-facter)".into(),
            action: cmd(
                "nixos-facter",
                &["-o", &format!("{STAGED_FLAKE}/nix/facter.json")],
                None,
                Capture::Stream,
            ),
        },
        Step {
            title: "Write install answers (settings.nix)".into(),
            action: Action::WriteFile {
                path: format!("{STAGED_FLAKE}/nix/settings.nix"),
                contents: cfg.settings_nix(),
                mode: 0o644,
            },
        },
        Step {
            title: "Write password hashes (secrets.nix)".into(),
            action: Action::WriteSecrets {
                path: format!("{STAGED_FLAKE}/nix/secrets.nix"),
                user_password: cfg.user_password.clone(),
            },
        },
        Step {
            title: "Stash install answers on target".into(),
            // Machine-specific answers for the first-login dots-clone service.
            // Layout on persist (bind-mounted to /var/lib/dots):
            //   facter.json          → /persist/var/lib/dots/facter.json
            //   settings.nix         → /persist/var/lib/dots/nix/settings.nix
            // (mirrors the flake paths the service expects; secrets.nix is
            // intentionally omitted — install-time only.)
            action: cmd(
                "sh",
                &[
                    "-c",
                    &format!(
                        "mkdir -p {mnt}/persist/var/lib/dots/nix \
                         && cp {STAGED_FLAKE}/nix/facter.json {mnt}/persist/var/lib/dots/ \
                         && cp {STAGED_FLAKE}/nix/settings.nix {mnt}/persist/var/lib/dots/"
                    ),
                ],
                None,
                Capture::Stream,
            ),
        },
        Step {
            title: "Copy network profiles to target".into(),
            action: cmd(
                "sh",
                &["-c", &format!(
                    "if [ -d /etc/NetworkManager/system-connections ]; then mkdir -p {mnt}/persist/etc/NetworkManager && cp -a /etc/NetworkManager/system-connections {mnt}/persist/etc/NetworkManager/; fi"
                )],
                None,
                Capture::Stream,
            ),
        },
        Step {
            title: "Install NixOS (this takes a while)".into(),
            action: cmd(
                "nixos-install",
                &[
                    "--root",
                    mnt,
                    "--no-root-passwd",
                    "--flake",
                    &format!("{STAGED_FLAKE}#tokyonight"),
                ],
                None,
                Capture::Stream,
            ),
        },
        // Note on the old `nixos-enter -- chpasswd` step, removed: under
        // userborn + immutable /etc the user account does not exist at install
        // time (userborn creates it at first boot from the closure baked by
        // nixos-install), so chpasswd had no target. The declarative hashes in
        // nix/secrets.nix (written above) are what actually seed the passwords
        // — and because account creation is decoupled from TPM2 enrollment, a
        // failed enrollment can no longer leave the installed system locked:
        // the closure already carries the hashes and userborn runs at first
        // boot regardless of the LUKS unlock method.
        Step {
            title: "Enroll TPM2 unlock (PCR 7)".into(),
            action: cmd(
                "systemd-cryptenroll",
                &[&unlock, "--tpm2-device=auto", "--tpm2-pcrs=7", LUKS_DEVICE],
                None,
                Capture::Stream,
            ),
        },
        Step {
            title: "Enroll recovery key".into(),
            action: cmd(
                "systemd-cryptenroll",
                &[&unlock, "--recovery-key", LUKS_DEVICE],
                None,
                Capture::RecoveryKey,
            ),
        },
        Step {
            title: "Scrub LUKS keyfile".into(),
            action: cmd("shred", &["-u", LUKS_PASSFILE], None, Capture::Stream),
        },
    ]
}

/// Execute the plan, streaming events. Never panics; all failures land as
/// `Event::Failed`.
pub fn run(cfg: InstallConfig, tx: Sender<Event>) {
    if std::env::var("DOTS_INSTALLER_DRY_RUN").is_ok() {
        run_dry(&cfg, &tx);
        return;
    }
    run_real(cfg, tx);
}

fn run_dry(cfg: &InstallConfig, tx: &Sender<Event>) {
    let steps = plan(cfg, "/etc/dots", "/mnt");
    let total = steps.len();
    for (i, step) in steps.iter().enumerate() {
        let _ = tx.send(Event::StepStarted(i + 1, total, step.title.clone()));
        let _ = tx.send(Event::Log(format!("[dry-run] {}", step.title)));
        std::thread::sleep(std::time::Duration::from_millis(400));
    }
    let _ = tx.send(Event::RecoveryKey("dry-run-recovery-key".into()));
    let _ = tx.send(Event::Finished);
}

fn run_real(cfg: InstallConfig, tx: Sender<Event>) {
    let steps = plan(&cfg, "/etc/dots", "/mnt");
    let total = steps.len();
    for (i, step) in steps.iter().enumerate() {
        let _ = tx.send(Event::StepStarted(i + 1, total, step.title.clone()));
        if let Err(e) = exec_step(step, &tx) {
            scrub_passfile();
            let _ = tx.send(Event::Failed(format!("{}: {e:#}", step.title)));
            return;
        }
    }
    scrub_passfile();
    let _ = tx.send(Event::Finished);
}

/// Best-effort removal of the plaintext LUKS keyfile — called on every exit
/// path so a mid-install failure never leaves the root password in /tmp.
fn scrub_passfile() {
    let _ = std::process::Command::new("shred")
        .args(["-u", LUKS_PASSFILE])
        .status();
    let _ = std::fs::remove_file(LUKS_PASSFILE);
}

const RECOVERY_KEY_FILE: &str = "/mnt/root/luks-recovery.txt";

/// Unlink + `O_EXCL` write: never follow a pre-planted file/symlink at a
/// predictable path, and `mode` applies from the first byte (`fs::write` would
/// create 0644 and only chmod afterwards). Parent dirs are created if missing.
fn write_file_secure(path: &str, contents: &str, mode: u32) -> anyhow::Result<()> {
    use anyhow::Context;
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    if let Some(parent) = std::path::Path::new(path).parent() {
        std::fs::create_dir_all(parent)?;
    }
    let _ = std::fs::remove_file(path);
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .open(path)
        .and_then(|mut f| f.write_all(contents.as_bytes()))
        .with_context(|| format!("writing {path}"))?;
    Ok(())
}

/// Hash a plaintext password with yescrypt via `mkpasswd -m yescrypt --stdin`
/// (from the whois package; in `corePackageNames`, so it ships in
/// /run/current-system/sw on every NixOS incl. the ISO — no Cargo dep, no extra
/// Nix package). The password is piped through stdin, never argv, so it can't
/// leak via /proc/<pid>/cmdline; mkpasswd generates a fresh urandom salt
/// itself (no installer-side RNG). yescrypt (`$y$`) is in both the
/// NixOS-accepted MCF scheme set and userborn's "secure" set, so crypt(3)
/// verifies it at login and userborn logs no weak-scheme warning.
fn hash_password(plaintext: &str) -> anyhow::Result<String> {
    use anyhow::Context;
    use std::io::Write;
    use std::process::{Command, Stdio};
    let mut child = Command::new("mkpasswd")
        .args(["-m", "yescrypt", "--stdin"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .context("spawning mkpasswd")?;
    {
        let mut stdin = child.stdin.take().expect("stdin piped");
        stdin
            .write_all(plaintext.as_bytes())
            .context("writing password to mkpasswd stdin")?;
        // stdin dropped here → EOF so mkpasswd emits the hash and exits
    }
    let output = child.wait_with_output().context("waiting on mkpasswd")?;
    anyhow::ensure!(
        output.status.success(),
        "mkpasswd exited with {}: {}",
        output.status,
        String::from_utf8_lossy(&output.stderr)
    );
    let hash = String::from_utf8(output.stdout)?.trim().to_string();
    // Guards against mkpasswd surfacing an error string on stdout instead of
    // a real hash, and confirms the scheme is yescrypt before we embed it in a
    // Nix `"..."` literal — yescrypt's alphabet (`./0-9A-Za-z`, no `{`) can't
    // form a `${…}` interpolation, so the hash is safe in a Nix string.
    anyhow::ensure!(
        hash.starts_with("$y$"),
        "mkpasswd did not produce a yescrypt hash: {hash}"
    );
    Ok(hash)
}

fn exec_step(step: &Step, tx: &Sender<Event>) -> anyhow::Result<()> {
    use anyhow::Context;
    use std::io::{BufRead, BufReader, Write};
    use std::process::{Command, Stdio};

    match &step.action {
        Action::WriteFile {
            path,
            contents,
            mode,
        } => {
            write_file_secure(path, contents, *mode)?;
            Ok(())
        }

        Action::WriteSecrets {
            path,
            user_password,
        } => {
            let user_hash = hash_password(user_password)?;
            let contents = format!("{{\n  userHash = \"{user_hash}\";\n}}\n");
            // 0600: the file carries offline-crackable hashes; it lives on the
            // ISO tmpfs (STAGED_FLAKE) and is gone after reboot, but tight
            // perms while it exists don't cost anything.
            write_file_secure(path, &contents, 0o600)?;
            Ok(())
        }

        Action::Command {
            program,
            args,
            stdin,
            capture,
        } => {
            let mut child = Command::new(program)
                .args(args)
                .stdin(if stdin.is_some() {
                    Stdio::piped()
                } else {
                    Stdio::null()
                })
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .with_context(|| format!("spawning {program}"))?;

            // Drain stderr on its own thread BEFORE feeding stdin, so a child
            // that errors early can't deadlock us on a full stderr pipe.
            let stderr = child.stderr.take().expect("stderr piped");
            let tx_err = tx.clone();
            let stderr_thread = std::thread::spawn(move || {
                for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                    let _ = tx_err.send(Event::Log(line));
                }
            });

            if let Some(input) = stdin {
                // Ignore write errors (EPIPE = child already exited) — fall
                // through to wait() so the real exit status/stderr surfaces.
                let _ = child
                    .stdin
                    .take()
                    .expect("stdin piped")
                    .write_all(input.as_bytes());
                // handle dropped here — closes the pipe so the child sees EOF
            }

            let stdout = child.stdout.take().expect("stdout piped");
            let mut last_line = String::new();
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                match capture {
                    Capture::Stream => {
                        let _ = tx.send(Event::Log(line));
                    }
                    // Keep the key out of the scrolling log; it is shown
                    // prominently on the Done screen instead.
                    Capture::RecoveryKey => {
                        if !line.trim().is_empty() {
                            last_line = line.trim().to_string();
                        }
                    }
                }
            }

            let status = child.wait()?;
            let _ = stderr_thread.join();
            anyhow::ensure!(status.success(), "{program} exited with {status}");

            if *capture == Capture::RecoveryKey {
                anyhow::ensure!(!last_line.is_empty(), "no recovery key captured");
                // Use the same O_EXCL + mode-from-first-byte helper as the
                // other secret files so the key is never briefly 0644.
                write_file_secure(RECOVERY_KEY_FILE, &format!("{last_line}\n"), 0o600)?;
                let _ = tx.send(Event::RecoveryKey(last_line));
            }
            Ok(())
        }
    }
}
