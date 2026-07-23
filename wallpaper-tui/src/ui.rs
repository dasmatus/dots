//! ratatui view. Pure draw over [`App`] state — no I/O. The one mutation is
//! `StatefulImage`'s own encode state advanced by `render_stateful_widget`
//! (the widget's intended design, not our state machine), which is why
//! [`draw`] takes `&mut App`; the list/info/help helpers stay `&App`.

use ratatui::layout::{Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::Line;
use ratatui::widgets::{Block, Borders, List, ListItem, ListState, Paragraph, Wrap};
use ratatui::Frame;
use ratatui_image::StatefulImage;

use crate::app::App;

const HELP: &str = "Enter:apply  j/k:move  m:mode  c:color  o:output  p:preview  r:restore  q:quit";

/// Top-level layout: a horizontal split (list | preview) above an info bar
/// above a one-line help footer.
pub fn draw(f: &mut Frame, app: &mut App) {
    let area = f.area();
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([
            Constraint::Min(5),
            Constraint::Length(1),
            Constraint::Length(1),
        ])
        .split(area);
    let body = chunks[0];
    let info = chunks[1];
    let help = chunks[2];

    if app.wallpapers.is_empty() {
        let msg = format!(
            "No wallpapers found in: {}",
            if app.config.wallpaper_folder.is_empty() {
                "?"
            } else {
                &app.config.wallpaper_folder
            }
        );
        f.render_widget(Paragraph::new(msg).wrap(Wrap { trim: true }), body);
        draw_info(f, app, info);
        draw_help(f, help);
        return;
    }

    let split = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Min(10), Constraint::Length(50)])
        .split(body);
    draw_list(f, app, split[0]);
    if app.show_preview {
        draw_preview(f, app, split[1]);
    } else {
        f.render_widget(Block::default().borders(Borders::LEFT), split[1]);
    }
    draw_info(f, app, info);
    draw_help(f, help);
}

fn draw_list(f: &mut Frame, app: &App, area: Rect) {
    let items: Vec<ListItem> = app
        .wallpapers
        .iter()
        .map(|p| {
            let name = p
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| p.to_string_lossy().into_owned());
            ListItem::new(Line::from(name))
        })
        .collect();
    let mut state = ListState::default();
    state.select(Some(app.selected));
    let list = List::new(items)
        .block(Block::default().borders(Borders::ALL).title("wallpapers"))
        .highlight_style(
            Style::default()
                .fg(Color::Black)
                .bg(Color::LightBlue)
                .add_modifier(Modifier::BOLD),
        )
        .highlight_symbol("> ");
    f.render_stateful_widget(list, area, &mut state);
}

fn draw_preview(f: &mut Frame, app: &mut App, area: Rect) {
    let block = Block::default().borders(Borders::ALL).title("preview");
    let inner = block.inner(area);
    f.render_widget(block, area);

    match app.preview.as_mut() {
        Some(proto) => f.render_stateful_widget(StatefulImage::default(), inner, proto),
        None => {
            let label = match app.preview_pending.as_deref() {
                Some(_) => "rendering…",
                None => "[preview unavailable]",
            };
            f.render_widget(Paragraph::new(Line::from(label)), inner);
        }
    }
}

fn draw_info(f: &mut Frame, app: &App, area: Rect) {
    let para = Paragraph::new(app.info_text()).style(
        Style::default()
            .bg(Color::DarkGray)
            .fg(Color::White)
            .add_modifier(Modifier::BOLD),
    );
    f.render_widget(para, area);
}

fn draw_help(f: &mut Frame, area: Rect) {
    let para = Paragraph::new(HELP).style(Style::default().fg(Color::DarkGray));
    f.render_widget(para, area);
}
