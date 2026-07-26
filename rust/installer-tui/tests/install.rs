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
        root_password: "rootsecret".into(),
        user_password: "usersecret".into(),
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
        script.contains(&format!("rm -rf {STAGED_FLAKE}")),
        "{script}"
    );
    assert!(
        script.contains(&format!("mkdir -p {STAGED_FLAKE}")),
        "{script}"
    );
    assert!(
        script.contains(&format!("cp -rTL /etc/dots {STAGED_FLAKE}")),
        "{script}"
    );
    assert!(
        script.contains(&format!("chmod -R u+w {STAGED_FLAKE}")),
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
    assert!(script.contains("mkdir -p /mnt/var/lib/dots"), "{script}");
    assert!(
        script.contains(&format!(
            "cp {STAGED_FLAKE}/nix/settings.nix {STAGED_FLAKE}/nix/facter.json /mnt/var/lib/dots/"
        )),
        "{script}"
    );
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
fn plan_sets_passwords_before_tpm2_enrollment() {
    let steps = plan(&cfg(), "/etc/dots", "/mnt");
    let idx = |pred: &dyn Fn(&Step) -> bool| steps.iter().position(pred).unwrap();
    let chpasswd =
        idx(&|s| matches!(&s.action, Action::Command { program, .. } if program == "nixos-enter"));
    let enroll = idx(
        &|s| matches!(&s.action, Action::Command { program, .. } if program == "systemd-cryptenroll"),
    );
    assert!(
        chpasswd < enroll,
        "a failed TPM2 enrollment must not leave every account locked"
    );
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
    assert!(
        script.contains("mkdir -p /mnt/etc/NetworkManager"),
        "{script}"
    );
    assert!(
        script.contains("cp -a /etc/NetworkManager/system-connections /mnt/etc/NetworkManager/"),
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
fn plan_pre_seeds_sbctl_keys_before_install() {
    let steps = plan(&cfg(), "/etc/dots", "/mnt");
    let idx = |pred: &dyn Fn(&Step) -> bool| steps.iter().position(pred).unwrap();
    let preseed = idx(&|s| s.title == "Pre-seed Secure Boot keys");
    let install = idx(
        &|s| matches!(&s.action, Action::Command { program, .. } if program == "nixos-install"),
    );
    assert!(
        preseed < install,
        "pre-seed must run before nixos-install: nixos-install activates generation 1, \
         and lanzaboote signs the UKI from /var/lib/sbctl/keys/db/db.pem during that \
         activation — the keys must already be on the target or signing fails with \
         'Failed to read public key from /var/lib/sbctl/keys/db/db.pem'"
    );
}

#[test]
fn plan_pre_seed_step_copies_iso_keys_to_target_var_lib_sbctl() {
    let steps = plan(&cfg(), "/etc/dots", "/mnt");
    let preseed = steps
        .iter()
        .find(|s| s.title == "Pre-seed Secure Boot keys")
        .expect("pre-seed step");
    let Action::Command { program, args, .. } = &preseed.action else {
        panic!("pre-seed step must be a command");
    };
    assert_eq!(program, "sh");
    let script = args.join(" ");
    assert!(script.contains("[ -d /etc/dots-sbctl-keys ]"), "{script}");
    assert!(script.contains("mkdir -p /mnt/var/lib/sbctl"), "{script}");
    assert!(
        script.contains("cp -a /etc/dots-sbctl-keys/. /mnt/var/lib/sbctl/"),
        "{script}"
    );
    assert!(
        script.contains("chmod 700 /mnt/var/lib/sbctl/keys"),
        "{script}"
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
