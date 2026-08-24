//! `dots-osd`: the desktop's voice.
//!
//! One subcommand per keybind, plus `watch` for the resident half.
//!
//! Both callers, a Hyprland bind and a systemd user unit, are things without
//! a terminal, so everything diagnostic goes through `tracing` to stderr and
//! the journal collects it. Timestamps are deliberately off: journald stamps
//! every line it receives, and a second timestamp inside the message is just
//! noise to read past. `RUST_LOG=debug` turns on the per-command detail.

use std::time::Duration;

use clap::{Parser, Subcommand, ValueEnum};
use dots_osd::control::{self, Step, Switch};
use dots_osd::notify::Bus;
use dots_osd::{observe, watch};
use tracing_subscriber::EnvFilter;

/// How often the watcher looks.
///
/// The readings it compares are refreshed by `beamenu --status-daemon` every
/// five seconds, so looking faster than this buys nothing; looking slower would
/// add its own lag on top of the poller's.
const TICK: Duration = Duration::from_secs(2);

/// Ticks between camera scans.
///
/// The camera reading is the only expensive one, around 15 ms against 89 µs
/// for the rest of a tick, measured in `benches/observe.rs`, so it runs at a
/// fifth of the rate. Every two seconds it would cost most of a percent of a
/// core forever; every ten it costs a fifth of that, and ten seconds is still
/// fast enough that a webcam switching on is news.
const CAMERA_EVERY: u32 = 5;

#[derive(Parser, Debug)]
#[command(
    name = "dots-osd",
    about = "On-screen feedback: keybind OSDs, and notifications when system state changes",
    version
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Move or mute the default audio output.
    Volume {
        #[arg(value_enum)]
        action: Level,
    },
    /// Toggle the microphone's mute.
    Microphone,
    /// Move the panel brightness.
    Brightness {
        #[arg(value_enum)]
        action: Direction,
    },
    /// Enable or disable the touchpad.
    Touchpad {
        #[arg(value_enum)]
        action: Flip,
    },
    /// Mute the microphone as a privacy switch, naming anything on the camera.
    Privacy {
        #[arg(value_enum)]
        action: Flip,
    },
    /// Watch for state changes and notify on them. Never returns.
    Watch,
}

#[derive(ValueEnum, Debug, Clone, Copy)]
enum Level {
    Up,
    Down,
    Mute,
}

#[derive(ValueEnum, Debug, Clone, Copy)]
enum Direction {
    Up,
    Down,
}

impl From<Direction> for Step {
    fn from(direction: Direction) -> Self {
        match direction {
            Direction::Up => Self::Up,
            Direction::Down => Self::Down,
        }
    }
}

/// A switch's argument. Named for the action rather than for its variants, so
/// the `toggle` value can keep the word a person would type for it.
#[derive(ValueEnum, Debug, Clone, Copy)]
enum Flip {
    On,
    Off,
    Toggle,
}

impl From<Flip> for Switch {
    fn from(flip: Flip) -> Self {
        match flip {
            Flip::On => Self::On,
            Flip::Off => Self::Off,
            Flip::Toggle => Self::Toggle,
        }
    }
}

fn main() -> miette::Result<()> {
    tracing_subscriber::fmt()
        // journald already stamps every line; a second timestamp inside the
        // message is one more thing to read past.
        .without_time()
        .with_writer(std::io::stderr)
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("warn")),
        )
        .init();

    let cli = Cli::parse();
    Ok(run(&cli.command)?)
}

fn run(command: &Command) -> dots_osd::Result<()> {
    let notification = match command {
        // The only mode that does not end in one notification: it ends in
        // however many the session earns before it is stopped.
        Command::Watch => return watch_forever(),
        Command::Volume { action } => match action {
            Level::Up => control::volume(Step::Up),
            Level::Down => control::volume(Step::Down),
            Level::Mute => control::volume_mute(),
        },
        Command::Microphone => control::microphone_mute(),
        Command::Brightness { action } => control::brightness((*action).into()),
        Command::Touchpad { action } => control::touchpad((*action).into()),
        Command::Privacy { action } => control::privacy((*action).into()),
    }?;

    Bus::connect()?.send(&notification)
}

/// Compare the machine against itself until the service is stopped.
///
/// A notification that fails to send is reported and dropped. The alternative
/// is exiting, which would mean a notification daemon restarting takes the
/// watcher with it, and the whole point of the watcher is to still be there
/// when something goes wrong.
fn watch_forever() -> dots_osd::Result<()> {
    let bus = Bus::connect()?;
    let state_dir = beamenu_status::cache::state_dir();
    let mut state = watch::State::new();
    let mut tick: u32 = 0;

    tracing::info!(
        state_dir = %state_dir.display(),
        tick_secs = TICK.as_secs(),
        "watching"
    );

    loop {
        let scan_cameras = tick.is_multiple_of(CAMERA_EVERY);
        let observed = observe::observe(&state_dir, scan_cameras);
        if observed.snapshot.is_none() {
            tracing::debug!("no fresh snapshot; the status poller may be stopped");
        }

        for notification in watch::advance(&mut state, &observed) {
            if let Err(err) = bus.send(&notification) {
                // Reported and dropped. Exiting would mean a notification
                // daemon restarting takes the watcher with it, and the whole
                // point of the watcher is to still be there when something
                // goes wrong.
                tracing::warn!(
                    summary = %notification.summary,
                    error = %miette::Report::new(err),
                    "could not show a notification"
                );
            }
        }

        tick = tick.wrapping_add(1);
        std::thread::sleep(TICK);
    }
}
