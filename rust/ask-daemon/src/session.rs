//! One conversation's live state: whether a turn is running, and which
//! permission requests are still open.
//!
//! Durable metadata is deliberately not here. `store.rs` owns the index, so
//! a title or a turn count exists once rather than in two copies that drift.
//! What is left is the part that cannot be reconstructed from a `conversations`
//! row and has to be folded out of the event stream: the turn boundary and
//! the pending-permission table.
//!
//! Folding is what makes restart recovery work. `Session::apply` runs over
//! the stored events in order, so a session rebuilt at startup knows a turn
//! was left open, and `Session::interrupt` closes it. A daemon restart killed
//! whatever was producing that turn, so from the pane's side a restart and a
//! user interrupt are the same event, and they produce the same
//! `stop: "interrupted"`.

use std::collections::BTreeMap;

use uuid::Uuid;

use crate::proto::{EventBody, StopReason};

/// Whether a turn is running, and what closing it needs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TurnState {
    /// No turn is running.
    Idle,
    /// A turn opened and has not closed.
    Running {
        /// The turn id, carried through from the `turn_start` that opened
        /// it. `None` only when that event carried none.
        turn: Option<Uuid>,
        /// Unix milliseconds the turn opened, for the `turn_end` duration.
        started_ms: u64,
    },
}

/// One conversation's turn lifecycle and pending permission requests.
#[derive(Debug, Clone)]
pub struct Session {
    id: Uuid,
    turn: TurnState,
    /// Request id to the `tool_call.call` it gates.
    pending: BTreeMap<String, String>,
}

impl Session {
    /// An idle session for a thread that has no stored events yet.
    #[must_use]
    pub fn new(id: Uuid) -> Self {
        Self {
            id,
            turn: TurnState::Idle,
            pending: BTreeMap::new(),
        }
    }

    /// The thread this session belongs to.
    #[must_use]
    pub fn id(&self) -> Uuid {
        self.id
    }

    /// Whether a turn is running, and its id.
    #[must_use]
    pub fn turn_state(&self) -> &TurnState {
        &self.turn
    }

    /// The running turn's id, or `None` when the session is idle.
    #[must_use]
    pub fn running_turn(&self) -> Option<Uuid> {
        match self.turn {
            TurnState::Idle => None,
            TurnState::Running { turn, .. } => turn,
        }
    }

    /// The `tool_call.call` an open permission request gates, or `None` when
    /// no request by that id is open.
    ///
    /// The server answers an `op:"permission"` naming an unknown request with
    /// a connection-scoped `bad_request`, because an id nothing is waiting on
    /// is an argument the daemon cannot resolve.
    #[must_use]
    pub fn pending_permission(&self, request: &str) -> Option<&str> {
        self.pending.get(request).map(String::as_str)
    }

    /// How many permission requests are still waiting for a decision.
    #[must_use]
    pub fn pending_count(&self) -> usize {
        self.pending.len()
    }

    /// Fold one event into the session.
    ///
    /// This runs over stored events at startup and over live events as they
    /// are emitted, so both paths reach the same state from the same input.
    pub fn apply(&mut self, body: &EventBody) {
        match body {
            EventBody::TurnStart {
                turn, started_ms, ..
            } => {
                self.turn = TurnState::Running {
                    turn: *turn,
                    started_ms: *started_ms,
                };
            }
            EventBody::TurnEnd { .. } => {
                self.turn = TurnState::Idle;
                // A turn that closed answers nothing, so anything still
                // waiting on it is dead. Dropping the table here is what
                // keeps a restart from reviving a prompt nobody can answer.
                self.pending.clear();
            }
            EventBody::PermissionRequest {
                request,
                call,
                withdrawn,
                ..
            } => {
                if *withdrawn {
                    self.pending.remove(request);
                } else {
                    self.pending.insert(request.clone(), call.clone());
                }
            }
            EventBody::ToolResult { call, .. } => {
                // The tool ran, so whatever gated it was answered.
                self.pending.retain(|_, gated| gated != call);
            }
            _ => {}
        }
    }

    /// Answer an open permission request, returning the call it gated.
    ///
    /// Returns `None` when no request by that id is open, which is what the
    /// server turns into a `bad_request`.
    pub fn resolve_permission(&mut self, request: &str) -> Option<String> {
        self.pending.remove(request)
    }

    /// Open a turn, returning the `turn_start` body to emit.
    ///
    /// Returns `None` when a turn is already running, because a backend
    /// speaks one turn at a time and a second `turn_start` would leave the
    /// first with no `turn_end`, which is the exact shape restart recovery
    /// has to repair.
    pub fn begin_turn(
        &mut self,
        backend: String,
        model: Option<String>,
        now_ms: u64,
    ) -> Option<EventBody> {
        if matches!(self.turn, TurnState::Running { .. }) {
            return None;
        }
        let turn = Uuid::new_v4();
        let body = EventBody::TurnStart {
            turn: Some(turn),
            backend,
            model,
            started_ms: now_ms,
        };
        self.apply(&body);
        Some(body)
    }

    /// Close the running turn, returning the `turn_end` body to emit.
    ///
    /// Returns `None` when nothing is running, so a stray `result` from a
    /// backend cannot invent a turn the pane never saw open.
    pub fn end_turn(
        &mut self,
        stop: StopReason,
        text: Option<String>,
        now_ms: u64,
    ) -> Option<EventBody> {
        let TurnState::Running { turn, started_ms } = self.turn else {
            return None;
        };
        let body = EventBody::TurnEnd {
            turn,
            stop,
            text,
            duration_ms: now_ms.saturating_sub(started_ms),
        };
        self.apply(&body);
        Some(body)
    }

    /// Stamp a backend-produced event with this session's turn, or drop it.
    ///
    /// A backend knows what it produced but not which turn the daemon is
    /// calling it, because the turn id is minted here and never leaves. So a
    /// backend emits bodies with `turn: None` and this fills them in, which
    /// keeps the turn machinery in one file and stops an adapter inventing a
    /// turn the pane never saw open.
    ///
    /// Three cases have no event behind them and return `None`:
    ///
    /// - A `turn_start` while a turn is already running. A backend speaks one
    ///   turn at a time, and a second one would leave the first with no
    ///   `turn_end`, which is the exact shape restart recovery repairs.
    /// - A `turn_end` while nothing is running, so a stray `result` cannot
    ///   close a turn twice.
    /// - Anything else while nothing is running, because a delta with no
    ///   turn behind it is a decoder bug rather than something to persist.
    ///   The two correlate-by-`call` events and `error` are exempt: they
    ///   carry no `turn` and can legitimately arrive between turns.
    ///
    /// This does not mutate the session. The caller records the returned
    /// body first and folds it in only once the store has taken it, so a
    /// store failure cannot leave the in-memory session ahead of the
    /// transcript.
    #[must_use]
    pub fn adopt(&self, body: EventBody, now_ms: u64) -> Option<EventBody> {
        match body {
            EventBody::TurnStart {
                backend,
                model,
                started_ms,
                ..
            } => {
                if matches!(self.turn, TurnState::Running { .. }) {
                    tracing::warn!(
                        conversation = %self.id,
                        "dropping a turn_start while a turn is already running"
                    );
                    return None;
                }
                Some(EventBody::TurnStart {
                    turn: Some(Uuid::new_v4()),
                    backend,
                    model,
                    started_ms,
                })
            }
            EventBody::TurnEnd { stop, text, .. } => {
                let TurnState::Running { turn, started_ms } = self.turn else {
                    tracing::debug!(
                        conversation = %self.id,
                        "dropping a turn_end with no turn running"
                    );
                    return None;
                };
                Some(EventBody::TurnEnd {
                    turn,
                    stop,
                    text,
                    duration_ms: now_ms.saturating_sub(started_ms),
                })
            }
            other => self.stamp_turn(other),
        }
    }

    /// Fill in `turn` on a body that carries one, or pass it through.
    fn stamp_turn(&self, body: EventBody) -> Option<EventBody> {
        // The events that correlate through `call`, plus `error` and
        // `user_message`, carry no turn at all and are always in season.
        let turn = match &body {
            EventBody::ToolResult { .. }
            | EventBody::PermissionRequest { .. }
            | EventBody::Diff { .. }
            | EventBody::UserMessage { .. }
            | EventBody::Error { .. } => return Some(body),
            _ => match self.turn {
                TurnState::Idle => {
                    tracing::warn!(
                        conversation = %self.id,
                        "dropping a turn event with no turn running"
                    );
                    return None;
                }
                TurnState::Running { turn, .. } => turn,
            },
        };

        Some(match body {
            EventBody::TextDelta { block, text, .. } => EventBody::TextDelta { turn, block, text },
            EventBody::ThinkingDelta {
                block,
                text,
                tokens,
                ..
            } => EventBody::ThinkingDelta {
                turn,
                block,
                text,
                tokens,
            },
            EventBody::CodeBlock {
                block,
                language,
                source,
                html,
                ..
            } => EventBody::CodeBlock {
                turn,
                block,
                language,
                source,
                html,
            },
            EventBody::Artifact {
                artifact,
                title,
                path,
                revision,
                bytes,
                ..
            } => EventBody::Artifact {
                turn,
                artifact,
                title,
                path,
                revision,
                bytes,
            },
            EventBody::ToolCall {
                call,
                name,
                display_name,
                summary,
                input,
                origin,
                ..
            } => EventBody::ToolCall {
                turn,
                call,
                name,
                display_name,
                summary,
                input,
                origin,
            },
            EventBody::Plan {
                title,
                markdown,
                state,
                ..
            } => EventBody::Plan {
                turn,
                title,
                markdown,
                state,
            },
            EventBody::Usage {
                input_tokens,
                output_tokens,
                cache_read_tokens,
                cache_write_tokens,
                thinking_tokens,
                cost_usd,
                rate_limit,
                ..
            } => EventBody::Usage {
                turn,
                input_tokens,
                output_tokens,
                cache_read_tokens,
                cache_write_tokens,
                thinking_tokens,
                cost_usd,
                rate_limit,
            },
            // The connection-scoped replies never reach a session, and the
            // two turn-boundary events were handled by the caller.
            other => other,
        })
    }

    /// Close the running turn as interrupted.
    ///
    /// This serves both the `op:"interrupt"` path and startup recovery. A
    /// restart killed whatever was producing the turn, so the pane is told
    /// the same thing either way, and no `error` event goes with it: the
    /// turn stopped because something on this side stopped it, not because
    /// the backend failed.
    pub fn interrupt(&mut self, now_ms: u64) -> Option<EventBody> {
        self.end_turn(StopReason::Interrupted, None, now_ms)
    }
}
