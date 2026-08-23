//! Expression evaluation.
//!
//! The grammar, precedence, tokenizer, `0x`/`0b` literals and `^` as
//! exponentiation all come from evalexpr. What this module adds is what a
//! calculator needs and a general expression crate does not ship: maths
//! functions under their bare names, the usual constants, an angle mode, and
//! factorial.

use std::f64::consts;
use std::fmt::Write as _;

use evalexpr::{
    eval_number_with_context, ContextWithMutableFunctions, ContextWithMutableVariables,
    DefaultNumericTypes, EvalexprError, Function, HashMapContext, Value,
};
use miette::{miette, LabeledSpan, Result};

/// Whether the trigonometric functions read and return degrees or radians.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum AngleMode {
    #[default]
    Radians,
    Degrees,
}

impl AngleMode {
    /// Convert an argument on its way into a trigonometric function.
    fn to_radians(self, value: f64) -> f64 {
        match self {
            Self::Radians => value,
            Self::Degrees => value.to_radians(),
        }
    }

    /// Convert a result on its way out of an inverse trigonometric function.
    fn to_display(self, value: f64) -> f64 {
        match self {
            Self::Radians => value,
            Self::Degrees => value.to_degrees(),
        }
    }
}

/// The base a result is rendered in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Radix {
    #[default]
    Decimal,
    Hex,
    Binary,
}

/// A plain real-valued function of one real argument.
type MathFn = fn(f64) -> f64;

/// Every function here works in f64, so they all share one numeric type.
type CalcFunction = Function<DefaultNumericTypes>;

/// Wrap a plain `f64 -> f64` as an evalexpr function.
fn unary(f: impl Fn(f64) -> f64 + Send + Sync + Clone + 'static) -> CalcFunction {
    Function::new(move |arg| Ok(Value::Float(f(arg.as_number()?))))
}

/// Gamma-free factorial: exact for the non-negative integers a calculator is
/// asked for, and an error for anything else rather than a silently wrong
/// number.
fn factorial(value: f64) -> std::result::Result<f64, String> {
    if value < 0.0 || (value - value.round()).abs() > f64::EPSILON {
        return Err(format!(
            "factorial needs a non-negative whole number, got {value}"
        ));
    }
    if value > 170.0 {
        return Err(format!("{value}! overflows a double"));
    }

    let mut acc = 1.0f64;
    let mut i = 2.0f64;
    while i <= value {
        acc *= i;
        i += 1.0;
    }
    Ok(acc)
}

/// The evaluation context: constants, then every function under its bare name.
fn context(angle: AngleMode) -> Result<HashMapContext> {
    let mut ctx = HashMapContext::new();

    for (name, value) in [("pi", consts::PI), ("e", consts::E), ("tau", consts::TAU)] {
        ctx.set_value(name.into(), Value::Float(value))
            .map_err(|err| miette!("could not define {name}: {err}"))?;
    }

    let trig: [(&str, MathFn); 3] = [("sin", f64::sin), ("cos", f64::cos), ("tan", f64::tan)];
    let inverse: [(&str, MathFn); 3] = [
        ("asin", f64::asin),
        ("acos", f64::acos),
        ("atan", f64::atan),
    ];
    let plain: [(&str, MathFn); 12] = [
        ("sinh", f64::sinh),
        ("cosh", f64::cosh),
        ("tanh", f64::tanh),
        ("ln", f64::ln),
        ("log2", f64::log2),
        ("log10", f64::log10),
        ("exp", f64::exp),
        ("sqrt", f64::sqrt),
        ("cbrt", f64::cbrt),
        ("abs", f64::abs),
        ("floor", f64::floor),
        ("ceil", f64::ceil),
    ];

    let mut define = |name: &str, function: CalcFunction| -> Result<()> {
        ctx.set_function(name.into(), function)
            .map_err(|err| miette!("could not define {name}(): {err}"))
    };

    for (name, f) in trig {
        define(name, unary(move |x| f(angle.to_radians(x))))?;
    }
    for (name, f) in inverse {
        define(name, unary(move |x| angle.to_display(f(x))))?;
    }
    for (name, f) in plain {
        define(name, unary(f))?;
    }

    // round() is not in `plain`: f64::round breaks ties away from zero, which
    // is what a calculator should do, but it needs no angle handling either.
    define("round", unary(f64::round))?;

    define(
        "fact",
        Function::new(|arg| {
            let value = arg.as_number()?;
            factorial(value)
                .map(Value::Float)
                .map_err(EvalexprError::CustomMessage)
        }),
    )?;

    Ok(ctx)
}

/// Rewrite every numeric literal into float form.
///
/// evalexpr keeps integer literals as integers, and integer division
/// truncates, so `10/4` answers 2. That is defensible in a scripting language
/// and wrong in a calculator. Normalising the literals up front makes every
/// operator work in f64 without touching the grammar.
///
/// Radix prefixes are converted here rather than left to evalexpr, so `0x`,
/// `0b` and `0o` all keep working once they are no longer integers. Identifiers
/// are skipped whole, so `log2` and `0b`-lookalikes inside names survive.
#[must_use]
pub fn normalise_literals(expr: &str) -> String {
    let chars: Vec<char> = expr.chars().collect();
    let mut out = String::with_capacity(expr.len() + 8);
    let mut i = 0;

    while i < chars.len() {
        let c = chars[i];

        if c.is_alphabetic() || c == '_' {
            while i < chars.len() && (chars[i].is_alphanumeric() || chars[i] == '_') {
                out.push(chars[i]);
                i += 1;
            }
            continue;
        }

        if !c.is_ascii_digit() {
            out.push(c);
            i += 1;
            continue;
        }

        if c == '0' && i + 1 < chars.len() {
            let (radix, prefix_len) = match chars[i + 1] {
                'x' | 'X' => (16, 2),
                'b' | 'B' => (2, 2),
                'o' | 'O' => (8, 2),
                _ => (10, 0),
            };

            if radix != 10 {
                let start = i + prefix_len;
                let mut j = start;
                while j < chars.len() && chars[j].is_digit(radix) {
                    j += 1;
                }
                if j > start {
                    let digits: String = chars[start..j].iter().collect();
                    if let Ok(value) = u64::from_str_radix(&digits, radix) {
                        #[allow(clippy::cast_precision_loss)]
                        let _ = write!(out, "{:.1}", value as f64);
                        i = j;
                        continue;
                    }
                }
            }
        }

        let start = i;
        while i < chars.len() && chars[i].is_ascii_digit() {
            i += 1;
        }
        let mut fractional = false;
        if i < chars.len() && chars[i] == '.' {
            fractional = true;
            i += 1;
            while i < chars.len() && chars[i].is_ascii_digit() {
                i += 1;
            }
        }
        // An `e` only starts an exponent when digits actually follow it;
        // otherwise it is the constant, and `2 e` is evalexpr's to reject.
        if i < chars.len() && (chars[i] == 'e' || chars[i] == 'E') {
            let mut j = i + 1;
            if j < chars.len() && (chars[j] == '+' || chars[j] == '-') {
                j += 1;
            }
            if j < chars.len() && chars[j].is_ascii_digit() {
                fractional = true;
                i = j;
                while i < chars.len() && chars[i].is_ascii_digit() {
                    i += 1;
                }
            }
        }

        let literal: String = chars[start..i].iter().collect();
        out.push_str(&literal);
        if !fractional {
            out.push_str(".0");
        }
    }

    out
}

/// Rewrite postfix `!` into a `fact(...)` call.
///
/// evalexpr's grammar is fixed prefix and infix, with no postfix operator and
/// no way to register one, so `5!` has to become `fact(5)` before the parser
/// ever sees it. `!=` is left alone, and the operand is whatever immediately
/// precedes the `!`: a parenthesised group, or a run of digits and letters.
#[must_use]
pub fn expand_factorial(expr: &str) -> String {
    let chars: Vec<char> = expr.chars().collect();
    let mut out: Vec<char> = Vec::with_capacity(chars.len());
    let mut i = 0;

    while i < chars.len() {
        if chars[i] != '!' || chars.get(i + 1) == Some(&'=') {
            out.push(chars[i]);
            i += 1;
            continue;
        }

        let start = match out.last() {
            Some(')') => {
                let mut depth = 0i32;
                let mut j = out.len();
                loop {
                    j -= 1;
                    match out[j] {
                        ')' => depth += 1,
                        '(' => {
                            depth -= 1;
                            if depth == 0 {
                                break;
                            }
                        }
                        _ => {}
                    }
                    if j == 0 {
                        break;
                    }
                }
                j
            }
            Some(c) if c.is_alphanumeric() || *c == '.' => {
                let mut j = out.len();
                while j > 0 && (out[j - 1].is_alphanumeric() || out[j - 1] == '.') {
                    j -= 1;
                }
                j
            }
            // A bare `!` with nothing to apply to: leave it for evalexpr to
            // reject, rather than inventing an operand.
            _ => {
                out.push('!');
                i += 1;
                continue;
            }
        };

        let operand: String = out.drain(start..).collect();
        out.extend("fact(".chars());
        out.extend(operand.chars());
        out.push(')');
        i += 1;
    }

    out.into_iter().collect()
}

/// Evaluate `expr`, returning the numeric result.
///
/// # Errors
/// Returns a diagnostic labelling the whole expression when it does not parse
/// or does not evaluate. evalexpr's errors carry no position, so there is
/// nothing narrower to point at honestly.
pub fn evaluate(expr: &str, angle: AngleMode) -> Result<f64> {
    let trimmed = expr.trim();
    if trimmed.is_empty() {
        return Err(miette!("nothing to evaluate"));
    }

    let ctx = context(angle)?;
    let prepared = expand_factorial(&normalise_literals(trimmed));
    tracing::debug!(
        expression = trimmed,
        prepared = prepared.as_str(),
        "evaluating"
    );

    eval_number_with_context(&prepared, &ctx).map_err(|err| {
        miette!(
            labels = vec![LabeledSpan::at(0..trimmed.len(), err.to_string())],
            "could not evaluate this expression"
        )
        .with_source_code(trimmed.to_string())
    })
}

/// Render a result for display.
///
/// Whole numbers lose the decimal tail, matching what the launcher's inline
/// calculator already does. Hex and binary only apply to whole numbers; a
/// fraction falls back to decimal rather than silently truncating.
#[must_use]
pub fn format_value(value: f64, radix: Radix) -> String {
    let whole = (value - value.round()).abs() < 1e-9 && value.abs() < 1e15;

    if whole {
        #[allow(clippy::cast_possible_truncation)]
        let as_int = value.round() as i64;
        return match radix {
            Radix::Decimal => as_int.to_string(),
            Radix::Hex => format!("{as_int:#x}"),
            Radix::Binary => format!("{as_int:#b}"),
        };
    }

    let rendered = format!("{value:.10}");
    rendered
        .trim_end_matches('0')
        .trim_end_matches('.')
        .to_string()
}
