//! The navigation stack.
//!
//! Raycast's Ctrl+K action panel and its nested command lists are the same
//! mechanism seen twice: the list you are looking at is replaced, and Escape
//! puts the previous one back. Modelling that as a stack is what let the C
//! view stay a flat list renderer with no notion of navigation at all.

use crate::item::Item;

/// One level of the stack.
#[derive(Debug, Clone)]
pub struct Frame {
    /// Rows to show. Empty means the frame is generated from providers.
    pub items: Vec<Item>,
    /// Search text to restore when this frame comes back to the top.
    pub query: String,
    /// True when the frame's rows are fixed rather than re-queried on every
    /// keystroke, which is the case for an action panel.
    pub static_items: bool,
}

#[derive(Debug, Default)]
pub struct Stack {
    frames: Vec<Frame>,
}

impl Stack {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// True when nothing has been pushed, so Escape should close the launcher.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.frames.is_empty()
    }

    #[must_use]
    pub fn depth(&self) -> usize {
        self.frames.len()
    }

    pub fn push(&mut self, frame: Frame) {
        self.frames.push(frame);
    }

    pub fn pop(&mut self) -> Option<Frame> {
        self.frames.pop()
    }

    #[must_use]
    pub fn top(&self) -> Option<&Frame> {
        self.frames.last()
    }

    /// Build the action-panel frame for `item`.
    ///
    /// Returns `None` when the item has no alternate actions, so the caller
    /// can leave the panel closed rather than show an empty list.
    #[must_use]
    pub fn actions_frame(item: &Item) -> Option<Frame> {
        if item.alt_actions.is_empty() {
            return None;
        }

        let mut items = Vec::with_capacity(item.alt_actions.len() + 1);
        items.push(
            Item::new("action:primary", "Open", item.action.clone())
                .subtitle(item.title.clone())
                .accessory("Enter")
                .section("Actions"),
        );
        items.extend(
            item.alt_actions
                .iter()
                .enumerate()
                .map(|(i, (label, action))| {
                    Item::new(format!("action:{i}"), label.clone(), action.clone())
                        .accessory("Action")
                        .section("Actions")
                }),
        );

        Some(Frame {
            items,
            query: String::new(),
            static_items: true,
        })
    }
}
