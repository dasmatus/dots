//! The internal markdown renderer for `detail` components: headings,
//! bold/italic, code/fences, lists, links-as-text, and — the point of the
//! whole exercise — that no worker-supplied text ever survives as raw HTML.

use beamenu_canvas::markdown::render;

#[test]
fn renders_headings() {
    assert_eq!(render("# Title"), "<h1>Title</h1>");
    assert_eq!(render("### Sub"), "<h3>Sub</h3>");
}

#[test]
fn renders_paragraph() {
    assert_eq!(render("just text"), "<p>just text</p>");
}

#[test]
fn joins_consecutive_lines_into_one_paragraph() {
    assert_eq!(render("line one\nline two"), "<p>line one line two</p>");
}

#[test]
fn blank_line_separates_paragraphs() {
    assert_eq!(render("first\n\nsecond"), "<p>first</p><p>second</p>");
}

#[test]
fn renders_bold_and_italic() {
    assert_eq!(render("**bold**"), "<p><strong>bold</strong></p>");
    assert_eq!(render("*italic*"), "<p><em>italic</em></p>");
    assert_eq!(render("_italic_"), "<p><em>italic</em></p>");
}

#[test]
fn renders_inline_code() {
    assert_eq!(
        render("run `cmd --flag`"),
        "<p>run <code>cmd --flag</code></p>"
    );
}

#[test]
fn renders_fenced_code_block_verbatim() {
    let out = render("```\nlet x = 1;\n```");
    assert_eq!(out, "<pre><code>let x = 1;\n</code></pre>");
}

#[test]
fn fenced_code_block_keeps_language_class_and_skips_inline_parsing() {
    let out = render("```rust\nlet x = *y;\n```");
    assert_eq!(
        out,
        "<pre><code class=\"language-rust\">let x = *y;\n</code></pre>"
    );
}

#[test]
fn renders_unordered_list() {
    assert_eq!(
        render("- one\n- two\n- three"),
        "<ul><li>one</li><li>two</li><li>three</li></ul>"
    );
}

#[test]
fn renders_ordered_list() {
    assert_eq!(
        render("1. one\n2. two"),
        "<ol><li>one</li><li>two</li></ol>"
    );
}

#[test]
fn links_render_as_text_not_anchors() {
    let out = render("see [the docs](https://example.com/evil)");
    assert_eq!(out, "<p>see the docs</p>");
    assert!(!out.contains("<a"));
    assert!(!out.contains("example.com"));
}

#[test]
fn escapes_raw_html_in_plain_text() {
    let out = render("<img src=x onerror=alert(1)>");
    assert!(!out.contains("<img"));
    assert!(out.contains("&lt;img"));
}

#[test]
fn escapes_raw_html_inside_inline_code() {
    let out = render("`<script>evil()</script>`");
    assert!(!out.contains("<script>"));
    assert!(out.contains("&lt;script&gt;"));
}

#[test]
fn escapes_raw_html_inside_a_heading() {
    let out = render("# <script>evil()</script>");
    assert!(!out.contains("<script>"));
}

#[test]
fn escapes_raw_html_inside_fenced_code() {
    let out = render("```\n<script>evil()</script>\n```");
    assert!(!out.contains("<script>evil"));
    assert!(out.contains("&lt;script&gt;"));
}

#[test]
fn escapes_raw_html_inside_link_label() {
    let out = render("[<b>click</b>](https://example.com)");
    assert!(!out.contains("<b>"));
}

#[test]
fn nested_emphasis_inside_bold_is_rendered() {
    // Different delimiters (`**`/`_`) so the closing pair is unambiguous,
    // unlike a run of three matching delimiters would be.
    assert_eq!(
        render("**bold _and italic_**"),
        "<p><strong>bold <em>and italic</em></strong></p>"
    );
}
