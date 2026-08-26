//! The preview pane's model: the protocol it reads and the markup it builds.
//!
//! The JSON literals here are the same ones `rust/beamenu/tests/preview.rs`
//! pins on the launcher side. The two crates carry deliberate duplicates of
//! these types rather than sharing a dependency, so this pair of files is
//! what stops them drifting: a field renamed on one side fails a test on both.

use std::path::PathBuf;

use beamenu_canvas::preview::{
    arrange_listing, base64, card_html, document_html, format_bytes, format_timestamp, image_html,
    image_mime, is_html, listing_html, looks_like_text, metadata_html, parse_line, text_html,
    text_prefix, web_app_entry, Entry, Geometry, Message, Preview, MAX_LISTING,
};

fn entry(name: &str, is_dir: bool) -> Entry {
    Entry {
        name: name.to_string(),
        is_dir,
    }
}

#[test]
fn the_metrics_line_parses_as_the_launcher_writes_it() {
    let message = parse_line(
        r#"{"type":"metrics","width":960,"height":520,"list_width":600,"content_y":57}"#,
    )
    .expect("the launcher's metrics line parses");

    assert_eq!(
        message,
        Message::Metrics {
            width: 960,
            height: 520,
            list_width: 600,
            content_y: 57,
        }
    );
}

#[test]
fn the_show_line_parses_as_the_launcher_writes_it() {
    let message = parse_line(
        r#"{"type":"show","id":"file:/tmp/a.png","title":"a.png","subtitle":"~/tmp/a.png","preview":{"kind":"file","path":"/tmp/a.png"},"metadata":[["Where","~/tmp"]]}"#,
    )
    .expect("the launcher's show line parses");

    assert_eq!(
        message,
        Message::Show {
            id: "file:/tmp/a.png".into(),
            title: "a.png".into(),
            subtitle: Some("~/tmp/a.png".into()),
            preview: Preview::File {
                path: PathBuf::from("/tmp/a.png"),
            },
            metadata: vec![("Where".into(), "~/tmp".into())],
        }
    );
}

/// The launcher leaves both off the wire when it has neither, so the pane has
/// to read a Show without them.
#[test]
fn a_show_line_without_a_subtitle_or_metadata_still_parses() {
    let message = parse_line(
        r##"{"type":"show","id":"file:/tmp/a","title":"a","preview":{"kind":"markdown","body":"# hello"}}"##,
    )
    .expect("a minimal show line parses");

    assert!(matches!(
        message,
        Message::Show {
            subtitle: None,
            metadata,
            ..
        } if metadata.is_empty()
    ));
}

#[test]
fn hide_and_quit_parse_as_the_launcher_writes_them() {
    assert_eq!(parse_line(r#"{"type":"hide"}"#), Some(Message::Hide));
    assert_eq!(parse_line(r#"{"type":"quit"}"#), Some(Message::Quit));
}

#[test]
fn a_plugin_view_line_parses_as_the_launcher_writes_it() {
    let message = parse_line(
        r#"{"type":"show","id":"plugin:dots:c","title":"C Toolchain","preview":{"kind":"command","manifest":"/home/matus/.config/beamenu/plugins/dots.json","command":"c","query":""}}"#,
    )
    .expect("a plugin view line parses");

    assert!(matches!(
        message,
        Message::Show {
            preview: Preview::Command { .. },
            ..
        }
    ));
}

/// A pane sitting beside a search line somebody is typing into must not fall
/// over because one message arrived mangled.
#[test]
fn a_line_that_makes_no_sense_is_dropped_rather_than_fatal() {
    for line in [
        "",
        "   ",
        "not json",
        r#"{"type":"nonsense"}"#,
        r#"{"type":"show"}"#,
        r#"{"type":"metrics","width":"wide"}"#,
    ] {
        assert_eq!(parse_line(line), None, "{line:?} must be dropped");
    }
}

#[test]
fn geometry_derives_the_column_from_the_split() {
    let geometry = Geometry {
        width: 960,
        height: 520,
        list_width: 600,
        content_y: 57,
    };

    assert_eq!(geometry.column_width(), 360);
    assert_eq!(geometry.column_height(), 463);
    assert!(geometry.usable());
}

#[test]
fn a_geometry_with_no_column_is_not_usable() {
    assert!(!Geometry::default().usable());
    assert!(!Geometry {
        width: 400,
        height: 520,
        list_width: 400,
        content_y: 57,
    }
    .usable());
}

#[test]
fn only_known_image_extensions_are_treated_as_images() {
    for (name, mime) in [
        ("a.png", "image/png"),
        ("a.PNG", "image/png"),
        ("a.jpg", "image/jpeg"),
        ("a.jpeg", "image/jpeg"),
        ("a.svg", "image/svg+xml"),
        ("a.webp", "image/webp"),
    ] {
        assert_eq!(image_mime(&PathBuf::from(name)), Some(mime), "{name}");
    }

    for name in ["a.txt", "a.rs", "a", "a.pngx", "a.jpg.gz"] {
        assert_eq!(image_mime(&PathBuf::from(name)), None, "{name}");
    }
}

#[test]
fn html_is_recognised_by_extension() {
    for name in ["page.html", "page.HTM", "page.xhtml"] {
        assert!(is_html(&PathBuf::from(name)), "{name}");
    }
    for name in ["page.htmlx", "page.md", "page"] {
        assert!(!is_html(&PathBuf::from(name)), "{name}");
    }
}

#[test]
fn a_directory_with_an_index_page_is_a_web_app() {
    let site = [entry("index.html", false), entry("assets", true)];
    assert_eq!(web_app_entry(&site), Some("index.html"));

    let folder = [entry("notes.md", false), entry("assets", true)];
    assert_eq!(web_app_entry(&folder), None);
}

/// A directory *named* index.html is a directory, not a page.
#[test]
fn a_directory_called_index_html_is_not_a_web_app() {
    let odd = [entry("index.html", true)];
    assert_eq!(web_app_entry(&odd), None);
}

/// The sandbox attributes are the whole reason a page can be rendered at all,
/// so they are worth asserting rather than assuming.
#[test]
fn a_rendered_document_is_sandboxed_and_carries_no_same_origin() {
    let html = document_html("<h1>hi</h1>");

    assert!(html.contains(r#"sandbox="allow-scripts""#), "{html}");
    assert!(
        !html.contains("allow-same-origin"),
        "same-origin would give the page the pane's own privileges: {html}"
    );
    assert!(!html.contains("allow-top-navigation"), "{html}");
    assert!(!html.contains("src=\"file:"), "{html}");
}

/// A page whose text is itself a broken-out attribute. Every quote in it has
/// to survive as `&quot;`, or the `srcdoc` value ends early and the rest
/// becomes attributes on the frame.
///
/// Counted rather than searched for, because `onload=` still appears in the
/// output and is meant to: it is escaped attribute *text*, not an attribute.
/// The three quoted attributes the frame carries account for six quote
/// characters, and any unescaped one in the payload would make seven.
#[test]
fn a_rendered_document_cannot_break_out_of_its_attribute() {
    let hostile = r#"" onload="alert(1)" x=""#;
    let html = document_html(hostile);

    assert_eq!(
        html.matches('"').count(),
        6,
        "only class, sandbox and srcdoc may be quoted: {html}"
    );
    assert!(html.contains("&quot;"), "the quotes are escaped: {html}");
}

#[test]
fn text_previews_escape_what_they_show() {
    let html = text_html("<script>alert(1)</script>", false);

    assert!(html.contains("&lt;script&gt;"), "{html}");
    assert!(!html.contains("<script>"), "{html}");
}

#[test]
fn a_truncated_text_preview_says_so() {
    assert!(!text_html("short", false).contains("Showing the first"));
    assert!(text_html("long", true).contains("Showing the first"));
}

#[test]
fn a_nul_byte_means_the_file_is_not_text() {
    assert!(!looks_like_text(b"hello\0world"));
    assert!(looks_like_text(b"hello world"));
    assert!(looks_like_text("hello \u{1f600} world".as_bytes()));
}

/// The read stops at a byte count, so the last character is routinely cut in
/// half. That is a truncated read, not a binary file.
#[test]
fn a_character_cut_in_half_by_the_read_cap_is_still_text() {
    let text = "aaa\u{1f600}";
    let cut = &text.as_bytes()[..text.len() - 2];

    assert!(looks_like_text(cut));
    assert_eq!(text_prefix(cut), "aaa");
}

#[test]
fn a_listing_puts_directories_first_and_then_sorts_by_name() {
    let (arranged, total) = arrange_listing(vec![
        entry("zebra.txt", false),
        entry("Alpha", true),
        entry("apple.txt", false),
        entry("beta", true),
    ]);

    assert_eq!(total, 4);
    let names: Vec<&str> = arranged.iter().map(|e| e.name.as_str()).collect();
    assert_eq!(names, ["Alpha", "beta", "apple.txt", "zebra.txt"]);
}

#[test]
fn a_long_listing_is_capped_and_says_how_much_it_left_out() {
    let entries: Vec<Entry> = (0..MAX_LISTING + 25)
        .map(|i| entry(&format!("file-{i:04}"), false))
        .collect();

    let (arranged, total) = arrange_listing(entries);
    assert_eq!(arranged.len(), MAX_LISTING);
    assert_eq!(total, MAX_LISTING + 25);

    let html = listing_html(&arranged, total);
    assert!(html.contains("25 more."), "{html}");
}

#[test]
fn a_complete_listing_says_nothing_about_more() {
    let (arranged, total) = arrange_listing(vec![entry("only.txt", false)]);
    let html = listing_html(&arranged, total);

    assert!(!html.contains("more."), "{html}");
    assert!(html.contains("only.txt"), "{html}");
}

#[test]
fn a_listing_escapes_the_names_it_shows() {
    let html = listing_html(&[entry("<script>.txt", false)], 1);

    assert!(html.contains("&lt;script&gt;"), "{html}");
    assert!(!html.contains("<script>"), "{html}");
}

#[test]
fn an_empty_metadata_strip_renders_nothing_at_all() {
    assert_eq!(metadata_html(&[]), "");
}

#[test]
fn the_metadata_strip_keeps_the_order_it_was_given() {
    let html = metadata_html(&[
        ("Kind".into(), "PNG file".into()),
        ("Size".into(), "1.2 MB".into()),
    ]);

    let kind = html.find("Kind").expect("Kind is present");
    let size = html.find("Size").expect("Size is present");
    assert!(kind < size, "{html}");
}

#[test]
fn metadata_escapes_both_halves_of_a_row() {
    let html = metadata_html(&[("<k>".into(), "<v>".into())]);

    assert!(!html.contains("<k>"), "{html}");
    assert!(!html.contains("<v>"), "{html}");
}

#[test]
fn a_card_escapes_its_note() {
    assert!(!card_html("<b>x</b>").contains("<b>"));
}

/// RFC 4648's own vectors, which is where the three padding cases live.
#[test]
fn base64_matches_the_rfc_vectors() {
    for (input, expected) in [
        ("", ""),
        ("f", "Zg=="),
        ("fo", "Zm8="),
        ("foo", "Zm9v"),
        ("foob", "Zm9vYg=="),
        ("fooba", "Zm9vYmE="),
        ("foobar", "Zm9vYmFy"),
    ] {
        assert_eq!(base64(input.as_bytes()), expected, "{input:?}");
    }
}

#[test]
fn base64_handles_every_byte_value() {
    let all: Vec<u8> = (0..=255u8).collect();
    let encoded = base64(&all);

    assert_eq!(encoded.len(), 344, "256 bytes is 344 base64 characters");
    assert!(encoded.ends_with('='), "256 is not a multiple of 3");
    assert!(encoded
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '+' || c == '/' || c == '='));
}

#[test]
fn an_image_is_inlined_as_a_data_uri() {
    let html = image_html("image/png", b"foo");

    assert!(
        html.contains("src=\"data:image/png;base64,Zm9v\""),
        "{html}"
    );
}

#[test]
fn sizes_read_the_way_a_file_manager_writes_them() {
    assert_eq!(format_bytes(0), "0 B");
    assert_eq!(format_bytes(999), "999 B");
    assert_eq!(format_bytes(1024), "1.0 KB");
    assert_eq!(format_bytes(1536), "1.5 KB");
    assert_eq!(format_bytes(1024 * 1024), "1.0 MB");
    assert_eq!(format_bytes(3 * 1024 * 1024 * 1024), "3.0 GB");
}

/// The clock on this desktop writes `26.08.2026 10:37:57`, and a preview two
/// centimetres away from it should not disagree about the format.
#[test]
fn timestamps_read_the_way_the_desktop_clock_writes_them() {
    // 2026-08-26 10:37:57.
    assert_eq!(format_timestamp(1_787_740_677), "26.08.2026 10:37:57");
}

#[test]
fn timestamps_survive_the_awkward_dates() {
    assert_eq!(format_timestamp(0), "01.01.1970 00:00:00");
    // A leap day, which is what the era arithmetic exists to get right.
    assert_eq!(format_timestamp(1_709_164_800), "29.02.2024 00:00:00");
    // The last second of a year.
    assert_eq!(format_timestamp(1_735_689_599), "31.12.2024 23:59:59");
}
