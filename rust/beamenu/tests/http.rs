//! The one-request HTTP client, against a listener in this process.
//!
//! No test here touches the network. Each one binds `127.0.0.1:0`, serves a
//! single canned response from a thread, and lets the client talk to that.

use std::io::{Read, Write};
use std::net::TcpListener;
use std::time::Duration;

use beamenu::http;

/// Serve `response` verbatim to one client, then close.
///
/// Returns the URL to point the client at. Closing is the point: the client
/// reads to EOF, which is only a correct body length because the peer hangs up.
fn serve(response: &'static str) -> String {
    serve_bytes(response.as_bytes())
}

fn serve_bytes(response: &'static [u8]) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").expect("an ephemeral port binds");
    let port = listener.local_addr().expect("the port is readable").port();

    std::thread::spawn(move || {
        let Ok((mut stream, _)) = listener.accept() else {
            return;
        };
        // Drain the request first. Writing and closing without reading would
        // race the client's write and can surface as a broken pipe.
        let mut request = [0u8; 2048];
        let _ = stream.read(&mut request);
        let _ = stream.write_all(response);
        let _ = stream.flush();
    });

    format!("http://127.0.0.1:{port}/search?q=test&format=json")
}

fn timeout() -> Duration {
    Duration::from_secs(5)
}

#[test]
fn a_normal_response_yields_its_status_and_body() {
    // SearXNG answers HTTP/1.0 with Connection: close, which is exactly the
    // shape this client is built around.
    let url = serve(
        "HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nContent-Length: 16\r\nConnection: close\r\n\r\n{\"results\": []}\r\n",
    );
    let response = http::get(&url, timeout()).expect("a well-formed response parses");

    assert_eq!(response.status, 200);
    assert!(response.body.starts_with("{\"results\": []}"));
}

#[test]
fn an_error_status_is_reported_rather_than_thrown_away() {
    // format=csv really does return 403 on this instance; the caller needs to
    // see the code to say something useful.
    let url = serve("HTTP/1.0 403 FORBIDDEN\r\nConnection: close\r\n\r\nnope");
    let response = http::get(&url, timeout()).expect("an error response still parses");

    assert_eq!(response.status, 403);
    assert_eq!(response.body, "nope");
}

#[test]
fn an_empty_body_is_not_an_error() {
    let url = serve("HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n");
    let response = http::get(&url, timeout()).expect("a bodiless response parses");

    assert_eq!(response.status, 204);
    assert!(response.body.is_empty());
}

#[test]
fn a_body_with_invalid_utf8_is_replaced_rather_than_fatal() {
    let url = serve_bytes(b"HTTP/1.0 200 OK\r\nConnection: close\r\n\r\n\xff\xfe bad");
    let response = http::get(&url, timeout()).expect("lossy decoding keeps the response");

    assert_eq!(response.status, 200);
    assert!(response.body.contains("bad"));
}

#[test]
fn a_response_with_no_header_terminator_is_rejected() {
    let url = serve("HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n");
    let err = http::get(&url, timeout()).expect_err("a truncated response is an error");

    assert!(
        err.to_string().contains("header terminator"),
        "unhelpful error: {err}"
    );
}

#[test]
fn a_malformed_status_line_is_rejected() {
    let url = serve("GARBAGE\r\n\r\nbody");
    assert!(http::get(&url, timeout()).is_err());
}

#[test]
fn https_is_refused_rather_than_silently_downgraded() {
    let err = http::get("https://example.invalid/", timeout())
        .expect_err("https must not be attempted in plaintext");

    assert!(
        err.to_string().contains("https is not supported"),
        "unhelpful error: {err}"
    );
}

#[test]
fn a_non_http_url_is_refused() {
    assert!(http::get("ftp://example.invalid/", timeout()).is_err());
    assert!(http::get("127.0.0.1:8888/search", timeout()).is_err());
}

#[test]
fn a_refused_connection_is_an_error_rather_than_a_hang() {
    // Bind then drop, so the port is almost certainly closed but was valid.
    let port = {
        let listener = TcpListener::bind("127.0.0.1:0").expect("a port binds");
        listener.local_addr().expect("the port is readable").port()
    };

    let result = http::get(
        &format!("http://127.0.0.1:{port}/"),
        Duration::from_millis(500),
    );
    assert!(result.is_err());
}
