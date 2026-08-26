//! The two argv contracts the launcher spawns `beamenu-canvas` with.
//!
//! `beamenu-canvas --manifest <path> --command <id> [--query <string>]` opens
//! one plugin view in a window of its own, which is what activating a `view`
//! row does.
//!
//! `beamenu-canvas --preview` is the resident preview pane. It opens no view
//! of its own and takes no manifest: it reads
//! `beamenu::preview::Message` lines on stdin and draws whichever row the
//! launcher's highlight is on, including a plugin view when that is what the
//! row is. Same renderer, same stylesheet, different lifetime.

use std::path::PathBuf;

use clap::Parser;

#[derive(Parser, Debug, Clone)]
#[command(
    name = "beamenu-canvas",
    about = "WebKitGTK sidecar that renders beamenu plugin views and previews",
    version
)]
pub struct Cli {
    /// Run as the launcher's preview pane, reading protocol lines on stdin.
    #[arg(long, conflicts_with_all = ["manifest", "command", "query"])]
    pub preview: bool,

    /// Path to the plugin's JSON manifest.
    #[arg(long, required_unless_present = "preview")]
    pub manifest: Option<PathBuf>,

    /// Id of the manifest command to run.
    #[arg(long, required_unless_present = "preview")]
    pub command: Option<String>,

    /// Query text substituted for `{query}` in the command's exec argv.
    #[arg(long)]
    pub query: Option<String>,
}
