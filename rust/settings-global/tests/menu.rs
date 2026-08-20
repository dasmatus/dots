//! Tests for the menu model backing the rofi frontend: one row per item,
//! rows show the live values, and the dispatch table cannot drift from the
//! displayed list because rows are derived from it.

use global_settings::menu::{rows, theme_args, Action, ITEMS};
use global_settings::settings::Settings;

const SRC: &str = "{\n  hostname = \"box\";\n  gitName = \"Matus\";\n  gitEmail = \"a@b.com\";\n  aiClaude = true;\n  aiCodex = false;\n  aiOllama = true;\n}\n";

#[test]
fn rows_match_items_one_to_one() {
    let s = Settings::parse(SRC).unwrap();
    assert_eq!(rows(&s).len(), ITEMS.len());
}

#[test]
fn rows_show_current_values() {
    let s = Settings::parse(SRC).unwrap();
    let rows = rows(&s);
    assert!(rows.iter().any(|r| r.contains("Matus")), "{rows:?}");
    assert!(rows.iter().any(|r| r.contains("a@b.com")), "{rows:?}");
    assert!(rows.iter().any(|r| r.contains("box")), "{rows:?}");
    let ollama = rows.iter().find(|r| r.contains("Ollama")).unwrap();
    assert!(ollama.contains("on"), "{ollama}");
    let codex = rows.iter().find(|r| r.contains("Codex")).unwrap();
    assert!(codex.contains("off"), "{codex}");
}

#[test]
fn theme_args_expand_to_rofi_flag_only_when_set() {
    assert_eq!(theme_args(None), Vec::<String>::new());
    assert_eq!(theme_args(Some("settings".into())), ["-theme", "settings"]);
    assert_eq!(theme_args(Some(String::new())), Vec::<String>::new());
}

#[test]
fn last_item_is_exit() {
    assert!(matches!(ITEMS.last().unwrap().action, Action::Exit));
    let s = Settings::parse(SRC).unwrap();
    assert_eq!(rows(&s).last().unwrap(), "Exit");
}
