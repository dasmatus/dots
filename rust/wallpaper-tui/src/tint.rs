//! Per-target accent tinting: Hyprland borders, Rofi, GTK 3/4, Kvantum (Qt)
//! and `MoreWaita` icons. Writers are pure (string in → string out); tree
//! tinters and the orchestrator take a [`TintCtx`] holding all base/dest
//! paths so they are unit-testable with tmp dirs and no env-var mutation
//! (process-global env would race under parallel `cargo test`).

use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::str::FromStr;

use regex::Regex;

use crate::accent::{hex_to_hls, hls_to_hex, TintBackend};
use crate::config::{self, TintState};

/// Adwaita-blue family used by `MoreWaita` folder/place icons. Each is recolored
/// to the accent's hue/saturation while keeping its own lightness, so the
/// icon's gradient shading is preserved.
pub const ADWAITA_BLUE_HEXES: &[&str] = &[
    "#1c71d8", "#438de6", "#3584e4", "#62a0ea", "#99c1f1", "#afd4ff",
];
/// Catppuccin-Frappe-Blue accents used by the Kvantum base theme; replaced
/// verbatim (case-insensitive). Any trailing alpha hex is preserved because
/// only the 7-char body is matched.
pub const KVANTUM_ACCENT_HEXES: &[&str] = &["#8caaee", "#839edd", "#98b2ef"];

pub const ICON_THEME_NAME: &str = "MoreWaita-Tint";

/// All paths the orchestrator touches, resolved up-front (from env in the
/// real entry, from tmp dirs in tests).
#[derive(Debug, Clone)]
pub struct TintCtx {
    /// `None` ⇒ Kvantum target skipped.
    pub kvantum_base: Option<PathBuf>,
    /// `None` ⇒ icon target skipped.
    pub icon_base: Option<PathBuf>,
    pub kvantum_dest: PathBuf,
    pub kvantum_select: PathBuf,
    pub icon_dest: PathBuf,
    pub tint_dir: PathBuf,
    pub rofi_base: PathBuf,
    /// `None` ⇒ Hyprland border target skipped (no `HYPRLAND_INSTANCE_SIGNATURE`).
    pub his: Option<String>,
    /// When `false` (tests), skip the `gsettings` icon-theme switch and report
    /// `icons_selected = false`, matching "gsettings absent from PATH". The
    /// real entry sets this `true`.
    pub try_icon_select: bool,
}

impl TintCtx {
    /// Resolve every path from the XDG env vars, exactly as the Python did.
    #[must_use]
    pub fn from_env() -> Self {
        let xdg_config = xdg("XDG_CONFIG_HOME", ".config");
        let xdg_data = xdg("XDG_DATA_HOME", ".local/share");
        Self {
            kvantum_base: env_dir("WALLPAPER_TUI_KVANTUM_BASE"),
            icon_base: env_dir("WALLPAPER_TUI_ICON_BASE"),
            kvantum_dest: xdg_config.join("Kvantum").join("WallpaperTint"),
            kvantum_select: xdg_config.join("Kvantum").join("kvantum.kvconfig"),
            icon_dest: xdg_data.join("icons").join("MoreWaita-Tint"),
            tint_dir: config::tint_dir(),
            rofi_base: xdg_config
                .join("rofi")
                .join("themes")
                .join("tokyonight.rasi"),
            his: std::env::var("HYPRLAND_INSTANCE_SIGNATURE").ok(),
            try_icon_select: true,
        }
    }

    /// `tint/current.json` under this ctx's tint dir.
    #[must_use]
    pub fn tint_state_file(&self) -> PathBuf {
        self.tint_dir.join("current.json")
    }
}

fn xdg(env: &str, default_sub: &str) -> PathBuf {
    match std::env::var(env) {
        Ok(s) if !s.is_empty() => PathBuf::from(s),
        _ => home().join(default_sub),
    }
}
fn home() -> PathBuf {
    std::env::var("HOME").map_or_else(|_| PathBuf::from("/"), PathBuf::from)
}
fn env_dir(env: &str) -> Option<PathBuf> {
    let s = std::env::var(env).ok()?;
    let p = PathBuf::from(s);
    (p.is_dir()).then_some(p)
}

/// Per-target status. The orchestrator returns `None` for the no-tint /
/// missing-path no-op (the Python empty-dict case); `Some` when it ran.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Status {
    pub accent: String,
    pub rofi: String,
    pub gtk: String,
    pub borders: String,
    pub qt: String,
    pub icons: String,
    pub qt_selected: bool,
    pub icons_selected: bool,
}

// ── pure writers ────────────────────────────────────────────────────────────

/// Substitute the `accent:` and `selected-bg:` rasi vars in the base text.
#[must_use]
pub fn rofi_rasi_text(base: &str, accent: &str, accent_dark: &str) -> String {
    let accent_re = Regex::new(r"(accent:\s*)#[0-9a-fA-F]{6};").unwrap();
    let sel_re = Regex::new(r"(selected-bg:\s*)#[0-9a-fA-F]{6};").unwrap();
    let out = accent_re.replace_all(base, |c: &regex::Captures| format!("{}{accent};", &c[1]));
    let out = sel_re.replace_all(&out, |c: &regex::Captures| {
        format!("{}{accent_dark};", &c[1])
    });
    out.into_owned()
}

/// `@define-color` overrides loaded after the Tokyonight theme import.
#[must_use]
pub fn gtk_css(accent: &str, accent_dark: &str, _accent_light: &str, version: u8) -> String {
    if version == 4 {
        format!(
            "/* wallpaper-tui accent tint — overrides Tokyonight accent. */\n\
             @define-color theme_selected_bg_color {accent};\n\
             @define-color theme_selected_fg_color #ffffff;\n\
             @define-color accent_color {accent};\n\
             @define-color accent_bg_color {accent};\n\
             @define-color accent_fg_color #ffffff;\n"
        )
    } else {
        format!(
            "/* wallpaper-tui accent tint — overrides Tokyonight selection. */\n\
             @define-color theme_selected_bg_color {accent};\n\
             @define-color theme_selected_fg_color #ffffff;\n\
             @define-color theme_selected_borders_color {accent_dark};\n\
             @define-color theme_unfocused_selected_bg_color {accent_dark};\n"
        )
    }
}

/// `hyprctl eval` argv setting both border colors through one
/// `hl.config({...})` call with flat dotted string keys, the shape
/// Hyprland's own `hl.meta.lua` stub declares for `HL.ConfigOpt`. The
/// hyprlang `keyword` IPC was retired for the Lua parser in 0.55+ (exits 0,
/// changes nothing), same as the `hyprctl keyword monitor` case hyprmon
/// already migrated off. `rgba()` takes bare hex, so the accents' leading
/// `#` is stripped. Returns `None` when Hyprland is not running (`his` is
/// `None`). Pure: takes the Hyprland instance signature explicitly so
/// tests don't mutate process-global env.
#[must_use]
pub fn hyprland_border_commands_for(
    his: Option<&str>,
    accent: &str,
    accent_dark: &str,
) -> Option<Vec<Vec<String>>> {
    his?;
    let active = accent.trim_start_matches('#');
    let inactive = accent_dark.trim_start_matches('#');
    Some(vec![vec![
        "hyprctl".into(),
        "eval".into(),
        format!(
            "hl.config({{ [\"general.col.active_border\"] = \"rgba({active}ff)\", \
             [\"general.col.inactive_border\"] = \"rgba({inactive}ff)\" }})"
        ),
    ]])
}

/// Env-driven wrapper around [`hyprland_border_commands_for`].
#[must_use]
pub fn hyprland_border_commands(accent: &str, accent_dark: &str) -> Option<Vec<Vec<String>>> {
    hyprland_border_commands_for(
        std::env::var("HYPRLAND_INSTANCE_SIGNATURE").ok().as_deref(),
        accent,
        accent_dark,
    )
}

/// Replace the Catppuccin-Frappe accent family; preserve trailing alpha.
#[must_use]
pub fn recolor_kvantum_text(
    text: &str,
    accent: &str,
    accent_dark: &str,
    accent_light: &str,
) -> String {
    let mut out = text.to_string();
    for (orig, repl) in [
        (KVANTUM_ACCENT_HEXES[0], accent),
        (KVANTUM_ACCENT_HEXES[1], accent_dark),
        (KVANTUM_ACCENT_HEXES[2], accent_light),
    ] {
        let re = Regex::new(&format!("(?i){}", regex::escape(orig))).unwrap();
        out = re.replace_all(&out, repl).into_owned();
    }
    out
}

/// Recolor the Adwaita-blue family to the accent hue/sat, keeping lightness.
#[must_use]
pub fn recolor_icon_text(text: &str, accent: &str) -> String {
    let (ah, _, asat) = hex_to_hls(accent);
    let pattern = ADWAITA_BLUE_HEXES
        .iter()
        .map(|h| regex::escape(h))
        .collect::<Vec<_>>()
        .join("|");
    let re = Regex::new(&format!("(?i){pattern}")).unwrap();
    re.replace_all(text, |c: &regex::Captures| {
        let (_, ol, _) = hex_to_hls(&c[0]);
        hls_to_hex(ah, ol, asat)
    })
    .into_owned()
}

// ── tree tinters ────────────────────────────────────────────────────────────

/// `copytree` whose output is owner-writable. The Kvantum/icon bases live in
/// the read-only Nix store; a plain copy carries their 0555/0444 mode bits.
/// Copying content only and chmod-ing the tree to 0755/0644 yields a writable
/// copy we can edit in place.
fn writable_copytree(src: &Path, dst: &Path) -> std::io::Result<()> {
    for entry in walkdir::WalkDir::new(src)
        .into_iter()
        .filter_map(std::result::Result::ok)
    {
        let rel = entry.path().strip_prefix(src).unwrap();
        let target = dst.join(rel);
        if entry.file_type().is_dir() {
            fs::create_dir_all(&target)?;
            fs::set_permissions(&target, fs::Permissions::from_mode(0o755))?;
        } else if entry.file_type().is_file() {
            if let Some(parent) = target.parent() {
                fs::create_dir_all(parent)?;
            }
            fs::write(&target, fs::read(entry.path())?)?;
            fs::set_permissions(&target, fs::Permissions::from_mode(0o644))?;
        }
    }
    Ok(())
}

/// Rename `<base>.kvconfig`/`<base>.svg` → `<new>.*` and rewrite the base-name
/// references inside.
fn rename_theme_files(dest: &Path, base_name: &str, new_name: &str) -> std::io::Result<()> {
    for ext in [".kvconfig", ".svg"] {
        let src = dest.join(format!("{base_name}{ext}"));
        if src.exists() {
            let txt = fs::read_to_string(&src)?.replace(base_name, new_name);
            let new_path = dest.join(format!("{new_name}{ext}"));
            fs::write(&new_path, txt)?;
            let _ = fs::remove_file(&src);
        }
    }
    Ok(())
}

/// Copy the base Kvantum theme to `dest` and recolor its accent family.
pub fn tint_kvantum_tree(
    base: &Path,
    dest: &Path,
    accent: &str,
    accent_dark: &str,
    accent_light: &str,
) -> std::io::Result<()> {
    if dest.exists() {
        let _ = fs::remove_dir_all(dest);
    }
    writable_copytree(base, dest)?;
    let base_name = base.file_name().and_then(|n| n.to_str()).unwrap_or("base");
    rename_theme_files(dest, base_name, "WallpaperTint")?;
    for entry in fs::read_dir(dest)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_file()
            && matches!(
                path.extension().and_then(|e| e.to_str()),
                Some("kvconfig" | "svg")
            )
        {
            let txt = fs::read_to_string(&path)?;
            fs::write(
                &path,
                recolor_kvantum_text(&txt, accent, accent_dark, accent_light),
            )?;
        }
    }
    Ok(())
}

/// Copy the icon theme to `dest`, recolor the Adwaita-blue family, rename.
pub fn tint_icon_tree(base: &Path, dest: &Path, accent: &str) -> std::io::Result<()> {
    if dest.exists() {
        let _ = fs::remove_dir_all(dest);
    }
    writable_copytree(base, dest)?;
    for entry in walkdir::WalkDir::new(dest)
        .into_iter()
        .filter_map(std::result::Result::ok)
    {
        if entry.file_type().is_file()
            && entry.path().extension().and_then(|e| e.to_str()) == Some("svg")
        {
            let p = entry.path();
            let txt = fs::read_to_string(p)?;
            fs::write(p, recolor_icon_text(&txt, accent))?;
        }
    }
    let idx = dest.join("index.theme");
    if idx.exists() {
        let txt = fs::read_to_string(&idx)?;
        let re = Regex::new(r"(?m)^Name=.*$").unwrap();
        let txt = re.replace_all(&txt, format!("Name={ICON_THEME_NAME}"));
        fs::write(&idx, txt.as_bytes())?;
    }
    Ok(())
}

fn write_text(path: &Path, text: &str) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, text)
}

/// Point `kvantum.kvconfig` at `WallpaperTint` (no-op if dest missing).
fn select_kvantum(ctx: &TintCtx) -> bool {
    if !ctx.kvantum_dest.exists() {
        return false;
    }
    let _ = fs::create_dir_all(ctx.kvantum_select.parent().unwrap_or(Path::new("")));
    write_text(&ctx.kvantum_select, "[General]\ntheme=WallpaperTint\n").is_ok()
}

/// gsettings-switch to MoreWaita-Tint (no-op if dest missing or no gsettings).
fn select_icon_theme(ctx: &TintCtx) -> bool {
    if !ctx.icon_dest.exists() {
        return false;
    }
    Command::new("gsettings")
        .args([
            "set",
            "org.gnome.desktop.interface",
            "icon-theme",
            ICON_THEME_NAME,
        ])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok()
}

/// Spawn each border command with the instance signature pinned into the
/// child's environment (so tests can target a nonexistent instance without
/// touching the live session). The first failure short-circuits into an
/// `error:` status; success is `"ok"`.
fn run_border_commands(his: &str, cmds: &[Vec<String>]) -> String {
    for c in cmds {
        let run = Command::new(&c[0])
            .args(&c[1..])
            .env("HYPRLAND_INSTANCE_SIGNATURE", his)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
        match run {
            Ok(st) if st.success() => {}
            Ok(st) => return format!("error: {} exited {}", c[0], st.code().unwrap_or(-1)),
            Err(e) => return format!("error: spawn {}: {e}", c[0]),
        }
    }
    "ok".into()
}

/// The orchestrator. Returns `None` for the no-tint / missing-path no-op
/// (Python's empty dict); `Some(Status)` when it ran. Each target is isolated.
#[must_use]
pub fn apply_tint_ctx(
    ctx: &TintCtx,
    path: &str,
    no_tint: bool,
    backend: TintBackend,
) -> Option<Status> {
    if no_tint || path.is_empty() || !Path::new(path).exists() {
        return None;
    }
    let (accent, accent_dark, accent_light) = crate::accent::extract_accent(path, backend);
    let mut s = Status {
        accent: accent.clone(),
        ..Status::default()
    };
    let _ = fs::create_dir_all(&ctx.tint_dir);
    let same_accent = TintState::load_from(ctx.tint_state_file())
        .accent
        .as_deref()
        == Some(accent.as_str());

    // Rofi — cheap text file, always regenerate.
    if ctx.rofi_base.exists() {
        match fs::read_to_string(&ctx.rofi_base) {
            Ok(base) => match write_text(
                &ctx.tint_dir.join("rofi.rasi"),
                &rofi_rasi_text(&base, &accent, &accent_dark),
            ) {
                Ok(()) => s.rofi = "ok".into(),
                Err(e) => s.rofi = format!("error: {e}"),
            },
            Err(e) => s.rofi = format!("error: {e}"),
        }
    } else {
        s.rofi = "skipped".into();
    }

    // GTK 3/4 — cheap CSS files, always regenerate.
    match (
        write_text(
            &ctx.tint_dir.join("gtk3.css"),
            &gtk_css(&accent, &accent_dark, &accent_light, 3),
        ),
        write_text(
            &ctx.tint_dir.join("gtk4.css"),
            &gtk_css(&accent, &accent_dark, &accent_light, 4),
        ),
    ) {
        (Ok(()), Ok(())) => s.gtk = "ok".into(),
        (Err(e), _) | (_, Err(e)) => s.gtk = format!("error: {e}"),
    }

    // Hyprland borders — spawned per apply; the first failure surfaces.
    s.borders = match ctx.his.as_deref() {
        None => "skipped".into(),
        Some(his) => match hyprland_border_commands_for(Some(his), &accent, &accent_dark) {
            None => "skipped".into(),
            Some(cmds) => run_border_commands(his, &cmds),
        },
    };

    // Kvantum (Qt) — expensive SVG copy, only regen on accent change.
    if let Some(base) = &ctx.kvantum_base {
        if !same_accent || !ctx.kvantum_dest.exists() {
            s.qt = match tint_kvantum_tree(
                base,
                &ctx.kvantum_dest,
                &accent,
                &accent_dark,
                &accent_light,
            ) {
                Ok(()) => "ok".into(),
                Err(e) => format!("error: {e}"),
            };
        } else {
            s.qt = "cached".into();
        }
        s.qt_selected = select_kvantum(ctx);
    } else {
        s.qt = "skipped".into();
    }

    // Icons — expensive SVG tree, only regen on accent change.
    if let Some(base) = &ctx.icon_base {
        if !same_accent || !ctx.icon_dest.exists() {
            s.icons = match tint_icon_tree(base, &ctx.icon_dest, &accent) {
                Ok(()) => "ok".into(),
                Err(e) => format!("error: {e}"),
            };
        } else {
            s.icons = "cached".into();
        }
        s.icons_selected = ctx.try_icon_select && select_icon_theme(ctx);
    } else {
        s.icons = "skipped".into();
    }

    let _ = TintState {
        accent: Some(accent.clone()),
        source_path: Some(path.to_string()),
    }
    .save_to(ctx.tint_state_file());
    Some(s)
}

/// Env-driven entry: build a [`TintCtx`] from the XDG env and orchestrate.
/// The backend may be overridden at runtime by `WALLPAPER_TUI_TINT_BACKEND`.
#[must_use]
pub fn apply_tint(path: &str, no_tint: bool, backend: TintBackend) -> Option<Status> {
    let backend = std::env::var("WALLPAPER_TUI_TINT_BACKEND")
        .ok()
        .and_then(|s| TintBackend::from_str(&s).ok())
        .unwrap_or(backend);
    let ctx = TintCtx::from_env();
    let s = apply_tint_ctx(&ctx, path, no_tint, backend);
    if let Some(s) = &s {
        eprintln!(
            "wallpaper-tui: tint {} — rofi={} gtk={} borders={} qt={} icons={}",
            s.accent, s.rofi, s.gtk, s.borders, s.qt, s.icons
        );
    }
    s
}

/// Map for serde-pretty-printing in tests/log (unused by the app itself).
#[allow(dead_code)]
#[must_use]
pub fn status_map(s: &Status) -> BTreeMap<&'static str, String> {
    let mut m = BTreeMap::new();
    m.insert("accent", s.accent.clone());
    m.insert("rofi", s.rofi.clone());
    m.insert("gtk", s.gtk.clone());
    m.insert("borders", s.borders.clone());
    m.insert("qt", s.qt.clone());
    m.insert("icons", s.icons.clone());
    m
}
