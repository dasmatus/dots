//! Calculator parsing, evaluation and unit conversion.

use beamenu::providers::calc::{convert, eval, format_result};

#[test]
fn evaluates_the_four_operators() {
    assert_eq!(eval("2+2"), Some(4.0));
    assert_eq!(eval("10-3"), Some(7.0));
    assert_eq!(eval("6*7"), Some(42.0));
    assert_eq!(eval("9/3"), Some(3.0));
}

#[test]
fn respects_precedence_and_parentheses() {
    assert_eq!(eval("2+3*4"), Some(14.0));
    assert_eq!(eval("(2+3)*4"), Some(20.0));
}

#[test]
fn power_is_right_associative() {
    // 2^(3^2) = 512, not (2^3)^2 = 64.
    assert_eq!(eval("2^3^2"), Some(512.0));
}

#[test]
fn handles_unary_minus() {
    assert_eq!(eval("-5"), Some(-5.0));
    assert_eq!(eval("3*-2"), Some(-6.0));
    assert_eq!(eval("(-4)+1"), Some(-3.0));
}

#[test]
fn division_by_zero_is_not_a_result() {
    assert_eq!(eval("1/0"), None);
    assert_eq!(eval("5%0"), None);
}

#[test]
fn rejects_malformed_input() {
    assert_eq!(eval(""), None);
    assert_eq!(eval("2+"), None);
    assert_eq!(eval("hello"), None);
    assert_eq!(eval("(2+3"), None);
}

#[test]
fn ignores_whitespace() {
    assert_eq!(eval("  2 +  2 "), Some(4.0));
}

#[test]
fn converts_within_a_unit_family() {
    let (value, unit) = convert("1 km to m").unwrap();
    assert!((value - 1000.0).abs() < 1e-6);
    assert_eq!(unit, "m");

    let (value, _) = convert("2 kg to g").unwrap();
    assert!((value - 2000.0).abs() < 1e-6);
}

#[test]
fn refuses_conversion_across_families() {
    assert!(convert("1 km to kg").is_none());
}

#[test]
fn converts_offset_temperature_scales() {
    let (value, _) = convert("100 c to f").unwrap();
    assert!((value - 212.0).abs() < 1e-6, "got {value}");

    let (value, _) = convert("32 f to c").unwrap();
    assert!(value.abs() < 1e-6, "got {value}");

    let (value, _) = convert("0 c to k").unwrap();
    assert!((value - 273.15).abs() < 1e-6, "got {value}");
}

#[test]
fn formats_whole_numbers_without_a_decimal_point() {
    assert_eq!(format_result(4.0), "4");
    assert_eq!(format_result(-7.0), "-7");
}

#[test]
fn formats_fractions_without_float_noise() {
    // 0.1 + 0.2 is 0.30000000000000004 in binary floating point.
    let sum = eval("0.1+0.2").unwrap();
    assert_eq!(format_result(sum), "0.3");
}

#[test]
fn reports_non_finite_results() {
    assert_eq!(format_result(f64::INFINITY), "undefined");
    assert_eq!(format_result(f64::NAN), "undefined");
}
