//! Denial parsing, the heuristic table, and the outbound-search gate.
//!
//! The load-bearing tests here are the gate ones. Everything else protects a
//! feature; those protect the user's filesystem paths from being pasted into
//! a web search by a model that was only ever asked to be helpful.

use std::path::PathBuf;

use miette::Diagnostic;

use dots_sandbox::triage::{
    assemble, classify, denial_from_journal_line, denial_from_message, parse_audit_fields,
    sanitize_query, Denial, QueryRejection, TriageCtx, Verdict,
};

fn ctx() -> TriageCtx {
    TriageCtx {
        home: PathBuf::from("/home/matus"),
        runtime_dir: PathBuf::from("/run/user/1000"),
        deny_paths: vec![
            PathBuf::from("/home/matus/.ssh"),
            PathBuf::from("/home/matus/.config/rbw"),
        ],
        app_ids: vec!["zed".into(), "edupage-mcp".into()],
    }
}

fn denial(operation: &str, name: Option<&str>, mask: Option<&str>) -> Denial {
    Denial {
        profile: "store-catchall".into(),
        operation: operation.into(),
        name: name.map(String::from),
        requested_mask: mask.map(String::from),
        denied_mask: None,
        comm: None,
    }
}

// --- parsing -------------------------------------------------------------

#[test]
fn a_quoted_value_containing_spaces_survives_parsing() {
    // The reason this is a scanner and not a whitespace split: a denied path
    // may legitimately contain spaces, and splitting first would truncate
    // precisely the field the whole proposal is about.
    let fields =
        parse_audit_fields(r#"apparmor="DENIED" name="/home/matus/My Documents/a b.txt" pid=42"#);

    assert_eq!(
        fields.get("name").map(String::as_str),
        Some("/home/matus/My Documents/a b.txt")
    );
    assert_eq!(fields.get("pid").map(String::as_str), Some("42"));
}

#[test]
fn status_records_are_not_denials() {
    // Profile loads dominate the log right after a rebuild. Treating them as
    // denials would bury every real finding under AppArmor's own bookkeeping.
    let message = r#"apparmor="STATUS" operation="profile_load" profile="unconfined" \
        name="unix-chkpwd" pid=766553 comm="apparmor_parser""#;

    assert!(denial_from_message(message).is_none());
}

#[test]
fn a_complain_mode_allowed_record_is_a_denial_for_our_purposes() {
    // In complain mode the kernel logs what it *would* have denied as
    // ALLOWED. Those are exactly the records this tool exists to read; if
    // only DENIED counted, a complain-mode profile would produce nothing.
    let message = r#"apparmor="ALLOWED" operation="open" profile="store-catchall" \
        name="/etc/hosts" requested_mask="r" denied_mask="r" comm="curl""#;

    let parsed = denial_from_message(message).expect("ALLOWED is a denial record");
    assert_eq!(parsed.operation, "open");
    assert_eq!(parsed.name.as_deref(), Some("/etc/hosts"));
    assert_eq!(parsed.requested_mask.as_deref(), Some("r"));
}

#[test]
fn a_malformed_journal_line_is_skipped_rather_than_fatal() {
    // One bad record must not cost the user the whole run.
    assert!(denial_from_journal_line("not json at all").is_none());
    assert!(denial_from_journal_line(r#"{"no_message_field": 1}"#).is_none());
}

#[test]
fn a_real_journal_line_parses_end_to_end() {
    let line = r#"{"MESSAGE":"audit: type=1400 audit(1788625341.874:159): apparmor=\"ALLOWED\" operation=\"open\" profile=\"store-catchall\" name=\"/nix/store/abc-foo/lib/libc.so\" requested_mask=\"r\" comm=\"foo\""}"#;

    let parsed = denial_from_journal_line(line).expect("well-formed journal line");
    assert_eq!(
        parsed.name.as_deref(),
        Some("/nix/store/abc-foo/lib/libc.so")
    );
}

// --- the heuristic table, in its contract order --------------------------

#[test]
fn deny_paths_outrank_everything_else() {
    // ~/.ssh would otherwise be caught by the credential rule too, but the
    // point of this test is ordering: the user's own explicit list is
    // consulted first and nothing later may soften it.
    let card = classify(
        &denial("open", Some("/home/matus/.ssh/id_ed25519"), Some("r")),
        &ctx(),
    );

    assert_eq!(card.verdict, Verdict::Block);
    assert!(
        card.provenance.contains("deny-paths"),
        "deny_paths must be the rule that fired, got {}",
        card.provenance
    );
}

#[test]
fn a_privileged_operation_is_blocked_even_with_no_path() {
    let card = classify(&denial("ptrace", None, None), &ctx());

    assert_eq!(card.verdict, Verdict::Block);
    assert!(card.provenance.contains("privileged-operation"));
}

#[test]
fn a_credential_filename_is_blocked_wherever_it_sits() {
    // The whole reason to match on basename: a Firefox profile directory has
    // a random name, so enumerating full paths would never cover it.
    let card = classify(
        &denial(
            "open",
            Some("/home/matus/.mozilla/firefox/x8f3k2p1.default/cert9.db"),
            Some("r"),
        ),
        &ctx(),
    );

    assert_eq!(card.verdict, Verdict::Block);
    assert!(card.provenance.contains("credential-shape"));
}

#[test]
fn a_store_read_is_allowed_but_a_store_write_is_not() {
    let read = classify(
        &denial("open", Some("/nix/store/abc-foo/bin/foo"), Some("r")),
        &ctx(),
    );
    assert_eq!(read.verdict, Verdict::Allow);

    // A write to an immutable path is never legitimate, and must not inherit
    // the allow just because the prefix matched.
    let write = classify(
        &denial("open", Some("/nix/store/abc-foo/bin/foo"), Some("w")),
        &ctx(),
    );
    assert_ne!(
        write.verdict,
        Verdict::Allow,
        "a write to the immutable store must not be waved past: {}",
        write.rationale
    );
}

#[test]
fn the_store_prefix_does_not_match_a_lookalike_directory() {
    // `/nix/store-evil` starts with `/nix/store` on a naive prefix test. The
    // trailing separator is what makes this correct, and this test is what
    // keeps it there.
    let card = classify(
        &denial("open", Some("/nix/store-evil/payload"), Some("r")),
        &ctx(),
    );

    assert_ne!(
        card.verdict,
        Verdict::Allow,
        "/nix/store-evil is not the store: {}",
        card.rationale
    );
}

#[test]
fn an_absent_mask_does_not_count_as_a_read() {
    // Absence of evidence is not evidence of a read. Falling through to
    // Unclassified is the safe direction; treating it as read-only would let
    // an unknown access be auto-proposed as an allow.
    let card = classify(
        &denial("open", Some("/nix/store/abc-foo/bin/foo"), None),
        &ctx(),
    );

    assert_ne!(card.verdict, Verdict::Allow);
}

#[test]
fn an_apps_own_state_is_allowed_but_another_apps_is_not() {
    let own = classify(
        &denial(
            "open",
            Some("/home/matus/.config/zed/settings.json"),
            Some("r"),
        ),
        &ctx(),
    );
    assert_eq!(own.verdict, Verdict::Allow);

    // The app-id test must be a path-component join, not a substring search:
    // `zed` must not match `~/.config/zed-other`, and an unknown app's config
    // is somebody else's business.
    let other = classify(
        &denial(
            "open",
            Some("/home/matus/.config/some-other-app/secrets"),
            Some("r"),
        ),
        &ctx(),
    );
    assert_eq!(
        other.verdict,
        Verdict::Unclassified,
        "another app's config is not this app's own state: {}",
        other.rationale
    );
}

#[test]
fn an_unmatched_path_stays_unclassified() {
    // The outcome that must survive to the output rather than being quietly
    // rounded to allow or block.
    let card = classify(
        &denial("open", Some("/srv/something/odd"), Some("r")),
        &ctx(),
    );

    assert_eq!(card.verdict, Verdict::Unclassified);
}

// --- the outbound search gate --------------------------------------------

#[test]
fn a_bare_filename_query_is_allowed_through() {
    // The gate has to pass the queries the feature actually needs, or the
    // assist layer is useless and gets switched off.
    assert_eq!(
        sanitize_query("cert9.db nss database", "matus").unwrap(),
        "cert9.db nss database"
    );
}

#[test]
fn a_query_carrying_an_absolute_path_is_refused() {
    assert_eq!(
        sanitize_query("what is /home/matus/Dokumente/tax-2025.pdf", "matus"),
        Err(QueryRejection::LooksLikeAPath)
    );
}

#[test]
fn a_relative_path_is_refused_too() {
    // The naive gate checks for the home directory. This is the case that
    // defeats it.
    assert_eq!(
        sanitize_query("Dokumente/tax-2025.pdf", "matus"),
        Err(QueryRejection::LooksLikeAPath)
    );
}

#[test]
fn percent_encoding_does_not_smuggle_a_separator_past_the_gate() {
    assert_eq!(
        sanitize_query("what is %2Fhome%2Fmatus%2Fsecret", "matus"),
        Err(QueryRejection::LooksLikeAPath)
    );
}

#[test]
fn double_percent_encoding_does_not_either() {
    // %252F decodes to %2F on one pass and to / only on the second, which is
    // why the decoder runs twice.
    assert_eq!(
        sanitize_query("what is %252Fhome%252Fmatus", "matus"),
        Err(QueryRejection::LooksLikeAPath)
    );
}

#[test]
fn a_homoglyph_separator_is_refused() {
    // U+2044 FRACTION SLASH renders like '/' and is not '/'.
    //
    // Deliberately contains no username. The first version of this test used
    // a path with "matus" in it, so it passed against a decoder that was
    // mangling every multi-byte character — the username check fired and hid
    // the fact that the homoglyph check never saw its own character. A gate
    // test that can be satisfied by a different rule is not testing its rule.
    assert_eq!(
        sanitize_query("what is \u{2044}etc\u{2044}shadow", ""),
        Err(QueryRejection::LooksLikeAPath)
    );
}

#[test]
fn every_listed_homoglyph_separator_is_refused() {
    // The set is small and closed, so cover it rather than sampling one and
    // assuming the rest were typed correctly.
    for separator in ['\u{2044}', '\u{2215}', '\u{FF0F}', '\u{29F8}'] {
        assert_eq!(
            sanitize_query(&format!("what is {separator}etc{separator}hosts"), ""),
            Err(QueryRejection::LooksLikeAPath),
            "U+{:04X} renders as a separator and must be refused",
            separator as u32
        );
    }
}

#[test]
fn percent_decoding_preserves_multibyte_characters() {
    // The regression that the homoglyph test above was written to catch:
    // decoding byte-by-byte into a String reinterprets UTF-8 as latin-1, so
    // a legitimate non-ASCII query came out as mojibake and any homoglyph in
    // it stopped being detectable. This asserts the decoder leaves a
    // multi-byte character intact when there is nothing to decode.
    assert_eq!(
        sanitize_query("größe der datei", "matus").unwrap(),
        "größe der datei"
    );
}

#[test]
fn a_tilde_path_is_refused() {
    assert_eq!(
        sanitize_query("what lives in ~/.gnupg", "matus"),
        Err(QueryRejection::LooksLikeAPath)
    );
}

#[test]
fn naming_the_user_is_refused_even_with_no_separator() {
    // A model that has been told "do not send paths" may still helpfully
    // send the username on its own.
    assert_eq!(
        sanitize_query("who is matus", "matus"),
        Err(QueryRejection::NamesTheUser)
    );
}

#[test]
fn the_rejection_tells_the_model_what_to_do_instead() {
    // The refusal goes back to the model as tool output, so it has to be
    // actionable — a bare "refused" just produces a retry of the same query.
    // Asserted on the diagnostic's `help`, not its `Display`: the help is the
    // half that carries the guidance, and it is the half handed to the model.
    let help = QueryRejection::LooksLikeAPath
        .help()
        .map(|h| h.to_string())
        .expect("a refusal the model must act on needs a help line");

    assert!(
        help.contains("bare filename") || help.contains("generic"),
        "the refusal must say what a legal query looks like, got: {help}"
    );
}

#[test]
fn every_refusal_a_model_can_trigger_carries_guidance() {
    // Empty is excluded on purpose: it is reachable only from an empty
    // string, where there is nothing to advise.
    for rejection in [QueryRejection::LooksLikeAPath, QueryRejection::NamesTheUser] {
        assert!(
            rejection.help().is_some(),
            "{rejection:?} is reachable by a model and must tell it what to do instead"
        );
    }
}

// --- assembly ------------------------------------------------------------

#[test]
fn identical_denials_are_grouped_and_counted() {
    // One missing library produces a record per process start. A proposal
    // list repeating it is one nobody reads.
    let repeated = vec![
        denial("open", Some("/etc/hosts"), Some("r")),
        denial("open", Some("/etc/hosts"), Some("r")),
        denial("open", Some("/etc/hosts"), Some("r")),
    ];

    let report = assemble(&repeated, &ctx());

    assert_eq!(report.proposals.len(), 1);
    assert_eq!(report.proposals[0].count, 3);
}

#[test]
fn the_list_leads_with_what_a_human_has_to_decide() {
    let mixed = vec![
        denial("open", Some("/nix/store/abc-foo/bin/foo"), Some("r")),
        denial("open", Some("/srv/unknown"), Some("r")),
        denial("ptrace", None, None),
    ];

    let report = assemble(&mixed, &ctx());
    let verdicts: Vec<Verdict> = report
        .proposals
        .iter()
        .map(|p| p.classification.verdict)
        .collect();

    assert_eq!(
        verdicts[0],
        Verdict::Unclassified,
        "unclassified entries need attention and must come first, got {verdicts:?}"
    );
    assert_eq!(
        verdicts[verdicts.len() - 1],
        Verdict::Allow,
        "routine allows belong at the bottom, got {verdicts:?}"
    );
}

#[test]
fn every_proposal_says_where_its_verdict_came_from() {
    // A reader must never have to guess whether they are looking at a
    // deterministic table match or an advisory model opinion.
    let report = assemble(&[denial("open", Some("/srv/unknown"), Some("r"))], &ctx());

    assert!(
        report.proposals[0]
            .classification
            .provenance
            .starts_with("heuristic:"),
        "a table verdict must be labelled as one, got {}",
        report.proposals[0].classification.provenance
    );
}
