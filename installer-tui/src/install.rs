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
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Step {
    pub title: String,
    pub action: Action,
}

pub const LUKS_PASSFILE: &str = "/tmp/dots-luks-pass";
/// disko partlabel for disk "main", partition "root" (see nix/disko.nix).
pub const LUKS_DEVICE: &str = "/dev/disk/by-partlabel/disk-main-root";

/// Round MemTotal up to whole GiB — parity with config.ram_gib() in the
/// Gentoo installer (swap sized = RAM).
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
        args: args.iter().map(|a| a.to_string()).collect(),
        stdin,
        capture,
    }
}

/// The full install sequence. `flake_src` is where the ISO carries the flake
/// (/etc/dots); `mnt` is the installation mount root (/mnt).
pub fn plan(cfg: &InstallConfig, flake_src: &str, mnt: &str) -> Vec<Step> {
    let target_flake = format!("{mnt}/etc/dots");
    let swap = format!("{}G", cfg.swap_size_gib);
    let unlock = format!("--unlock-key-file={LUKS_PASSFILE}");

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
            title: "Scrub LUKS keyfile".into(),
            action: cmd("shred", &["-u", LUKS_PASSFILE], None, Capture::Stream),
        },
    ]
}

/// Execute the plan, streaming events. Never panics; all failures land as
/// Event::Failed.
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
            let _ = tx.send(Event::Failed(format!("{}: {e:#}", step.title)));
            return;
        }
    }
    let _ = tx.send(Event::Finished);
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
            std::fs::write(path, contents).with_context(|| format!("writing {path}"))?;
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(*mode))?;
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

            if let Some(input) = stdin {
                child
                    .stdin
                    .take()
                    .expect("stdin piped")
                    .write_all(input.as_bytes())
                    .context("feeding stdin")?;
                // handle dropped here — closes the pipe so the child sees EOF
            }

            let stderr = child.stderr.take().expect("stderr piped");
            let tx_err = tx.clone();
            let stderr_thread = std::thread::spawn(move || {
                for line in BufReader::new(stderr).lines().map_while(Result::ok) {
                    let _ = tx_err.send(Event::Log(line));
                }
            });

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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Variant;

    fn cfg() -> InstallConfig {
        InstallConfig {
            disk: "/dev/vda".into(),
            hostname: "myhost".into(),
            username: "alice".into(),
            root_password: "rootsecret".into(),
            user_password: "usersecret".into(),
            variant: Variant::Amd,
            swap_size_gib: 16,
        }
    }

    #[test]
    fn swap_size_rounds_meminfo_up_to_gib() {
        assert_eq!(
            swap_size_from_meminfo("MemTotal:       16384256 kB\nMemFree: 1 kB"),
            16
        );
        assert_eq!(swap_size_from_meminfo("MemTotal: 1048576 kB"), 1);
        assert_eq!(swap_size_from_meminfo("MemTotal: 1048577 kB"), 2);
    }

    #[test]
    fn plan_writes_luks_passfile_with_root_password_mode_600() {
        let steps = plan(&cfg(), "/etc/dots", "/mnt");
        let wf = steps
            .iter()
            .find_map(|s| match &s.action {
                Action::WriteFile {
                    path,
                    contents,
                    mode,
                } if path == LUKS_PASSFILE => Some((contents.clone(), *mode)),
                _ => None,
            })
            .expect("luks passfile step");
        assert_eq!(wf.0, "rootsecret");
        assert_eq!(wf.1, 0o600);
    }

    #[test]
    fn plan_runs_disko_with_chosen_disk_and_swap() {
        let steps = plan(&cfg(), "/etc/dots", "/mnt");
        let args = steps
            .iter()
            .find_map(|s| match &s.action {
                Action::Command { program, args, .. } if program == "disko" => Some(args.clone()),
                _ => None,
            })
            .expect("disko step");
        let joined = args.join(" ");
        assert!(joined.contains("--argstr disk /dev/vda"), "{joined}");
        assert!(joined.contains("--argstr swapSize 16G"), "{joined}");
        assert!(joined.contains("destroy,format,mount"), "{joined}");
    }

    #[test]
    fn plan_installs_from_embedded_flake_with_variant_attr() {
        let steps = plan(&cfg(), "/etc/dots", "/mnt");
        let joined: String = steps
            .iter()
            .filter_map(|s| match &s.action {
                Action::Command { program, args, .. } if program == "nixos-install" => {
                    Some(args.join(" "))
                }
                _ => None,
            })
            .collect();
        assert!(
            joined.contains("--flake /mnt/etc/dots#tokyonight-amd"),
            "{joined}"
        );
        assert!(joined.contains("--no-root-passwd"), "{joined}");
    }

    #[test]
    fn plan_overwrites_settings_nix_on_target() {
        let steps = plan(&cfg(), "/etc/dots", "/mnt");
        let found = steps.iter().any(|s| match &s.action {
            Action::WriteFile { path, contents, .. } => {
                path == "/mnt/etc/dots/nix/settings.nix" && contents.contains("myhost")
            }
            _ => false,
        });
        assert!(found, "settings.nix rewrite step missing");
    }

    #[test]
    fn plan_enrolls_tpm2_then_recovery_key() {
        let steps = plan(&cfg(), "/etc/dots", "/mnt");
        let cryptenroll_args: Vec<Vec<String>> = steps
            .iter()
            .filter_map(|s| match &s.action {
                Action::Command { program, args, .. } if program == "systemd-cryptenroll" => {
                    Some(args.clone())
                }
                _ => None,
            })
            .collect();
        assert_eq!(cryptenroll_args.len(), 2, "tpm2 + recovery enrollments");
        let tpm2 = cryptenroll_args[0].join(" ");
        assert!(tpm2.contains("--tpm2-device=auto"), "{tpm2}");
        assert!(tpm2.contains("--tpm2-pcrs=7"), "{tpm2}");
        assert!(tpm2.contains(LUKS_DEVICE), "{tpm2}");
        let rec = cryptenroll_args[1].join(" ");
        assert!(rec.contains("--recovery-key"), "{rec}");
        // The recovery key must be captured for the Done screen.
        let captured = steps.iter().any(|s| {
            matches!(
                &s.action,
                Action::Command { program, capture: Capture::RecoveryKey, .. }
                    if program == "systemd-cryptenroll"
            )
        });
        assert!(captured);
    }

    #[test]
    fn plan_sets_passwords_via_stdin_never_argv() {
        let steps = plan(&cfg(), "/etc/dots", "/mnt");
        let chpasswd = steps
            .iter()
            .find_map(|s| match &s.action {
                Action::Command {
                    program,
                    args,
                    stdin,
                    ..
                } if program == "nixos-enter" => {
                    args.iter().any(|a| a == "chpasswd").then(|| stdin.clone())
                }
                _ => None,
            })
            .flatten()
            .expect("chpasswd step with stdin");
        assert_eq!(chpasswd, "root:rootsecret\nalice:usersecret\n");

        for s in &steps {
            if let Action::Command { program, args, .. } = &s.action {
                let joined = format!("{program} {}", args.join(" "));
                assert!(
                    !joined.contains("rootsecret") && !joined.contains("usersecret"),
                    "password leaked into argv: {joined}"
                );
            }
        }
    }

    #[test]
    fn plan_shreds_passfile_last() {
        let steps = plan(&cfg(), "/etc/dots", "/mnt");
        let last = steps.last().expect("steps nonempty");
        match &last.action {
            Action::Command { program, args, .. } => {
                assert_eq!(program, "shred");
                assert!(args.iter().any(|a| a == LUKS_PASSFILE));
            }
            other => panic!("last step must shred the passfile, got {other:?}"),
        }
    }
}
