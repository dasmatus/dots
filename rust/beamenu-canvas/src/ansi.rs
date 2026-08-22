//! Basic ANSI SGR (colour, bold) handling for the `ui: "log"` pane.
//!
//! Recognises `ESC [ ... m` Select Graphic Rendition sequences for the eight
//! standard foreground colours (30-37), their bright counterparts (90-97),
//! bold (1) and reset (0 and 22/39). Every other escape sequence — cursor
//! movement (`ESC [ ... <letter>`), OSC window-title sequences
//! (`ESC ] ... BEL`), anything else starting with `ESC` — is stripped rather
//! than passed through, so the log pane never receives raw control bytes.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AnsiColor {
    Black,
    Red,
    Green,
    Yellow,
    Blue,
    Magenta,
    Cyan,
    White,
    BrightBlack,
    BrightRed,
    BrightGreen,
    BrightYellow,
    BrightBlue,
    BrightMagenta,
    BrightCyan,
    BrightWhite,
}

impl AnsiColor {
    /// The CSS class the generated stylesheet (`crate::theme::stylesheet`)
    /// defines a colour rule for.
    #[must_use]
    pub fn css_class(self) -> &'static str {
        match self {
            Self::Black => "ansi-fg-black",
            Self::Red => "ansi-fg-red",
            Self::Green => "ansi-fg-green",
            Self::Yellow => "ansi-fg-yellow",
            Self::Blue => "ansi-fg-blue",
            Self::Magenta => "ansi-fg-magenta",
            Self::Cyan => "ansi-fg-cyan",
            Self::White => "ansi-fg-white",
            Self::BrightBlack => "ansi-fg-bright-black",
            Self::BrightRed => "ansi-fg-bright-red",
            Self::BrightGreen => "ansi-fg-bright-green",
            Self::BrightYellow => "ansi-fg-bright-yellow",
            Self::BrightBlue => "ansi-fg-bright-blue",
            Self::BrightMagenta => "ansi-fg-bright-magenta",
            Self::BrightCyan => "ansi-fg-bright-cyan",
            Self::BrightWhite => "ansi-fg-bright-white",
        }
    }

    fn from_standard_code(offset: u32) -> Option<Self> {
        Some(match offset {
            0 => Self::Black,
            1 => Self::Red,
            2 => Self::Green,
            3 => Self::Yellow,
            4 => Self::Blue,
            5 => Self::Magenta,
            6 => Self::Cyan,
            7 => Self::White,
            _ => return None,
        })
    }

    fn from_bright_code(offset: u32) -> Option<Self> {
        Some(match offset {
            0 => Self::BrightBlack,
            1 => Self::BrightRed,
            2 => Self::BrightGreen,
            3 => Self::BrightYellow,
            4 => Self::BrightBlue,
            5 => Self::BrightMagenta,
            6 => Self::BrightCyan,
            7 => Self::BrightWhite,
            _ => return None,
        })
    }
}

/// A run of text sharing one style, in source order.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Span {
    pub text: String,
    pub fg: Option<AnsiColor>,
    pub bold: bool,
}

/// Parse `input`, stripping every escape sequence and keeping only
/// colour/bold state from `m`-terminated SGR sequences.
#[must_use]
pub fn parse(input: &str) -> Vec<Span> {
    let mut spans = Vec::new();
    let mut fg: Option<AnsiColor> = None;
    let mut bold = false;
    let mut current = String::new();
    let mut chars = input.chars().peekable();

    while let Some(c) = chars.next() {
        if c != '\u{1b}' {
            current.push(c);
            continue;
        }

        match chars.peek() {
            Some('[') => {
                chars.next();
                let mut param = String::new();
                let mut final_byte = None;
                while let Some(&next) = chars.peek() {
                    if next.is_ascii_digit() || next == ';' {
                        param.push(next);
                        chars.next();
                    } else {
                        final_byte = Some(next);
                        chars.next();
                        break;
                    }
                }
                if final_byte == Some('m') {
                    if !current.is_empty() {
                        spans.push(Span {
                            text: std::mem::take(&mut current),
                            fg,
                            bold,
                        });
                    }
                    apply_sgr(&param, &mut fg, &mut bold);
                }
                // Any other final byte (cursor movement, erase-line, …) is
                // dropped along with its parameters.
            }
            Some(']') => {
                // OSC: ESC ] ... (BEL | ESC \\)
                chars.next();
                loop {
                    match chars.next() {
                        None | Some('\u{7}') => break,
                        Some('\u{1b}') => {
                            if chars.peek() == Some(&'\\') {
                                chars.next();
                            }
                            break;
                        }
                        Some(_) => {}
                    }
                }
            }
            Some(_) => {
                // A two-character escape (ESC followed by one byte, e.g.
                // ESC 7 / ESC 8 save-restore-cursor) — drop both.
                chars.next();
            }
            None => {}
        }
    }

    if !current.is_empty() {
        spans.push(Span {
            text: current,
            fg,
            bold,
        });
    }

    spans
}

fn apply_sgr(param: &str, fg: &mut Option<AnsiColor>, bold: &mut bool) {
    if param.is_empty() {
        *fg = None;
        *bold = false;
        return;
    }
    // A plain iterator, not `for`, because 38/48 (extended colour) need to
    // pull their own payload params out of the same stream before the loop
    // continues — see below.
    let mut codes = param.split(';');
    while let Some(code) = codes.next() {
        let Ok(n) = code.parse::<u32>() else {
            continue;
        };
        match n {
            0 => {
                *fg = None;
                *bold = false;
            }
            1 => *bold = true,
            22 => *bold = false,
            39 => *fg = None,
            30..=37 => *fg = AnsiColor::from_standard_code(n - 30),
            90..=97 => *fg = AnsiColor::from_bright_code(n - 90),
            38 | 48 => {
                // Extended (256-colour / truecolor) foreground (38) or
                // background (48) — outside "basic colour/bold" scope, so
                // its payload is consumed as a UNIT and ignored rather than
                // left to fall through param-by-param. Falling through
                // would let a literal "0" or "1" inside the payload (e.g.
                // the green channel of `38;2;0;255;0`, or the palette index
                // of `38;5;0`) get misread as an unrelated reset/bold code.
                match codes.next().and_then(|mode| mode.parse::<u32>().ok()) {
                    Some(5) => {
                        codes.next(); // 256-colour palette index
                    }
                    Some(2) => {
                        codes.next(); // r
                        codes.next(); // g
                        codes.next(); // b
                    }
                    _ => {}
                }
            }
            // Background colours (40-47/100-107) and everything else fall
            // outside "basic colour/bold" and are intentionally ignored,
            // not stripped from the text — they simply don't change
            // rendering state.
            _ => {}
        }
    }
}

/// Escape `text` for safe inclusion in canvas-generated HTML.
#[must_use]
pub fn escape_html(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            _ => out.push(c),
        }
    }
    out
}

/// Render spans as the canvas-generated HTML the log pane appends — never
/// raw worker output, always escaped text inside classes the one stylesheet
/// defines.
#[must_use]
pub fn to_html(spans: &[Span]) -> String {
    let mut out = String::new();
    for span in spans {
        let mut classes = Vec::new();
        if let Some(fg) = span.fg {
            classes.push(fg.css_class());
        }
        if span.bold {
            classes.push("ansi-bold");
        }
        if classes.is_empty() {
            out.push_str(&escape_html(&span.text));
        } else {
            out.push_str("<span class=\"");
            out.push_str(&classes.join(" "));
            out.push_str("\">");
            out.push_str(&escape_html(&span.text));
            out.push_str("</span>");
        }
    }
    out
}
