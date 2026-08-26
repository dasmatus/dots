// Spliced into `mod tests` in src/lib.rs via `include!` -- see the comment
// there for why. Not a standalone Cargo integration test.

/// `dev---ops` is `mmdc` 11.16.0's textbook silent-corruption case: its
/// lexer greedily consumes the trailing `o` as a circle-edge terminator, so
/// `ops` becomes a phantom node named `ps`. This parser tokenizes solid
/// arrows as a fixed three-character window, so `---` is consumed in full
/// before `ops` is ever looked at; the edge below is the correctly parsed
/// undirected `dev`-`ops`, and no `ps` node is possible.
#[pg_test]
fn test_mermaid_edges_no_phantom_ps_node() {
    let src: String = Spi::get_one("SELECT src FROM agentmem.mermaid_edges($$dev---ops$$)")
        .unwrap()
        .unwrap();
    let dst: String = Spi::get_one("SELECT dst FROM agentmem.mermaid_edges($$dev---ops$$)")
        .unwrap()
        .unwrap();
    let directed: bool = Spi::get_one("SELECT directed FROM agentmem.mermaid_edges($$dev---ops$$)")
        .unwrap()
        .unwrap();
    assert_eq!(src, "dev");
    assert_eq!(dst, "ops");
    assert!(
        !directed,
        "`dev---ops` is a solid open link and must be undirected"
    );
}

/// One representative arrow per stroke family, checking the `directed` flag
/// this parser assigns: `arrow_open` tokens (`---`, `===`, `-.-`) and the
/// invisible link (`~~~`) are undirected; every terminator that carries a
/// point, circle or cross is directed.
#[pg_test]
fn test_mermaid_edges_family_directedness() {
    let cases = [
        ("a --> b", true),
        ("a --- b", false),
        ("a --o b", true),
        ("a --x b", true),
        ("a ==> b", true),
        ("a === b", false),
        ("a ==o b", true),
        ("a ==x b", true),
        ("a -.-> b", true),
        ("a -.- b", false),
        ("a ~~~ b", false),
    ];
    for (doc, expected) in cases {
        let query = format!("SELECT directed FROM agentmem.mermaid_edges($${doc}$$)");
        let directed: bool = Spi::get_one(&query).unwrap().unwrap();
        assert_eq!(directed, expected, "wrong directedness for `{doc}`");
    }
}

/// `A -->|label| B`: the label attaches directly to the arrow with no
/// space.
#[pg_test]
fn test_mermaid_edges_pipe_label_form() {
    let verb: String = Spi::get_one("SELECT verb FROM agentmem.mermaid_edges($$a -->|owns| b$$)")
        .unwrap()
        .unwrap();
    assert_eq!(verb, "owns");
}

/// `A -- label --> B`: the label sits between a stroke opener and a full
/// closing arrow of the same family, and produces the same triple as the
/// pipe-label spelling of the same edge.
#[pg_test]
fn test_mermaid_edges_surrounded_label_form() {
    let verb: String = Spi::get_one("SELECT verb FROM agentmem.mermaid_edges($$a -- owns --> b$$)")
        .unwrap()
        .unwrap();
    assert_eq!(verb, "owns");
}

/// `A --> B --> C` folds into one row per hop, left to right.
#[pg_test]
fn test_mermaid_edges_chains_into_one_row_per_hop() {
    let pairs: String = Spi::get_one(
        "SELECT string_agg(src || '->' || dst, ',' ORDER BY ord) FROM agentmem.mermaid_edges($$a --> b --> c$$)",
    )
    .unwrap()
    .unwrap();
    assert_eq!(pairs, "a->b,b->c");
}

/// `A & B --> C & D` expands to the full cross product, source group
/// outermost.
#[pg_test]
fn test_mermaid_edges_expands_ampersand_groups() {
    let pairs: String = Spi::get_one(
        "SELECT string_agg(src || '->' || dst, ',' ORDER BY ord) FROM agentmem.mermaid_edges($$a & b --> c & d$$)",
    )
    .unwrap()
    .unwrap();
    assert_eq!(pairs, "a->c,a->d,b->c,b->d");
}

/// A reserved word used as a node id is a hard parse error, not a best
/// effort at picking a different meaning.
#[pg_test(error = "mermaid_edges: `call` is a reserved word and cannot be used as a node id")]
fn test_mermaid_edges_rejects_reserved_word() {
    let _: Option<i32> =
        Spi::get_one("SELECT ord FROM agentmem.mermaid_edges($$call --> b$$)").unwrap();
}

/// `A -- t ==> B` opens a solid stroke and closes with a thick arrow.
/// `mmdc` pushes an `INVALID` edge type into its edge list and never
/// raises; this parser refuses the line outright.
#[pg_test(error = "mermaid_edges: stroke mismatch: `--` opener does not match its closing arrow")]
fn test_mermaid_edges_rejects_stroke_mismatch() {
    let _: Option<i32> =
        Spi::get_one("SELECT ord FROM agentmem.mermaid_edges($$a -- t ==> b$$)").unwrap();
}

/// Bracketed node shapes are not part of this subset at all, so a document
/// using one is rejected rather than approximated.
#[pg_test(error = "mermaid_edges: expected a link operator, found `[shape] --> b`")]
fn test_mermaid_edges_rejects_out_of_subset() {
    let _: Option<i32> =
        Spi::get_one("SELECT ord FROM agentmem.mermaid_edges($$a[shape] --> b$$)").unwrap();
}
