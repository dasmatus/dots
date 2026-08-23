//! Scientific calculator for the beamenu launcher, shipped as a plugin.
//!
//! Two entry points over one evaluator. `beamenu-calc <expr>` prints a result
//! and is what the tests drive; `beamenu-calc --serve` speaks the launcher's
//! JSON-RPC view protocol to beamenu-canvas.
//!
//! The plugin protocol is submit-driven: the only message the canvas sends
//! back is `form.submit`, so this evaluates on Enter rather than per keystroke
//! the way the launcher's built-in `=` calculator does.

pub mod eval;
pub mod rpc;
