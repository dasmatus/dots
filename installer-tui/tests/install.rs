//! Install-plan contract tests (step order, argv hygiene, TPM2 flow).

use dots_installer::config::InstallConfig;
use dots_installer::install::{
    plan, swap_size_from_meminfo, Action, Capture, Step, LUKS_DEVICE, LUKS_PASSFILE,
};

fn cfg() -> InstallConfig {
    InstallConfig {
        disk: "/dev/vda".into(),
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
fn plan_installs_from_embedded_flake() {
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
        joined.contains("--flake /mnt/etc/dots#tokyonight"),
        "{joined}"
    );
    assert!(joined.contains("--no-root-passwd"), "{joined}");
}

#[test]
fn plan_detects_hardware_into_target_flake_before_install() {
    let steps = plan(&cfg(), "/etc/dots", "/mnt");
    let idx = |pred: &dyn Fn(&Step) -> bool| steps.iter().position(pred).unwrap();
    let copy = idx(&|s| matches!(&s.action, Action::Command { program, .. } if program == "sh"));
    let facter =
        idx(&|s| matches!(&s.action, Action::Command { program, .. } if program == "nixos-facter"));
    let install = idx(
        &|s| matches!(&s.action, Action::Command { program, .. } if program == "nixos-install"),
    );
    assert!(
        copy < facter && facter < install,
        "the report must land in the copied flake before nixos-install evaluates it"
    );
    let Action::Command { args, .. } = &steps[facter].action else {
        unreachable!()
    };
    assert_eq!(args.join(" "), "-o /mnt/etc/dots/nix/facter.json");
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
