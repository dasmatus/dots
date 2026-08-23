//! The navigation stack and the action panel built on it.

use beamenu::frame::{Frame, Stack};
use beamenu::item::{Action, Item};

#[test]
fn a_new_stack_is_empty_so_escape_closes_the_launcher() {
    let stack = Stack::new();
    assert!(stack.is_empty());
    assert_eq!(stack.depth(), 0);
}

#[test]
fn push_and_pop_restore_the_previous_query() {
    let mut stack = Stack::new();
    stack.push(Frame {
        items: Vec::new(),
        query: "fire".into(),
        static_items: false,
    });
    assert_eq!(stack.depth(), 1);

    let popped = stack.pop().expect("a pushed frame pops");
    assert_eq!(popped.query, "fire");
    assert!(stack.is_empty());
}

#[test]
fn an_item_with_no_alternates_has_no_action_panel() {
    let item = Item::new("x", "Plain", Action::None);
    assert!(Stack::actions_frame(&item).is_none());
}

#[test]
fn the_action_panel_leads_with_the_primary_action() {
    let item = Item::new("x", "Notes", Action::Shell("open".into()))
        .alt("Copy path", Action::Copy("/tmp/notes".into()))
        .alt("Reveal", Action::Shell("nautilus /tmp".into()));

    let frame = Stack::actions_frame(&item).expect("alternates produce a panel");
    assert!(
        frame.static_items,
        "the panel does not re-query as you type"
    );
    assert_eq!(frame.items.len(), 3);

    assert_eq!(frame.items[0].title, "Open");
    assert_eq!(frame.items[0].action, Action::Shell("open".into()));
    assert_eq!(frame.items[0].subtitle.as_deref(), Some("Notes"));
    assert_eq!(
        frame.items[0].accessory.as_deref(),
        Some("Enter"),
        "the primary row keeps its functional hint, unlike a provider's category tag"
    );

    assert_eq!(frame.items[1].title, "Copy path");
    assert_eq!(frame.items[1].accessory.as_deref(), Some("Action"));
    assert_eq!(frame.items[2].title, "Reveal");
    assert_eq!(frame.items[2].accessory.as_deref(), Some("Action"));
}

#[test]
fn every_action_panel_row_shares_one_heading() {
    let item = Item::new("x", "Thing", Action::None).alt("Copy", Action::Copy("t".into()));
    let frame = Stack::actions_frame(&item).unwrap();
    assert!(frame
        .items
        .iter()
        .all(|i| i.section.as_deref() == Some("Actions")));
}
