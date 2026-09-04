// RGB <-> HLS conversion, ported verbatim from
// rust/wallpaper-tui/src/accent.rs (rgb_to_hls/hls_to_rgb), which is itself a
// faithful port of CPython's colorsys (HLS, parameter order h, l, s). Kept as
// a second port rather than a shared crate so the wallpaper port task can
// read the accent straight off tint/current.json without an FFI boundary;
// the two implementations are exercised against the same behaviour, not the
// same source.
//
// All three channels are 0-1 floats in both directions, matching colorsys
// and the Rust port rather than the 0-255 byte range Theme.qml's colours use.
.pragma library

// Rust's `%.rem_euclid(1.0)` always returns a non-negative remainder; JS's
// `%` keeps the sign of its left operand, so a second `+ 1.0 % 1.0` folds a
// negative result back into [0, 1) the way rem_euclid does.
function wrap(x) {
    return ((x % 1.0) + 1.0) % 1.0;
}

function rgbToHls(r, g, b) {
    const maxc = Math.max(r, g, b);
    const minc = Math.min(r, g, b);
    const l = (minc + maxc) / 2.0;
    if (minc === maxc)
        return { h: 0.0, l: l, s: 0.0 };

    const s = l <= 0.5 ? (maxc - minc) / (maxc + minc) : (maxc - minc) / (2.0 - maxc - minc);

    const rc = (maxc - r) / (maxc - minc);
    const gc = (maxc - g) / (maxc - minc);
    const bc = (maxc - b) / (maxc - minc);

    let h;
    if (r === maxc)
        h = bc - gc;
    else if (g === maxc)
        h = 2.0 + rc - bc;
    else
        h = 4.0 + gc - rc;

    return { h: wrap(h / 6.0), l: l, s: s };
}

// Port of colorsys._v, the hue -> channel-value helper hls_to_rgb calls three
// times a third of a turn apart.
function v(m1, m2, hue) {
    hue = wrap(hue);
    if (hue < 1.0 / 6.0)
        return m1 + (m2 - m1) * hue * 6.0;
    if (hue < 0.5)
        return m2;
    if (hue < 2.0 / 3.0)
        return m1 + (m2 - m1) * (2.0 / 3.0 - hue) * 6.0;
    return m1;
}

function hlsToRgb(h, l, s) {
    if (s === 0.0)
        return { r: l, g: l, b: l };

    const m2 = l <= 0.5 ? l * (1.0 + s) : l + s - l * s;
    const m1 = 2.0 * l - m2;

    return {
        r: v(m1, m2, h + 1.0 / 3.0),
        g: v(m1, m2, h),
        b: v(m1, m2, h - 1.0 / 3.0)
    };
}
