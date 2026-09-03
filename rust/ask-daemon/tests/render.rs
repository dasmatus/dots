//! Pins what `render.rs` produces, and above all what it refuses to.
//!
//! The interesting half of this file is the allowlist. The QML pane feeds
//! `code_block.html` and `diff.html` straight into Qt's `Text.RichText` and
//! has no way to police them. Qt runs no script there, but `QQuickText` does
//! resolve `<img src="...">` through `QQuickPixmap`, which handles `http(s):`
//! and `file:`, and there is no property that turns image loading off. So
//! model output reaching the renderer unescaped would let a remote host learn
//! that the pane rendered, or pull a local file into it, and the QML side
//! cannot mitigate that even in principle.
//!
//! `renders_no_tag_outside_the_allowlist` is therefore an acceptance
//! criterion rather than a nice-to-have.

use ask_daemon::render::{
    code_block_html, code_blocks, diff_html, diff_line_counts, escape_text, CodeBlock,
};

/// Every tag the two renderers are allowed to emit.
///
/// Written out rather than derived, so widening it is a deliberate edit to
/// this list and shows up in a diff.
const ALLOWED_TAGS: [&str; 4] = ["pre", "/pre", "span", "/span"];

/// Attributes that make Qt fetch something, which is the whole risk.
///
/// `QQuickText` resolves `<img src>` through `QQuickPixmap`, and there is no
/// property that turns that off, so neither of these may appear inside a tag
/// no matter what the model wrote.
const FORBIDDEN_ATTRIBUTES: [&str; 2] = ["src", "href"];

/// Assert that a rendered string is markup only from the allowlist.
///
/// The check walks the `<...>` regions and ignores everything between them.
/// That is the correct reading: text between tags is what the escaper already
/// neutered, so `&lt;img src=...&gt;` in the body is a success rather than a
/// failure. It is the literal `<` that would make Qt parse a tag, and this
/// asserts every one of those is a tag the renderer meant to write.
fn assert_allowlisted(html: &str) {
    let mut rest = html;
    let mut tags = 0_usize;
    while let Some(start) = rest.find('<') {
        let after = &rest[start + 1..];
        let end = after
            .find('>')
            .unwrap_or_else(|| panic!("an unterminated tag reached the output: {html}"));
        let tag = &after[..end];
        let mut fields = tag.split_whitespace();
        let name = fields.next().unwrap_or(tag);
        assert!(
            ALLOWED_TAGS.contains(&name),
            "tag {name:?} is not on the allowlist: {html}"
        );
        for field in fields {
            let attribute = field.split('=').next().unwrap_or(field);
            assert!(
                !FORBIDDEN_ATTRIBUTES.contains(&attribute),
                "attribute {attribute:?} reached the output: {html}"
            );
        }
        tags += 1;
        rest = &after[end + 1..];
    }
    assert!(tags > 0, "nothing was rendered at all: {html}");
}

#[test]
fn a_fenced_rust_block_produces_highlighted_spans() {
    let markdown = "Here is some code.\n\n```rust\nfn main() { let x = 1; }\n```\n";
    let blocks = code_blocks(markdown);
    assert_eq!(
        blocks,
        vec![CodeBlock {
            language: Some("rust".to_owned()),
            source: "fn main() { let x = 1; }\n".to_owned(),
        }]
    );

    let html = code_block_html(&blocks[0].source, blocks[0].language.as_deref());
    assert!(html.starts_with("<pre class=\"code\">"), "wrapped: {html}");
    assert!(html.ends_with("</pre>"), "closed: {html}");
    assert!(html.contains("<span style=\"color:#"), "styled: {html}");
    // More than one colour, which is what separates a highlight from a wrap.
    let colours: std::collections::BTreeSet<&str> = html
        .split("color:#")
        .skip(1)
        .filter_map(|rest| rest.get(..6))
        .collect();
    assert!(
        colours.len() > 1,
        "a highlighted rust block uses more than one colour, saw {colours:?}"
    );
    assert!(html.contains("fn"), "the source survives: {html}");
}

#[test]
fn an_unknown_language_degrades_to_plain_text() {
    let blocks = code_blocks("```wubbleflorp\nnot a real language\n```\n");
    assert_eq!(blocks[0].language.as_deref(), Some("wubbleflorp"));

    let html = code_block_html(&blocks[0].source, blocks[0].language.as_deref());
    assert!(
        html.contains("not a real language"),
        "the source is still there: {html}"
    );
    assert_allowlisted(&html);
}

#[test]
fn a_fence_with_no_language_tag_reports_none() {
    let blocks = code_blocks("```\nplain\n```\n");
    assert_eq!(blocks[0].language, None, "a bare fence names no language");
    assert_eq!(blocks[0].source, "plain\n");
}

#[test]
fn only_the_first_word_of_an_info_string_is_the_language() {
    let blocks = code_blocks("```rust,ignore extra\nfn main() {}\n```\n");
    assert_eq!(
        blocks[0].language.as_deref(),
        Some("rust,ignore"),
        "the rest of the info string is attributes, not a language"
    );
}

#[test]
fn an_unterminated_fence_does_not_panic() {
    // A model that stopped mid-block, which is what an interrupt produces.
    let blocks = code_blocks("```rust\nfn main() {\n    let x = 1;\n");
    assert_eq!(blocks.len(), 1, "the open fence still yields a block");
    assert_eq!(blocks[0].language.as_deref(), Some("rust"));
    assert!(blocks[0].source.contains("let x = 1;"));
    let html = code_block_html(&blocks[0].source, blocks[0].language.as_deref());
    assert_allowlisted(&html);
}

#[test]
fn several_fences_come_back_in_order() {
    let blocks = code_blocks("```sh\nls\n```\ntext\n```rust\nfn a() {}\n```\n");
    let languages: Vec<Option<&str>> = blocks
        .iter()
        .map(|block| block.language.as_deref())
        .collect();
    assert_eq!(languages, vec![Some("sh"), Some("rust")]);
}

#[test]
fn prose_with_no_fence_produces_no_block() {
    assert!(code_blocks("just a sentence with `inline code` in it").is_empty());
}

#[test]
fn renders_no_tag_outside_the_allowlist() {
    // Hostile markdown: a raw image tag pointing at a remote host, a raw
    // image tag pointing at a local file, a link, a script, and the markdown
    // spellings of the first two, all inside a fence so the renderer has to
    // carry them through as source.
    let hostile = concat!(
        "```html\n",
        "<img src=http://example.invalid/x>\n",
        "<img src=\"file:///etc/shadow\">\n",
        "<a href=\"http://example.invalid/\">click</a>\n",
        "<script>fetch('http://example.invalid')</script>\n",
        "![alt](http://example.invalid/y.png)\n",
        "[text](file:///etc/passwd)\n",
        "```\n",
    );
    let blocks = code_blocks(hostile);
    assert_eq!(blocks.len(), 1, "the fence is one block");

    let html = code_block_html(&blocks[0].source, blocks[0].language.as_deref());
    assert_allowlisted(&html);
    assert!(
        html.contains("&lt;"),
        "an angle bracket the model wrote arrives escaped: {html}"
    );
    assert!(
        !html.contains("<img"),
        "and never as a tag Qt would resolve: {html}"
    );
    assert!(
        html.contains("example.invalid"),
        "the host is still readable as text, which is the point: {html}"
    );
}

#[test]
fn a_diff_renders_no_tag_outside_the_allowlist() {
    // The same hostility, this time as file contents rather than as a fence,
    // because diff.html goes to the same Text.RichText.
    let old_text = "<a href=\"http://example.invalid/\">before</a>\n";
    let new_text = "<img src=\"file:///etc/shadow\">\n<script>x</script>\n";
    let html = diff_html(old_text, new_text);
    assert_allowlisted(&html);
    assert!(html.contains("&lt;img"), "escaped, not emitted: {html}");
    assert!(html.contains("&lt;script"), "escaped, not emitted: {html}");
    assert!(!html.contains("<img"), "never a real tag: {html}");
    assert!(!html.contains("<script"), "never a real tag: {html}");
}

#[test]
fn a_diff_counts_the_lines_it_shows() {
    let (added, removed) = diff_line_counts("a\nb\nc\n", "a\nB\nc\nd\n");
    assert_eq!(
        (added, removed),
        (2, 1),
        "one line changed and one added, so two inserts against one delete"
    );
}

#[test]
fn creating_a_file_is_all_additions() {
    let (added, removed) = diff_line_counts("", "alpha\nbeta\n");
    assert_eq!((added, removed), (2, 0));
}

#[test]
fn an_unchanged_file_diffs_to_nothing() {
    assert_eq!(diff_line_counts("same\n", "same\n"), (0, 0));
}

#[test]
fn escaping_covers_the_five_characters_qt_treats_as_markup() {
    assert_eq!(
        escape_text("<a href=\"x\">&'</a>"),
        "&lt;a href=&quot;x&quot;&gt;&amp;&#39;&lt;/a&gt;"
    );
}

#[test]
fn escaping_leaves_ordinary_text_alone() {
    let text = "ordinary prose, with — a dash and ünïcode";
    assert_eq!(escape_text(text), text);
}

#[test]
fn an_empty_block_still_renders_a_wrapper() {
    let html = code_block_html("", Some("rust"));
    assert_eq!(html, "<pre class=\"code\"></pre>");
}
