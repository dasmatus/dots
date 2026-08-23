//! The JSON-RPC side of the dashboard worker.
//!
//! Newline-delimited JSON-RPC 2.0 over stdio, the `ui: "rpc"` view mode a
//! plugin manifest asks for. Traffic here is one-way: this end pushes
//! `ui.render` notifications and nothing else. The canvas only ever sends
//! `form.submit`, which a dashboard has no form to receive, so incoming lines
//! are read and dropped.
//!
//! Repeated unprompted `ui.render` pushes are legal precisely because it is a
//! notification rather than a request — that is what makes a ticking dashboard
//! possible without extending the protocol.

use serde_json::{json, Value};

const VERSION: &str = "2.0";

/// Wrap a markdown body in the `ui.render` notification carrying a `detail`
/// component.
#[must_use]
pub fn render(markdown: &str) -> Value {
    json!({
        "jsonrpc": VERSION,
        "method": "ui.render",
        "params": { "tree": { "type": "detail", "markdown": markdown } },
    })
}
