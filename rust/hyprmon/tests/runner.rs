//! End-to-end apply pipeline with a stubbed [`HyprCtl`]: monitors JSON →
//! match → plan → recorded `eval` Lua calls.

mod common;

use common::{monitors_json_two, FakeCtl};
use hyprmon::rules::Rules;
use hyprmon::runner::apply;

#[test]
fn apply_emits_one_eval_per_monitor() {
    let ctl = FakeCtl::new(&monitors_json_two());
    let rules = common::rules_two();
    let specs = apply(&ctl, &rules).unwrap();
    assert_eq!(specs.len(), 2);
    let evals = ctl.evals.lock().unwrap().clone();
    assert_eq!(evals.len(), 2);
    assert_eq!(
        evals[0],
        "hl.monitor({output=\"DP-1\", mode=\"1920x1080@240\", position=\"0x0\", scale=1, vrr=1})"
    );
    assert_eq!(
        evals[1],
        "hl.monitor({output=\"HDMI-A-1\", mode=\"2560x1200@60\", position=\"1920x0\", scale=1})"
    );
}

#[test]
fn apply_no_match_is_noop() {
    let ctl = FakeCtl::new(&monitors_json_two());
    let specs = apply(&ctl, &Rules::default()).unwrap();
    assert!(specs.is_empty());
    assert!(ctl.evals.lock().unwrap().is_empty());
}

#[test]
fn apply_propagates_eval_failure() {
    use hyprmon::runner::HyprCtl;
    use std::sync::Mutex;

    struct FailingCtl {
        calls: Mutex<usize>,
    }
    impl HyprCtl for FailingCtl {
        fn monitors_json(&self) -> Result<String, String> {
            Ok(monitors_json_two())
        }
        fn eval(&self, _lua: &str) -> Result<String, String> {
            let mut c = self.calls.lock().unwrap();
            *c += 1;
            if *c == 2 {
                Err("boom".to_string())
            } else {
                Ok("ok".to_string())
            }
        }
    }
    let ctl = FailingCtl {
        calls: Mutex::new(0),
    };
    let err = apply(&ctl, &common::rules_two()).unwrap_err();
    assert_eq!(err, "boom");
}
