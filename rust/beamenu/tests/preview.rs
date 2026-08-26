//! The preview pane's protocol and the decisions behind what it is sent.
//!
//! `preview::plan` is where a keystroke turns into a message, so these cover
//! what it stays silent about as much as what it says: a pane told something
//! on every frame would re-render the same row nine times a second.
//!
//! The wire format is pinned to literal JSON here and to the same literals in
//! `rust/beamenu-canvas/tests/preview.rs`. The two crates carry deliberate
//! duplicates of these types rather than a shared dependency, so this pair of
//! files is what stops them drifting apart.

use std::path::PathBuf;

use beamenu::item::{Action, Item, Preview};
use beamenu::preview::{apply, plan, Message, PaneState};
use beamenu::view::PanelMetrics;

/// A panel with a real column in it.
fn metrics() -> PanelMetrics {
    PanelMetrics {
        width: 960,
        height: 520,
        list_width: 600,
        content_y: 57,
    }
}

fn row(id: &str) -> Item {
    Item::new(id, "notes.txt", Action::None).preview(Preview::File {
        path: PathBuf::from("/home/matus/notes.txt"),
    })
}

#[test]
fn a_first_frame_sends_geometry_before_the_row() {
    let messages = plan(&PaneState::default(), metrics(), Some(&row("file:a")));

    assert_eq!(messages.len(), 2, "geometry and a row: {messages:?}");
    assert!(matches!(messages[0], Message::Metrics { .. }));
    assert!(matches!(messages[1], Message::Show { .. }));
}

#[test]
fn the_same_row_on_the_same_panel_sends_nothing() {
    let mut state = PaneState::default();
    let item = row("file:a");

    let opening = plan(&state, metrics(), Some(&item));
    apply(&mut state, &opening);

    assert!(
        plan(&state, metrics(), Some(&item)).is_empty(),
        "a frame that changed nothing must be silent"
    );
}

#[test]
fn moving_the_highlight_sends_only_the_new_row() {
    let mut state = PaneState::default();
    let opening = plan(&state, metrics(), Some(&row("file:a")));
    apply(&mut state, &opening);

    let messages = plan(&state, metrics(), Some(&row("file:b")));

    assert_eq!(messages.len(), 1, "geometry did not move: {messages:?}");
    assert!(matches!(&messages[0], Message::Show { id, .. } if id == "file:b"));
}

#[test]
fn a_panel_that_resizes_under_a_still_highlight_sends_geometry() {
    let mut state = PaneState::default();
    let item = row("file:a");
    let opening = plan(&state, metrics(), Some(&item));
    apply(&mut state, &opening);

    let taller = PanelMetrics {
        height: 300,
        ..metrics()
    };
    let messages = plan(&state, taller, Some(&item));

    assert_eq!(messages.len(), 1, "the row did not change: {messages:?}");
    assert!(matches!(messages[0], Message::Metrics { height: 300, .. }));
}

#[test]
fn a_row_with_no_preview_hides_the_pane() {
    let mut state = PaneState::default();
    let opening = plan(&state, metrics(), Some(&row("file:a")));
    apply(&mut state, &opening);

    let plain = Item::new("app:libreWolf", "LibreWolf", Action::None);
    let messages = plan(&state, metrics(), Some(&plain));

    assert_eq!(messages, vec![Message::Hide]);
}

#[test]
fn an_empty_list_hides_the_pane_once_and_then_stays_quiet() {
    let mut state = PaneState::default();
    let opening = plan(&state, metrics(), Some(&row("file:a")));
    apply(&mut state, &opening);

    let hide = plan(&state, metrics(), None);
    assert_eq!(hide, vec![Message::Hide]);
    apply(&mut state, &hide);

    assert!(
        plan(&state, metrics(), None).is_empty(),
        "a list that is still empty must not re-send Hide"
    );
}

#[test]
fn nothing_is_sent_before_the_first_paint() {
    // All zeroes is what `bm_menu_get_panel_metrics` answers before anything
    // has been drawn. A Show then would land on a surface with no geometry.
    let messages = plan(
        &PaneState::default(),
        PanelMetrics::default(),
        Some(&row("file:a")),
    );

    assert!(messages.is_empty(), "{messages:?}");
}

#[test]
fn a_panel_too_narrow_to_split_hides_a_pane_that_was_showing() {
    let mut state = PaneState::default();
    let opening = plan(&state, metrics(), Some(&row("file:a")));
    apply(&mut state, &opening);

    // What the renderer reports when `bm_preview_columns` refused the split:
    // a real panel whose list occupies all of it.
    let unsplit = PanelMetrics {
        width: 400,
        list_width: 400,
        ..metrics()
    };

    assert_eq!(
        plan(&state, unsplit, Some(&row("file:a"))),
        vec![Message::Hide]
    );
}

#[test]
fn applying_a_plan_leaves_a_state_that_plans_nothing() {
    let mut state = PaneState::default();
    let item = row("file:a");

    for _ in 0..3 {
        let messages = plan(&state, metrics(), Some(&item));
        apply(&mut state, &messages);
    }

    assert!(plan(&state, metrics(), Some(&item)).is_empty());
}

#[test]
fn the_metrics_message_serializes_to_the_agreed_json() {
    let json = serde_json::to_string(&Message::Metrics {
        width: 960,
        height: 520,
        list_width: 600,
        content_y: 57,
    })
    .expect("Message serializes");

    assert_eq!(
        json,
        r#"{"type":"metrics","width":960,"height":520,"list_width":600,"content_y":57}"#
    );
}

#[test]
fn the_show_message_serializes_to_the_agreed_json() {
    let json = serde_json::to_string(&Message::Show {
        id: "file:/tmp/a.png".into(),
        title: "a.png".into(),
        subtitle: Some("~/tmp/a.png".into()),
        preview: Preview::File {
            path: PathBuf::from("/tmp/a.png"),
        },
        metadata: vec![("Where".into(), "~/tmp".into())],
    })
    .expect("Message serializes");

    assert_eq!(
        json,
        r#"{"type":"show","id":"file:/tmp/a.png","title":"a.png","subtitle":"~/tmp/a.png","preview":{"kind":"file","path":"/tmp/a.png"},"metadata":[["Where","~/tmp"]]}"#
    );
}

#[test]
fn an_absent_subtitle_and_empty_metadata_stay_off_the_wire() {
    let json = serde_json::to_string(&Message::Show {
        id: "file:/tmp/a".into(),
        title: "a".into(),
        subtitle: None,
        preview: Preview::Markdown {
            body: "# hello".into(),
        },
        metadata: Vec::new(),
    })
    .expect("Message serializes");

    assert_eq!(
        json,
        r##"{"type":"show","id":"file:/tmp/a","title":"a","preview":{"kind":"markdown","body":"# hello"}}"##
    );
}

#[test]
fn hide_and_quit_serialize_to_the_agreed_json() {
    assert_eq!(
        serde_json::to_string(&Message::Hide).expect("Message serializes"),
        r#"{"type":"hide"}"#
    );
    assert_eq!(
        serde_json::to_string(&Message::Quit).expect("Message serializes"),
        r#"{"type":"quit"}"#
    );
}

#[test]
fn a_plugin_view_preview_serializes_to_the_agreed_json() {
    let json = serde_json::to_string(&Preview::Command {
        manifest: PathBuf::from("/home/matus/.config/beamenu/plugins/dots.json"),
        command: "c".into(),
        query: String::new(),
    })
    .expect("Preview serializes");

    assert_eq!(
        json,
        r#"{"kind":"command","manifest":"/home/matus/.config/beamenu/plugins/dots.json","command":"c","query":""}"#
    );
}

#[test]
fn panel_metrics_derive_the_column_from_the_split() {
    let metrics = metrics();

    assert_eq!(metrics.preview_width(), 360);
    assert_eq!(metrics.preview_height(), 463);
    assert!(metrics.usable());
}

#[test]
fn a_panel_with_no_column_is_not_usable() {
    let unsplit = PanelMetrics {
        width: 400,
        height: 520,
        list_width: 400,
        content_y: 57,
    };

    assert_eq!(unsplit.preview_width(), 0);
    assert!(!unsplit.usable());
}
