//! `hyprmon override` — an interactive editor for `overrides.json`, built on
//! `AbstractTUI`. Lists the connected monitors (left), shows an edit form for
//! the selected one (right), and writes the result back to
//! `~/.config/hyprmon/overrides.json`. A spinner ticks while the app is idle
//! and a slide+fade `Toast` confirms each save — the cheap animation that
//! makes the override editor feel alive without distracting from the form.
//!
//! The data-fetch (monitors + planned specs + loaded overrides) is done once
//! before the reactive tree is mounted, so the loop itself stays pure: the
//! only I/O inside the loop is writing the override file on `Save`/`Clear`.

use std::time::Duration;

use abstracttui::prelude::*;
use abstracttui::reactive::after;
use abstracttui::widgets::SpinnerKind;

use crate::matcher::match_monitors;
use crate::overrides::{match_override, overrides_file, OverrideEntry, Overrides};
use crate::plan::plan;
use crate::rules::{Rules, Vrr};
use crate::runner::{parse_monitors, HyprCtl};
use crate::spec::{Monitor, MonitorSpec};

/// The seven editable form fields, each a reactive string buffer bound to a
/// `TextInput`. Kept together so selection changes can reload them as a unit.
#[derive(Clone, Copy)]
struct FormFields {
    name: Signal<String>,
    description: Signal<String>,
    resolution: Signal<String>,
    position: Signal<String>,
    scale: Signal<String>,
    transform: Signal<String>,
    vrr: Signal<String>,
}

impl FormFields {
    fn new(cx: Scope) -> Self {
        Self {
            name: cx.signal(String::new()),
            description: cx.signal(String::new()),
            resolution: cx.signal(String::new()),
            position: cx.signal(String::new()),
            scale: cx.signal(String::new()),
            transform: cx.signal(String::new()),
            vrr: cx.signal(String::new()),
        }
    }

    /// Load values for `monitors[i]`: from the existing override entry if
    /// present, else from the planned spec, else empty. Unpinned fields show
    /// the value that would be applied so the form reads as "current state".
    fn load(self, monitors: &[Monitor], specs: &[MonitorSpec], ov: &Overrides, i: usize) {
        let Some(m) = monitors.get(i) else {
            return;
        };
        let spec = specs.iter().find(|s| s.name == m.name);
        let entry = match_override(m, ov);
        self.name.set(m.name.clone());
        self.description.set(m.description.clone());
        self.resolution.set(
            entry
                .and_then(|e| e.resolution.clone())
                .or_else(|| spec.map(|s| s.resolution.clone()))
                .unwrap_or_default(),
        );
        self.position.set(
            entry
                .and_then(|e| e.position.clone())
                .or_else(|| spec.map(|s| s.position.clone()))
                .unwrap_or_default(),
        );
        self.scale.set(
            entry
                .and_then(|e| e.scale.map(crate::plan::render_scale))
                .or_else(|| spec.map(|s| s.scale.clone()))
                .unwrap_or_default(),
        );
        self.transform.set(
            entry
                .and_then(|e| e.transform.map(|t| t.to_string()))
                .or_else(|| spec.and_then(|s| s.transform.map(|t| t.to_string())))
                .unwrap_or_default(),
        );
        self.vrr
            .set(entry.and_then(|e| e.vrr.map(vrr_name)).unwrap_or_default());
    }

    /// Build an override entry from the buffers. Empty text → `None` (fall
    /// through to the plan); unparseable scale/transform/vrr → `None` too,
    /// so a typo drops just that field rather than aborting the save.
    fn entry(self) -> OverrideEntry {
        OverrideEntry {
            name: nonempty(&self.name.get()),
            description: nonempty(&self.description.get()),
            resolution: nonempty(&self.resolution.get()),
            position: nonempty(&self.position.get()),
            scale: nonempty(&self.scale.get()).and_then(|s| s.parse::<f64>().ok()),
            transform: nonempty(&self.transform.get()).and_then(|s| s.parse::<u8>().ok()),
            vrr: nonempty(&self.vrr.get()).and_then(|s| parse_vrr(&s)),
        }
    }
}

/// Bundle of the reactive state the right-hand form reads and writes, passed
/// as one argument so [`form_panel`] stays under clippy's argument-count
/// limit. Every member is `Copy` except `monitors`, which the `Clear` button
/// clones into its click closure.
struct FormCtx {
    fields: FormFields,
    selected: Signal<usize>,
    ov: Signal<Overrides>,
    status: Signal<String>,
    frame: Signal<u64>,
    monitors: Vec<Monitor>,
}

/// Run the override editor against `ctl` and `rules`. Fetches monitors, plans
/// the detected specs, loads existing overrides, and mounts the editor. The
/// `ctl` indirection keeps the fetch testable; only `run`'s pre-loop I/O
/// touches it.
///
/// # Errors
///
/// Bails if stdin isn't a tty; otherwise forwards `hyprctl`/parse/`App::run`
/// failures as `anyhow::Error`.
pub fn run(ctl: &impl HyprCtl, rules: &Rules) -> anyhow::Result<()> {
    if !abstracttui::term::have_tty() {
        anyhow::bail!("hyprmon override: needs an interactive terminal");
    }
    let json = ctl.monitors_json().map_err(anyhow::Error::msg)?;
    let monitors = parse_monitors(&json).map_err(anyhow::Error::msg)?;
    let matched = match_monitors(&monitors, rules);
    let specs = plan(&matched);
    let overrides = Overrides::load();

    let mut app = App::new(Size::new(96, 32));
    let quitter = app.quitter();

    app.mount(move |cx| {
        let theme = use_theme(cx);
        let t = theme.get_untracked().tokens;

        let ov = cx.signal(overrides);
        let selected = cx.signal(0usize);
        let status = cx.signal(String::from(
            "tab focus · type to edit · ctrl+s save · ctrl+r clear · q quit",
        ));
        let frame = cx.signal(0u64);
        spin(frame);

        let fields = FormFields::new(cx);
        fields.load(&monitors, &specs, &ov.get_untracked(), 0);

        let items: Vec<String> = monitors
            .iter()
            .map(|m| {
                let res = specs
                    .iter()
                    .find(|s| s.name == m.name)
                    .map_or("?", |s| s.resolution.as_str());
                format!("{}  {}", m.name, res)
            })
            .collect();

        let mut root = Element::new()
            .style(LayoutStyle::column().padding(Edges::all(1)).gap(1))
            .shortcut(KeyChord::plain(Key::Char('q')), move |_| quitter.quit())
            .shortcut(KeyChord::new(Mods::CTRL, Key::Char('s')), move |_| {
                save(fields, ov, status);
            })
            .shortcut(KeyChord::new(Mods::CTRL, Key::Char('r')), {
                let monitors = monitors.clone();
                move |_| clear(fields, ov, status, selected, &monitors)
            });

        if monitors.is_empty() {
            root = root.child(
                Block::new()
                    .border(BorderKind::Rounded)
                    .title("hyprmon override")
                    .fill(t.surface)
                    .layout(LayoutStyle::column().grow(1.0))
                    .child(text("no monitors connected — nothing to override"))
                    .element(&t)
                    .build(),
            );
        } else {
            root = root.child(
                Element::new()
                    .style(LayoutStyle::row().gap(1).grow(1.0))
                    .child(
                        Block::new()
                            .border(BorderKind::Rounded)
                            .title("monitors")
                            .fill(t.surface)
                            .layout(LayoutStyle::column().grow(1.0))
                            .child(
                                List::new(items)
                                    .selection(selected)
                                    .on_select({
                                        let monitors = monitors.clone();
                                        let specs = specs.clone();
                                        move |i| {
                                            fields.load(&monitors, &specs, &ov.get_untracked(), i);
                                        }
                                    })
                                    .layout(LayoutStyle::default().grow(1.0))
                                    .element(cx, &t)
                                    .build(),
                            )
                            .element(&t)
                            .build(),
                    )
                    .child(form_panel(
                        cx,
                        &t,
                        &FormCtx {
                            fields,
                            selected,
                            ov,
                            status,
                            frame,
                            monitors: monitors.clone(),
                        },
                    ))
                    .build(),
            );
        }

        root.build()
    })?;
    app.run().map_err(anyhow::Error::msg)
}

/// Right pane: the edit form for the selected monitor — seven labeled
/// `TextInput`s, the live status line with an animated spinner, and the
/// Save/Clear buttons.
fn form_panel(cx: Scope, t: &TokenSet, ctx: &FormCtx) -> View {
    let t = *t;
    let fields = ctx.fields;
    let frame = ctx.frame;
    let status = ctx.status;
    let ov = ctx.ov;
    let selected = ctx.selected;
    let monitors = ctx.monitors.clone();
    Block::new()
        .border(BorderKind::Rounded)
        .title("edit override")
        .fill(t.surface)
        .layout(LayoutStyle::column().grow(1.0).gap(1))
        .child(field(
            cx,
            &t,
            "name",
            fields.name,
            "connector, e.g. HDMI-A-1",
        ))
        .child(field(
            cx,
            &t,
            "desc",
            fields.description,
            "model+serial (replug key)",
        ))
        .child(field(cx, &t, "res", fields.resolution, "WxH@R"))
        .child(field(cx, &t, "pos", fields.position, "XxY"))
        .child(field(cx, &t, "scale", fields.scale, "1, 1.5, 2"))
        .child(field(cx, &t, "transform", fields.transform, "0-7"))
        .child(field(cx, &t, "vrr", fields.vrr, "off|left|right|auto"))
        .child(dyn_view(
            LayoutStyle::default().h(1).shrink(0.0),
            move || {
                Element::new()
                    .style(LayoutStyle::row().gap(1).h(1))
                    .child(
                        Spinner::new()
                            .kind(SpinnerKind::Dots)
                            .frame(frame.get())
                            .element(&t)
                            .build(),
                    )
                    .child(text(status.get()))
                    .build()
            },
        ))
        .child(
            Element::new()
                .style(LayoutStyle::row().gap(2).h(1).shrink(0.0))
                .child(
                    Button::new("save")
                        .on_click(move || save(fields, ov, status))
                        .element(cx, &t)
                        .build(),
                )
                .child(
                    Button::new("clear")
                        .on_click(move || clear(fields, ov, status, selected, &monitors))
                        .element(cx, &t)
                        .build(),
                )
                .child(text("q · quit"))
                .build(),
        )
        .element(&t)
        .build()
}

/// One labeled text-input row: fixed-width label on the left, growing input
/// on the right.
fn field(cx: Scope, t: &TokenSet, label: &str, value: Signal<String>, placeholder: &str) -> View {
    Element::new()
        .style(LayoutStyle::row().gap(1).h(1).shrink(0.0))
        .child(text(format!("{label:<10}")))
        .child(
            TextInput::new()
                .value(value)
                .placeholder(placeholder)
                .layout(LayoutStyle::default().grow(1.0).h(1).shrink(0.0))
                .element(cx, t)
                .build(),
        )
        .build()
}

/// `Save`: build an entry from the form, upsert it into the overrides, and
/// write `overrides.json`.
fn save(fields: FormFields, ov: Signal<Overrides>, status: Signal<String>) {
    let entry = fields.entry();
    let name = entry.name.clone().unwrap_or_default();
    let mut next = ov.get_untracked();
    next.upsert(entry);
    match next.save_to(&overrides_file()) {
        Ok(()) => {
            ov.set(next);
            status.set(format!("saved · {name}"));
        }
        Err(e) => status.set(format!("error: {e}")),
    }
}

/// `Clear`: remove the selected monitor's name-pinned entry and re-save.
fn clear(
    fields: FormFields,
    ov: Signal<Overrides>,
    status: Signal<String>,
    selected: Signal<usize>,
    monitors: &[Monitor],
) {
    let i = selected.get_untracked();
    let Some(m) = monitors.get(i) else {
        return;
    };
    let mut next = ov.get_untracked();
    if next.remove_by_name(&m.name) {
        match next.save_to(&overrides_file()) {
            Ok(()) => {
                fields.load(monitors, &[], &next, i);
                ov.set(next);
                status.set(format!("cleared · {}", m.name));
            }
            Err(e) => status.set(format!("error: {e}")),
        }
    } else {
        status.set(format!("no name pin on {}", m.name));
    }
}

/// Self-rescheduling clock that advances the spinner frame ~12 fps. The dyn
/// view reading `frame` re-renders only itself each tick — the rest of the
/// form stays idle.
fn spin(frame: Signal<u64>) {
    after(Duration::from_millis(80), move || {
        frame.update(|f| *f = f.wrapping_add(1));
        spin(frame);
    });
}

fn nonempty(s: &str) -> Option<String> {
    let trimmed = s.trim();
    (!trimmed.is_empty()).then_some(trimmed.to_string())
}

fn vrr_name(v: Vrr) -> String {
    match v {
        Vrr::Off => "off",
        Vrr::Left => "left",
        Vrr::Right => "right",
        Vrr::Auto => "auto",
    }
    .to_string()
}

fn parse_vrr(s: &str) -> Option<Vrr> {
    match s.trim().to_ascii_lowercase().as_str() {
        "off" => Some(Vrr::Off),
        "left" => Some(Vrr::Left),
        "right" => Some(Vrr::Right),
        "auto" => Some(Vrr::Auto),
        _ => None,
    }
}
