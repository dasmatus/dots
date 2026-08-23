//! beamenu's entry point.
//!
//! Four modes. With no arguments it opens the launcher. `--command` runs one
//! system command directly, which is how a Hyprland keybind reaches a single
//! action without going through the UI. `--daemon` runs the clipboard watcher,
//! and `--status-daemon` the system-status poller.
//!
//! Exit codes matter here because a keybind is the usual caller and has no
//! terminal to read a message from: 0 for done, 1 for a real failure, 2 for a
//! usage error. Diagnostics go to stderr so `--list-commands` stays pipeable.

use std::process::ExitCode;

use clap::Parser;

use beamenu::{config, daemon, dispatch, item::Action, providers::system, App};

/// Something went wrong at run time.
const EXIT_FAILURE: u8 = 1;
/// The arguments did not name anything real.
const EXIT_USAGE: u8 = 2;

#[derive(Parser, Debug)]
#[command(
    name = "beamenu",
    about = "Raycast-style launcher for Wayland",
    version
)]
struct Cli {
    /// Run one system command by id and exit, skipping the launcher.
    #[arg(long, value_name = "ID")]
    command: Option<String>,

    /// List the ids --command accepts, one per line.
    #[arg(long)]
    list_commands: bool,

    /// Run the clipboard-history watcher in the foreground.
    #[arg(long)]
    daemon: bool,

    /// Run the system-status poller in the foreground.
    ///
    /// Refreshes the readings the launcher cannot afford to take itself, into
    /// a snapshot file the status provider reads.
    #[arg(long)]
    status_daemon: bool,
}

fn main() -> ExitCode {
    let cli = Cli::parse();

    match run(&cli) {
        Ok(code) => code,
        Err(err) => {
            // anyhow's chain carries the context each layer added; printing all
            // of it is the difference between "failed" and "wl-copy is not
            // available".
            eprintln!("beamenu: {err}");
            for cause in err.chain().skip(1) {
                eprintln!("  caused by: {cause}");
            }
            ExitCode::from(EXIT_FAILURE)
        }
    }
}

fn run(cli: &Cli) -> anyhow::Result<ExitCode> {
    if cli.list_commands {
        for id in system::command_ids() {
            println!("{id}");
        }
        return Ok(ExitCode::SUCCESS);
    }

    if cli.daemon {
        let state = config::state_dir();
        std::fs::create_dir_all(&state)?;
        daemon::watch(&daemon::log_path(&state))?;
        return Ok(ExitCode::SUCCESS);
    }

    if cli.status_daemon {
        let state = config::state_dir();
        std::fs::create_dir_all(&state)?;
        daemon::poll_status(&state)?;
        return Ok(ExitCode::SUCCESS);
    }

    if let Some(id) = &cli.command {
        let Some(command) = system::command_for(id) else {
            eprintln!("beamenu: unknown command '{id}'");
            eprintln!("beamenu: run --list-commands to see the available ids");
            return Ok(ExitCode::from(EXIT_USAGE));
        };
        // The command list is all shell one-liners, none of which run in a
        // terminal. dispatch still takes one for the Launch arm, and reading
        // it here keeps the emulator out of this file.
        let config = config::Config::load(&config::config_dir().join("config.json"));
        dispatch::dispatch(&Action::Shell(command.to_string()), &config.terminal)?;
        return Ok(ExitCode::SUCCESS);
    }

    let mut app = App::new();
    beamenu::run(&mut app)?;
    Ok(ExitCode::SUCCESS)
}
