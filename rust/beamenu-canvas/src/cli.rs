//! The argv contract the launcher spawns `beamenu-canvas` with (binding,
//! see the task brief):
//! `beamenu-canvas --manifest <path> --command <id> [--query <string>]`.

use std::path::PathBuf;

use clap::Parser;

#[derive(Parser, Debug, Clone)]
#[command(
    name = "beamenu-canvas",
    about = "WebKitGTK sidecar that renders beamenu plugin views",
    version
)]
pub struct Cli {
    /// Path to the plugin's JSON manifest.
    #[arg(long)]
    pub manifest: PathBuf,

    /// Id of the manifest command to run.
    #[arg(long)]
    pub command: String,

    /// Query text substituted for `{query}` in the command's exec argv.
    #[arg(long)]
    pub query: Option<String>,
}
