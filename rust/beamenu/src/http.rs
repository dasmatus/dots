//! A one-request HTTP client, deliberately smaller than a dependency.
//!
//! This exists for exactly one caller: a `GET` to the SearXNG instance on
//! `127.0.0.1:8888`. That destination removes everything that normally makes
//! writing an HTTP client a bad idea — there is no TLS, no redirect chain, no
//! proxy, no chunked encoding (SearXNG answers `HTTP/1.0` with
//! `Connection: close` and a `Content-Length`), no keep-alive pool and no
//! retry policy. What is left is: open a socket, write a request line, read
//! until the peer closes, split on the blank line.
//!
//! Pulling in an HTTP crate for that would put a TLS stack into the launcher's
//! closure, and the launcher ships on the LiveISO. If this ever needs to reach
//! a real host — redirects, HTTPS, anything off loopback — replace it with
//! `ureq` rather than growing it.

use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};

/// Largest response body accepted.
///
/// A SearXNG JSON page is tens of kilobytes; anything past this is a
/// misconfiguration rather than a search result, and reading it into a launcher
/// that must repaint in milliseconds helps nobody.
const MAX_BODY_BYTES: usize = 4 * 1024 * 1024;

/// A parsed HTTP response.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Response {
    pub status: u16,
    pub body: String,
}

/// The pieces of a URL this client understands.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Target {
    host: String,
    port: u16,
    /// Path plus query string, i.e. everything after the authority.
    request_uri: String,
}

/// Split an `http://` URL into host, port and request URI.
///
/// `https` is rejected rather than silently downgraded: a caller asking for TLS
/// deserves an error, not a plaintext request it did not ask for.
fn parse_url(url: &str) -> Result<Target> {
    if url.starts_with("https://") {
        bail!("https is not supported by this client (use ureq if it is ever needed)");
    }
    let rest = url
        .strip_prefix("http://")
        .ok_or_else(|| anyhow!("not an http:// URL: {url}"))?;

    let (authority, path) = match rest.find('/') {
        Some(at) => (&rest[..at], &rest[at..]),
        None => (rest, "/"),
    };
    if authority.is_empty() {
        bail!("no host in URL: {url}");
    }

    let (host, port) = match authority.rsplit_once(':') {
        Some((host, port)) => (
            host,
            port.parse::<u16>()
                .with_context(|| format!("bad port in URL: {url}"))?,
        ),
        None => (authority, 80),
    };

    Ok(Target {
        host: host.to_string(),
        port,
        request_uri: path.to_string(),
    })
}

/// `GET url`, giving up after `timeout` on connect, read or write.
///
/// # Errors
/// Fails when the URL is not a plain-HTTP one this client understands, the host
/// does not resolve or refuses the connection, the peer stops answering within
/// `timeout`, the response is not recognisable HTTP, or the body exceeds
/// [`MAX_BODY_BYTES`].
pub fn get(url: &str, timeout: Duration) -> Result<Response> {
    let target = parse_url(url)?;

    // to_socket_addrs rather than a bare connect, so the timeout covers the
    // connect itself. A launcher must not hang on an unreachable host.
    let address = std::net::ToSocketAddrs::to_socket_addrs(&(target.host.as_str(), target.port))
        .with_context(|| format!("could not resolve {}:{}", target.host, target.port))?
        .next()
        .ok_or_else(|| anyhow!("no address for {}:{}", target.host, target.port))?;

    let mut stream = TcpStream::connect_timeout(&address, timeout)
        .with_context(|| format!("could not connect to {address}"))?;
    stream.set_read_timeout(Some(timeout))?;
    stream.set_write_timeout(Some(timeout))?;

    // Connection: close is what makes read-to-EOF a correct body length, so
    // this client never has to implement chunked transfer encoding.
    let request = format!(
        "GET {} HTTP/1.1\r\nHost: {}\r\nAccept: application/json\r\nUser-Agent: beamenu\r\nConnection: close\r\n\r\n",
        target.request_uri, target.host
    );
    stream
        .write_all(request.as_bytes())
        .context("could not send the request")?;
    stream.flush().context("could not flush the request")?;

    let mut raw = Vec::new();
    // take() rather than read_to_end() alone: a peer that never stops sending
    // would otherwise be an unbounded allocation.
    stream
        .take(MAX_BODY_BYTES as u64 + 1)
        .read_to_end(&mut raw)
        .context("could not read the response")?;
    if raw.len() > MAX_BODY_BYTES {
        bail!("response larger than {MAX_BODY_BYTES} bytes");
    }

    parse_response(&raw)
}

/// Split a raw response into its status code and body.
fn parse_response(raw: &[u8]) -> Result<Response> {
    let split = raw
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .ok_or_else(|| anyhow!("response had no header terminator"))?;
    let (head, body) = raw.split_at(split);

    let status_line = std::str::from_utf8(head)
        .context("response headers were not UTF-8")?
        .lines()
        .next()
        .ok_or_else(|| anyhow!("response had no status line"))?;

    // "HTTP/1.0 200 OK" — the middle field is the only one that matters here.
    let status: u16 = status_line
        .split_whitespace()
        .nth(1)
        .ok_or_else(|| anyhow!("malformed status line: {status_line}"))?
        .parse()
        .with_context(|| format!("malformed status line: {status_line}"))?;

    Ok(Response {
        status,
        body: String::from_utf8_lossy(&body[4..]).into_owned(),
    })
}
