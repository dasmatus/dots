//! The pure `evaluate_javascript` call builders: every worker-derived
//! string must be JSON/JS-string-escaped before landing in a script, so a
//! quote or backslash in rendered content can never break out of the call.

use beamenu_canvas::shell::{
    call_append_log, call_append_stderr, call_render_detail, call_render_form, call_render_log,
    call_show_exit, PAGE_SHELL,
};

#[test]
fn page_shell_declares_a_strict_csp() {
    assert!(PAGE_SHELL.contains("Content-Security-Policy"));
    assert!(PAGE_SHELL.contains("default-src 'none'"));
}

#[test]
fn render_detail_call_escapes_quotes_and_html() {
    let call = call_render_detail("<b>\"quoted\"</b>");
    assert_eq!(
        call,
        r#"window.__beamenu.renderDetail("<b>\"quoted\"</b>")"#
    );
}

#[test]
fn render_log_call_takes_no_arguments() {
    assert_eq!(call_render_log(), "window.__beamenu.renderLog()");
}

#[test]
fn append_log_call_escapes_newlines() {
    let call = call_append_log("line one\nline two");
    assert_eq!(call, r#"window.__beamenu.appendLog("line one\nline two")"#);
}

#[test]
fn append_stderr_call_escapes_content() {
    let call = call_append_stderr("warn: it's broken");
    assert_eq!(
        call,
        r#"window.__beamenu.appendStderr("warn: it's broken")"#
    );
}

#[test]
fn show_exit_call_escapes_content() {
    assert_eq!(
        call_show_exit("exited: 0"),
        r#"window.__beamenu.showExit("exited: 0")"#
    );
}

#[test]
fn render_form_call_passes_fields_json_unescaped_and_quotes_the_label() {
    let call = call_render_form(r#"[{"key":"k","label":"K","type":"text"}]"#, Some("Go"));
    assert_eq!(
        call,
        r#"window.__beamenu.renderForm([{"key":"k","label":"K","type":"text"}], "Go")"#
    );
}

#[test]
fn render_form_call_uses_null_for_missing_submit_label() {
    let call = call_render_form("[]", None);
    assert_eq!(call, "window.__beamenu.renderForm([], null)");
}
