//! Basic ANSI SGR (colour, bold) parsing for the log pane, and stripping of
//! everything else.

use beamenu_canvas::ansi::{parse, to_html, AnsiColor, Span};

#[test]
fn plain_text_is_one_span_with_no_style() {
    let spans = parse("hello world");
    assert_eq!(
        spans,
        vec![Span {
            text: "hello world".to_string(),
            fg: None,
            bold: false,
        }]
    );
}

#[test]
fn recognises_standard_foreground_colour() {
    let spans = parse("\u{1b}[31mred text\u{1b}[0m");
    assert_eq!(
        spans,
        vec![Span {
            text: "red text".to_string(),
            fg: Some(AnsiColor::Red),
            bold: false,
        }]
    );
}

#[test]
fn recognises_bright_foreground_colour() {
    let spans = parse("\u{1b}[92mgreen\u{1b}[0m");
    assert_eq!(spans[0].fg, Some(AnsiColor::BrightGreen));
}

#[test]
fn recognises_bold() {
    let spans = parse("\u{1b}[1mbold text\u{1b}[22m");
    assert!(spans[0].bold);
    assert_eq!(spans[0].text, "bold text");
}

#[test]
fn combines_bold_and_colour_from_one_sgr_sequence() {
    let spans = parse("\u{1b}[1;34mbold blue\u{1b}[0m");
    assert_eq!(spans[0].fg, Some(AnsiColor::Blue));
    assert!(spans[0].bold);
}

#[test]
fn reset_clears_state_for_following_text() {
    let spans = parse("\u{1b}[31mred\u{1b}[0mplain");
    assert_eq!(spans.len(), 2);
    assert_eq!(spans[0].fg, Some(AnsiColor::Red));
    assert_eq!(spans[1].fg, None);
    assert_eq!(spans[1].text, "plain");
}

#[test]
fn truecolor_sequence_leaves_colour_and_bold_state_untouched() {
    // 38;2;0;255;0 is truecolor green — out of "basic colour" scope, so it
    // must be consumed as a unit rather than corrupt state by having its
    // "0" and "255" component values fall through to the reset/other arms.
    let spans = parse("\u{1b}[1;38;2;0;255;0mstill bold\u{1b}[0m");
    assert_eq!(spans[0].fg, None);
    assert!(spans[0].bold);
    assert_eq!(spans[0].text, "still bold");
}

#[test]
fn reset_after_truecolor_sequence_still_resets() {
    let spans = parse("\u{1b}[38;2;0;255;0mtruecolor\u{1b}[0mplain");
    assert_eq!(spans.len(), 2);
    assert_eq!(spans[1].fg, None);
    assert!(!spans[1].bold);
    assert_eq!(spans[1].text, "plain");
}

#[test]
fn extended_256_colour_index_is_ignored_without_corrupting_following_codes() {
    // 38;5;196 is 256-colour red; its palette index component (196, and
    // critically a case like `38;5;0`) must not be misread as SGR 0
    // (reset) or leak into whatever code comes after it in the sequence.
    let spans = parse("\u{1b}[38;5;196;1mbold, not red\u{1b}[0m");
    assert_eq!(spans[0].fg, None);
    assert!(spans[0].bold);
}

#[test]
fn extended_256_colour_zero_index_does_not_reset() {
    let spans = parse("\u{1b}[1;38;5;0mstill bold\u{1b}[0m");
    assert!(spans[0].bold);
}

#[test]
fn strips_cursor_movement_sequences() {
    // ESC[2K (erase line) and ESC[10;5H (cursor position) are not `m`
    // sequences and must be dropped along with their parameters, leaving
    // only the literal text.
    let spans = parse("before\u{1b}[2K\u{1b}[10;5Hafter");
    let text: String = spans.iter().map(|s| s.text.clone()).collect();
    assert_eq!(text, "beforeafter");
}

#[test]
fn strips_osc_title_sequences() {
    let spans = parse("a\u{1b}]0;window title\u{7}b");
    let text: String = spans.iter().map(|s| s.text.clone()).collect();
    assert_eq!(text, "ab");
}

#[test]
fn strips_osc_sequence_terminated_by_st() {
    let spans = parse("a\u{1b}]0;title\u{1b}\\b");
    let text: String = spans.iter().map(|s| s.text.clone()).collect();
    assert_eq!(text, "ab");
}

#[test]
fn to_html_escapes_text_and_wraps_in_class() {
    let spans = vec![Span {
        text: "<b>&".to_string(),
        fg: Some(AnsiColor::Red),
        bold: true,
    }];
    let html = to_html(&spans);
    assert_eq!(
        html,
        "<span class=\"ansi-fg-red ansi-bold\">&lt;b&gt;&amp;</span>"
    );
}

#[test]
fn to_html_plain_span_has_no_wrapper() {
    let spans = vec![Span {
        text: "plain".to_string(),
        fg: None,
        bold: false,
    }];
    assert_eq!(to_html(&spans), "plain");
}
