//! Emoji picker, reached with a leading `:`.
//!
//! The table is curated rather than the full Unicode set. A complete CLDR
//! dump is about 1800 entries with localised keywords, and shipping it would
//! mean either a build-time download or a vendored data blob a hundred times
//! the size of this file. What is here covers what people actually reach a
//! picker for; the search terms matter more than the count, so each entry
//! carries the words you would plausibly type.

use crate::item::{Action, Item};
use crate::providers::{Ctx, Provider, Trigger};

pub struct Emoji;

/// Glyph, canonical name, extra search keywords.
const EMOJI: &[(&str, &str, &str)] = &[
    ("😀", "grinning face", "smile happy grin"),
    ("😂", "face with tears of joy", "lol laugh crying funny"),
    ("🙂", "slightly smiling face", "smile polite"),
    ("😉", "winking face", "wink flirt"),
    ("😍", "smiling face with heart-eyes", "love adore crush"),
    ("😎", "smiling face with sunglasses", "cool sunglasses"),
    ("🤔", "thinking face", "hmm consider ponder"),
    ("😅", "grinning face with sweat", "relief nervous phew"),
    ("😭", "loudly crying face", "sob cry sad"),
    ("😡", "enraged face", "angry mad rage"),
    ("🥳", "partying face", "celebrate party birthday"),
    ("😴", "sleeping face", "sleep tired zzz"),
    ("🤯", "exploding head", "mind blown shocked"),
    ("🫠", "melting face", "melt awkward heat"),
    ("😬", "grimacing face", "awkward cringe yikes"),
    ("🙃", "upside-down face", "irony sarcasm"),
    ("👍", "thumbs up", "yes approve ok lgtm good"),
    ("👎", "thumbs down", "no disapprove bad"),
    ("👏", "clapping hands", "applause bravo well done"),
    ("🙏", "folded hands", "please thanks pray"),
    ("🤝", "handshake", "deal agree partner"),
    ("💪", "flexed biceps", "strong muscle"),
    ("🫡", "saluting face", "salute yes sir respect"),
    ("👋", "waving hand", "hello bye wave"),
    ("✍️", "writing hand", "write note"),
    ("🖖", "vulcan salute", "spock star trek"),
    ("❤️", "red heart", "love heart"),
    ("💔", "broken heart", "breakup sad"),
    ("🔥", "fire", "hot lit flame burn"),
    ("✨", "sparkles", "shiny magic new"),
    ("⭐", "star", "favourite rating"),
    ("💯", "hundred points", "perfect score agree"),
    ("🎉", "party popper", "celebrate congrats ship"),
    ("🚀", "rocket", "launch ship deploy fast"),
    ("💡", "light bulb", "idea insight"),
    ("⚡", "high voltage", "fast power electric"),
    ("🐛", "bug", "insect defect issue"),
    ("🔧", "wrench", "fix tool repair"),
    ("🔨", "hammer", "build tool"),
    ("⚙️", "gear", "settings config cog"),
    ("🧪", "test tube", "test experiment lab"),
    ("📦", "package", "box release parcel"),
    ("🗑️", "wastebasket", "delete trash remove"),
    ("📌", "pushpin", "pin important"),
    ("📝", "memo", "note write document"),
    ("📎", "paperclip", "attach clip"),
    ("🔍", "magnifying glass", "search find zoom"),
    ("🔒", "locked", "secure private lock"),
    ("🔑", "key", "password access"),
    ("🖥️", "desktop computer", "computer monitor screen"),
    ("💻", "laptop", "computer notebook"),
    ("⌨️", "keyboard", "type keys"),
    ("🖱️", "computer mouse", "pointer click"),
    ("📱", "mobile phone", "phone smartphone"),
    ("🌐", "globe with meridians", "web internet network"),
    ("📡", "satellite antenna", "signal network broadcast"),
    ("🔋", "battery", "power charge"),
    ("💾", "floppy disk", "save disk storage"),
    ("🗂️", "card index dividers", "files organise folder"),
    ("📁", "file folder", "folder directory"),
    ("📅", "calendar", "date schedule"),
    ("⏰", "alarm clock", "time alarm reminder"),
    ("⏳", "hourglass not done", "wait pending loading"),
    ("✅", "check mark button", "done yes complete pass"),
    ("❌", "cross mark", "no fail wrong error"),
    ("⚠️", "warning", "caution alert"),
    ("🚧", "construction", "wip work in progress"),
    ("🛑", "stop sign", "halt stop"),
    ("♻️", "recycling symbol", "recycle refactor reuse"),
    ("🏷️", "label", "tag version"),
    ("🔗", "link", "url chain"),
    ("📊", "bar chart", "graph stats metrics"),
    ("📈", "chart increasing", "growth up trend"),
    ("📉", "chart decreasing", "decline down trend"),
    ("☕", "hot beverage", "coffee tea break"),
    ("🍕", "pizza", "food lunch"),
    ("🌙", "crescent moon", "night dark sleep"),
    ("☀️", "sun", "day light sunny"),
    ("🌧️", "cloud with rain", "rain weather wet"),
    ("❄️", "snowflake", "snow cold winter freeze"),
    ("🐧", "penguin", "linux tux"),
    ("🦀", "crab", "rust ferris"),
    ("🐍", "snake", "python"),
    ("🐳", "whale", "docker container"),
    ("🎩", "top hat", "haskell formal"),
    ("👀", "eyes", "look watch review"),
    ("🧠", "brain", "think smart mind"),
    ("🎯", "bullseye", "target goal accurate"),
    ("🧩", "puzzle piece", "extension plugin part"),
    ("🪄", "magic wand", "magic auto generate"),
    ("🔮", "crystal ball", "predict future magic"),
];

impl Provider for Emoji {
    fn id(&self) -> &'static str {
        "emoji"
    }

    fn section(&self) -> &'static str {
        "Emoji"
    }

    fn trigger(&self) -> Trigger {
        Trigger::Prefix(":")
    }

    fn query(&self, _ctx: &Ctx, query: &str) -> Vec<Item> {
        let needle = query.trim().to_ascii_lowercase();
        EMOJI
            .iter()
            .filter(|(_, name, keywords)| {
                needle.is_empty() || name.contains(&needle) || keywords.contains(&needle)
            })
            .map(|(glyph, name, _)| {
                // The glyph leads the title so the list reads as a grid of
                // emoji rather than a wall of names.
                Item::new(
                    format!("emoji:{glyph}"),
                    format!("{glyph}  {name}"),
                    Action::Paste((*glyph).to_string()),
                )
                .accessory("Paste")
                .alt("Copy", Action::Copy((*glyph).to_string()))
            })
            .collect()
    }
}
