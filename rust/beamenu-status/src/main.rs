//! `beamenu-dashboard`: the live system dashboard beamenu-canvas spawns.
//!
//! Re-renders on a timer rather than on demand, which is the point — the
//! launcher's own rows are a snapshot taken as you type, and this is where a
//! reading that changes while you watch belongs.

use std::io::Write;
use std::time::Duration;

use anyhow::{Context, Result};
use beamenu_status::{cache, dashboard, probe, rpc};
use clap::Parser;

/// How often the dashboard repaints.
const TICK: Duration = Duration::from_secs(1);

#[derive(Parser, Debug)]
#[command(
    name = "beamenu-dashboard",
    about = "Live system status dashboard for the beamenu launcher",
    version
)]
struct Cli {
    /// The metric to emphasise, i.e. the row the dashboard was opened from.
    #[arg(value_name = "METRIC", default_value = "")]
    metric: Vec<String>,

    /// Render one frame to stdout as plain markdown and exit.
    ///
    /// The dashboard is otherwise only reachable through the canvas, which
    /// makes it awkward to look at while changing it.
    #[arg(long)]
    once: bool,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let metric = cli.metric.join(" ");
    let state = cache::state_dir();

    if cli.once {
        let markdown = frame(&state, &metric);
        print!("{markdown}");
        return Ok(());
    }

    let mut stdout = std::io::stdout().lock();
    loop {
        let markdown = frame(&state, &metric);
        writeln!(stdout, "{}", rpc::render(&markdown)).context("could not write to the canvas")?;
        // Flushing per message is the contract: the canvas reads
        // newline-delimited JSON off a pipe, so a buffered frame never lands.
        stdout.flush().context("could not flush to the canvas")?;
        std::thread::sleep(TICK);
    }
}

fn frame(state: &std::path::Path, metric: &str) -> String {
    let live = probe::live();
    let snapshot = cache::load(&cache::path(state));
    dashboard::render(&live, snapshot.as_ref(), metric)
}
