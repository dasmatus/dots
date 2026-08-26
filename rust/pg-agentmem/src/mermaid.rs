//! Parser for the strict flowchart-Mermaid subset described in
//! `docs/superpowers/specs/2026-08-26-postgres-memory-plugin-design.md`,
//! section 8.
//!
//! Mermaid's reference renderer (`mmdc`) is documented there to accept
//! nonsense silently and exit 0: `dev---ops` renders a node named `ps`
//! because a lone `o` is swallowed as a circle-edge terminator, `click` as a
//! node id parses to zero nodes, and `A -- text ==> B` pushes an `INVALID`
//! edge type into the edge list without ever raising. This parser accepts
//! a fixed, exactly-specified subset of the grammar and rejects everything
//! else outright rather than guessing at what the author meant.

/// One parsed edge at document position `ord`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Edge {
    pub ord: i32,
    pub src: String,
    pub verb: String,
    pub dst: String,
    pub directed: bool,
}

/// Identifiers Mermaid's own grammar reserves for statement keywords. Using
/// one as a node id is a hard parse error, never a best-effort guess.
pub const RESERVED_WORDS: &[&str] = &[
    "call",
    "class",
    "classDef",
    "end",
    "flowchart",
    "graph",
    "href",
    "linkStyle",
    "style",
    "subgraph",
    "click",
];

/// First words that mark a whole line as a directive to skip rather than an
/// edge statement to parse.
const SKIP_DIRECTIVES: &[&str] = &[
    "subgraph",
    "end",
    "direction",
    "class",
    "classDef",
    "style",
    "click",
    "linkStyle",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Family {
    Solid,
    Thick,
    Dotted,
    Invisible,
}

/// Bare arrow tokens, longest first: `-.->`'s four characters must be tried
/// before `-.-`'s three, or the shorter token would always shadow it.
const ARROW_TOKENS: &[(&str, Family, bool)] = &[
    ("-.->", Family::Dotted, true),
    ("-.-", Family::Dotted, false),
    ("-->", Family::Solid, true),
    ("--o", Family::Solid, true),
    ("--x", Family::Solid, true),
    ("---", Family::Solid, false),
    ("==>", Family::Thick, true),
    ("==o", Family::Thick, true),
    ("==x", Family::Thick, true),
    ("===", Family::Thick, false),
    ("~~~", Family::Invisible, false),
];

/// Openers for the "surrounded" label form (`A -- text --> B`). Dotted has
/// no entry: its two-character opener (`-.`) would be indistinguishable
/// without a space from the start of the bare undirected token (`-.-`), so
/// a dotted surrounded label is out of subset and rejected.
const OPENERS: &[(&str, Family)] = &[("--", Family::Solid), ("==", Family::Thick)];

/// Match a fixed arrow token at `chars[pos..]`, returning it and the
/// position just past it.
fn match_arrow(chars: &[char], pos: usize) -> Option<(Family, bool, usize)> {
    for &(tok, family, directed) in ARROW_TOKENS {
        let len = tok.chars().count();
        if pos + len > chars.len() {
            continue;
        }
        if chars[pos..pos + len].iter().copied().eq(tok.chars()) {
            return Some((family, directed, pos + len));
        }
    }
    None
}

struct Lexer {
    chars: Vec<char>,
    pos: usize,
}

impl Lexer {
    fn new(line: &str) -> Self {
        Self {
            chars: line.chars().collect(),
            pos: 0,
        }
    }

    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    fn eof(&self) -> bool {
        self.pos >= self.chars.len()
    }

    fn rest(&self) -> String {
        self.chars[self.pos..].iter().collect()
    }

    fn skip_ws(&mut self) {
        while matches!(self.peek(), Some(c) if c.is_whitespace()) {
            self.pos += 1;
        }
    }

    fn starts_with(&self, tok: &str) -> bool {
        let len = tok.chars().count();
        self.pos + len <= self.chars.len()
            && self.chars[self.pos..self.pos + len]
                .iter()
                .copied()
                .eq(tok.chars())
    }
}

/// A single node identifier: `[A-Za-z_][A-Za-z0-9_]*`, not a reserved word.
fn parse_ident(lex: &mut Lexer) -> Result<String, String> {
    let start = lex.pos;
    if !matches!(lex.peek(), Some(c) if c.is_ascii_alphabetic() || c == '_') {
        return Err(format!("expected a node id, found `{}`", lex.rest()));
    }
    while matches!(lex.peek(), Some(c) if c.is_ascii_alphanumeric() || c == '_') {
        lex.pos += 1;
    }
    let ident: String = lex.chars[start..lex.pos].iter().collect();
    if RESERVED_WORDS.contains(&ident.as_str()) {
        return Err(format!(
            "`{ident}` is a reserved word and cannot be used as a node id"
        ));
    }
    Ok(ident)
}

/// `A & B & C`: one or more identifiers joined by `&`, expanded elsewhere as
/// a cross product against the group on the other side of a link.
fn parse_group(lex: &mut Lexer) -> Result<Vec<String>, String> {
    let mut group = vec![parse_ident(lex)?];
    loop {
        lex.skip_ws();
        if lex.peek() != Some('&') {
            break;
        }
        lex.pos += 1;
        lex.skip_ws();
        group.push(parse_ident(lex)?);
    }
    Ok(group)
}

struct Link {
    directed: bool,
    verb: String,
}

/// Strip one layer of wrapping double quotes, if the whole label is quoted
/// that way -- the form `render::render` emits so a label may safely
/// contain spaces and reserved punctuation.
fn strip_quotes(label: &str) -> &str {
    if label.len() >= 2 && label.starts_with('"') && label.ends_with('"') {
        &label[1..label.len() - 1]
    } else {
        label
    }
}

/// Reverse a label's `#entity;` escaping, the inverse of
/// `render::escape_label`. Decoded in the opposite order the encoder
/// applies its escapes, so a `#` produced by decoding `#quot;` or `#124;`
/// is never mistaken for the start of another entity.
fn decode_label(label: &str) -> String {
    strip_quotes(label)
        .replace("#124;", "|")
        .replace("#quot;", "\"")
        .replace("#35;", "#")
}

/// `A -->|text| B`: an arrow immediately followed (no space) by a pipe
/// label. Consumes up to and including the closing `|`.
fn parse_pipe_label(lex: &mut Lexer) -> Result<String, String> {
    let start = lex.pos;
    while let Some(c) = lex.peek() {
        if c == '|' {
            let text: String = lex.chars[start..lex.pos].iter().collect();
            lex.pos += 1;
            return Ok(decode_label(text.trim()));
        }
        lex.pos += 1;
    }
    Err("unterminated `|label|`".to_string())
}

/// `-- text -->`: everything between an opener and the next arrow token
/// that immediately follows whitespace. Returns the label and the closing
/// arrow's family and direction; the caller checks the family against the
/// opener.
fn parse_surrounded_label(lex: &mut Lexer) -> Result<(String, Family, bool), String> {
    let start = lex.pos;
    loop {
        if lex.eof() {
            return Err("unterminated inline edge label".to_string());
        }
        if matches!(lex.peek(), Some(c) if c.is_whitespace()) {
            let mut probe = lex.pos;
            while matches!(lex.chars.get(probe), Some(c) if c.is_whitespace()) {
                probe += 1;
            }
            if let Some((family, directed, after)) = match_arrow(&lex.chars, probe) {
                let label: String = lex.chars[start..lex.pos].iter().collect();
                lex.pos = after;
                return Ok((decode_label(label.trim()), family, directed));
            }
        }
        lex.pos += 1;
    }
}

/// One link operator between two node groups: a bare arrow, an arrow with a
/// pipe label, or an opener-and-closer surrounded label. Anything else, and
/// an opener whose closer disagrees on stroke family, is rejected.
fn parse_link(lex: &mut Lexer) -> Result<Link, String> {
    if let Some((_family, directed, after)) = match_arrow(&lex.chars, lex.pos) {
        lex.pos = after;
        if lex.peek() == Some('|') {
            lex.pos += 1;
            let verb = parse_pipe_label(lex)?;
            return Ok(Link { directed, verb });
        }
        return Ok(Link {
            directed,
            verb: String::new(),
        });
    }

    for &(opener, family) in OPENERS {
        if lex.starts_with(opener) {
            let after_opener = lex.pos + opener.chars().count();
            if !matches!(lex.chars.get(after_opener), Some(c) if c.is_whitespace()) {
                continue;
            }
            lex.pos = after_opener;
            lex.skip_ws();
            let (verb, closer_family, directed) = parse_surrounded_label(lex)?;
            if closer_family != family {
                return Err(format!(
                    "stroke mismatch: `{opener}` opener does not match its closing arrow"
                ));
            }
            return Ok(Link { directed, verb });
        }
    }

    Err(format!("expected a link operator, found `{}`", lex.rest()))
}

/// One edge-chain statement: `Group Link Group (Link Group)*`. Every
/// consecutive pair of groups is expanded as a cross product, in document
/// order, against a running `ord` counter shared across the whole document.
fn parse_statement(line: &str, ord: &mut i32, out: &mut Vec<Edge>) -> Result<(), String> {
    let mut lex = Lexer::new(line);
    lex.skip_ws();
    let mut groups = vec![parse_group(&mut lex)?];
    let mut links = Vec::new();
    loop {
        lex.skip_ws();
        if lex.eof() {
            break;
        }
        links.push(parse_link(&mut lex)?);
        lex.skip_ws();
        groups.push(parse_group(&mut lex)?);
    }
    if links.is_empty() {
        return Err(format!("`{line}` is not a recognised edge statement"));
    }
    for (i, link) in links.iter().enumerate() {
        for src in &groups[i] {
            for dst in &groups[i + 1] {
                out.push(Edge {
                    ord: *ord,
                    src: src.clone(),
                    verb: link.verb.clone(),
                    dst: dst.clone(),
                    directed: link.directed,
                });
                *ord += 1;
            }
        }
    }
    Ok(())
}

/// Parse a whole flowchart document into edges. Blank lines, `%%` comments,
/// the leading `flowchart`/`graph` header, and `subgraph`/`end`/
/// `direction`/`class`/`classDef`/`style`/`click`/`linkStyle` lines are
/// skipped; everything else must parse as an edge-chain statement or the
/// whole document is rejected.
pub fn parse(doc: &str) -> Result<Vec<Edge>, String> {
    let mut edges = Vec::new();
    let mut ord: i32 = 0;
    let mut seen_content = false;
    for raw_line in doc.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with("%%") {
            continue;
        }
        let first_word = line.split_whitespace().next().unwrap_or("");
        if !seen_content && (first_word == "flowchart" || first_word == "graph") {
            seen_content = true;
            continue;
        }
        seen_content = true;
        if SKIP_DIRECTIVES.contains(&first_word) {
            continue;
        }
        parse_statement(line, &mut ord, &mut edges)?;
    }
    Ok(edges)
}
