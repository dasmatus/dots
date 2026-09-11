//! `dots-secreport`: the privacy/hardware-security dashboard collector, and
//! the AppArmor denial triage classifier, in one CLI.
//!
//! `report --json`/`watch --json` feed
//! `qml/settings/pages/security.qml`'s dashboard half. `triage` reads
//! AppArmor denial records — live from the journal, or from a captured
//! file, for testing and for replaying a log gathered on another machine —
//! and prints the allow/block proposals `triage::assemble` derives from
//! them, which is what a per-app AppArmor profile's `state = "enforce"`
//! flip should be based on rather than a hand guess.
use std::env;
use std::fs;
use std::io::{self, Write as _};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};
use std::time::Duration;

use dots_secreport::report;
use dots_secreport::triage::{self, Denial, TriageCtx, TriageReport};

const USAGE: &str = "usage: dots-secreport <report|watch|triage> [OPTIONS...]

  report --json
      Print the privacy/hardware-security dashboard as one JSON document:
      what recently touched a sensor, and how hard this machine is to
      attack. Read-only and unprivileged throughout; every external
      command it consults is optional, and a missing one degrades only
      its own card.

  watch --json
      Print the same document as `report --json`, then reprint it every
      few seconds, one complete JSON document per line, so a long-lived
      reader (the Settings page) sees the mic/camera/screen-capture cards
      update without re-spawning this process on every repaint.

  triage [--json] [--input PATH] [--since SPEC]
      Classify AppArmor denial records into allow/block proposals.
      Without --input, reads live from `journalctl`; SPEC (e.g. \"-1h\",
      \"2026-09-01\") is passed straight through to journalctl's own
      --since. --input PATH (or --input - for stdin) reads
      `journalctl -o json` formatted lines from a file instead, for
      replaying a log captured elsewhere. --json prints the full
      TriageReport document; the default is a short human-readable table,
      worst (Unclassified) first.";

fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("warn")),
        )
        .without_time()
        .with_writer(io::stderr)
        .init();

    let mut args = env::args().skip(1);
    let Some(command) = args.next() else {
        return usage_failure("no arguments given");
    };
    let rest: Vec<String> = args.collect();

    match command.as_str() {
        "-h" | "--help" => {
            println!("{USAGE}");
            ExitCode::SUCCESS
        }
        "report" => report_command(&rest),
        "watch" => watch_command(&rest),
        "triage" => triage_command(&rest),
        other => usage_failure(&format!("unknown command {other:?}")),
    }
}

fn usage_failure(message: &str) -> ExitCode {
    eprintln!("{message}\n{USAGE}");
    ExitCode::FAILURE
}

fn report_command(args: &[String]) -> ExitCode {
    // `--json` is the only output this subcommand knows how to produce
    // today; naming it explicitly (rather than accepting any bare
    // `report`) leaves room for a future human-readable mode without an
    // ambiguous default to change later.
    if args != ["--json"] {
        return usage_failure("dots-secreport report: only `--json` is supported");
    }
    match serde_json::to_string(&report::collect()) {
        Ok(json) => {
            println!("{json}");
            ExitCode::SUCCESS
        }
        Err(err) => {
            eprintln!("dots-secreport report: failed to serialize the report: {err}");
            ExitCode::FAILURE
        }
    }
}

/// How often `watch` recollects and reprints the report. Short enough that
/// a mic/camera indicator feels live, long enough that this process is not
/// itself a meaningful source of load — `collect()` shells out to half a
/// dozen external commands per call.
const WATCH_INTERVAL: Duration = Duration::from_secs(3);

fn watch_command(args: &[String]) -> ExitCode {
    if args != ["--json"] {
        return usage_failure("dots-secreport watch: only `--json` is supported");
    }
    loop {
        match serde_json::to_string(&report::collect()) {
            Ok(json) => {
                // One document per line, flushed immediately: a reader
                // blocked on a line it cannot see because it sat in a
                // buffer would look exactly like a report that never
                // updates.
                println!("{json}");
                if io::stdout().flush().is_err() {
                    // The reader went away (the QML Process was torn down,
                    // most likely). Nothing left to print for; stop rather
                    // than spin forever writing into a closed pipe.
                    return ExitCode::SUCCESS;
                }
            }
            Err(err) => {
                eprintln!("dots-secreport watch: failed to serialize the report: {err}");
                return ExitCode::FAILURE;
            }
        }
        std::thread::sleep(WATCH_INTERVAL);
    }
}

struct TriageArgs {
    json: bool,
    input: Option<String>,
    since: Option<String>,
}

fn parse_triage_args(args: &[String]) -> Result<TriageArgs, String> {
    let mut json = false;
    let mut input = None;
    let mut since = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--json" => json = true,
            "--input" => {
                i += 1;
                input = Some(
                    args.get(i)
                        .ok_or("--input needs a PATH (or - for stdin)")?
                        .clone(),
                );
            }
            "--since" => {
                i += 1;
                since = Some(
                    args.get(i)
                        .ok_or("--since needs a journalctl SPEC")?
                        .clone(),
                );
            }
            other => return Err(format!("unexpected argument {other:?}")),
        }
        i += 1;
    }
    Ok(TriageArgs { json, input, since })
}

fn triage_command(args: &[String]) -> ExitCode {
    let parsed = match parse_triage_args(args) {
        Ok(parsed) => parsed,
        Err(message) => return usage_failure(&format!("dots-secreport triage: {message}")),
    };

    let lines = match &parsed.input {
        Some(path) => match read_lines(path) {
            Ok(lines) => lines,
            Err(err) => {
                eprintln!("dots-secreport triage: reading {path:?}: {err}");
                return ExitCode::FAILURE;
            }
        },
        None => match journalctl_apparmor_lines(parsed.since.as_deref()) {
            Ok(lines) => lines,
            Err(err) => {
                eprintln!("dots-secreport triage: {err}");
                return ExitCode::FAILURE;
            }
        },
    };

    let denials: Vec<Denial> = lines
        .iter()
        .filter_map(|line| triage::denial_from_journal_line(line))
        .collect();

    let ctx = build_ctx();
    let report = triage::assemble(&denials, &ctx);

    if parsed.json {
        match serde_json::to_string(&report) {
            Ok(json) => println!("{json}"),
            Err(err) => {
                eprintln!("dots-secreport triage: failed to serialize the report: {err}");
                return ExitCode::FAILURE;
            }
        }
    } else {
        print_human(&report);
    }
    ExitCode::SUCCESS
}

/// Reads either a real file or, for `path == "-"`, stdin — one line per
/// `journalctl -o json` record, matching `triage::denial_from_journal_line`'s
/// contract.
fn read_lines(path: &str) -> io::Result<Vec<String>> {
    if path == "-" {
        io::stdin().lines().collect()
    } else {
        let contents = fs::read_to_string(Path::new(path))?;
        Ok(contents.lines().map(str::to_owned).collect())
    }
}

/// Shells out to `journalctl -o json`, filtered to lines that at least
/// mention `apparmor=` before the (comparatively expensive) per-line parse
/// in `triage::denial_from_journal_line` runs — `journalctl -g` does that
/// filtering in the journal reader itself rather than this process reading
/// every line the system ever logged.
fn journalctl_apparmor_lines(since: Option<&str>) -> Result<Vec<String>, String> {
    let mut command = Command::new("journalctl");
    command.args(["-o", "json", "-g", "apparmor="]);
    if let Some(since) = since {
        command.args(["--since", since]);
    }
    let output = command
        .output()
        .map_err(|err| format!("could not run journalctl: {err}"))?;
    if !output.status.success() {
        return Err(format!(
            "journalctl exited with {}: {}",
            output.status,
            String::from_utf8_lossy(&output.stderr)
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(str::to_owned)
        .collect())
}

/// Reads `/proc/self/status`'s real uid, so `$XDG_RUNTIME_DIR` has a
/// fallback that does not assume uid 1000. Avoids a `libc` dependency for
/// one `getuid()` call — `report`/`triage` otherwise depend on nothing
/// beyond serde/miette/tracing, and this crate's whole point is to be the
/// small, easy-to-audit half of what `dots-sandbox` used to be.
fn current_uid() -> Option<String> {
    let status = fs::read_to_string("/proc/self/status").ok()?;
    status.lines().find_map(|line| {
        let rest = line.strip_prefix("Uid:")?;
        rest.split_whitespace().next().map(str::to_owned)
    })
}

fn build_ctx() -> TriageCtx {
    let home = env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"));
    let runtime_dir = env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .or_else(|| current_uid().map(|uid| PathBuf::from(format!("/run/user/{uid}"))))
        .unwrap_or_else(|| PathBuf::from("/run/user/0"));
    TriageCtx {
        home,
        runtime_dir,
        // No per-app sandbox policy exists to read a denylist or an app-id
        // catalog from any more (see TriageCtx's own doc comment) — empty
        // is the honest, safe default: it only widens what falls through
        // to Verdict::Unclassified rather than misclassifying anything.
        deny_paths: Vec::new(),
        app_ids: Vec::new(),
    }
}

fn print_human(report: &TriageReport) {
    if let Some(reason) = &report.assist_unavailable {
        println!("(assist layer unavailable: {reason})");
    }
    if report.proposals.is_empty() {
        println!("no AppArmor denials found");
        return;
    }
    for proposal in &report.proposals {
        let path = proposal.path.as_deref().unwrap_or("-");
        println!(
            "{:?}\t{}\t{}\t{}\tx{}\t{}",
            proposal.classification.verdict,
            proposal.profile,
            proposal.operation,
            path,
            proposal.count,
            proposal.classification.rationale,
        );
        if let Some(include) = &proposal.proposed_include {
            println!("\t-> {include}");
        }
    }
}
