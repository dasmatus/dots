//! Binary entry point: `hyprmon apply` (one-shot) and `hyprmon watch`
//! (long-running daemon for the systemd user service). The watch loop and
//! the apply pipeline live in the library; this is a thin dispatch so the
//! logic stays testable.

use clap::{Parser, Subcommand};

use hyprmon::rules::Rules;
use hyprmon::runner::{apply, LiveHyprCtl};
use hyprmon::watch::{watch, Applier, Socket2Stream};

#[derive(Parser)]
#[command(
    name = "hyprmon",
    about = "declarative multi-monitor auto-detection for Hyprland"
)]
struct Args {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Apply the ruleset once and exit.
    Apply,
    /// Apply once, then re-apply on monitor hotplug (daemon mode).
    Watch,
}

fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    let rules = Rules::load();
    match args.cmd {
        Cmd::Apply => {
            let specs = apply(&LiveHyprCtl, &rules).map_err(anyhow::Error::msg)?;
            for s in specs {
                println!("{}", s.render());
            }
            Ok(())
        }
        Cmd::Watch => {
            let stream = Socket2Stream::open().map_err(anyhow::Error::msg)?;
            let applier = LiveApplier;
            watch(stream, &applier, &rules).map_err(anyhow::Error::msg)
        }
    }
}

/// Live applier: shells out to `hyprctl` via the library's [`apply`].
struct LiveApplier;

impl Applier for LiveApplier {
    fn apply(&self, rules: &Rules) -> Result<Vec<hyprmon::MonitorSpec>, String> {
        apply(&LiveHyprCtl, rules)
    }
}
