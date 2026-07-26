//! Watch loop: initial apply, trigger filtering, debounce collapse, and
//! clean exit when the stream closes.

mod common;

use std::sync::{Arc, Mutex};
use std::thread;

use hyprmon::rules::Rules;
use hyprmon::spec::MonitorSpec;
use hyprmon::watch::{watch, Applier, EventStream};

/// A channel-backed event stream: preloaded with a sequence of event lines
/// (or `None` to model the compositor closing socket2 mid-script), returning
/// `None` once drained so the watch loop exits. `Send + 'static` so it can
/// move into the reader thread the watch loop spawns.
struct ScriptedStream {
    events: Mutex<Vec<Option<String>>>,
    idx: Mutex<usize>,
}

impl ScriptedStream {
    /// `lines` carries `Some(line)` for a real event and `None` for a
    /// mid-script EOF; once the script is exhausted the stream reports EOF
    /// permanently.
    fn new(lines: Vec<Option<String>>) -> Self {
        Self {
            events: Mutex::new(lines),
            idx: Mutex::new(0),
        }
    }

    /// Sugar: build from plain `&str` lines (all real events, no EOF).
    fn lines(lines: Vec<&str>) -> Self {
        Self::new(lines.into_iter().map(|s| Some(s.to_string())).collect())
    }
}

impl EventStream for ScriptedStream {
    fn next_event(&mut self) -> Option<String> {
        let events = self.events.lock().unwrap();
        let mut idx = self.idx.lock().unwrap();
        if *idx >= events.len() {
            return None;
        }
        let ev = events[*idx].clone();
        *idx += 1;
        ev
    }
}

/// Counting applier: records the number of apply calls (initial + each
/// re-apply). Returns success with empty specs so the loop keeps running.
struct CountingApplier {
    calls: Arc<Mutex<usize>>,
}

impl Applier for CountingApplier {
    fn apply(&self, _rules: &Rules) -> Result<Vec<MonitorSpec>, String> {
        let mut c = self.calls.lock().unwrap();
        *c += 1;
        Ok(Vec::new())
    }
}

#[test]
fn initial_apply_runs_before_any_event() {
    let calls = Arc::new(Mutex::new(0));
    let applier = CountingApplier {
        calls: calls.clone(),
    };
    // Stream with no events → loop drains immediately and exits via None.
    let stream = ScriptedStream::lines(Vec::new());
    watch(stream, &applier, &Rules::default()).unwrap();
    assert_eq!(*calls.lock().unwrap(), 1, "exactly the initial apply");
}

#[test]
fn one_trigger_one_reapply() {
    let calls = Arc::new(Mutex::new(0));
    let applier = CountingApplier {
        calls: calls.clone(),
    };
    let stream = ScriptedStream::lines(vec!["monitoradded>>DP-2"]);
    watch(stream, &applier, &Rules::default()).unwrap();
    // 1 (initial) + 1 (debounced re-apply after the trigger).
    assert_eq!(*calls.lock().unwrap(), 2);
}

#[test]
fn burst_of_triggers_collapse_into_one_reapply() {
    let calls = Arc::new(Mutex::new(0));
    let applier = CountingApplier {
        calls: calls.clone(),
    };
    // A dock unplug firing several monitorremoved events within the debounce
    // window must collapse into a single re-apply: the reader thread drains
    // all three into the channel before the 300 ms deadline elapses, so the
    // loop re-arms the deadline on each and applies once when it fires.
    let stream = ScriptedStream::lines(vec![
        "monitorremoved>>DP-2",
        "monitorremoved>>DP-3",
        "monitorremoved>>HDMI-A-1",
    ]);
    watch(stream, &applier, &Rules::default()).unwrap();
    assert_eq!(*calls.lock().unwrap(), 2);
}

#[test]
fn non_trigger_events_are_ignored() {
    let calls = Arc::new(Mutex::new(0));
    let applier = CountingApplier {
        calls: calls.clone(),
    };
    let stream = ScriptedStream::lines(vec![
        "activewindow>>kitty, kitty",
        "workspace>>2",
        "monitoradded>>DP-2",
    ]);
    watch(stream, &applier, &Rules::default()).unwrap();
    // Initial + one debounced re-apply for the monitoradded only.
    assert_eq!(*calls.lock().unwrap(), 2);
}

#[test]
fn stream_close_exits_cleanly() {
    let calls = Arc::new(Mutex::new(0));
    let applier = CountingApplier {
        calls: calls.clone(),
    };
    // A None in the middle of the script simulates the compositor closing
    // socket2 — the loop must stop and not spin. The pre-EOF trigger gets
    // one debounced apply; the post-EOF trigger never fires.
    let stream = ScriptedStream::new(vec![
        Some("monitoradded>>DP-2".to_string()),
        None,
        Some("monitoradded>>DP-3".to_string()),
    ]);
    watch(stream, &applier, &Rules::default()).unwrap();
    assert_eq!(*calls.lock().unwrap(), 2);
}

#[test]
fn parse_event_splits_name_and_args() {
    let (name, args) = hyprmon::watch::parse_event("monitoradded>>DP-2");
    assert_eq!(name, "monitoradded");
    assert_eq!(args, "DP-2");
}

#[test]
fn trigger_counts_classifies_lines() {
    use std::collections::HashMap;
    let lines = vec![
        "monitoradded>>DP-2".to_string(),
        "monitorremoved>>DP-2".to_string(),
        "workspace>>2".to_string(),
        "configreloaded>>".to_string(),
    ];
    let counts = hyprmon::watch::trigger_counts(&lines);
    let mut expected = HashMap::new();
    expected.insert("monitoradded".to_string(), 1);
    expected.insert("monitorremoved".to_string(), 1);
    expected.insert("configreloaded".to_string(), 1);
    assert_eq!(counts, expected);
}

#[test]
fn watch_runs_in_thread_without_blocking_forever() {
    // Smoke test that the loop terminates under a realistic stream size and
    // doesn't deadlock on the shared Mutex.
    let calls = Arc::new(Mutex::new(0));
    let applier = CountingApplier {
        calls: calls.clone(),
    };
    let stream = ScriptedStream::lines((0..5).map(|_| "monitoradded>>DP-1").collect::<Vec<_>>());
    let handle = thread::spawn(move || watch(stream, &applier, &Rules::default()));
    handle.join().unwrap().unwrap();
    assert!(*calls.lock().unwrap() >= 1);
}
