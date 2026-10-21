//! `dots-release-proxy [ADDRESS]`: serve the repository's GitHub releases on
//! a loopback address (default `127.0.0.1:8484`) for systemd-sysupdate.
//!
//! Under systemd socket activation (one `ListenStream=` socket) it serves that
//! socket instead and ignores `ADDRESS`.
//!
//! `DOTS_PROXY_REPOSITORY` names the repository (default `dasmatus/dots`),
//! `GITHUB_TOKEN` optionally lifts the API's anonymous rate limit, and
//! `DOTS_PROXY_API` points at another API root.

use std::net::TcpListener;
use std::os::fd::FromRawFd;
use std::process::ExitCode;
use std::time::Duration;

use dots_release_proxy::{serve, Config};

fn main() -> ExitCode {
    let address = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "127.0.0.1:8484".into());
    let config = Config {
        repository: std::env::var("DOTS_PROXY_REPOSITORY")
            .unwrap_or_else(|_| "dasmatus/dots".into()),
        api: std::env::var("DOTS_PROXY_API").unwrap_or_else(|_| "https://api.github.com".into()),
        token: std::env::var("GITHUB_TOKEN").ok().filter(|t| !t.is_empty()),
        ttl: Duration::from_mins(5),
    };
    let server = match activated() {
        Some(listener) => tiny_http::Server::from_listener(listener, None),
        None => tiny_http::Server::http(&address),
    };
    let server = match server {
        Ok(server) => server,
        Err(e) => {
            eprintln!("dots-release-proxy: {address}: {e}");
            return ExitCode::FAILURE;
        }
    };
    eprintln!(
        "dots-release-proxy: serving {} releases at http://{}/updates/",
        config.repository,
        server.server_addr()
    );
    serve(&server, config);
    ExitCode::SUCCESS
}

/// The socket systemd passed in, per `sd_listen_fds(3)`: `LISTEN_PID` is this
/// process and `LISTEN_FDS` is exactly one, which is then descriptor 3.
fn activated() -> Option<TcpListener> {
    let pid = std::env::var("LISTEN_PID").ok()?.parse::<u32>().ok()?;
    let fds = std::env::var("LISTEN_FDS").ok()?;
    if pid != std::process::id() || fds != "1" {
        return None;
    }
    // SAFETY: systemd hands descriptor 3 to this process alone, open, and
    // nothing else in it has taken ownership of it.
    Some(unsafe { TcpListener::from_raw_fd(3) })
}
