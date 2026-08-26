//! The preview pane: a resident `beamenu-canvas --preview` child, told what
//! to draw as the highlight moves.
//!
//! The launcher owns no part of what a preview looks like, on purpose. It
//! reserves a column in the panel (see `bm_menu_set_preview_width`), works out
//! where that column landed, and hands the pane a description of the
//! highlighted row. Everything after that (reading the file, decoding the
//! image, laying out the text) happens in the pane's own process, so a slow
//! preview costs a slow preview rather than a stuck keyboard.
//!
//! Two things follow from that split and shape this module.
//!
//! The pane is resident. Starting WebKit takes long enough to be visible, and
//! arrowing down a list would otherwise pay it per row. One child is spawned
//! on the first row that has a preview and kept until the launcher exits; the
//! daemon carries it across shows the same way it carries the app cache.
//!
//! Nothing here blocks on it. Messages go to a writer thread over a channel,
//! never straight down the pipe: a pane that stops reading its stdin would
//! otherwise fill the pipe buffer and freeze the launcher mid-keystroke. The
//! writer coalesces whatever piled up while it was busy, so a pane that falls
//! behind skips frames instead of replaying them.

use std::io::Write;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Sender, TryRecvError};

use serde::{Deserialize, Serialize};

use crate::item::{Item, Preview};
use crate::view::PanelMetrics;

/// The sidecar the pane runs in, resolved through `PATH`.
const CANVAS: &str = "beamenu-canvas";

/// One line of the launcher-to-pane protocol, newline-delimited JSON.
///
/// `beamenu-canvas` carries a deliberate duplicate of this enum rather than
/// depending on this crate, the same arrangement its `config` module already
/// has. Both sides are tested against the same literal JSON, so a field
/// renamed on one side fails a test on both rather than silently rendering
/// nothing.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum Message {
    /// Where the panel is, so the pane can sit exactly on its preview column.
    Metrics {
        width: u32,
        height: u32,
        list_width: u32,
        content_y: u32,
    },
    /// Draw this row's preview.
    ///
    /// `id` is the row's [`Item::id`]. The pane uses it to tell a genuinely
    /// new row from a redraw of the one it already has, and it is what makes
    /// [`apply`] a function of the messages alone rather than of the messages
    /// plus the item they came from.
    Show {
        id: String,
        title: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        subtitle: Option<String>,
        preview: Preview,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        metadata: Vec<(String, String)>,
    },
    /// Nothing is highlighted, or what is has no preview. Take the pane away.
    Hide,
    /// The launcher is done with the pane. Exit.
    Quit,
}

/// What the pane was last told, so a frame that changed nothing sends nothing.
///
/// Split from [`Pane`] because deciding what to send is pure and worth
/// testing, while sending it needs a live child process.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PaneState {
    /// Geometry last sent, all zeroes before the first frame.
    pub metrics: PanelMetrics,
    /// [`Item::id`] of the row whose preview is on screen, if any.
    pub showing: Option<String>,
}

/// The messages that bring the pane from `state` to showing `item`.
///
/// Returns an empty vector for a frame that changed nothing, which is the
/// common case: most keystrokes move neither the panel nor the highlight onto
/// a different row.
///
/// Metrics travel before the row does, so a pane that has just been spawned
/// knows where to put itself before it has anything to put there. That
/// ordering also covers the panel resizing under a highlight that did not
/// move, which happens whenever the result count changes the panel's height.
///
/// `item` is `None` for an empty list, and an item with no [`Item::preview`]
/// is the same thing as far as the pane is concerned: both mean hide. A hide
/// is only sent when something was showing, so an empty list does not send
/// one per keystroke.
#[must_use]
pub fn plan(state: &PaneState, metrics: PanelMetrics, item: Option<&Item>) -> Vec<Message> {
    let mut messages = Vec::new();

    if !metrics.usable() {
        // Nothing has been painted yet, or the panel is too narrow to hold a
        // column. Either way there is nowhere to draw, and a Show would land
        // on a surface with no geometry.
        if state.showing.is_some() {
            messages.push(Message::Hide);
        }
        return messages;
    }

    if metrics != state.metrics {
        messages.push(Message::Metrics {
            width: metrics.width,
            height: metrics.height,
            list_width: metrics.list_width,
            content_y: metrics.content_y,
        });
    }

    match item.and_then(|item| item.preview.as_ref().map(|preview| (item, preview))) {
        Some((item, preview)) => {
            if state.showing.as_deref() != Some(item.id.as_str()) {
                messages.push(Message::Show {
                    id: item.id.clone(),
                    title: item.title.clone(),
                    subtitle: item.subtitle.clone(),
                    preview: preview.clone(),
                    metadata: item.metadata.clone(),
                });
            }
        }
        None => {
            if state.showing.is_some() {
                messages.push(Message::Hide);
            }
        }
    }

    messages
}

/// Apply `messages` to `state`, recording what the pane now believes.
///
/// Separate from [`plan`] so the two can be tested against each other: a plan
/// applied to its own starting state must leave a state that plans nothing.
pub fn apply(state: &mut PaneState, messages: &[Message]) {
    for message in messages {
        match message {
            Message::Metrics {
                width,
                height,
                list_width,
                content_y,
            } => {
                state.metrics = PanelMetrics {
                    width: *width,
                    height: *height,
                    list_width: *list_width,
                    content_y: *content_y,
                };
            }
            Message::Show { id, .. } => state.showing = Some(id.clone()),
            Message::Hide | Message::Quit => state.showing = None,
        }
    }
}

/// A live preview pane, or the decision not to have one.
pub struct Pane {
    /// `None` until the first row with a preview, and after a failed spawn.
    child: Option<Child>,
    /// Handle on the writer thread. Dropped to close the pane's stdin.
    outbox: Option<Sender<Message>>,
    state: PaneState,
    /// Set once a spawn has failed, so a missing sidecar costs one failed
    /// spawn rather than one per keystroke for the rest of the session.
    unavailable: bool,
}

impl Default for Pane {
    fn default() -> Self {
        Self::new()
    }
}

impl Pane {
    #[must_use]
    pub fn new() -> Self {
        Self {
            child: None,
            outbox: None,
            state: PaneState::default(),
            unavailable: false,
        }
    }

    /// Bring the pane in line with the frame just drawn.
    ///
    /// Spawns the sidecar the first time a row actually has a preview, so a
    /// launcher nobody previews anything in never starts one.
    pub fn sync(&mut self, metrics: PanelMetrics, item: Option<&Item>) {
        let messages = plan(&self.state, metrics, item);
        if messages.is_empty() {
            return;
        }

        // Only a Show is worth starting a process for. Metrics and Hide on
        // their own describe a pane that does not exist yet, and sending them
        // into a freshly spawned WebKit would trade a wasted process for a
        // blank one.
        let wants_pane = messages
            .iter()
            .any(|message| matches!(message, Message::Show { .. }));
        if self.outbox.is_none() && !wants_pane {
            return;
        }
        if !self.ensure_spawned() {
            return;
        }

        apply(&mut self.state, &messages);
        for message in messages {
            if !self.send(message) {
                break;
            }
        }
    }

    /// Take the pane off screen without stopping the process.
    ///
    /// The launcher closing is not the pane's death: the daemon shows the
    /// panel again in a moment, and paying WebKit's startup for every show is
    /// exactly what keeping the child resident avoids.
    pub fn hide(&mut self) {
        if self.outbox.is_some() && self.state.showing.is_some() {
            self.state.showing = None;
            self.send(Message::Hide);
        }
    }

    /// Whether a sidecar is running.
    #[must_use]
    pub fn is_running(&self) -> bool {
        self.outbox.is_some()
    }

    /// Spawn the sidecar if it is not already up. Returns whether one is.
    fn ensure_spawned(&mut self) -> bool {
        if self.outbox.is_some() {
            return true;
        }
        if self.unavailable {
            return false;
        }

        let spawned = Command::new(CANVAS)
            .arg("--preview")
            .stdin(Stdio::piped())
            // stdout and stderr are left alone so the pane's own diagnostics
            // land wherever the launcher's do. Piping them without a reader
            // would wedge the pane the first time it wrote a warning.
            .spawn();

        let Ok(mut child) = spawned else {
            // A sidecar that is not installed is a missing feature, not a
            // broken launcher: the panel keeps working, minus the column.
            self.unavailable = true;
            return false;
        };

        let Some(stdin) = child.stdin.take() else {
            let _ = child.kill();
            self.unavailable = true;
            return false;
        };

        self.outbox = Some(spawn_writer(stdin));
        self.child = Some(child);
        true
    }

    /// Hand one message to the writer thread. Returns whether it got there.
    fn send(&mut self, message: Message) -> bool {
        let Some(outbox) = self.outbox.as_ref() else {
            return false;
        };
        if outbox.send(message).is_ok() {
            return true;
        }
        // The writer thread is gone, which means the pipe broke, which means
        // the pane died. Forget it rather than keep addressing a corpse.
        self.outbox = None;
        self.state.showing = None;
        self.state.metrics = PanelMetrics::default();
        false
    }
}

impl Drop for Pane {
    fn drop(&mut self) {
        let _ = self.send(Message::Quit);
        // Closing the channel closes the pane's stdin, which is the same
        // signal again; a pane that honours either exits on its own.
        self.outbox = None;
        if let Some(child) = self.child.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// Start the thread that owns the pane's stdin, and return its inbox.
///
/// Coalescing lives here rather than in [`Pane`] because only this thread
/// knows what is still queued. Holding the arrow key down while the pane is
/// mid-render piles up one Show per row travelled; replaying all of them
/// would render every row of the list in turn to arrive at the one under the
/// cursor. Only the newest of each kind survives the drain.
fn spawn_writer(mut stdin: ChildStdin) -> Sender<Message> {
    let (tx, rx) = mpsc::channel::<Message>();

    std::thread::spawn(move || {
        while let Ok(first) = rx.recv() {
            let mut metrics = None;
            let mut row = None;
            let mut quit = false;

            let mut absorb = |message: Message| match message {
                Message::Metrics { .. } => metrics = Some(message),
                Message::Show { .. } | Message::Hide => row = Some(message),
                Message::Quit => quit = true,
            };

            absorb(first);
            loop {
                match rx.try_recv() {
                    Ok(message) => absorb(message),
                    Err(TryRecvError::Empty) => break,
                    // The sender is gone: write what was drained, then stop.
                    Err(TryRecvError::Disconnected) => {
                        quit = true;
                        break;
                    }
                }
            }

            // Geometry first, so a row never lands on a stale column.
            for message in metrics.into_iter().chain(row) {
                if write_line(&mut stdin, &message).is_err() {
                    return;
                }
            }
            if quit {
                let _ = write_line(&mut stdin, &Message::Quit);
                return;
            }
        }
    });

    tx
}

fn write_line(stdin: &mut ChildStdin, message: &Message) -> std::io::Result<()> {
    let mut line = serde_json::to_string(message)
        .map_err(|err| std::io::Error::new(std::io::ErrorKind::InvalidData, err))?;
    line.push('\n');
    stdin.write_all(line.as_bytes())?;
    stdin.flush()
}
