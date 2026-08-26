//! The navigation stack.
//!
//! Raycast's Ctrl+K action panel and its nested command lists are the same
//! mechanism seen twice: the list you are looking at is replaced, and Escape
//! puts the previous one back. Modelling that as a stack is what let the C
//! view stay a flat list renderer with no notion of navigation at all.

use crate::item::{Action, FileOp, Item};

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
    /// The operation this frame is collecting a word for, if it is a prompt.
    ///
    /// A prompt frame is the opposite of a static one: its single row is
    /// rebuilt from the search line on every keystroke, because the search
    /// line is the text field. See [`prompt_rows`].
    pub prompt: Option<FileOp>,
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
            prompt: None,
        })
    }

    /// Build the yes/no frame for an [`Action::Confirm`].
    ///
    /// Two rows, with the destructive one first, because the highlight starts
    /// on the first row and a confirmation whose default is "yes" is the one
    /// that gets dismissed by reflex. Escape is the third way out and needs
    /// no row: it pops this frame like any other.
    #[must_use]
    pub fn confirm_frame(label: &str, action: &Action, query: &str) -> Frame {
        Frame {
            items: vec![
                Item::new("confirm:yes", label.to_string(), action.clone())
                    .accessory("Enter")
                    .section("Are you sure?"),
                Item::new("confirm:no", "Cancel", Action::None)
                    .accessory("Esc")
                    .section("Are you sure?"),
            ],
            query: query.to_string(),
            static_items: true,
            prompt: None,
        }
    }
}

/// The single row a prompt frame shows for what is typed so far.
///
/// Rebuilt on every keystroke, which is the whole mechanism: the search line
/// is the text field, and this row is the preview of what pressing Enter will
/// do with it. An empty line gets a row that says what is wanted and does
/// nothing, rather than no row at all, since a panel that empties itself as
/// you clear the field reads as broken.
#[must_use]
pub fn prompt_rows(op: &FileOp, query: &str) -> Vec<Item> {
    let typed = query.trim();
    let section = "Enter a name";

    let (empty_hint, confirm) = match op {
        FileOp::NewFolder { parent } => (
            format!("New folder in {}", parent.display()),
            format!("Create \"{typed}\""),
        ),
        FileOp::Rename { target } => (
            format!("Rename {}", short_name(target)),
            format!("Rename to \"{typed}\""),
        ),
        FileOp::MoveTo { target } => (
            format!("Move {} to a folder", short_name(target)),
            format!("Move to {typed}"),
        ),
        // Neither asks for anything, so neither can reach a prompt frame.
        FileOp::Trash { .. } | FileOp::Delete { .. } => return Vec::new(),
    };

    if typed.is_empty() {
        return vec![Item::new("prompt:empty", empty_hint, Action::None)
            .subtitle("Type a name, then press Enter")
            .section(section)];
    }

    vec![Item::new(
        "prompt:confirm",
        confirm,
        Action::File {
            op: op.clone(),
            argument: typed.to_string(),
        },
    )
    .accessory("Enter")
    .section(section)]
}

fn short_name(path: &std::path::Path) -> String {
    path.file_name().map_or_else(
        || path.display().to_string(),
        |name| name.to_string_lossy().into_owned(),
    )
}
