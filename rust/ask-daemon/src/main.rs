//! `dots-ask`: the daemon behind the Quickshell ask pane.
//!
//! It runs as a systemd user service rather than inside Quickshell, because
//! `nix/home/quickshell/default.nix` puts the QML tree on
//! `X-Restart-Triggers`. Every rebuild restarts the shell, and a turn living
//! inside the shell would die with it.
//!
//! Argument parsing is by hand rather than through a parser crate. There are
//! two options, both of them path overrides that exist so a test or a second
//! instance can point somewhere other than the XDG defaults, and a dependency
//! for that would cost more than it explains.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use tracing_subscriber::EnvFilter;

use ask_daemon::artifact::{self, ArtifactStore};
use ask_daemon::backend::Registry;
use ask_daemon::mcp::McpPool;
use ask_daemon::policy::Policy;
use ask_daemon::secrets::SecretStore;
use ask_daemon::server::{
    default_policy_path, default_socket_path, default_state_root, Artifacts, Daemon,
};
use ask_daemon::AskError;

/// What the command line asked for.
enum Invocation {
    /// Run the daemon.
    Serve {
        /// Where to bind, defaulting to `$XDG_RUNTIME_DIR/dots-ask.sock`.
        socket: Option<PathBuf>,
        /// Where conversations live, defaulting to `$XDG_DATA_HOME/dots-ask`.
        state_root: Option<PathBuf>,
    },
    /// Print usage and stop.
    Help,
    /// Print the version and stop.
    Version,
}

/// What `--help` prints.
const USAGE: &str = "\
dots-ask: the AI side pane daemon

usage: dots-ask [--socket <path>] [--state-dir <path>]

  --socket <path>     bind here instead of $XDG_RUNTIME_DIR/dots-ask.sock
  --state-dir <path>  keep conversations here instead of $XDG_DATA_HOME/dots-ask
  -h, --help          print this and exit
  -V, --version       print the version and exit

Logging follows RUST_LOG and goes to stderr.";

#[tokio::main]
async fn main() -> miette::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .without_time()
        .with_writer(std::io::stderr)
        .init();

    let (socket, state_root) = match parse_args(std::env::args().skip(1))? {
        Invocation::Help => {
            println!("{USAGE}");
            return Ok(());
        }
        Invocation::Version => {
            println!("dots-ask {}", env!("CARGO_PKG_VERSION"));
            return Ok(());
        }
        Invocation::Serve { socket, state_root } => (socket, state_root),
    };

    let socket = match socket {
        Some(path) => path,
        None => default_socket_path()?,
    };
    let state_root = match state_root {
        Some(path) => path,
        None => default_state_root()?,
    };

    let policy_path = default_policy_path()?;
    tracing::info!(path = %policy_path.display(), "loading the approval store");
    let policy = Arc::new(Mutex::new(Policy::open(policy_path)?));

    // Discovery reads config files and starts nothing, so it is safe here.
    // The one probe the registry does run is a local connect to ollama's
    // 11434, which is bounded. Nothing touches the keyring: a locked
    // collection would block this for ten seconds before the socket exists,
    // which is what `secrets.rs` is written to avoid.
    let home = std::env::var_os("HOME").map(PathBuf::from);
    let mcp = Arc::new(home.as_deref().map_or_else(McpPool::empty, |home| {
        McpPool::discover(home, std::env::current_dir().ok().as_deref())
    }));
    let registry = Arc::new(
        Registry::discover(Arc::new(SecretStore::default()), mcp, Arc::clone(&policy)).await,
    );

    // Bound before the unix socket exists, so the very first `ready` can
    // carry a real `artifact_base`. A loopback port that will not bind is not
    // a reason to refuse to run: every backend still works, pages are still
    // written and recorded, and the pane learns it has nothing to open them
    // with from an `artifact_base` of null rather than from a dead link.
    let store = Arc::new(ArtifactStore::open(&state_root)?);
    let (artifacts, server) = match artifact::serve::bind(Arc::clone(&store)) {
        Ok(bound) => (
            Artifacts {
                store,
                base: Some(bound.base().to_owned()),
            },
            Some(bound),
        ),
        Err(err) => {
            tracing::warn!(error = %err, "no artifact server; pages will be written but not openable");
            (Artifacts { store, base: None }, None)
        }
    };
    if let Some(bound) = server {
        tokio::spawn(bound.serve());
    }

    tracing::info!(state = %state_root.display(), "opening the conversation store");
    let daemon = Daemon::bind(socket, state_root, registry, artifacts)?;
    daemon.serve().await;
    Ok(())
}

/// Read the command line.
///
/// # Errors
///
/// [`AskError::Usage`] for an unknown flag or an option with no value.
fn parse_args(args: impl Iterator<Item = String>) -> Result<Invocation, AskError> {
    let mut socket = None;
    let mut state_root = None;
    let mut args = args;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "-h" | "--help" => return Ok(Invocation::Help),
            "-V" | "--version" => return Ok(Invocation::Version),
            "--socket" => socket = Some(PathBuf::from(value_for(&arg, &mut args)?)),
            "--state-dir" => state_root = Some(PathBuf::from(value_for(&arg, &mut args)?)),
            other => {
                return Err(AskError::Usage {
                    detail: format!("unknown argument {other:?}"),
                })
            }
        }
    }
    Ok(Invocation::Serve { socket, state_root })
}

/// Take the value that follows an option.
fn value_for(flag: &str, args: &mut impl Iterator<Item = String>) -> Result<String, AskError> {
    args.next().ok_or_else(|| AskError::Usage {
        detail: format!("{flag} needs a path"),
    })
}
