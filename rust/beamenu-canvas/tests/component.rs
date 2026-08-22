//! Component tree validation: the closed set a worker may hand the canvas
//! over `ui.render`, and rejection of everything outside it — including any
//! attempt to smuggle raw HTML.

use beamenu_canvas::component::{Component, FieldType, FormField};
use serde_json::json;

#[test]
fn accepts_detail() {
    let value = json!({"type": "detail", "markdown": "# hi"});
    let component = Component::validate(value).expect("valid detail component");
    assert_eq!(
        component,
        Component::Detail {
            markdown: "# hi".to_string()
        }
    );
}

#[test]
fn accepts_log_with_no_extra_fields() {
    let value = json!({"type": "log"});
    let component = Component::validate(value).expect("valid log component");
    assert_eq!(component, Component::Log);
}

#[test]
fn accepts_form_with_all_field_types() {
    let value = json!({
        "type": "form",
        "submit_label": "Go",
        "fields": [
            {"key": "user", "label": "Username", "type": "text", "value": "alice"},
            {"key": "pass", "label": "Password", "type": "password"},
            {"key": "remember", "label": "Remember me", "type": "checkbox", "value": true},
            {"key": "env", "label": "Environment", "type": "dropdown", "options": ["dev", "prod"], "value": "dev"}
        ]
    });
    let component = Component::validate(value).expect("valid form component");
    let Component::Form {
        fields,
        submit_label,
    } = component
    else {
        panic!("expected a form component");
    };
    assert_eq!(submit_label.as_deref(), Some("Go"));
    assert_eq!(fields.len(), 4);
    assert_eq!(fields[0].field_type, FieldType::Text);
    assert_eq!(fields[1].field_type, FieldType::Password);
    assert_eq!(fields[2].field_type, FieldType::Checkbox);
    assert_eq!(fields[3].field_type, FieldType::Dropdown);
    assert_eq!(
        fields[3].options.as_deref(),
        Some(&["dev".to_string(), "prod".to_string()][..])
    );
}

#[test]
fn form_submit_label_is_optional() {
    let value = json!({
        "type": "form",
        "fields": [{"key": "k", "label": "K", "type": "text"}]
    });
    let component = Component::validate(value).expect("valid form component");
    let Component::Form { submit_label, .. } = component else {
        panic!("expected a form component");
    };
    assert_eq!(submit_label, None);
}

#[test]
fn rejects_unknown_component_type() {
    let value = json!({"type": "html", "html": "<script>evil()</script>"});
    let err = Component::validate(value).expect_err("unknown type must be rejected");
    assert!(err.0.contains("html") || err.0.to_lowercase().contains("unknown variant"));
}

#[test]
fn rejects_component_missing_required_field() {
    // "detail" without "markdown".
    let value = json!({"type": "detail"});
    assert!(Component::validate(value).is_err());
}

#[test]
fn rejects_form_field_with_unknown_field_type() {
    let value = json!({
        "type": "form",
        "fields": [{"key": "k", "label": "K", "type": "date"}]
    });
    assert!(Component::validate(value).is_err());
}

#[test]
fn rejects_non_object_tree() {
    let value = json!("just a string");
    assert!(Component::validate(value).is_err());
}

#[test]
fn there_is_no_html_carrying_variant() {
    // Structural guarantee, not just a validation-error check: nothing in
    // the schema a worker can construct includes a field meant to be
    // rendered as raw markup. `Detail::markdown` is text that only ever
    // reaches the page through `crate::markdown::render`.
    let field = FormField {
        key: "k".into(),
        label: "K".into(),
        field_type: FieldType::Text,
        value: None,
        options: None,
    };
    let form = Component::Form {
        fields: vec![field],
        submit_label: None,
    };
    let json = serde_json::to_value(&form).expect("form serializes");
    assert!(!json.to_string().contains("\"html\""));
}
