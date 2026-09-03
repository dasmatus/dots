// Battery pill arithmetic.
//
// The regression this exists for: Quickshell's UPowerDevice.percentage is a
// 0-1 fraction, while waybar's {capacity} — which the pill was ported from —
// was UPower's raw 0-100 D-Bus property. Reading the fraction as if it were
// the raw value rounds every charge under 50% to 0 and every charge over it
// to 1, so the bar shows an empty red 0% pill on a half-full battery.
//
// Numbers here are real readings taken from
// /org/freedesktop/UPower/devices/DisplayDevice, not invented ones.
import QtQuick
import QtTest
import "../../nix/home/quickshell/qml/bar/battery.js" as Battery

TestCase {
    name: "Battery"

    function test_percent_scales_the_fraction_data() {
        return [
            { tag: "empty", fraction: 0.0, expected: 0 },
            { tag: "critical", fraction: 0.07, expected: 7 },
            { tag: "warning", fraction: 0.3, expected: 30 },
            { tag: "observed", fraction: 0.45, expected: 45 },
            { tag: "half", fraction: 0.5, expected: 50 },
            { tag: "high", fraction: 0.87, expected: 87 },
            { tag: "full", fraction: 1.0, expected: 100 }
        ];
    }

    function test_percent_scales_the_fraction(row) {
        compare(Battery.percent(row.fraction), row.expected);
    }

    // The pill binds `device?.percentage ?? 0`, so a shell that paints before
    // the D-Bus round trip lands passes undefined through here.
    function test_percent_treats_a_missing_reading_as_zero() {
        compare(Battery.percent(undefined), 0);
        compare(Battery.percent(null), 0);
    }

    function test_ramp_index_stays_in_bounds_data() {
        return [
            { tag: "empty", percent: 0, expected: 0 },
            { tag: "observed", percent: 45, expected: 4 },
            { tag: "full", percent: 100, expected: 10 }
        ];
    }

    function test_ramp_index_stays_in_bounds(row) {
        const index = Battery.rampIndex(row.percent, 11);
        compare(index, row.expected);
        verify(index >= 0 && index <= 10);
    }

    // waybar's thresholds still hold for the two warnings and for charging.
    // What changed is the healthy discharging case: it names no colour, so the
    // pill falls back to the bar's neutral fill and only a real state lights
    // up. An empty string here is the assertion, not a missing value.
    function test_color_follows_waybar_thresholds_data() {
        return [
            { tag: "critical", percent: 15, charging: false, expected: "red" },
            { tag: "just above critical", percent: 16, charging: false, expected: "yellow" },
            { tag: "warning", percent: 30, charging: false, expected: "yellow" },
            { tag: "just above warning", percent: 31, charging: false, expected: "" },
            { tag: "healthy", percent: 45, charging: false, expected: "" },
            { tag: "charging while critical", percent: 7, charging: true, expected: "green" }
        ];
    }

    function test_color_follows_waybar_thresholds(row) {
        compare(Battery.colorName(row.percent, row.charging), row.expected);
    }

    // Guards the pairing the bar depends on: a named colour means a bright
    // fill and therefore dark text, and no name means the neutral fill and
    // light text. Battery.qml and Network.qml both branch on exactly this,
    // and getting it backwards renders the percentage invisible.
    function test_healthy_and_charging_are_distinguishable() {
        compare(Battery.colorName(80, false), "", "a healthy discharging battery names no colour");
        compare(Battery.colorName(80, true), "green", "the same battery charging still names one");
        verify(Battery.colorName(10, false) !== "", "a critical battery must never fall through to neutral");
    }
}
