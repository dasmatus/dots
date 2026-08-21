//! CLI parsing and the non-interactive dispatch paths (``--restore``,
//! ``--cache-previews``, ``--output PATH``). The interactive TUI loop lives in
//! `main.rs`. The argument surface is identical to the previous Python
//! `main()` so the Nix service, `random_wp.nix` and the Hyprland `exec-once`
//! keep working unchanged.

use clap::builder::PossibleValuesParser;
use clap::Parser;

use crate::accent::TintBackend;
use crate::config::{preview_cache_dir, Config, State, DEFAULT_COLOR, MODES};
use crate::preview::{cache_previews, parse_preview_size};
use crate::tint::apply_tint;
use crate::wallpaperd::{
    apply_wallpaper, hyprtile_config_path, pidfile_path, restore_groups, sync_hyprtile_config,
    Group, LiveWallpaperd,
};

#[derive(Parser, Debug)]
#[command(
    name = "wallpaper-tui",
    about = "hyprtile-wallpaperd-based TUI wallpaper changer"
)]
pub struct Args {
    /// Re-apply effective wallpapers and exit.
    #[arg(long)]
    pub restore: bool,
    /// Output name (non-interactive apply).
    #[arg(long)]
    pub output: Option<String>,
    /// hyprtile-wallpaperd --mode (was swaybg scaling mode).
    #[arg(long, value_parser = PossibleValuesParser::new(MODES.iter().copied()), default_value = "fill")]
    pub mode: String,
    /// Fill color (hex) for letterbox modes.
    #[arg(long, default_value = DEFAULT_COLOR)]
    pub color: String,
    /// Skip wallpaper-derived accent tinting.
    #[arg(long = "no-tint")]
    pub no_tint: bool,
    /// Palette backend used to extract the wallpaper accent.
    #[arg(long = "tint-backend", value_parser = PossibleValuesParser::new(["internal", "pywal"]))]
    pub tint_backend: Option<String>,
    /// Regenerate the wallpaper thumbnail cache and exit.
    #[arg(long = "cache-previews")]
    pub cache_previews: bool,
    /// Thumbnail size `WxH` for --cache-previews.
    #[arg(long = "preview-size", default_value = "320x200")]
    pub preview_size: String,
    /// Wallpaper path (non-interactive apply).
    pub path: Option<String>,
}

/// Re-apply every declared output, using overrides where present; tint from
/// the first output's wallpaper. Returns the process exit code.
#[must_use]
pub fn restore_all(config: &Config, state: &State, no_tint: bool, backend: TintBackend) -> i32 {
    let groups = restore_groups(config, state);
    if groups.is_empty() {
        eprintln!("wallpaper-tui: nothing to restore.");
        return 1;
    }
    if apply_wallpaper(&LiveWallpaperd, &groups, &pidfile_path()) {
        sync_hyprtile_config(&hyprtile_config_path(), &groups[0].path, &groups[0].mode);
    }
    let _ = apply_tint(&groups[0].path, no_tint, backend);
    eprintln!("wallpaper-tui: restored {} output(s).", groups.len());
    0
}

/// Non-interactive apply of one path to one output, with tint.
#[allow(clippy::too_many_arguments)]
pub fn apply_noninteractive(
    state: &mut State,
    output: &str,
    path: &str,
    mode: &str,
    color: &str,
    no_tint: bool,
    backend: TintBackend,
) -> anyhow::Result<()> {
    use crate::config::OutputOverride;
    state.outputs.insert(
        output.to_string(),
        OutputOverride {
            path: Some(path.to_string()),
            mode: Some(mode.to_string()),
            fill_color: Some(color.to_string()),
        },
    );
    state.save()?;
    let groups = vec![Group {
        output: output.to_string(),
        path: path.to_string(),
        mode: mode.to_string(),
        fill_color: color.to_string(),
    }];
    if apply_wallpaper(&LiveWallpaperd, &groups, &pidfile_path()) {
        sync_hyprtile_config(&hyprtile_config_path(), path, mode);
    }
    let _ = apply_tint(path, no_tint, backend);
    eprintln!("wallpaper-tui: applied {path} to {output}.");
    Ok(())
}

/// Regenerate the wallpaper thumbnail cache (``--cache-previews``).
pub fn run_cache(config: &Config, preview_size: &str) -> anyhow::Result<()> {
    let (w, h) = parse_preview_size(preview_size).unwrap_or((320, 200));
    let stats = cache_previews(
        &config.wallpaper_folder,
        config.recursive,
        &preview_cache_dir(),
        (w, h),
    );
    eprintln!(
        "wallpaper-tui: cached {} new, skipped {}.",
        stats.written, stats.skipped
    );
    Ok(())
}

/// `--mode` value parser passthrough — re-exported so tests can build the
/// allowed set without depending on clap internals.
#[must_use]
pub fn modes() -> &'static [&'static str] {
    MODES
}
