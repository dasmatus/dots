//! Crate root for `dots-ask`, the daemon behind the Quickshell ask pane.
//!
//! The binary in `main.rs` is a thin shell over this library so the test
//! crates in `tests/` can drive the store, the session state machine and the
//! socket server directly instead of spawning a process and reading its
//! output back.
//!
//! The error type lives here rather than in a module of its own, because
//! every module below returns it and the spec's module map gives the crate
//! root that job. Diagnostics are `miette`, which is a first for this repo:
//! the other crates reach for `thiserror`, and this one does not, because a
//! daemon that fails at startup gets one chance to say why on stderr, and
//! `miette`'s `help` text is the part a person acts on.

use std::error::Error;
use std::fmt;
use std::io;
use std::path::PathBuf;

use miette::Diagnostic;

pub mod proto;

/// Everything the daemon can fail at outside the wire protocol.
///
/// A wire-level mistake is deliberately not in here. A client that sends
/// garbage gets a connection-scoped `error` event and keeps its connection,
/// so it never travels as a Rust error at all.
#[derive(Debug, Diagnostic)]
#[non_exhaustive]
pub enum AskError {
    /// The daemon has no runtime directory to put its socket in.
    #[diagnostic(
        code(dots_ask::no_runtime_dir),
        help("start dots-ask from a logind session, or pass --socket <path>")
    )]
    NoRuntimeDir,

    /// The daemon has nowhere to keep conversations.
    #[diagnostic(
        code(dots_ask::no_data_home),
        help("set XDG_DATA_HOME or HOME, or pass --state-dir <path>")
    )]
    NoDataHome,

    /// A directory the daemon needs could not be created.
    #[diagnostic(
        code(dots_ask::create_dir),
        help("check the permissions on the parent directory")
    )]
    CreateDir {
        /// The directory that could not be created.
        path: PathBuf,
        /// What the filesystem said.
        source: io::Error,
    },

    /// A socket left behind by a crashed run could not be removed.
    ///
    /// A unix socket outlives the process that bound it, so startup always
    /// unlinks the old one. Without that, binding fails with `EADDRINUSE`
    /// and the message names the wrong problem.
    #[diagnostic(
        code(dots_ask::stale_socket),
        help("remove the file by hand, or check that no other dots-ask is running")
    )]
    RemoveStaleSocket {
        /// The socket path.
        path: PathBuf,
        /// What the filesystem said.
        source: io::Error,
    },

    /// The listener could not bind.
    #[diagnostic(
        code(dots_ask::bind),
        help("check that the runtime directory exists and is writable")
    )]
    Bind {
        /// The socket path.
        path: PathBuf,
        /// What the kernel said.
        source: io::Error,
    },

    /// The socket could not be narrowed to mode 0600.
    ///
    /// The mode is the whole access-control story for this protocol, so a
    /// socket the daemon cannot lock down is not one it should serve.
    #[diagnostic(
        code(dots_ask::socket_mode),
        help("the socket mode is the only gate on this protocol, so a wide one is refused")
    )]
    SocketMode {
        /// The socket path.
        path: PathBuf,
        /// What the filesystem said.
        source: io::Error,
    },

    /// A store file could not be read.
    #[diagnostic(code(dots_ask::store_read))]
    StoreRead {
        /// The file that could not be read.
        path: PathBuf,
        /// What the filesystem said.
        source: io::Error,
    },

    /// A store file could not be written.
    #[diagnostic(code(dots_ask::store_write))]
    StoreWrite {
        /// The file that could not be written.
        path: PathBuf,
        /// What the filesystem said.
        source: io::Error,
    },

    /// A stored line is not an event this build understands.
    #[diagnostic(
        code(dots_ask::store_decode),
        help("the transcript came from another protocol version; move it aside to recover the rest")
    )]
    StoreDecode {
        /// The transcript the line came from.
        path: PathBuf,
        /// Which line, counting from one.
        line: usize,
        /// What serde said.
        source: serde_json::Error,
    },

    /// An event could not be turned into a wire line.
    #[diagnostic(code(dots_ask::encode))]
    Encode {
        /// What serde said.
        source: serde_json::Error,
    },

    /// The command line was not one the daemon accepts.
    #[diagnostic(code(dots_ask::usage), help("run dots-ask --help"))]
    Usage {
        /// What was wrong with it.
        detail: String,
    },
}

impl fmt::Display for AskError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NoRuntimeDir => f.write_str("XDG_RUNTIME_DIR is not set"),
            Self::NoDataHome => f.write_str("neither XDG_DATA_HOME nor HOME is set"),
            Self::CreateDir { path, .. } => {
                write!(f, "cannot create directory {}", path.display())
            }
            Self::RemoveStaleSocket { path, .. } => {
                write!(f, "cannot remove the stale socket at {}", path.display())
            }
            Self::Bind { path, .. } => write!(f, "cannot bind {}", path.display()),
            Self::SocketMode { path, .. } => {
                write!(f, "cannot set mode 0600 on {}", path.display())
            }
            Self::StoreRead { path, .. } => write!(f, "cannot read {}", path.display()),
            Self::StoreWrite { path, .. } => write!(f, "cannot write {}", path.display()),
            Self::StoreDecode { path, line, .. } => {
                write!(f, "{}:{line} is not a stored event", path.display())
            }
            Self::Encode { .. } => f.write_str("cannot encode an event as a wire line"),
            Self::Usage { detail } => write!(f, "{detail}"),
        }
    }
}

impl Error for AskError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::NoRuntimeDir | Self::NoDataHome | Self::Usage { .. } => None,
            Self::CreateDir { source, .. }
            | Self::RemoveStaleSocket { source, .. }
            | Self::Bind { source, .. }
            | Self::SocketMode { source, .. }
            | Self::StoreRead { source, .. }
            | Self::StoreWrite { source, .. } => Some(source),
            Self::StoreDecode { source, .. } | Self::Encode { source } => Some(source),
        }
    }
}
