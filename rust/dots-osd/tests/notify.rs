//! Escaping the text that reaches a markup-parsing notification daemon.
//!
//! `nix/home/dunst.nix` sets `markup = "full"`, so a summary and body are Pango
//! markup by the time they are drawn. Several bodies interpolate text this
//! machine does not choose: an SSID belongs to whoever runs the access point,
//! and a process name comes from `/proc/<pid>/comm`, which any local process
//! sets for itself.

use dots_osd::notify::escape_markup;

#[test]
fn ordinary_text_is_left_alone() {
    assert_eq!(escape_markup("Connected to home"), "Connected to home");
    assert_eq!(
        escape_markup("94% full, 2.1 GiB left"),
        "94% full, 2.1 GiB left"
    );
    // The em dash the notification bodies use is not markup and must survive.
    assert_eq!(escape_markup("Charging — 50%"), "Charging — 50%");
}

#[test]
fn an_access_point_cannot_style_itself_into_your_notifications() {
    // Verified against the running dunst: an unescaped `<b>` reaches the
    // renderer verbatim, so without this an SSID could render as bold text
    // inside a notification the user reads as the system talking.
    assert_eq!(
        escape_markup("Connected to <b>Bank</b>"),
        "Connected to &lt;b&gt;Bank&lt;/b&gt;"
    );
}

#[test]
fn an_unclosed_tag_cannot_break_the_parser() {
    // Pango rejects malformed markup outright. An SSID of `<b>Free WiFi` would
    // otherwise hand it something it cannot parse.
    assert_eq!(escape_markup("<b>Free WiFi"), "&lt;b&gt;Free WiFi");
}

#[test]
fn ampersands_survive_as_themselves() {
    // `&` first, or the entities introduced for `<` and `>` would be mangled
    // by the ampersand pass that followed them.
    assert_eq!(escape_markup("Bar & Grill"), "Bar &amp; Grill");
    assert_eq!(
        escape_markup("a <b> & </b> b"),
        "a &lt;b&gt; &amp; &lt;/b&gt; b"
    );
}

#[test]
fn quotes_are_escaped_too() {
    assert_eq!(escape_markup("Joe's Cafe"), "Joe&apos;s Cafe");
    assert_eq!(escape_markup("say \"hi\""), "say &quot;hi&quot;");
}

#[test]
fn escaping_is_not_applied_twice() {
    // The output of one pass is text a second pass would mangle, which is why
    // `Bus::send` escapes once at the boundary and no caller escapes earlier.
    let once = escape_markup("Bar & Grill");
    assert_ne!(
        escape_markup(&once),
        once,
        "double-escaping must be visible"
    );
    assert_eq!(escape_markup(&once), "Bar &amp;amp; Grill");
}
