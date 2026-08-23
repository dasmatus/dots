//! Ranking behaviour: what a launcher must put first.

use beamenu::item::{Action, Item};
use beamenu::rank::{rank, score};

fn item(title: &str) -> Item {
    Item::new(title.to_lowercase(), title, Action::None)
}

#[test]
fn empty_query_matches_everything() {
    assert_eq!(score("Firefox", ""), Some(0));
    assert_eq!(score("", ""), Some(0));
}

#[test]
fn matches_are_subsequences_not_substrings() {
    assert!(score("Firefox", "fox").is_some());
    assert!(score("gnome-system-monitor", "gsm").is_some());
    assert!(score("Firefox", "xof").is_none());
}

#[test]
fn matching_is_case_insensitive() {
    assert!(score("Firefox", "FIREFOX").is_some());
    assert!(score("FIREFOX", "firefox").is_some());
}

#[test]
fn prefix_beats_midword() {
    let prefix = score("Files", "fi").unwrap();
    let midword = score("Profiles", "fi").unwrap();
    assert!(prefix > midword, "{prefix} should beat {midword}");
}

#[test]
fn word_start_beats_midword() {
    let word_start = score("gnome-monitor", "mon").unwrap();
    let midword = score("gnomemonitor", "mon").unwrap();
    assert!(word_start > midword, "{word_start} should beat {midword}");
}

#[test]
fn consecutive_beats_scattered() {
    let consecutive = score("abcdef", "abc").unwrap();
    let scattered = score("axbxcx", "abc").unwrap();
    assert!(
        consecutive > scattered,
        "{consecutive} should beat {scattered}"
    );
}

#[test]
fn shorter_title_wins_a_tie() {
    let short = score("Files", "files").unwrap();
    let long = score("Recently Used Files Browser", "files").unwrap();
    assert!(short > long, "{short} should beat {long}");
}

#[test]
fn rank_drops_non_matches_and_sorts_best_first() {
    let mut items = vec![item("Profiles"), item("Files"), item("Thunderbird")];
    rank(&mut items, "fi", |_| 0);

    let titles: Vec<&str> = items.iter().map(|i| i.title.as_str()).collect();
    assert_eq!(titles, vec!["Files", "Profiles"]);
}

#[test]
fn frecency_boost_can_promote_a_weaker_match() {
    let mut items = vec![item("Files"), item("Profiles")];
    // A large boost on the weaker match must be able to overtake.
    rank(
        &mut items,
        "fi",
        |id| if id == "profiles" { 100 } else { 0 },
    );
    assert_eq!(items[0].title, "Profiles");
}

#[test]
fn ties_break_on_title_so_ordering_is_stable() {
    let mut first = vec![item("Bravo"), item("Alpha")];
    let mut second = vec![item("Alpha"), item("Bravo")];
    rank(&mut first, "", |_| 0);
    rank(&mut second, "", |_| 0);
    assert_eq!(first[0].title, second[0].title);
    assert_eq!(first[0].title, "Alpha");
}

#[test]
fn acronyms_reach_word_starts_past_an_earlier_letter() {
    // Plain greedy matching latches onto the m in "gnome" and never reaches
    // the word start, scoring this below a run-together title.
    let hyphenated = score("gnome-monitor", "mon").unwrap();
    let run_together = score("gnomemonitor", "mon").unwrap();
    assert!(
        hyphenated > run_together,
        "word start {hyphenated} should beat midword {run_together}"
    );
}

#[test]
fn preferring_word_starts_never_loses_an_available_match() {
    // Skipping to the word-start "a" at index 3 strands the second "a";
    // the greedy fallback still finds 0 then 3.
    assert!(score("ab-a", "aa").is_some());
    assert!(score("a-ba", "aa").is_some());
}

#[test]
fn initialisms_across_several_words_match() {
    assert!(score("gnome-system-monitor", "gsm").is_some());
    assert!(score("Visual Studio Code", "vsc").is_some());
}

#[test]
fn results_are_grouped_so_each_section_gets_one_heading() {
    // Sorting purely by score interleaves providers, and the renderer emits a
    // heading wherever the section changes, so an interleaved list would
    // repeat "Apps" partway down the panel.
    let mut items = vec![
        item("Firefox").section("Apps"),
        item("Fish").section("System"),
        item("Files").section("Apps"),
        item("Finder").section("System"),
    ];
    rank(&mut items, "fi", |_| 0);

    let sections: Vec<&str> = items
        .iter()
        .map(|i| i.section.as_deref().unwrap_or(""))
        .collect();

    let mut seen = Vec::new();
    for section in &sections {
        if seen.last() != Some(section) {
            assert!(
                !seen.contains(section),
                "section {section} appears twice in {sections:?}"
            );
            seen.push(section);
        }
    }
}

#[test]
fn a_strong_match_pulls_its_whole_section_up() {
    let mut items = vec![item("Zed").section("Apps"), item("files").section("Docs")];
    // "files" is the exact title, so Docs must lead even though Apps was first.
    rank(&mut items, "files", |_| 0);
    assert_eq!(items[0].section.as_deref(), Some("Docs"));
}
