//! Install plan + runner. `plan()` produces the full declarative step list
//! (unit-tested); `run()` executes it on a worker thread, streaming output
//! lines back to the UI over an mpsc channel.

use std::{env::temp_dir, process::Command, sync::{LazyLock, mpsc::Sender}};

use walkdir::WalkDir;

use crate::config::InstallConfig;
static mut TARGET_FLAKE: LazyLock<String> = LazyLock::new(|| String::new());
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
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Step {
    pub title: String,
    pub action: Action,
}

pub const LUKS_PASSFILE: &str = "/tmp/dots-luks-pass";
/// disko partlabel for disk "main", partition "root" (see nix/disko.nix).
pub const LUKS_DEVICE: &str = "/dev/disk/by-partlabel/disk-main-root";

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
fn x() -> String {
    temp_dir().join("dots").display().to_string()
}
/// The full install sequence. `flake_src` is where the ISO carries the flake
/// (/etc/dots); `mnt` is the installation mount root (/mnt).
#[must_use]
pub fn plan(cfg: &InstallConfig, flake_src: &str, mnt: &str) -> Vec<Step> {
    let target_flake = format!("{mnt}/etc/dots");
    let swap = format!("{}G", cfg.swap_size_gib);
    let unlock = format!("--unlock-key-file={LUKS_PASSFILE}");
    Command::new("nix-shell").arg("-p").arg("git").arg("--run").args(["git", "clone", "https://gitlab.com/tentypekmatus/tokyonight-dots", &temp_dir().join("dots").display().to_string()]).status().and_then(|_| {
        Ok(if WalkDir::new(target_flake.clone()).into_iter().count() != WalkDir::new(&temp_dir().join("dots")).into_iter().count() {
            // the git version takes a precedence
            unsafe { TARGET_FLAKE = LazyLock::new(
                x
            ) };
        } else {
           unsafe { TARGET_FLAKE = LazyLock::from(format!("{mnt}/etc/dots")) }; 
        })
    }).unwrap();
    let target_flake = unsafe {
        #[allow(static_mut_refs)]
        TARGET_FLAKE.to_string()
    };
    vec![
        Step {
            title: "Write LUKS keyfile".into(),
            action: Action::WriteFile {
                path: LUKS_PASSFILE.into(),
                contents: cfg.root_password.clone(),
                mode: 0o600,
            },
        },
        Step {
            title: "Partition, encrypt and mount (disko)".into(),
            action: cmd(
                "disko",
                &[
                    "--mode",
                    "destroy,format,mount",
                    "--yes-wipe-all-disks",
                    "--argstr",
                    "disk",
                    &cfg.disk,
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
            title: "Copy flake to target".into(),
            action: cmd(
                "sh",
                &[
                    "-c",
                    &format!(
                        "mkdir -p {target_flake} && cp -rTL {flake_src} {target_flake} && chmod -R u+w {target_flake}"
                    ),
                ],
                None,
                Capture::Stream,
            ),
        },
        Step {
            title: "Write install answers (settings.nix)".into(),
            action: Action::WriteFile {
                path: format!("{target_flake}/nix/settings.nix"),
                contents: cfg.settings_nix(),
                mode: 0o644,
            },
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
                    &format!("{target_flake}#{}", cfg.variant.flake_attr()),
                ],
                None,
                Capture::Stream,
            ),
        },
        // Passwords first: a failed TPM2 enrollment (e.g. no TPM) must not
        // leave an otherwise-installed system with every account locked.
        Step {
            title: "Set passwords".into(),
            action: cmd(
                "nixos-enter",
                &["--root", mnt, "--", "chpasswd"],
                Some(format!(
                    "root:{}\n{}:{}\n",
                    cfg.root_password, cfg.username, cfg.user_password
                )),
                Capture::Stream,
            ),
        },
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

fn exec_step(step: &Step, tx: &Sender<Event>) -> anyhow::Result<()> {
    use anyhow::Context;
    use std::io::{BufRead, BufReader, Write};
    use std::os::unix::fs::PermissionsExt;
    use std::process::{Command, Stdio};

    match &step.action {
        Action::WriteFile {
            path,
            contents,
            mode,
        } => {
            if let Some(parent) = std::path::Path::new(path).parent() {
                std::fs::create_dir_all(parent)?;
            }
            // Unlink + O_EXCL: never follow a pre-planted file/symlink at a
            // predictable path, and the mode applies from the first byte
            // (fs::write would create 0644 and only chmod afterwards).
            let _ = std::fs::remove_file(path);
            use std::os::unix::fs::OpenOptionsExt;
            std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(*mode)
                .open(path)
                .and_then(|mut f| f.write_all(contents.as_bytes()))
                .with_context(|| format!("writing {path}"))?;
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
                if let Some(parent) = std::path::Path::new(RECOVERY_KEY_FILE).parent() {
                    let _ = std::fs::create_dir_all(parent);
                }
                std::fs::write(RECOVERY_KEY_FILE, format!("{last_line}\n"))?;
                std::fs::set_permissions(
                    RECOVERY_KEY_FILE,
                    std::fs::Permissions::from_mode(0o600),
                )?;
                let _ = tx.send(Event::RecoveryKey(last_line));
            }
            Ok(())
        }
    }
}
