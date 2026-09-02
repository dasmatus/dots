// Unit tests for sourcescan.js. The source-text assertions in
// tst_chrome_geometry.qml and tst_interaction_grammar.qml are only as strong
// as the strip that feeds them: an over-eager strip deletes the binding those
// tests look for, and a shy one lets prose stand in for it — the exact bug
// that let a gutted Cheatsheet height binding pass. Both directions are
// pinned here so the helper cannot regress quietly under them.
import QtQuick
import QtTest
import "sourcescan.js" as SourceScan

TestCase {
    name: "SourceScan"

    function occurrences(hay, needle) {
        let n = 0;
        let at = hay.indexOf(needle);
        while (at !== -1) {
            n++;
            at = hay.indexOf(needle, at + 1);
        }
        return n;
    }

    // ---- comments must go ----

    function test_strips_comments_data() {
        return [
            { tag: "line", src: "// panel.implicitHeight\n" },
            { tag: "block", src: "/* panel.implicitHeight */" },
            { tag: "trailing", src: "width: 4 // panel.implicitHeight\n" },
            { tag: "multiline block", src: "/*\n * panel.implicitHeight\n */\n" },
            { tag: "apostrophe inside", src: "// Chrome's own panel.implicitHeight\n" },
            { tag: "double quote inside", src: "// the \"panel.implicitHeight\" binding\n" },
            { tag: "backtick inside", src: "// a `panel.implicitHeight` binding\n" },
            { tag: "url inside", src: "// see https://doc.qt.io/ panel.implicitHeight\n" }
        ];
    }

    function test_strips_comments(row) {
        compare(SourceScan.stripComments(row.src).indexOf("panel.implicitHeight"), -1, row.tag + " must not survive the strip");
    }

    // ---- code must stay ----

    function test_keeps_code_data() {
        return [
            { tag: "plain binding", src: "height: panel.implicitHeight\n" },
            { tag: "after a line comment", src: "// note\nheight: panel.implicitHeight\n" },
            { tag: "after a block comment", src: "/* note */ height: panel.implicitHeight\n" },
            { tag: "double-quoted url on the same line", src: "u: \"https://a.com\"; height: panel.implicitHeight\n" },
            { tag: "single-quoted url on the same line", src: "u: 'https://a.com'; height: panel.implicitHeight\n" },
            { tag: "templated url on the same line", src: "u: `https://a.com/${x}`; height: panel.implicitHeight\n" },
            { tag: "apostrophe in a template literal", src: "t: `Chrome's panel`; height: panel.implicitHeight\n" },
            { tag: "escaped quote in a string", src: "s: \"a\\\"b\"; height: panel.implicitHeight\n" }
        ];
    }

    function test_keeps_code(row) {
        compare(occurrences(SourceScan.stripComments(row.src), "panel.implicitHeight"), 1, row.tag + " must survive the strip exactly once");
    }

    // The two cases the previous regex got wrong, kept as named tests because
    // each was a live route back to a green suite over a broken binding.
    function test_a_comment_after_an_apostrophe_in_a_template_literal_is_still_stripped() {
        const src = "t: `Chrome's panel`\n// panel.implicitHeight\nconst q = 'x';\n";
        compare(SourceScan.stripComments(src).indexOf("panel.implicitHeight"), -1, "an apostrophe in a template literal must not shield the comment that follows it");
    }

    function test_a_double_slash_inside_a_template_literal_deletes_nothing() {
        const src = "path: `https://a.com` + panel.implicitHeight\n";
        compare(occurrences(SourceScan.stripComments(src), "panel.implicitHeight"), 1, "a // inside a template literal must not eat the rest of the line");
    }

    function test_string_literals_are_returned_untouched() {
        const src = "a: \"x // y\"; b: 'p /* q */ r'; c: `s // t`\n";
        compare(SourceScan.stripComments(src), src, "nothing inside a string literal is a comment");
    }

    // ---- blockAfter ----

    function test_blockAfter_returns_the_matched_block() {
        const src = "before\nfoo: {\n  if (a) {\n    b();\n  }\n}\nafter\n";
        const block = SourceScan.blockAfter(src, "foo: {");
        compare(block[block.length - 1], "}");
        verify(block.indexOf("b()") !== -1, "the nested body must be included");
        verify(block.indexOf("after") === -1, "the block must not over-run its closing brace");
    }

    function test_blockAfter_is_empty_when_the_marker_is_absent() {
        compare(SourceScan.blockAfter("nothing here\n", "foo: {"), "");
    }

    function test_blockAfter_is_empty_when_the_block_never_closes() {
        compare(SourceScan.blockAfter("foo: {\n  if (a) {\n", "foo: {"), "");
    }
}
