//! How a row is drawn, for the parts of it that are not FFI.

use beamenu::item::{Action, Item};
use beamenu::view::nest_depth;

fn row(title: &str) -> Item {
    Item::new(title.to_lowercase(), title, Action::None)
}

fn child(title: &str, parent: &str) -> Item {
    Item::new(format!("{parent}#{title}"), title, Action::None).parent(parent)
}

#[test]
fn a_row_with_no_parent_never_nests() {
    assert_eq!(nest_depth(&row("LibreWolf"), true), 0);
    assert_eq!(nest_depth(&row("LibreWolf"), false), 0);
}

#[test]
fn a_child_nests_only_while_the_list_is_at_rest() {
    let action = child("New Private Window", "librewolf");
    assert_eq!(nest_depth(&action, true), 1);
    assert_eq!(
        nest_depth(&action, false),
        0,
        "a filtered list draws every row full size: the parent this hangs \
         under may not have matched, so there is nothing to indent beneath"
    );
}
