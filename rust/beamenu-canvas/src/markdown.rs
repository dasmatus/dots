//! A small internal markdown renderer for `detail` components.
//!
//! Covers headings, bold/italic, inline code and fenced code blocks, lists
//! and links-as-text (a link renders its label, never a clickable `<a>` —
//! the canvas loads no remote content and CSP forbids it anyway). Every run
//! of literal text is HTML-escaped before it is wrapped in the tags this
//! module generates itself, so a worker can never smuggle raw markup through
//! `Component::Detail { markdown }` — the only place worker text reaches the
//! page.

use crate::ansi::escape_html;

/// Render `markdown` to the HTML fragment placed inside the detail pane.
#[must_use]
pub fn render(markdown: &str) -> String {
    let mut out = String::new();
    let mut lines = markdown.lines().peekable();
    let mut paragraph: Vec<&str> = Vec::new();

    while let Some(line) = lines.next() {
        let trimmed = line.trim_end();

        if trimmed.trim().is_empty() {
            flush_paragraph(&mut out, &mut paragraph);
            continue;
        }

        if let Some(lang) = trimmed.trim_start().strip_prefix("```") {
            flush_paragraph(&mut out, &mut paragraph);
            render_fence(&mut out, lang.trim(), &mut lines);
            continue;
        }

        if let Some(level) = heading_level(trimmed) {
            flush_paragraph(&mut out, &mut paragraph);
            let text = trimmed.trim_start_matches('#').trim();
            out.push_str(&format!("<h{level}>{}</h{level}>", inline(text)));
            continue;
        }

        if let Some(item) = unordered_item(trimmed) {
            flush_paragraph(&mut out, &mut paragraph);
            out.push_str("<ul>");
            out.push_str(&format!("<li>{}</li>", inline(item)));
            while let Some(next) = lines.peek().copied() {
                let Some(next_item) = unordered_item(next.trim_end()) else {
                    break;
                };
                out.push_str(&format!("<li>{}</li>", inline(next_item)));
                lines.next();
            }
            out.push_str("</ul>");
            continue;
        }

        if let Some(item) = ordered_item(trimmed) {
            flush_paragraph(&mut out, &mut paragraph);
            out.push_str("<ol>");
            out.push_str(&format!("<li>{}</li>", inline(item)));
            while let Some(next) = lines.peek().copied() {
                let Some(next_item) = ordered_item(next.trim_end()) else {
                    break;
                };
                out.push_str(&format!("<li>{}</li>", inline(next_item)));
                lines.next();
            }
            out.push_str("</ol>");
            continue;
        }

        paragraph.push(trimmed);
    }

    flush_paragraph(&mut out, &mut paragraph);
    out
}

fn flush_paragraph(out: &mut String, paragraph: &mut Vec<&str>) {
    if paragraph.is_empty() {
        return;
    }
    out.push_str("<p>");
    out.push_str(&inline(&paragraph.join(" ")));
    out.push_str("</p>");
    paragraph.clear();
}

fn render_fence<'a>(
    out: &mut String,
    lang: &str,
    lines: &mut std::iter::Peekable<impl Iterator<Item = &'a str>>,
) {
    let class = if lang.is_empty() {
        String::new()
    } else {
        format!(" class=\"language-{}\"", escape_html(lang))
    };
    out.push_str(&format!("<pre><code{class}>"));
    for code_line in lines.by_ref() {
        if code_line.trim_start().starts_with("```") {
            break;
        }
        out.push_str(&escape_html(code_line));
        out.push('\n');
    }
    out.push_str("</code></pre>");
}

fn heading_level(line: &str) -> Option<u8> {
    let hashes = line.chars().take_while(|c| *c == '#').count();
    if hashes == 0 || hashes > 6 {
        return None;
    }
    let rest = &line[hashes..];
    if rest.starts_with(' ') || rest.is_empty() {
        Some(u8::try_from(hashes).ok()?)
    } else {
        None
    }
}

fn unordered_item(line: &str) -> Option<&str> {
    line.strip_prefix("- ").or_else(|| line.strip_prefix("* "))
}

fn ordered_item(line: &str) -> Option<&str> {
    let digits: String = line.chars().take_while(char::is_ascii_digit).collect();
    if digits.is_empty() {
        return None;
    }
    line[digits.len()..].strip_prefix(". ")
}

/// Apply inline formatting — bold, italic, inline code, links-as-text — to
/// one run of text, escaping everything else.
fn inline(text: &str) -> String {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::new();
    let mut i = 0;

    while i < chars.len() {
        if chars[i] == '`' {
            if let Some(end) = find_close(&chars, i + 1, '`') {
                out.push_str("<code>");
                out.push_str(&escape_html(&collect(&chars, i + 1, end)));
                out.push_str("</code>");
                i = end + 1;
                continue;
            }
        }

        if chars[i] == '*' && chars.get(i + 1) == Some(&'*') {
            if let Some(end) = find_close_pair(&chars, i + 2, '*') {
                out.push_str("<strong>");
                out.push_str(&inline(&collect(&chars, i + 2, end)));
                out.push_str("</strong>");
                i = end + 2;
                continue;
            }
        }

        if chars[i] == '*' || chars[i] == '_' {
            let delim = chars[i];
            if let Some(end) = find_close(&chars, i + 1, delim) {
                out.push_str("<em>");
                out.push_str(&inline(&collect(&chars, i + 1, end)));
                out.push_str("</em>");
                i = end + 1;
                continue;
            }
        }

        if chars[i] == '[' {
            if let Some(close_bracket) = find_close(&chars, i + 1, ']') {
                if chars.get(close_bracket + 1) == Some(&'(') {
                    if let Some(close_paren) = find_close(&chars, close_bracket + 2, ')') {
                        // Links-as-text: emit the label only, drop the URL.
                        let label = collect(&chars, i + 1, close_bracket);
                        out.push_str(&escape_html(&label));
                        i = close_paren + 1;
                        continue;
                    }
                }
            }
        }

        out.push_str(&escape_html(&chars[i].to_string()));
        i += 1;
    }

    out
}

fn collect(chars: &[char], from: usize, to: usize) -> String {
    chars[from..to].iter().collect()
}

fn find_close(chars: &[char], from: usize, delim: char) -> Option<usize> {
    chars[from..]
        .iter()
        .position(|c| *c == delim)
        .map(|p| from + p)
}

fn find_close_pair(chars: &[char], from: usize, delim: char) -> Option<usize> {
    let mut i = from;
    while i + 1 < chars.len() {
        if chars[i] == delim && chars[i + 1] == delim {
            return Some(i);
        }
        i += 1;
    }
    None
}
