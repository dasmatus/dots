//! The file-manager operations, and the prompt frame that feeds them.
//!
//! These run against a real temporary directory rather than a mock, because
//! the thing worth checking is what ends up on disk. A mock filesystem would
//! only prove that the mock was called.

use std::fs;
use std::path::PathBuf;

use beamenu::dispatch::dispatch;
use beamenu::frame::prompt_rows;
use beamenu::item::{Action, FileOp};
use beamenu::providers::files::{worth_searching, Files, Scope};
use beamenu::providers::{Provider, Trigger};

/// Run one file operation. The terminal name is irrelevant to every `FileOp`,
/// so the tests do not have to invent one that means something.
fn run(op: FileOp, argument: &str) -> anyhow::Result<()> {
    dispatch(
        &Action::File {
            op,
            argument: argument.to_string(),
        },
        "xterm",
    )
}

#[test]
fn a_new_folder_lands_in_the_directory_it_was_asked_for() {
    let dir = tempfile::tempdir().expect("a temporary directory");

    run(
        FileOp::NewFolder {
            parent: dir.path().to_path_buf(),
        },
        "Reports",
    )
    .expect("the folder is created");

    assert!(dir.path().join("Reports").is_dir());
}

#[test]
fn a_rename_keeps_the_file_in_its_directory() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let before = dir.path().join("draft.txt");
    fs::write(&before, "hello").expect("the file is written");

    run(
        FileOp::Rename {
            target: before.clone(),
        },
        "final.txt",
    )
    .expect("the file is renamed");

    assert!(!before.exists());
    assert_eq!(
        fs::read_to_string(dir.path().join("final.txt")).expect("the renamed file reads"),
        "hello"
    );
}

/// The check that stops a rename from being a move. `../x` would put the file
/// in the parent directory and `/etc/x` somewhere else entirely, neither of
/// which is what a row labelled "Rename" said it would do.
#[test]
fn a_rename_refuses_anything_that_is_not_one_name() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let target = dir.path().join("draft.txt");
    fs::write(&target, "hello").expect("the file is written");

    for name in [
        "../escaped.txt",
        "/etc/passwd",
        "sub/dir.txt",
        "..",
        ".",
        "",
        "   ",
    ] {
        let result = run(
            FileOp::Rename {
                target: target.clone(),
            },
            name,
        );
        assert!(result.is_err(), "{name:?} must be refused");
    }

    assert!(target.exists(), "a refused rename leaves the file alone");
}

#[test]
fn a_new_folder_refuses_a_name_that_would_escape_its_parent() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let outside = dir.path().join("outside");
    fs::create_dir(&outside).expect("the sibling exists");

    let inside = outside.join("inside");
    fs::create_dir(&inside).expect("the parent exists");

    let result = run(FileOp::NewFolder { parent: inside }, "../escaped");
    assert!(result.is_err());
    assert!(!outside.join("escaped").exists());
}

#[test]
fn a_move_carries_the_name_into_the_destination() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let target = dir.path().join("photo.png");
    fs::write(&target, "not really a png").expect("the file is written");
    let destination = dir.path().join("Pictures");
    fs::create_dir(&destination).expect("the destination exists");

    run(
        FileOp::MoveTo {
            target: target.clone(),
        },
        &destination.display().to_string(),
    )
    .expect("the file moves");

    assert!(!target.exists());
    assert!(destination.join("photo.png").exists());
}

#[test]
fn a_permanent_delete_removes_a_directory_and_everything_under_it() {
    let dir = tempfile::tempdir().expect("a temporary directory");
    let target = dir.path().join("build");
    fs::create_dir_all(target.join("deep/deeper")).expect("the tree exists");
    fs::write(target.join("deep/deeper/artifact"), "x").expect("the file is written");

    run(
        FileOp::Delete {
            target: target.clone(),
        },
        "",
    )
    .expect("the tree is removed");

    assert!(!target.exists());
    assert!(dir.path().exists(), "only the target goes");
}

#[test]
fn a_permanent_delete_of_a_missing_path_fails_rather_than_passing_quietly() {
    let dir = tempfile::tempdir().expect("a temporary directory");

    let result = run(
        FileOp::Delete {
            target: dir.path().join("never-existed"),
        },
        "",
    );

    assert!(result.is_err());
}

/// The root list runs on every keystroke somebody types all day, so it earns
/// a shorter leash than a search the user asked for by name. One or two
/// characters match most of a filesystem, and the walk would run to its cap
/// every time to return rows nobody meant.
#[test]
fn the_root_list_waits_for_a_query_worth_walking_a_filesystem_for() {
    for query in ["", "i", "iD"] {
        assert!(
            !worth_searching(query, Scope::Ambient),
            "{query:?} is too short for the root list"
        );
    }
    assert!(worth_searching("iDB", Scope::Ambient));
}

/// Behind `f ` a single character is honoured: typing the prefix was the
/// request, and the only thing that stays refused is the empty pattern, which
/// `fd` reads as "list the entire tree".
#[test]
fn the_keyworded_search_honours_anything_but_an_empty_pattern() {
    assert!(!worth_searching("", Scope::Deep));
    assert!(worth_searching("i", Scope::Deep));
}

/// Two providers, one section, distinct ids. The ambient half owns the pill
/// (`Pills::new` registers ambient providers only) and the frecency store
/// keys on the row id rather than the provider, so a file found either way is
/// the same file.
#[test]
fn the_two_scopes_are_separately_nameable_but_share_a_heading() {
    let ambient = Files {
        scope: Scope::Ambient,
    };
    let deep = Files { scope: Scope::Deep };

    assert_eq!(ambient.section(), deep.section());
    assert_ne!(ambient.id(), deep.id());
    assert_eq!(ambient.trigger(), Trigger::Ambient);
    assert_eq!(deep.trigger(), Trigger::Prefix("f ".into()));
}

#[test]
fn an_empty_prompt_offers_a_hint_that_does_nothing() {
    let rows = prompt_rows(
        &FileOp::Rename {
            target: PathBuf::from("/home/matus/draft.txt"),
        },
        "",
    );

    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].action, Action::None, "an empty name must not run");
    assert!(rows[0].title.contains("draft.txt"));
}

#[test]
fn a_typed_prompt_carries_what_was_typed_into_the_action() {
    let op = FileOp::Rename {
        target: PathBuf::from("/home/matus/draft.txt"),
    };
    let rows = prompt_rows(&op, "  final.txt  ");

    assert_eq!(rows.len(), 1);
    assert_eq!(
        rows[0].action,
        Action::File {
            op,
            argument: "final.txt".into(),
        },
        "the argument is trimmed, since a trailing space in a filename is a typo"
    );
}

#[test]
fn the_operations_that_ask_for_nothing_have_no_prompt_rows() {
    for op in [
        FileOp::Trash {
            target: PathBuf::from("/home/matus/draft.txt"),
        },
        FileOp::Delete {
            target: PathBuf::from("/home/matus/draft.txt"),
        },
    ] {
        assert!(!op.needs_argument());
        assert!(prompt_rows(&op, "anything").is_empty());
    }
}

/// Renaming is usually editing a name, so the field opens on the current one.
/// The other two open empty: there is no guessable new folder name, and a
/// prefilled destination is only a path to delete first.
#[test]
fn only_rename_prefills_the_search_line() {
    let target = PathBuf::from("/home/matus/draft.txt");

    assert_eq!(
        FileOp::Rename {
            target: target.clone()
        }
        .initial(),
        "draft.txt"
    );
    assert_eq!(FileOp::MoveTo { target }.initial(), "");
    assert_eq!(
        FileOp::NewFolder {
            parent: PathBuf::from("/home/matus")
        }
        .initial(),
        ""
    );
}
