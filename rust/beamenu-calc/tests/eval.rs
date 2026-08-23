//! The evaluator: what evalexpr gives us, and what this crate adds on top.

use beamenu_calc::eval::{
    evaluate, expand_factorial, format_value, normalise_literals, AngleMode, Radix,
};

/// Floating point comparison with room for the last bit or two.
fn close(actual: f64, expected: f64) {
    assert!(
        (actual - expected).abs() < 1e-9,
        "expected {expected}, got {actual}"
    );
}

fn rad(expr: &str) -> f64 {
    evaluate(expr, AngleMode::Radians).expect("a result")
}

fn deg(expr: &str) -> f64 {
    evaluate(expr, AngleMode::Degrees).expect("a result")
}

// --- what evalexpr already handles ---

#[test]
fn arithmetic_follows_the_usual_precedence() {
    close(rad("2 + 3 * 4"), 14.0);
    close(rad("(2 + 3) * 4"), 20.0);
    close(rad("10 / 4"), 2.5);
    close(rad("7 % 3"), 1.0);
}

#[test]
fn the_caret_is_exponentiation_not_xor() {
    // rhai, the runner-up crate, reads ^ as bitwise xor; this one does not,
    // which is most of why it was chosen.
    close(rad("2^10"), 1024.0);
    close(rad("2^0.5"), std::f64::consts::SQRT_2);
}

#[test]
fn hex_and_binary_literals_parse() {
    close(rad("0xff"), 255.0);
    close(rad("0b1010"), 10.0);
    close(rad("0xff + 0b1010"), 265.0);
}

#[test]
fn unary_minus_binds_the_way_a_calculator_expects() {
    close(rad("-3 + 5"), 2.0);
    close(rad("-(3 + 5)"), -8.0);
}

// --- constants and functions this crate adds ---

#[test]
fn the_constants_are_bare_identifiers() {
    close(rad("pi"), std::f64::consts::PI);
    close(rad("e"), std::f64::consts::E);
    close(rad("tau"), std::f64::consts::TAU);
    close(rad("tau"), 2.0 * std::f64::consts::PI);
}

#[test]
fn functions_answer_to_their_bare_names() {
    // evalexpr namespaces its own under math::; a calculator may not ask its
    // user to type that.
    close(rad("sqrt(16)"), 4.0);
    close(rad("cbrt(27)"), 3.0);
    close(rad("ln(e)"), 1.0);
    close(rad("log10(1000)"), 3.0);
    close(rad("log2(1024)"), 10.0);
    close(rad("exp(0)"), 1.0);
    close(rad("abs(-4)"), 4.0);
    close(rad("floor(2.7)"), 2.0);
    close(rad("ceil(2.1)"), 3.0);
    close(rad("round(2.5)"), 3.0);
}

#[test]
fn the_hyperbolic_functions_are_available() {
    close(rad("sinh(0)"), 0.0);
    close(rad("cosh(0)"), 1.0);
    close(rad("tanh(0)"), 0.0);
}

#[test]
fn functions_compose_with_arithmetic() {
    close(rad("sqrt(16) + 2^3"), 12.0);
    close(rad("ln(exp(3))"), 3.0);
}

// --- angle mode ---

#[test]
fn radians_are_the_default_reading() {
    close(rad("sin(pi/2)"), 1.0);
    close(rad("cos(0)"), 1.0);
}

#[test]
fn degrees_convert_on_the_way_in() {
    close(deg("sin(90)"), 1.0);
    close(deg("cos(180)"), -1.0);
    close(deg("tan(45)"), 1.0);
}

#[test]
fn degrees_convert_on_the_way_out_of_the_inverses() {
    close(deg("asin(1)"), 90.0);
    close(deg("acos(0)"), 90.0);
    close(deg("atan(1)"), 45.0);
    close(rad("atan(1)"), std::f64::consts::FRAC_PI_4);
}

// --- factorial ---

#[test]
fn postfix_factorial_becomes_a_call_before_parsing() {
    assert_eq!(expand_factorial("5!"), "fact(5)");
    assert_eq!(expand_factorial("2 + 5!"), "2 + fact(5)");
    assert_eq!(expand_factorial("(2+3)!"), "fact((2+3))");
    assert_eq!(expand_factorial("5! + 3!"), "fact(5) + fact(3)");
}

#[test]
fn a_not_equals_operator_is_left_alone() {
    assert_eq!(expand_factorial("1 != 2"), "1 != 2");
}

#[test]
fn factorial_evaluates() {
    close(rad("5!"), 120.0);
    close(rad("0!"), 1.0);
    close(rad("(2+2)!"), 24.0);
    close(rad("3! + 4"), 10.0);
}

#[test]
fn factorial_refuses_what_it_cannot_answer_exactly() {
    assert!(evaluate("(-1)!", AngleMode::Radians).is_err());
    assert!(evaluate("2.5!", AngleMode::Radians).is_err());
    assert!(evaluate("200!", AngleMode::Radians).is_err());
}

// --- failure modes ---

#[test]
fn an_empty_expression_is_an_error_not_a_zero() {
    assert!(evaluate("", AngleMode::Radians).is_err());
    assert!(evaluate("   ", AngleMode::Radians).is_err());
}

#[test]
fn malformed_input_is_an_error() {
    assert!(evaluate("2 +", AngleMode::Radians).is_err());
    assert!(evaluate("(2 + 3", AngleMode::Radians).is_err());
    assert!(evaluate("nosuchfn(2)", AngleMode::Radians).is_err());
}

#[test]
fn dividing_by_zero_does_not_panic() {
    // Whether it errors or yields an infinity is evalexpr's call; not
    // panicking is this crate's.
    let _ = evaluate("1/0", AngleMode::Radians);
}

// --- formatting ---

#[test]
fn whole_numbers_lose_the_decimal_tail() {
    assert_eq!(format_value(4.0, Radix::Decimal), "4");
    assert_eq!(format_value(-12.0, Radix::Decimal), "-12");
    assert_eq!(format_value(1024.0, Radix::Decimal), "1024");
}

#[test]
fn fractions_keep_their_digits_without_trailing_zeros() {
    assert_eq!(format_value(2.5, Radix::Decimal), "2.5");
    assert_eq!(format_value(0.125, Radix::Decimal), "0.125");
}

#[test]
fn hex_and_binary_render_whole_numbers() {
    assert_eq!(format_value(255.0, Radix::Hex), "0xff");
    assert_eq!(format_value(10.0, Radix::Binary), "0b1010");
}

#[test]
fn a_fraction_falls_back_to_decimal_rather_than_truncating() {
    assert_eq!(format_value(2.5, Radix::Hex), "2.5");
    assert_eq!(format_value(2.5, Radix::Binary), "2.5");
}

// --- literal normalisation ---

#[test]
fn integer_literals_become_floats_so_division_does_not_truncate() {
    // evalexpr keeps 10 and 4 as integers, and integer division answers 2.
    // A calculator may not.
    assert_eq!(normalise_literals("10 / 4"), "10.0 / 4.0");
    close(rad("10 / 4"), 2.5);
    close(rad("1 / 3 * 3"), 1.0);
}

#[test]
fn radix_prefixes_are_converted_rather_than_left_as_integers() {
    assert_eq!(normalise_literals("0xff"), "255.0");
    assert_eq!(normalise_literals("0b1010"), "10.0");
    assert_eq!(normalise_literals("0o17"), "15.0");
    close(rad("0o17"), 15.0);
    close(rad("0xff / 2"), 127.5);
}

#[test]
fn identifiers_are_left_alone() {
    // log2 and log10 end in digits; a naive scan would maul them.
    assert_eq!(normalise_literals("log2(8)"), "log2(8.0)");
    assert_eq!(normalise_literals("log10(100)"), "log10(100.0)");
    assert_eq!(normalise_literals("pi"), "pi");
    assert_eq!(normalise_literals("e"), "e");
}

#[test]
fn existing_decimals_and_exponents_are_untouched() {
    assert_eq!(normalise_literals("2.5"), "2.5");
    assert_eq!(normalise_literals("1e3"), "1e3");
    assert_eq!(normalise_literals("1.5e-3"), "1.5e-3");
    close(rad("1e3"), 1000.0);
}
