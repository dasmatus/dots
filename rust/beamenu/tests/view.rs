//! How a row is drawn, for the parts of it that are not FFI.

use beamenu::item::{Action, Item};
use beamenu::view::indented;

fn row(title: &str) -> Item {
    Item::new(title.to_lowercase(), title, Action::None)
}

fn child(title: &str, parent: &str) -> Item {
    Item::new(format!("{parent}#{title}"), title, Action::None).parent(parent)
}

#[test]
fn a_row_with_no_parent_is_drawn_as_itself() {
    let items = vec![row("LibreWolf")];
    assert_eq!(indented(&items, 0), "LibreWolf");
}

#[test]
fn the_last_child_closes_the_branch_and_the_others_continue_it() {
    let items = vec![
        row("LibreWolf"),
        child("New Private Window", "librewolf"),
        child("New Window", "librewolf"),
        child("Profile Manager", "librewolf"),
    ];
    assert_eq!(indented(&items, 0), "LibreWolf");
    assert_eq!(indented(&items, 1), "├─ New Private Window");
    assert_eq!(indented(&items, 2), "├─ New Window");
    assert_eq!(indented(&items, 3), "└─ Profile Manager");
}

#[test]
fn an_only_child_closes_the_branch_immediately() {
    let items = vec![row("Thunderbird"), child("Compose", "thunderbird")];
    assert_eq!(indented(&items, 1), "└─ Compose");
}

#[test]
fn a_childs_branch_closes_where_the_next_row_belongs_to_another_parent() {
    let items = vec![
        row("LibreWolf"),
        child("New Window", "librewolf"),
        row("Thunderbird"),
        child("Compose", "thunderbird"),
    ];
    assert_eq!(
        indented(&items, 1),
        "└─ New Window",
        "the row after it is another app, not a sibling"
    );
}

#[test]
fn an_orphaned_child_still_draws_a_branch() {
    // rank() promotes a child whose parent lost the filter, and it keeps its
    // parent id. Drawing it as a branch is honest: it is still an action of
    // something, and its subtitle says which.
    let items = vec![child("New Private Window", "librewolf")];
    assert_eq!(indented(&items, 0), "└─ New Private Window");
}

#[test]
fn an_index_past_the_end_is_empty_rather_than_a_panic() {
    assert_eq!(indented(&[], 0), "");
    assert_eq!(indented(&[row("A")], 7), "");
}
