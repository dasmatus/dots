//! Attachment ingest and the three provider encodings.
//!
//! Nothing here touches the network. The provider shapes are checked as the
//! JSON the daemon would post, which is the only thing this crate controls;
//! whether a given server likes that JSON is what `tests/anthropic.rs`,
//! `tests/openai.rs` and `tests/ollama.rs` cover for the rest of the body.

use std::fs;
use std::path::PathBuf;

use uuid::Uuid;

use ask_daemon::attach;
use ask_daemon::proto::{BlockKind, SendBlock};
use ask_daemon::AskError;

/// A one-pixel PNG, so the base64 in the assertions below is a real image
/// rather than bytes pretending to be one.
const PNG: [u8; 67] = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
];

/// A scratch state root, plus the pane-side scratch a capture would write to.
struct Scratch {
    root: PathBuf,
}

impl Scratch {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("dots-ask-att-{}", Uuid::new_v4()));
        fs::create_dir_all(root.join("scratch")).expect("temp root is creatable");
        Self { root }
    }

    /// Write a file where the pane's own capture would put it, outside the
    /// state root.
    fn capture(&self, name: &str, bytes: &[u8]) -> PathBuf {
        let path = self.root.join("scratch").join(name);
        fs::write(&path, bytes).expect("the capture writes");
        path
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        drop(fs::remove_dir_all(&self.root));
    }
}

fn text(body: &str) -> SendBlock {
    SendBlock {
        kind: BlockKind::Text,
        text: Some(body.to_owned()),
        path: None,
        mime: None,
    }
}

fn image(path: PathBuf) -> SendBlock {
    SendBlock {
        kind: BlockKind::Image,
        text: None,
        path: Some(path),
        mime: Some("image/png".to_owned()),
    }
}

fn file(path: PathBuf) -> SendBlock {
    SendBlock {
        kind: BlockKind::File,
        text: None,
        path: Some(path),
        mime: None,
    }
}

#[test]
fn a_text_only_message_is_left_exactly_alone() {
    // A send with no attachment must not create a directory, because most
    // sends have no attachment and a per-thread directory for every one of
    // them is litter.
    let scratch = Scratch::new();
    let conversation = Uuid::new_v4();
    let blocks = vec![text("explain this crate")];
    let out = attach::ingest(&scratch.root, conversation, blocks.clone()).expect("ingest works");
    assert_eq!(out, blocks);
    assert!(!attach::conversation_dir(&scratch.root, conversation).exists());
}

#[test]
fn an_attachment_is_copied_into_the_thread_and_the_block_names_the_copy() {
    // The point of the copy: what the transcript records has to outlive the
    // pane's tmpfs scratch, and it has to be somewhere the harness is allowed
    // to read.
    let scratch = Scratch::new();
    let conversation = Uuid::new_v4();
    let capture = scratch.capture("cap-3.png", &PNG);

    let out = attach::ingest(
        &scratch.root,
        conversation,
        vec![text("what is this"), image(capture.clone())],
    )
    .expect("ingest works");

    let copied = out[1].path.as_ref().expect("the block still has a path");
    assert_ne!(copied, &capture, "the block must name the copy");
    assert!(
        copied.starts_with(attach::conversation_dir(&scratch.root, conversation)),
        "the copy belongs to the thread: {}",
        copied.display()
    );
    assert_eq!(fs::read(copied).expect("the copy is there"), PNG);
    assert!(
        capture.exists(),
        "the original is not the daemon's to delete"
    );
    assert_eq!(out[0], text("what is this"), "text passes through");
}

#[test]
fn the_copy_keeps_the_name_the_person_saw() {
    // A model told to look at `flamegraph.svg` does better than one told to
    // look at a bare uuid, so the name survives and only a prefix is added.
    let scratch = Scratch::new();
    let source = scratch.capture("flamegraph.svg", b"<svg/>");
    let out = attach::ingest(&scratch.root, Uuid::new_v4(), vec![file(source)]).expect("ingest");
    let copied = out[0].path.as_ref().expect("path");
    let name = copied.file_name().and_then(|n| n.to_str()).expect("name");
    assert!(name.ends_with("-flamegraph.svg"), "{name}");
}

#[test]
fn two_files_with_one_name_land_as_two_files() {
    let scratch = Scratch::new();
    let conversation = Uuid::new_v4();
    let one = scratch.capture("shot.png", &PNG);
    fs::create_dir_all(scratch.root.join("scratch/second")).expect("dir");
    let two = scratch.root.join("scratch/second/shot.png");
    fs::write(&two, b"different").expect("writes");

    let out = attach::ingest(&scratch.root, conversation, vec![image(one), image(two)])
        .expect("ingest works");
    assert_ne!(
        out[0].path, out[1].path,
        "one name must not overwrite the other"
    );
    assert_eq!(
        fs::read(out[0].path.as_ref().expect("path")).expect("read"),
        PNG
    );
    assert_eq!(
        fs::read(out[1].path.as_ref().expect("path")).expect("read"),
        b"different"
    );
}

#[test]
fn a_name_that_could_mean_something_to_a_path_is_rebuilt() {
    // The name comes from a client and ends up inside the one directory the
    // harness is given read access to, so it is rebuilt from an allowlist
    // rather than checked against a denylist.
    let scratch = Scratch::new();
    let source = scratch.capture("odd name;rm -rf.png", &PNG);
    let out = attach::ingest(&scratch.root, Uuid::new_v4(), vec![image(source)]).expect("ingest");
    let name = out[0]
        .path
        .as_ref()
        .and_then(|path| path.file_name())
        .and_then(|name| name.to_str())
        .expect("name");
    assert!(
        name.chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-' || c == '_'),
        "{name}"
    );
}

#[test]
fn resending_a_block_that_is_already_ours_does_not_copy_it_again() {
    // What a replayed message resent from the pane looks like. Copying a file
    // onto itself would leave a second copy of the same bytes under a new
    // name on every resend.
    let scratch = Scratch::new();
    let conversation = Uuid::new_v4();
    let capture = scratch.capture("cap.png", &PNG);
    let first = attach::ingest(&scratch.root, conversation, vec![image(capture)]).expect("ingest");
    let second =
        attach::ingest(&scratch.root, conversation, first.clone()).expect("a resend works");
    assert_eq!(first, second);
    let entries = fs::read_dir(attach::conversation_dir(&scratch.root, conversation))
        .expect("the directory is there")
        .count();
    assert_eq!(entries, 1, "a resend must not leave a second copy");
}

#[test]
fn a_path_that_is_not_there_is_refused_rather_than_recorded() {
    let scratch = Scratch::new();
    let missing = scratch.root.join("scratch/nothing.png");
    match attach::ingest(&scratch.root, Uuid::new_v4(), vec![image(missing.clone())]) {
        Err(AskError::Attachment { path, .. }) => assert_eq!(path, missing),
        other => panic!("a missing attachment must be refused: {other:?}"),
    }
}

#[test]
fn a_directory_is_not_an_attachment() {
    let scratch = Scratch::new();
    let dir = scratch.root.join("scratch");
    match attach::ingest(&scratch.root, Uuid::new_v4(), vec![file(dir)]) {
        Err(AskError::Attachment { detail, .. }) => {
            assert!(detail.contains("regular file"), "{detail}");
        }
        other => panic!("a directory must be refused: {other:?}"),
    }
}

#[test]
fn a_file_over_the_cap_is_refused_rather_than_copied() {
    // The copy runs inside the hub's critical section, so it is bounded for
    // the same reason the artifact write is.
    let scratch = Scratch::new();
    let conversation = Uuid::new_v4();
    let big = scratch.root.join("scratch/big.bin");
    let bytes = vec![0_u8; usize::try_from(attach::MAX_ATTACHMENT_BYTES).expect("fits") + 1];
    fs::write(&big, &bytes).expect("the big file writes");

    match attach::ingest(&scratch.root, conversation, vec![file(big)]) {
        Err(AskError::Attachment { detail, .. }) => assert!(detail.contains("cap"), "{detail}"),
        other => panic!("an oversized attachment must be refused: {other:?}"),
    }
}

#[test]
fn deleting_a_thread_takes_its_attachments_with_it() {
    let scratch = Scratch::new();
    let conversation = Uuid::new_v4();
    let capture = scratch.capture("cap.png", &PNG);
    attach::ingest(&scratch.root, conversation, vec![image(capture)]).expect("ingest");
    let dir = attach::conversation_dir(&scratch.root, conversation);
    assert!(dir.exists());

    attach::forget(&scratch.root, conversation).expect("forget works");
    assert!(!dir.exists());
    attach::forget(&scratch.root, conversation).expect("a second forget is fine");
}

#[test]
fn the_anthropic_shape_inlines_an_image_as_a_base64_block() {
    let scratch = Scratch::new();
    let capture = scratch.capture("cap.png", &PNG);
    let blocks = vec![text("what is this"), image(capture)];
    let content = attach::anthropic_content(&blocks);

    assert_eq!(content[0]["type"], "text");
    assert_eq!(content[0]["text"], "what is this");
    assert_eq!(content[1]["type"], "image");
    assert_eq!(content[1]["source"]["type"], "base64");
    assert_eq!(content[1]["source"]["media_type"], "image/png");
    let data = content[1]["source"]["data"].as_str().expect("data");
    assert!(
        data.starts_with("iVBORw0KGgo"),
        "a real PNG in base64: {data}"
    );
}

#[test]
fn the_openai_shape_inlines_an_image_as_a_data_url() {
    let scratch = Scratch::new();
    let capture = scratch.capture("cap.png", &PNG);
    let content = attach::openai_content(&[text("hi"), image(capture)]);

    assert_eq!(content[1]["type"], "image_url");
    let url = content[1]["image_url"]["url"].as_str().expect("url");
    assert!(
        url.starts_with("data:image/png;base64,iVBORw0KGgo"),
        "{url}"
    );
}

#[test]
fn the_ollama_shape_puts_images_in_a_sibling_array_of_bare_base64() {
    // ollama takes no content parts and no data URL prefix. Getting this
    // wrong sends a data: URL as an image and the model sees nothing.
    let scratch = Scratch::new();
    let capture = scratch.capture("cap.png", &PNG);
    let message = attach::ollama_message(&[text("describe this"), image(capture)]);

    assert_eq!(message["role"], "user");
    assert_eq!(message["content"], "describe this");
    let images = message["images"].as_array().expect("images");
    assert_eq!(images.len(), 1);
    let data = images[0].as_str().expect("base64");
    assert!(data.starts_with("iVBORw0KGgo"), "{data}");
    assert!(!data.starts_with("data:"), "no data URL prefix: {data}");
}

#[test]
fn a_message_with_no_image_carries_no_images_key_for_ollama() {
    let message = attach::ollama_message(&[text("plain")]);
    assert_eq!(message["content"], "plain");
    assert!(
        message.get("images").is_none(),
        "an empty images array is not the same as no images: {message}"
    );
}

#[test]
fn a_file_that_is_not_an_inlinable_image_is_named_rather_than_sent() {
    // The Anthropic `document` block is PDF-only and this daemon has no
    // recorded fixture for one, so a non-image is a path the model can ask a
    // tool to read. Sending a block the provider rejects would turn an
    // attachment into a failed turn.
    let scratch = Scratch::new();
    let source = scratch.capture("notes.txt", b"hello");
    let blocks = vec![file(source.clone())];

    let anthropic = attach::anthropic_content(&blocks);
    assert_eq!(anthropic[0]["type"], "text");
    assert!(
        anthropic[0]["text"]
            .as_str()
            .expect("text")
            .contains("notes.txt"),
        "{}",
        anthropic[0]
    );

    let openai = attach::openai_content(&blocks);
    assert_eq!(openai[0]["type"], "text");

    let ollama = attach::ollama_message(&blocks);
    assert!(ollama.get("images").is_none());
    assert!(ollama["content"]
        .as_str()
        .expect("content")
        .contains("notes.txt"));
}

#[test]
fn an_untyped_image_takes_its_media_type_from_the_extension() {
    // The pane sets a mime for a capture. A dropped file may not, and a
    // provider that is told the wrong media type rejects the image.
    let scratch = Scratch::new();
    let jpeg = scratch.capture("photo.jpg", &PNG);
    let block = SendBlock {
        kind: BlockKind::Image,
        text: None,
        path: Some(jpeg),
        mime: None,
    };
    assert!(attach::inlines_as_image(&block));
    assert_eq!(attach::image_mime(&block), "image/jpeg");

    let unknown = SendBlock {
        kind: BlockKind::Image,
        text: None,
        path: Some(PathBuf::from("/tmp/thing.tiff")),
        mime: None,
    };
    assert!(
        !attach::inlines_as_image(&unknown),
        "a type no provider takes must not be inlined"
    );
}
