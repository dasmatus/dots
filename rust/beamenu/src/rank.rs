//! Fuzzy matching and result ordering.
//!
//! bemenu can filter its own item list, but only with dmenu's substring and
//! prefix modes, and only against the item text. beamenu ranks in Rust
//! instead: providers hand back everything they consider relevant, this
//! module scores it, and the view is refilled in score order with bemenu's
//! own filtering switched off.
//!
//! The scorer is a subsequence matcher in the style of fzf's. It is cheap,
//! allocates nothing per candidate, and is biased towards the matches a
//! launcher user actually means: word starts, prefixes, and short titles.

/// Score awarded for a character that starts a word (follows a separator).
const WORD_START_BONUS: i64 = 12;
/// Score awarded for consecutive matched characters.
const CONSECUTIVE_BONUS: i64 = 8;
/// Score awarded when the match begins at the very start of the title.
const PREFIX_BONUS: i64 = 20;
/// Score awarded per matched character, before bonuses.
const MATCH_SCORE: i64 = 4;
/// Penalty per character skipped between matches.
const GAP_PENALTY: i64 = 1;

/// True when `c` ends a word, so the next character starts one.
fn is_separator(c: char) -> bool {
    c.is_whitespace() || matches!(c, '-' | '_' | '.' | '/' | ':' | '(' | '[')
}

/// Score `needle` against `haystack`, or `None` when it isn't a subsequence.
///
/// Matching is case-insensitive and order-preserving but not contiguous, so
/// "fox" matches "Firefox" and "gnome-system-monitor" answers to "gsm".
/// An empty needle scores 0 and matches everything, which is what makes the
/// root list show up before you type.
#[must_use]
pub fn score(haystack: &str, needle: &str) -> Option<i64> {
    if needle.is_empty() {
        return Some(0);
    }

    let hay: Vec<char> = haystack.chars().collect();

    // Two passes, best score wins.
    //
    // Plain greedy takes the earliest occurrence of each character, which gets
    // the acronym cases wrong: "mon" against "gnome-monitor" latches onto the
    // m in "gnome" and never reaches the word start that the user meant. The
    // first pass prefers a word-start occurrence when one is reachable.
    //
    // It cannot simply replace greedy, because skipping ahead to a word start
    // can strand the rest of the needle: "aa" against "ab-a" would take the a
    // at index 3 and find nothing after it, reporting no match where one
    // exists. So greedy stays as the fallback and both results are compared.
    let word_start = walk(&hay, needle, true);
    let earliest = walk(&hay, needle, false);

    match (word_start, earliest) {
        (Some(a), Some(b)) => Some(a.max(b)),
        (found, None) | (None, found) => found,
    }
}

/// Score one alignment of `needle` into `hay`.
///
/// With `prefer_word_start`, each character takes the first occurrence that
/// begins a word if there is one, and the first occurrence otherwise.
fn walk(hay: &[char], needle: &str, prefer_word_start: bool) -> Option<i64> {
    let mut total = 0i64;
    let mut hay_idx = 0usize;
    let mut last_match: Option<usize> = None;

    for need_c in needle.chars() {
        let need_lower = need_c.to_ascii_lowercase();
        let mut earliest = None;
        let mut at_word_start = None;

        for (offset, h) in hay[hay_idx..].iter().enumerate() {
            if h.to_ascii_lowercase() != need_lower {
                continue;
            }
            let index = hay_idx + offset;
            if earliest.is_none() {
                earliest = Some(index);
            }
            if index == 0 || is_separator(hay[index - 1]) {
                at_word_start = Some(index);
                break;
            }
        }

        let found = if prefer_word_start {
            at_word_start.or(earliest)?
        } else {
            earliest?
        };

        total += MATCH_SCORE;

        if found == 0 {
            total += PREFIX_BONUS;
        } else if is_separator(hay[found - 1]) {
            total += WORD_START_BONUS;
        }

        match last_match {
            Some(prev) if found == prev + 1 => total += CONSECUTIVE_BONUS,
            Some(prev) => {
                total -= GAP_PENALTY * i64::try_from(found - prev - 1).unwrap_or(i64::MAX);
            }
            None => total -= GAP_PENALTY * i64::try_from(found).unwrap_or(i64::MAX),
        }

        last_match = Some(found);
        hay_idx = found + 1;
    }

    // Prefer the shorter of two titles that matched equally well: "Files"
    // should beat "Recently Used Files" for the query "files".
    // Casts are bounded: a menu row title is never anywhere near i64::MAX
    // characters, so none of these can wrap.
    total -= i64::try_from(hay.len() / 8).unwrap_or(i64::MAX);

    Some(total)
}

/// Subtracted from a keyword match, so a row whose *title* matches always
/// outranks one that only matched a hidden alias.
///
/// Large enough to clear any score `walk` can produce for a realistic row, so
/// this is a strict tier rather than a thumb on the scale.
const KEYWORD_PENALTY: i64 = 10_000;

/// Score `query` against a row's title and its hidden keywords.
///
/// Keywords are scored individually and the best one wins, then drops a tier.
/// See [`crate::item::Item::keywords`] for why they are not one joined string.
#[must_use]
pub fn match_score(item: &crate::item::Item, query: &str) -> Option<i64> {
    let title = score(&item.title, query);
    let keyword = item
        .keywords
        .iter()
        .filter_map(|keyword| score(keyword, query))
        .max()
        .map(|best| best - KEYWORD_PENALTY);

    match (title, keyword) {
        (Some(a), Some(b)) => Some(a.max(b)),
        (found, None) | (None, found) => found,
    }
}

/// Rank `items` against `query`, dropping non-matches and sorting best-first.
///
/// Ties break on title so ordering is stable across runs rather than
/// dependent on whatever order the providers happened to answer in.
pub fn rank(items: &mut Vec<crate::item::Item>, query: &str, boost: impl Fn(&str) -> i64) {
    items.retain_mut(|item| match match_score(item, query) {
        Some(s) => {
            item.score = s + boost(&item.id);
            true
        }
        None => false,
    });

    items.sort_by(|a, b| b.score.cmp(&a.score).then_with(|| a.title.cmp(&b.title)));
    group_by_section(items);
}

/// Gather rows of the same section together, strongest section first.
///
/// Sorting purely by score interleaves providers, and since the renderer emits
/// a heading wherever the section changes, an interleaved list repeats
/// "Applications" three times down the panel. Grouping afterwards keeps the
/// ranking that decided *which* rows win while giving each section one
/// heading.
///
/// A section's rank is its best row, so a strong match still pulls its whole
/// group up. Within a group the score order set above is preserved.
fn group_by_section(items: &mut [crate::item::Item]) {
    use std::collections::HashMap;

    let mut best: HashMap<Option<String>, (i64, usize)> = HashMap::new();
    for (position, item) in items.iter().enumerate() {
        best.entry(item.section.clone())
            .or_insert((item.score, position));
    }

    items.sort_by(|a, b| {
        let (a_score, a_pos) = best[&a.section];
        let (b_score, b_pos) = best[&b.section];
        b_score
            .cmp(&a_score)
            // Two sections whose best rows tie keep the order the providers
            // were registered in, so the list does not reshuffle per keystroke.
            .then_with(|| a_pos.cmp(&b_pos))
            .then_with(|| b.score.cmp(&a.score))
            .then_with(|| a.title.cmp(&b.title))
    });
}
