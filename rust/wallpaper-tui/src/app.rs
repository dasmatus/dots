//! TUI state machine. [`App::handle_key`] is a pure transition function —
//! all interaction logic lives here so it is unit-testable without a
//! terminal. I/O (apply/tint, preview decode) is expressed as *pending* ops
//! that [`main`] spawns on worker threads, keeping selection responsive.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use abstracttui::base::Rgba;
use abstracttui::gfx::Bitmap;

use crate::accent::TintBackend;
use crate::awww::Group;
use crate::config::{effective_output, Config, State, COLOR_PALETTE, DEFAULT_COLOR, MODES};
use crate::input::{KeyCode, KeyEvent};

/// A request the event loop drains off the TUI thread.
#[derive(Debug, Clone)]
pub enum PendingOp {
    /// Apply one group + run the accent tint.
    Apply {
        group: Group,
        no_tint: bool,
        backend: TintBackend,
    },
    /// Re-apply every declared output, tinting from the first. awww targets
    /// outputs individually, so every group is rendered rather than only the
    /// first; the tint still comes from one wallpaper because the accent
    /// palette is global.
    Restore {
        groups: Vec<Group>,
        no_tint: bool,
        backend: TintBackend,
    },
    /// Decode the preview thumbnail for a path into a `DynamicImage`.
    Preview { path: String },
}

/// Worker → TUI events.
#[derive(Debug, Clone)]
pub enum Event {
    /// Apply+tint finished (or failed); `msg` is shown in the info bar.
    ApplyDone { msg: String },
    /// Preview image ready for `path`; `None` means the decode failed.
    PreviewReady {
        path: String,
        image: Option<image::DynamicImage>,
    },
}

/// The pure picker state. `Clone` so it can live in a `Signal<App>` on the
/// abstracttui runtime; the `Arc<Bitmap>` preview clones cheaply (no pixel copy
/// per rebuild) and the `preview_cache` memoizes decoded `DynamicImage`s.
#[derive(Clone)]
pub struct App {
    pub config: Config,
    pub state: State,
    pub no_tint: bool,
    pub backend: TintBackend,
    pub wallpapers: Vec<PathBuf>,
    pub outputs: Vec<String>,
    pub current_output: usize,
    pub selected: usize,
    pub fill_mode: String,
    pub current_color: String,
    pub show_preview: bool,
    /// The on-screen preview as a mosaic bitmap. `None` until the first decode
    /// arrives (or after a failed decode). Rendered through abstracttui's
    /// `Image` widget on the unicode-mosaic backend — no native image protocol.
    pub preview: Option<Arc<Bitmap>>,
    /// Decoded preview thumbnails, memoized by path. A return to a previously
    /// seen wallpaper rebuilds the `Bitmap` on the UI thread — no worker
    /// round-trip.
    pub preview_cache: HashMap<String, image::DynamicImage>,
    /// The path the preview worker is currently decoding (avoids duplicate
    /// requests for the same selection).
    pub preview_pending: Option<String>,
    /// Set by `handle_key`; the event loop takes it and spawns the worker.
    pub pending: Option<PendingOp>,
    /// One-line status from the last apply (shown in the info bar).
    pub status: Option<String>,
    pub should_quit: bool,
}

impl App {
    #[must_use]
    pub fn new(config: Config, state: State, no_tint: bool, backend: TintBackend) -> Self {
        let wallpapers =
            crate::wallpapers::list_wallpapers(&config.wallpaper_folder, config.recursive);
        let mut outputs = crate::wallpapers::detect_outputs();
        for name in config.outputs.keys() {
            if !outputs.contains(name) {
                outputs.push(name.clone());
            }
        }
        if outputs.is_empty() {
            outputs.push("*".to_string());
        }
        let mut current_output = 0;
        let cur = &config.current_output;
        if !cur.is_empty() {
            if let Some(idx) = outputs.iter().position(|o| o == cur) {
                current_output = idx;
            }
        }
        let eff = effective_output(&config, &state, &outputs[current_output]);
        Self {
            config,
            state,
            no_tint,
            backend,
            wallpapers,
            outputs,
            current_output,
            selected: 0,
            fill_mode: eff.mode,
            current_color: eff.fill_color,
            show_preview: true,
            preview: None,
            preview_cache: HashMap::new(),
            preview_pending: None,
            pending: None,
            status: None,
            should_quit: false,
        }
    }

    #[must_use]
    pub fn output_name(&self) -> &str {
        &self.outputs[self.current_output]
    }

    /// The currently-highlighted wallpaper path, if any.
    #[must_use]
    pub fn selected_path(&self) -> Option<String> {
        self.wallpapers
            .get(self.selected)
            .map(|p| p.to_string_lossy().into_owned())
    }

    /// One-line info bar text.
    #[must_use]
    pub fn info_text(&self) -> String {
        let eff = effective_output(&self.config, &self.state, self.output_name());
        let name = if eff.path.is_empty() {
            "(none)".to_string()
        } else {
            PathBuf::from(&eff.path)
                .file_name()
                .map_or_else(|| eff.path.clone(), |n| n.to_string_lossy().into_owned())
        };
        let mut s = format!(
            " Output: {} | Mode: {} | Color: {} | Current: {} ",
            self.output_name(),
            self.fill_mode,
            self.current_color,
            name,
        );
        if let Some(st) = &self.status {
            let _ = std::fmt::Write::write_fmt(&mut s, format_args!("| {st} "));
        }
        s
    }

    /// Request a preview render for the current selection. A cache hit rebuilds
    /// the `Bitmap` on the UI thread immediately (no worker round-trip); a miss
    /// asks the worker to decode the thumbnail.
    pub fn request_preview(&mut self) {
        if !self.show_preview {
            return;
        }
        if let Some(path) = self.selected_path() {
            if let Some(img) = self.preview_cache.get(&path).cloned() {
                self.preview = Some(dynimg_to_bitmap(&img));
                return;
            }
            if self.preview_pending.as_deref() == Some(&path) {
                return;
            }
            self.preview_pending = Some(path.clone());
            self.pending = Some(PendingOp::Preview { path });
        }
    }

    pub fn handle_key(&mut self, key: KeyEvent) {
        match key.code {
            KeyCode::Char('q') | KeyCode::Esc => self.should_quit = true,
            KeyCode::Char('j') | KeyCode::Down => self.cursor_down(),
            KeyCode::Char('k') | KeyCode::Up => self.cursor_up(),
            KeyCode::Enter => self.apply(),
            KeyCode::Char('m') => self.cycle_mode(),
            KeyCode::Char('c') => self.set_color(),
            KeyCode::Char('o') => self.cycle_output(),
            KeyCode::Char('p') => self.toggle_preview(),
            KeyCode::Char('r') => self.restore(),
            _ => {}
        }
    }

    fn cursor_up(&mut self) {
        if self.wallpapers.is_empty() {
            return;
        }
        if self.selected == 0 {
            self.selected = self.wallpapers.len() - 1;
        } else {
            self.selected -= 1;
        }
        self.request_preview();
    }

    fn cursor_down(&mut self) {
        if self.wallpapers.is_empty() {
            return;
        }
        if self.selected + 1 >= self.wallpapers.len() {
            self.selected = 0;
        } else {
            self.selected += 1;
        }
        self.request_preview();
    }

    fn cycle_mode(&mut self) {
        let idx = MODES.iter().position(|m| *m == self.fill_mode).unwrap_or(0);
        let next = (idx + 1) % MODES.len();
        self.fill_mode = MODES[next].to_string();
    }

    fn set_color(&mut self) {
        let idx = COLOR_PALETTE
            .iter()
            .position(|c| *c == self.current_color)
            .unwrap_or(0);
        let next = (idx + 1) % COLOR_PALETTE.len();
        self.current_color = COLOR_PALETTE[next].to_string();
    }

    fn cycle_output(&mut self) {
        self.current_output = (self.current_output + 1) % self.outputs.len();
        let eff = effective_output(&self.config, &self.state, self.output_name());
        self.fill_mode = eff.mode;
        self.current_color = eff.fill_color;
    }

    fn toggle_preview(&mut self) {
        self.show_preview = !self.show_preview;
    }

    fn apply(&mut self) {
        let Some(path) = self.selected_path() else {
            return;
        };
        let output = self.output_name().to_string();
        self.state.outputs.entry(output.clone()).or_default().path = Some(path.clone());
        self.state.outputs.get_mut(&output).unwrap().mode = Some(self.fill_mode.clone());
        self.state.outputs.get_mut(&output).unwrap().fill_color = Some(self.current_color.clone());
        if let Err(e) = self.state.save() {
            self.status = Some(format!("state save failed: {e}"));
        }
        let group = Group {
            output,
            path: path.clone(),
            mode: self.fill_mode.clone(),
            fill_color: self.current_color.clone(),
        };
        self.pending = Some(PendingOp::Apply {
            group,
            no_tint: self.no_tint,
            backend: self.backend,
        });
    }

    fn restore(&mut self) {
        let groups = crate::awww::restore_groups(&self.config, &self.state);
        if groups.is_empty() {
            self.status = Some("nothing to restore".to_string());
            return;
        }
        self.pending = Some(PendingOp::Restore {
            groups,
            no_tint: self.no_tint,
            backend: self.backend,
        });
    }

    /// Drain a worker event into state. Called from the event loop each frame.
    pub fn on_event(&mut self, ev: Event) {
        match ev {
            Event::ApplyDone { msg } => self.status = Some(msg),
            Event::PreviewReady { path, image } => {
                self.preview_pending = self.preview_pending.take().filter(|p| p != &path);
                match image {
                    Some(img) => {
                        self.preview = Some(dynimg_to_bitmap(&img));
                        self.preview_cache.insert(path, img);
                    }
                    None => self.preview = None,
                }
            }
        }
    }
}

/// Convert a decoded `image::DynamicImage` into a shared mosaic `Bitmap`: take
/// the RGBA buffer, map each `image::Rgba<u8>` to `abstracttui::base::Rgba`,
/// and wrap in `Arc` so the `Image` widget clones the handle (not the pixels)
/// per rebuild. The recipe is documented in
/// `docs/superpowers/refs/abstracttui-api.md` §7/§12.
fn dynimg_to_bitmap(img: &image::DynamicImage) -> Arc<Bitmap> {
    let rgba = img.to_rgba8();
    let px: Vec<Rgba> = rgba
        .pixels()
        .map(|p| Rgba::new(p.0[0], p.0[1], p.0[2], p.0[3]))
        .collect();
    let bmp = Bitmap::from_pixels(rgba.width(), rgba.height(), px)
        .expect("to_rgba8 yields exactly width*height pixels");
    Arc::new(bmp)
}

/// Default fill color (re-exported for the CLI's `--color` default).
#[must_use]
pub fn default_color() -> &'static str {
    DEFAULT_COLOR
}
