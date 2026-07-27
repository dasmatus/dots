//! Binary entry point: argument dispatch + the terminal event loop.
//!
//! The non-interactive paths (`--restore`, `--cache-previews`, `--path`) are
//! unchanged. The interactive `run_tui` is rewritten onto the abstracttui
//! runtime in Task 5; this stub keeps the binary compiling after the dep swap
//! so the non-TUI integration tests stay green.

use std::str::FromStr;

use clap::Parser;

use wallpaper_tui::accent::TintBackend;
use wallpaper_tui::cli::{self, Args};
use wallpaper_tui::config::{Config, State};

fn resolve_backend(args_backend: Option<String>, config_backend: &str) -> TintBackend {
    if let Some(b) = args_backend {
        if let Ok(backend) = TintBackend::from_str(&b) {
            return backend;
        }
    }
    TintBackend::from_str(config_backend).unwrap_or_default()
}

fn main() -> anyhow::Result<()> {
    let args = Args::parse();
    let config = Config::load();
    let state = State::load();
    let backend = resolve_backend(args.tint_backend.clone(), &config.tint_backend);

    if args.restore {
        std::process::exit(cli::restore_all(&config, &state, args.no_tint, backend));
    }
    if args.cache_previews {
        return cli::run_cache(&config, &args.preview_size);
    }
    if let Some(path) = args.path.clone() {
        let output = args
            .output
            .clone()
            .ok_or_else(|| anyhow::anyhow!("--output is required when a path is given"))?;
        return cli::apply_noninteractive(
            &config,
            &mut { state },
            &output,
            &path,
            &args.mode,
            &args.color,
            args.no_tint,
            backend,
        );
    }

    run_tui(config, state, args.no_tint, backend)
}

/// Interactive TUI — rewritten onto abstracttui in Task 5.
fn run_tui(
    _config: Config,
    _state: State,
    _no_tint: bool,
    _backend: TintBackend,
) -> anyhow::Result<()> {
    anyhow::bail!("wallpaper TUI is being migrated to abstracttui (Task 5)")
}
