//! Install-plan contract tests (step order, argv hygiene, TPM2 flow).

use dots_installer::config::InstallConfig;
use dots_installer::install::{
    plan, swap_size_from_meminfo, Action, Capture, Step, LUKS_DEVICE, LUKS_PASSFILE, STAGED_FLAKE,
};

fn cfg() -> InstallConfig {
    InstallConfig {
        disks: vec!["/dev/vda".into()],
        hostname: "myhost".into(),
        username: "alice".into(),
        git_name: "Alice Q".into(),
        git_email: "alice@example.org".into(),
        user_password: "usersecret".into(),
        swap_size_gib: 16,
        ..Default::default()
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
fn plan_writes_random_luks_keyfile_from_urandom() {
    // The LUKS keyfile is 64 random bytes from /dev/urandom — disk encryption
    // is decoupled from any login password. Slot 0 becomes an unknown random
    // passphrase; the real unlock paths are TPM2 (auto) + the recovery key.
    // The keyfile is shredded after enrollment (plan_shreds_passfile_last),
    // so the random passphrase is never recoverable — it just authorized the
    // TPM2/recovery enrollment.
    let steps = plan(&cfg(), "/etc/dots", "/mnt");
    let keyfile = steps
        .iter()
        .find(|s| s.title == "Write LUKS keyfile")
        .expect("luks keyfile step");
    let Action::Command { program, args, .. } = &keyfile.action else {
        panic!("luks keyfile step must be a command");
    };
    assert_eq!(program, "sh");
    let script = args.join(" ");
    assert!(script.contains("/dev/urandom"), "{script}");
    assert!(script.contains(LUKS_PASSFILE), "{script}");
    // The keyfile must never be a static WriteFile (e.g. a login password):
    // it has to come from the CSPRNG at install time.
    let passfile_write = steps.iter().any(|s| {
        matches!(
            &s.action,
            Action::WriteFile {
                path,
                ..
            } if path == LUKS_PASSFILE
        )
    });
    assert!(
        !passfile_write,
        "LUKS keyfile must be a random command, not a static WriteFile"
    );
}

#[test]
fn plan_runs_disko_with_selected_disks_and_swap() {
    let steps = plan(&cfg(), "/etc/dots", "/mnt");
    let args = steps
        .iter()
        .find_map(|s| match &s.action {
            Action::Command { program, args, .. } if program == "disko" => Some(args.clone()),
            _ => None,
        })
        .expect("disko step");
    let joined = args.join(" ");
    assert!(joined.contains("--arg disks [ \"/dev/vda\" ]"), "{joined}");
    assert!(joined.contains("--argstr swapSize 16G"), "{joined}");
    assert!(joined.contains("destroy,format,mount"), "{joined}");
}

#[test]
fn plan_installs_from_staged_flake() {
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
        joined.contains(&format!("--flake {STAGED_FLAKE}#tokyonight")),
        "{joined}"
    );
    assert!(joined.contains("--no-root-passwd"), "{joined}");
}

#[test]
fn plan_stages_flake_before_detecting_hardware_before_install() {
    let steps = plan(&cfg(), "/etc/dots", "/mnt");
    let idx = |pred: &dyn Fn(&Step) -> bool| steps.iter().position(pred).unwrap();
    let stage = idx(&|s| s.title == "Stage flake for install");
    let facter =
        idx(&|s| matches!(&s.action, Action::Command { program, .. } if program == "nixos-facter"));
    let install = idx(
        &|s| matches!(&s.action, Action::Command { program, .. } if program == "nixos-install"),
    );
    assert!(
        stage < facter && facter < install,
        "the report must land in the staged flake before nixos-install evaluates it"
    );
    let Action::Command { args, .. } = &steps[facter].action else {
        unreachable!()
    };
    assert_eq!(args.join(" "), format!("-o {STAGED_FLAKE}/nix/facter.json"));
}

#[test]
fn plan_stage_step_recreates_staging_dir_and_copies_from_flake_src() {
    let steps = plan(&cfg(), "/etc/dots", "/mnt");
    let stage = steps
        .iter()
        .find(|s| s.title == "Stage flake for install")
        .expect("stage step");
    let Action::Command { program, args, .. } = &stage.action else {
        panic!("stage step must be a command");
    };
    assert_eq!(program, "sh");
    let script = args.join(" ");
    assert!(
        script.contains(&format!("rm -rf {STAGED_FLAKE} {STAGED_FLAKE}.new")),
        "{script}"
    );
    assert!(
        script.contains(&format!("cp -a /etc/dots/. {STAGED_FLAKE}.new/")),
        "{script}"
    );
    assert!(script.contains("find "), "{script}");
    assert!(script.contains("readlink"), "{script}");
    assert!(script.contains("ln -sfn"), "{script}");
    assert!(
        script.contains(&format!("chmod -R u+w {STAGED_FLAKE}.new")),
        "{script}"
    );
    assert!(
        script.contains(&format!("mv {STAGED_FLAKE}.new {STAGED_FLAKE}")),
        "{script}"
    );
}

#[test]
fn plan_writes_settings_nix_into_staged_flake() {
    let steps = plan(&cfg(), "/etc/dots", "/mnt");
    let found = steps.iter().any(|s| match &s.action {
        Action::WriteFile { path, contents, .. } => {
            path == &format!("{STAGED_FLAKE}/nix/settings.nix") && contents.contains("myhost")
        }
        _ => false,
    });
    assert!(found, "settings.nix rewrite step missing");
}

#[test]
fn plan_writes_ai_toggles_into_settings_nix() {
    // The AI screen's toggles render as aiClaude/aiCodex/aiOllama booleans in
    // settings.nix, bridged to options.dots.ai.* by nix/modules/dots.nix. A
    // toggled-off value must render as `false` (not omitted) so the override
    // propagates: defaults.nix would otherwise leave it `true`.
    let mut cfg = cfg();
    cfg.ai_claude = true;
    cfg.ai_codex = false;
    cfg.ai_ollama = true;
    let steps = plan(&cfg, "/etc/dots", "/mnt");
    let found = steps.iter().any(|s| match &s.action {
        Action::WriteFile { path, contents, .. } => {
            path == &format!("{STAGED_FLAKE}/nix/settings.nix")
                && contents.contains("aiClaude = true;")
                && contents.contains("aiCodex = false;")
                && contents.contains("aiOllama = true;")
        }
        _ => false,
    });
    assert!(found, "settings.nix must render the AI toggles");
}

#[test]
fn plan_stashes_exactly_settings_and_facter_to_var_lib_dots() {
    let steps = plan(&cfg(), "/etc/dots", "/mnt");
    let stash = steps
        .iter()
        .find(|s| s.title == "Stash install answers on target")
        .expect("stash step");
    let Action::Command { program, args, .. } = &stash.action else {
        panic!("stash step must be a command");
    };
    assert_eq!(program, "sh");
    let script = args.join(" ");
    // Must land on the persistent /persist subvol: the root is a tmpfs wiped
    // each boot, so nixos-impermanence bind-mounts /persist/var/lib/dots →
    // /var/lib/dots for the first-login dots-clone service to read.
    assert!(
        script.contains("mkdir -p /mnt/persist/var/lib/dots"),
        "{script}"
    );
    // Copies may be issued as a single cp of both files or as two separate
    // cps; either way both answers must end up under the persist path.
    assert!(
        script.contains(&format!("cp {STAGED_FLAKE}/nix/facter.json"))
            || script.contains(&format!(
                "cp {STAGED_FLAKE}/nix/settings.nix {STAGED_FLAKE}/nix/facter.json"
            )),
        "{script}"
    );
    assert!(
        script.contains(&format!("cp {STAGED_FLAKE}/nix/settings.nix"))
            || script.contains(&format!(
                "cp {STAGED_FLAKE}/nix/settings.nix {STAGED_FLAKE}/nix/facter.json"
            )),
        "{script}"
    );
    assert!(script.contains("/mnt/persist/var/lib/dots/"), "{script}");
}

#[test]
fn plan_stashes_answers_after_settings_write_and_before_install() {
    let steps = plan(&cfg(), "/etc/dots", "/mnt");
    let idx = |pred: &dyn Fn(&Step) -> bool| steps.iter().position(pred).unwrap();
    let settings = idx(&|s| s.title == "Write install answers (settings.nix)");
    let stash = idx(&|s| s.title == "Stash install answers on target");
    let install = idx(
        &|s| matches!(&s.action, Action::Command { program, .. } if program == "nixos-install"),
    );
    assert!(
        settings < stash && stash < install,
        "the stash must run after settings.nix is written and before nixos-install"
    );
}

#[test]
fn plan_never_references_mnt_etc_dots() {
    let steps = plan(&cfg(), "/etc/dots", "/mnt");
    for step in &steps {
        match &step.action {
            Action::Command { program, args, .. } => {
                assert!(
                    !program.contains("/mnt/etc/dots"),
                    "{}: {program}",
                    step.title
                );
                for a in args {
                    assert!(
                        !a.contains("/mnt/etc/dots"),
                        "{}: argv leaked /mnt/etc/dots: {a}",
                        step.title
                    );
                }
            }
            Action::WriteFile { path, contents, .. } => {
                assert!(
                    !path.contains("/mnt/etc/dots"),
                    "{}: path leaked /mnt/etc/dots",
                    step.title
                );
                assert!(
                    !contents.contains("/mnt/etc/dots"),
                    "{}: contents leaked /mnt/etc/dots",
                    step.title
                );
            }
            Action::WriteSecrets { path, .. } => {
                assert!(
                    !path.contains("/mnt/etc/dots"),
                    "{}: path leaked /mnt/etc/dots",
                    step.title
                );
            }
        }
    }
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
fn plan_seeds_passwords_via_secrets_nix_not_chpasswd() {
    // Under userborn + immutable /etc the user account does not exist at
    // install time (userborn creates it at first boot from the closure baked
    // by nixos-install), so the old `nixos-enter -- chpasswd` step had no
    // target. The declarative yescrypt hashes in nix/secrets.nix replace it:
    // the WriteSecrets step computes them from the plaintext passwords and
    // writes the file into the staged flake.
    let steps = plan(&cfg(), "/etc/dots", "/mnt");
    let has_chpasswd = steps.iter().any(|s| {
        matches!(
            &s.action,
            Action::Command { program, args, .. }
            if program == "nixos-enter" && args.iter().any(|a| a == "chpasswd")
        )
    });
    assert!(
        !has_chpasswd,
        "chpasswd step should be replaced by WriteSecrets"
    );

    let user_password = steps
        .iter()
        .find_map(|s| match &s.action {
            Action::WriteSecrets {
                path,
                user_password,
            } if path == &format!("{STAGED_FLAKE}/nix/secrets.nix") => Some(user_password.clone()),
            _ => None,
        })
        .expect("WriteSecrets step writing nix/secrets.nix");
    assert_eq!(user_password, "usersecret");

    // The user password must never appear in any command's argv: the
    // WriteSecrets runner pipes it to mkpasswd via stdin, so it never hits
    // /proc argv.
    for s in &steps {
        if let Action::Command { program, args, .. } = &s.action {
            let joined = format!("{program} {}", args.join(" "));
            assert!(
                !joined.contains("usersecret"),
                "password leaked into argv: {joined}"
            );
        }
    }
}

#[test]
fn plan_writes_secrets_before_install_and_never_stashes_them() {
    let steps = plan(&cfg(), "/etc/dots", "/mnt");
    let idx = |pred: &dyn Fn(&Step) -> bool| steps.iter().position(pred).unwrap();
    let secrets = idx(&|s| matches!(&s.action, Action::WriteSecrets { .. }));
    let install = idx(
        &|s| matches!(&s.action, Action::Command { program, .. } if program == "nixos-install"),
    );
    assert!(
        secrets < install,
        "secrets.nix must be written before nixos-install evaluates the flake"
    );

    // The load-bearing git-leak guard: secrets.nix must never reach
    // /var/lib/dots, or dots-clone (nix/home/dots-repo.nix) would restore it
    // into the user's git clone and a yescrypt hash would be committable.
    // No command in the plan may reference secrets.nix at all — the stash cp
    // lists only settings.nix + facter.json, and WriteSecrets writes into the
    // tmpfs STAGED_FLAKE, not the target.
    for s in &steps {
        if let Action::Command { program, args, .. } = &s.action {
            let joined = format!("{program} {}", args.join(" "));
            assert!(
                !joined.contains("secrets.nix"),
                "secrets.nix must not appear in any command (would risk stashing it): {joined}"
            );
        }
    }
}

#[test]
fn plan_copies_network_profiles_to_target() {
    let steps = plan(&cfg(), "/etc/dots", "/mnt");
    let copy = steps
        .iter()
        .find(|s| s.title == "Copy network profiles to target")
        .expect("network profile copy step");
    let Action::Command { program, args, .. } = &copy.action else {
        panic!("copy step must be a command");
    };
    assert_eq!(program, "sh");
    let script = args.join(" ");
    assert!(
        script.contains("if [ -d /etc/NetworkManager/system-connections ]"),
        "{script}"
    );
    // Must land on the persistent /persist subvol, not the ephemeral /mnt/etc:
    // the root is a tmpfs wiped each boot, so nixos-impermanence bind-mounts
    // /persist/etc/NetworkManager/system-connections over /etc/...; writing to
    // the persistent source is what survives the first reboot.
    assert!(
        script.contains("mkdir -p /mnt/persist/etc/NetworkManager"),
        "{script}"
    );
    assert!(
        script.contains(
            "cp -a /etc/NetworkManager/system-connections /mnt/persist/etc/NetworkManager/"
        ),
        "{script}"
    );
}

#[test]
fn plan_copies_network_profiles_after_mount_before_install() {
    let steps = plan(&cfg(), "/etc/dots", "/mnt");
    let idx = |pred: &dyn Fn(&Step) -> bool| steps.iter().position(pred).unwrap();
    let disko =
        idx(&|s| matches!(&s.action, Action::Command { program, .. } if program == "disko"));
    let copy = idx(&|s| s.title == "Copy network profiles to target");
    let install = idx(
        &|s| matches!(&s.action, Action::Command { program, .. } if program == "nixos-install"),
    );
    assert!(
        disko < copy && copy < install,
        "a copy before disko mounts the target would vanish with the tmpfs"
    );
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
