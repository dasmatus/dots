// Spliced into `mod tests` in src/lib.rs via `include!` -- see the comment
// there for why. Not a standalone Cargo integration test.

const RESERVED: &[&str] = &[
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

/// `#quot;` is the only correct escape for a literal double quote inside a
/// Mermaid label; nested raw quotes are silently dropped by `mmdc`.
/// `edges_to_mermaid` must escape one in, and `mermaid_edges` must decode
/// it back out, so the label survives a full render-then-parse round trip.
#[pg_test]
fn test_edges_to_mermaid_label_survives_double_quote_round_trip() {
    let original = "he said \"hi\"";
    let rendered: String = Spi::get_one(
        "SELECT agentmem.edges_to_mermaid(ARRAY['a'], ARRAY[$lbl$he said \"hi\"$lbl$], ARRAY['b'])",
    )
    .unwrap()
    .unwrap();
    assert!(
        rendered.contains("#quot;"),
        "expected an escaped quote, got: {rendered}"
    );

    let query = format!("SELECT verb FROM agentmem.mermaid_edges($mm${rendered}$mm$)");
    let recovered: String = Spi::get_one(&query).unwrap().unwrap();
    assert_eq!(recovered, original);
}

/// A hash and a pipe both need escaping too, and in an order that does not
/// let one escape's output be mistaken for the start of another.
#[pg_test]
fn test_edges_to_mermaid_escapes_hash_and_pipe() {
    let rendered: String = Spi::get_one(
        "SELECT agentmem.edges_to_mermaid(ARRAY['a'], ARRAY[$lbl$#1 | urgent$lbl$], ARRAY['b'])",
    )
    .unwrap()
    .unwrap();
    assert!(
        rendered.contains("#35;1"),
        "expected an escaped hash, got: {rendered}"
    );
    assert!(
        rendered.contains("#124;"),
        "expected an escaped pipe, got: {rendered}"
    );

    let query = format!("SELECT verb FROM agentmem.mermaid_edges($mm${rendered}$mm$)");
    let recovered: String = Spi::get_one(&query).unwrap().unwrap();
    assert_eq!(recovered, "#1 | urgent");
}

/// However a slug maps input text, the reserved words `mermaid_edges`
/// refuses as node ids must never come out the other end of rendering: a
/// document `edges_to_mermaid` writes has to stay parseable by
/// `mermaid_edges`. The header line is excluded from the scan: its own
/// `flowchart` keyword is the one place that word belongs verbatim.
#[pg_test]
fn test_edges_to_mermaid_blocklists_reserved_words() {
    let rendered: String =
        Spi::get_one("SELECT agentmem.edges_to_mermaid(ARRAY['class'], ARRAY[''], ARRAY['end'])")
            .unwrap()
            .unwrap();

    let body = rendered.lines().skip(1).collect::<Vec<_>>().join("\n");
    for token in body.split(|c: char| !(c.is_ascii_alphanumeric() || c == '_')) {
        assert!(
            !RESERVED.contains(&token),
            "reserved word `{token}` appeared as a bare identifier in: {rendered}"
        );
    }
}

/// An empty verb renders as a plain arrow, with no pipe label at all.
#[pg_test]
fn test_edges_to_mermaid_omits_empty_labels() {
    let rendered: String =
        Spi::get_one("SELECT agentmem.edges_to_mermaid(ARRAY['a'], ARRAY[''], ARRAY['b'])")
            .unwrap()
            .unwrap();
    assert!(
        !rendered.contains('|'),
        "an empty verb must not render a pipe label: {rendered}"
    );
    assert!(
        rendered.contains("a --> b"),
        "expected a plain arrow, got: {rendered}"
    );
}
