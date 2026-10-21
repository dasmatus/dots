//! Path routing, channel selection and part joining, then the whole server
//! against a fake GitHub on loopback.

use std::io::Read;
use std::thread;
use std::time::Duration;

use dots_release_proxy::{
    channel, in_channel, locate, merge_sums, route, serve, Asset, Config, Release, Route, Source,
};

fn asset(name: &str, size: u64) -> Asset {
    Asset {
        name: name.into(),
        size,
        url: format!("https://example.invalid/{name}"),
    }
}

fn release(tag: &str, assets: Vec<Asset>) -> Release {
    Release {
        tag: tag.into(),
        draft: false,
        assets,
    }
}

const A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

#[test]
fn routes_updates_paths_only() {
    assert_eq!(
        route("/updates/weekly/x86_64/SHA256SUMS"),
        Route::Sums { channel: "weekly" }
    );
    assert_eq!(
        route("/updates/nightly/x86_64/x_1.iso"),
        Route::File {
            channel: "nightly",
            name: "x_1.iso"
        }
    );
    assert_eq!(
        route("/updates/weekly/x86_64/../SHA256SUMS"),
        Route::NotFound
    );
    assert_eq!(route("/updates/weekly/x86_64"), Route::NotFound);
    assert_eq!(route("/updates/weekly/x86_64/a/b"), Route::NotFound);
    assert_eq!(route("/other/weekly/x86_64/a"), Route::NotFound);
}

#[test]
fn channels_are_tag_prefixes() {
    assert!(in_channel("weekly", "weekly-2026.43"));
    assert!(in_channel("nightly", "nightly"));
    assert!(!in_channel("weekly", "weekly-"));
    assert!(!in_channel("week", "weekly-2026.43"));
    assert!(!in_channel("nightly", "nightly2"));

    let all = [
        release("weekly-2026.42", vec![]),
        release("nightly", vec![]),
        release("weekly-2026.43", vec![]),
        Release {
            draft: true,
            ..release("weekly-2026.44", vec![])
        },
    ];
    let tags: Vec<&str> = channel(&all, "weekly")
        .iter()
        .map(|r| r.tag.as_str())
        .collect();
    assert_eq!(tags, ["weekly-2026.43", "weekly-2026.42"]);
}

#[test]
fn locates_whole_files_and_ordered_parts() {
    let newer = release(
        "weekly-2026.43",
        vec![
            asset("full_2.iso.part001", 5),
            asset("full_2.iso.part000", 10),
            asset("full_2.iso.part002", 1),
            asset("lean_2.iso", 7),
        ],
    );
    let older = release(
        "weekly-2026.42",
        vec![
            asset("full_1.iso.part000", 3),
            asset("full_1.iso.part002", 3),
        ],
    );
    let releases = [&newer, &older];

    assert_eq!(
        locate(&releases, "lean_2.iso"),
        Some(Source::Whole(&newer.assets[3]))
    );
    let Some(Source::Parts(parts)) = locate(&releases, "full_2.iso") else {
        panic!("full_2.iso should be found in parts");
    };
    let names: Vec<&str> = parts.iter().map(|p| p.name.as_str()).collect();
    assert_eq!(
        names,
        [
            "full_2.iso.part000",
            "full_2.iso.part001",
            "full_2.iso.part002"
        ]
    );
    assert_eq!(Source::Parts(parts).size(), 16);
    // A gap in the numbering is not served short.
    assert_eq!(locate(&releases, "full_1.iso"), None);
    assert_eq!(locate(&releases, "full_2.iso.part0"), None);
}

#[test]
fn merges_sums_newest_first() {
    let newer = format!("{A}  new.iso\n{A}  shared.iso\n");
    let older = format!("{B} *shared.iso\n{B}  old.iso\nnot a line\n{B}  ../escape\n");
    assert_eq!(
        merge_sums([newer.as_str(), older.as_str()]),
        format!("{A}  new.iso\n{A}  shared.iso\n{B}  old.iso\n")
    );
}

/// A fake GitHub: one API listing and the assets it names, all on loopback.
fn fake_github() -> String {
    let server = tiny_http::Server::http("127.0.0.1:0").expect("bind the fake API");
    let base = format!(
        "http://{}",
        server.server_addr().to_ip().expect("an IP address")
    );
    let listing = serde_json::json!([
        {
            "tag_name": "weekly-2026.43",
            "assets": [
                { "name": "SHA256SUMS", "size": 1, "browser_download_url": format!("{base}/dl/43/SHA256SUMS") },
                { "name": "full_2026.43.iso.part000", "size": 4, "browser_download_url": format!("{base}/dl/43/p0") },
                { "name": "full_2026.43.iso.part001", "size": 3, "browser_download_url": format!("{base}/dl/43/p1") },
                { "name": "lean_2026.43.iso", "size": 2, "browser_download_url": format!("{base}/dl/43/lean") }
            ]
        },
        {
            "tag_name": "weekly-2026.42",
            "assets": [
                { "name": "SHA256SUMS", "size": 1, "browser_download_url": format!("{base}/dl/42/SHA256SUMS") }
            ]
        },
        { "tag_name": "nightly", "assets": [] }
    ])
    .to_string();
    thread::spawn(move || {
        for request in server.incoming_requests() {
            let body = match request.url() {
                "/repos/o/r/releases?per_page=100" => listing.clone(),
                "/dl/43/SHA256SUMS" => format!("{A}  full_2026.43.iso\n{A}  lean_2026.43.iso\n"),
                "/dl/42/SHA256SUMS" => format!("{B}  full_2026.42.iso\n"),
                "/dl/43/p0" => "abcd".into(),
                "/dl/43/p1" => "efg".into(),
                "/dl/43/lean" => "hi".into(),
                _ => {
                    let _ = request.respond(tiny_http::Response::empty(404));
                    continue;
                }
            };
            let _ = request.respond(tiny_http::Response::from_string(body));
        }
    });
    base
}

#[test]
fn serves_merged_sums_and_joined_parts() {
    let api = fake_github();
    let server = tiny_http::Server::http("127.0.0.1:0").expect("bind the proxy");
    let proxy = format!(
        "http://{}",
        server.server_addr().to_ip().expect("an IP address")
    );
    thread::spawn(move || {
        serve(
            &server,
            Config {
                repository: "o/r".into(),
                api,
                token: None,
                ttl: Duration::from_mins(1),
            },
        );
    });

    let get = |path: &str| {
        ureq::get(&format!("{proxy}{path}"))
            .call()
            .map_err(Box::new)
    };
    let body = |path: &str| {
        let mut out = String::new();
        get(path)
            .expect("a 200")
            .into_reader()
            .read_to_string(&mut out)
            .expect("a body");
        out
    };

    assert_eq!(
        body("/updates/weekly/x86_64/SHA256SUMS"),
        format!("{A}  full_2026.43.iso\n{A}  lean_2026.43.iso\n{B}  full_2026.42.iso\n")
    );
    let joined = get("/updates/weekly/x86_64/full_2026.43.iso").expect("a 200");
    assert_eq!(joined.header("content-length"), Some("7"));
    let mut bytes = String::new();
    joined
        .into_reader()
        .read_to_string(&mut bytes)
        .expect("a body");
    assert_eq!(bytes, "abcdefg");
    // A whole asset is a redirect, which the client follows to the fake.
    assert_eq!(body("/updates/weekly/x86_64/lean_2026.43.iso"), "hi");

    let missing =
        |path: &str| matches!(get(path).map_err(|e| *e), Err(ureq::Error::Status(404, _)));
    assert!(missing("/updates/weekly/x86_64/full_2026.42.iso"));
    assert!(missing("/updates/nightly/x86_64/SHA256SUMS"));
    assert!(missing("/updates/stable/x86_64/SHA256SUMS"));
    assert!(missing("/elsewhere"));
}
