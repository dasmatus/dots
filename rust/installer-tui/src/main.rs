//! Entry point. The full abstracttui runtime — `App::new` + `mount` + custom
//! loop draining the install/net worker channels, the key bridge, and the
//! reboot side effect — is (re)wired in a later task. The body is intentionally
//! minimal here so the library and its headless view tests build standalone.

fn main() {}
