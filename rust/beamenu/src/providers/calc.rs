//! Inline calculator, reached with a leading `=`.
//!
//! A shunting-yard parser rather than a dependency: the grammar a launcher
//! calculator needs is four operators, unary minus, parentheses, a power
//! operator and a handful of unit conversions. That is a few hundred lines
//! and no supply chain.
//!
//! Conversions use the `<value> <unit> to <unit>` form, which is what Raycast
//! accepts and what reads naturally when you are typing fast.

use crate::item::{Action, Item};
use crate::providers::{Ctx, Provider, Trigger};

pub struct Calc;

#[derive(Debug, Clone, Copy, PartialEq)]
enum Token {
    Num(f64),
    Op(char),
    LParen,
    RParen,
}

fn tokenize(input: &str) -> Option<Vec<Token>> {
    let mut tokens = Vec::new();
    let chars: Vec<char> = input.chars().collect();
    let mut i = 0;

    while i < chars.len() {
        let c = chars[i];
        if c.is_whitespace() {
            i += 1;
        } else if c.is_ascii_digit() || c == '.' {
            let start = i;
            while i < chars.len() && (chars[i].is_ascii_digit() || chars[i] == '.') {
                i += 1;
            }
            let text: String = chars[start..i].iter().collect();
            tokens.push(Token::Num(text.parse().ok()?));
        } else if matches!(c, '+' | '-' | '*' | '/' | '%' | '^') {
            // A leading or post-operator minus is unary: rewrite `-x` as
            // `(0 - x)` so the shunting yard never sees a prefix operator.
            let unary =
                c == '-' && matches!(tokens.last(), None | Some(Token::Op(_) | Token::LParen));
            if unary {
                tokens.push(Token::LParen);
                tokens.push(Token::Num(0.0));
                tokens.push(Token::Op('-'));
                // The closing paren is appended once the operand is read, which
                // for a literal is the very next token.
                i += 1;
                let start = i;
                while i < chars.len() && (chars[i].is_ascii_digit() || chars[i] == '.') {
                    i += 1;
                }
                if start == i {
                    return None;
                }
                let text: String = chars[start..i].iter().collect();
                tokens.push(Token::Num(text.parse().ok()?));
                tokens.push(Token::RParen);
            } else {
                tokens.push(Token::Op(c));
                i += 1;
            }
        } else if c == '(' {
            tokens.push(Token::LParen);
            i += 1;
        } else if c == ')' {
            tokens.push(Token::RParen);
            i += 1;
        } else {
            return None;
        }
    }

    (!tokens.is_empty()).then_some(tokens)
}

fn precedence(op: char) -> u8 {
    match op {
        '+' | '-' => 1,
        '*' | '/' | '%' => 2,
        '^' => 3,
        _ => 0,
    }
}

fn apply(op: char, a: f64, b: f64) -> Option<f64> {
    Some(match op {
        '+' => a + b,
        '-' => a - b,
        '*' => a * b,
        '/' => {
            if b == 0.0 {
                return None;
            }
            a / b
        }
        '%' => {
            if b == 0.0 {
                return None;
            }
            a % b
        }
        '^' => a.powf(b),
        _ => return None,
    })
}

/// Evaluate an arithmetic expression, or `None` if it does not parse.
#[must_use]
pub fn eval(input: &str) -> Option<f64> {
    fn reduce(values: &mut Vec<f64>, op: char) -> Option<()> {
        let b = values.pop()?;
        let a = values.pop()?;
        values.push(apply(op, a, b)?);
        Some(())
    }

    let tokens = tokenize(input)?;
    let mut values: Vec<f64> = Vec::new();
    let mut ops: Vec<Token> = Vec::new();

    for token in tokens {
        match token {
            Token::Num(n) => values.push(n),
            Token::LParen => ops.push(token),
            Token::RParen => loop {
                match ops.pop() {
                    Some(Token::Op(op)) => reduce(&mut values, op)?,
                    Some(Token::LParen) => break,
                    _ => return None,
                }
            },
            Token::Op(op) => {
                // `^` is right-associative, so an equal-precedence operator on
                // the stack must not be reduced first.
                while let Some(Token::Op(top)) = ops.last().copied() {
                    let should_reduce = if op == '^' {
                        precedence(top) > precedence(op)
                    } else {
                        precedence(top) >= precedence(op)
                    };
                    if !should_reduce {
                        break;
                    }
                    ops.pop();
                    reduce(&mut values, top)?;
                }
                ops.push(Token::Op(op));
            }
        }
    }

    while let Some(op) = ops.pop() {
        match op {
            Token::Op(op) => reduce(&mut values, op)?,
            _ => return None,
        }
    }

    (values.len() == 1).then(|| values[0])
}

/// Unit name and its size in the family's base unit.
const UNITS: &[(&str, &str, f64)] = &[
    // length, base metre
    ("mm", "length", 0.001),
    ("cm", "length", 0.01),
    ("m", "length", 1.0),
    ("km", "length", 1000.0),
    ("in", "length", 0.0254),
    ("ft", "length", 0.3048),
    ("yd", "length", 0.9144),
    ("mi", "length", 1609.344),
    // mass, base kilogram
    ("g", "mass", 0.001),
    ("kg", "mass", 1.0),
    ("lb", "mass", 0.453_592_37),
    ("oz", "mass", 0.028_349_523_125),
    ("st", "mass", 6.350_293_18),
    // data, base byte
    ("b", "data", 1.0),
    ("kb", "data", 1024.0),
    ("mb", "data", 1024.0 * 1024.0),
    ("gb", "data", 1024.0 * 1024.0 * 1024.0),
    ("tb", "data", 1024.0 * 1024.0 * 1024.0 * 1024.0),
    // duration, base second
    ("s", "time", 1.0),
    ("min", "time", 60.0),
    ("h", "time", 3600.0),
    ("d", "time", 86400.0),
    ("wk", "time", 604_800.0),
];

fn unit(name: &str) -> Option<(&'static str, f64)> {
    let lower = name.to_ascii_lowercase();
    UNITS
        .iter()
        .find(|(n, ..)| *n == lower)
        .map(|(_, family, factor)| (*family, *factor))
}

/// Convert `<value> <from> to <to>`, or `None` if that is not what this is.
///
/// Temperature is handled separately from [`UNITS`] because Celsius,
/// Fahrenheit and Kelvin are offset scales, not multiples of a base unit.
#[must_use]
pub fn convert(input: &str) -> Option<(f64, String)> {
    let (lhs, to) = input.split_once(" to ")?;
    let lhs = lhs.trim();
    let to = to.trim();

    let split = lhs.find(|c: char| c.is_alphabetic())?;
    let (value_text, from) = lhs.split_at(split);
    let value: f64 = value_text.trim().parse().ok()?;
    let from = from.trim();

    if let Some(result) = convert_temperature(value, from, to) {
        return Some((result, to.to_string()));
    }

    let (from_family, from_factor) = unit(from)?;
    let (to_family, to_factor) = unit(to)?;
    (from_family == to_family).then(|| (value * from_factor / to_factor, to.to_string()))
}

fn convert_temperature(value: f64, from: &str, to: &str) -> Option<f64> {
    let from = from.to_ascii_lowercase();
    let to = to.to_ascii_lowercase();
    let kelvin = match from.as_str() {
        "c" | "celsius" => value + 273.15,
        "f" | "fahrenheit" => (value - 32.0) * 5.0 / 9.0 + 273.15,
        "k" | "kelvin" => value,
        _ => return None,
    };
    Some(match to.as_str() {
        "c" | "celsius" => kelvin - 273.15,
        "f" | "fahrenheit" => (kelvin - 273.15) * 9.0 / 5.0 + 32.0,
        "k" | "kelvin" => kelvin,
        _ => return None,
    })
}

/// Render a result without a trailing `.0` on whole numbers, and without
/// float noise like `0.30000000000000004` on the rest.
#[must_use]
pub fn format_result(value: f64) -> String {
    if !value.is_finite() {
        return "undefined".to_string();
    }
    if (value - value.round()).abs() < 1e-9 && value.abs() < 1e15 {
        // Guarded by the 1e15 bound just tested, which is well inside i64.
        #[allow(clippy::cast_possible_truncation)]
        let whole = value.round() as i64;
        return format!("{whole}");
    }
    let rounded = format!("{value:.10}");
    let trimmed = rounded.trim_end_matches('0').trim_end_matches('.');
    trimmed.to_string()
}

impl Provider for Calc {
    fn id(&self) -> &'static str {
        "calc"
    }

    fn section(&self) -> &'static str {
        "Calculator"
    }

    fn trigger(&self) -> Trigger {
        Trigger::Prefix("=".to_string())
    }

    fn query(&self, _ctx: &Ctx, query: &str) -> Vec<Item> {
        let query = query.trim();
        if query.is_empty() {
            return Vec::new();
        }

        let (value, suffix) = match convert(query) {
            Some((value, unit)) => (value, format!(" {unit}")),
            None => match eval(query) {
                Some(value) => (value, String::new()),
                None => return Vec::new(),
            },
        };

        let text = format!("{}{}", format_result(value), suffix);
        vec![Item::new("calc:result", text.clone(), Action::Copy(text))
            .subtitle(query)
            .accessory("Copy")]
    }
}
