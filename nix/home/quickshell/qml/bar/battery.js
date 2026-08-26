// Pure mapping from a UPower reading to what the battery pill draws.
//
// Split out of Battery.qml so tests/qml can reach it: the component itself
// inherits Pill, reads Theme and binds UPower.displayDevice, none of which
// exist under qmltestrunner. Everything here is arithmetic over numbers, so
// the test needs no D-Bus, no compositor and no palette.
//
// Colours come back as Theme property names rather than colours, for the same
// reason — a `.pragma library` has no import of its own to reach Theme with.
.pragma library

// Quickshell normalises UPower's `Percentage` onto 0-1. waybar's {capacity}
// interpolated the raw 0-100 D-Bus property instead, so the scale back to
// whole percent happens here — without it every reading under 50% rounds to 0
// and the pill claims an empty battery.
function percent(fraction) {
    return Math.round((fraction === undefined || fraction === null ? 0 : fraction) * 100);
}

// Index into Battery.qml's eleven-glyph ramp.
function rampIndex(percent, length) {
    return Math.min(length - 1, Math.floor(percent / 10));
}

// waybar's states block: critical at 15, warning at 30, and charging overrides
// both because a charging battery at 8% is not an emergency.
function colorName(percent, charging) {
    if (charging)
        return "green";

    if (percent <= 15)
        return "red";

    if (percent <= 30)
        return "yellow";

    return "green";
}
