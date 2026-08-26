// Wallpaper accent extraction, ported from rust/wallpaper-tui/src/accent.rs's
// `try_extract_accent_internal` — the Internal backend only. The crate's
// default backend, Pywal, shells out to `wal` and stays a Rust-side concern;
// nothing here reproduces it.
//
// The algorithm: drop near-black/near-white/low-saturation pixels (they carry
// no usable hue), bucket what is left into 16 hue bins weighted by
// saturation, and pick the bucket with the largest saturation-weighted
// population. The winning bucket's mean hue is remapped onto a fixed
// lightness/saturation (0.62/0.55, with 0.40/0.78 companions) so the accent
// is always a usable UI colour regardless of how dark or washed out the
// source pixels were.
//
// `accentFrom` takes whatever RGBA quad stream the caller hands it. Rust's
// downsample to a 64x64 thumbnail (`DynamicImage::thumbnail`) is the canvas's
// job, not this function's — see tst_accent.qml's drawImage — because the
// bucket loop below only sums and counts; it is order- and size-independent
// and does not care how many pixels it is given or where they came from.
.pragma library
.import "../common/hls.js" as Hls

// Same fallback triple as config.rs's DEFAULT_ACCENT/_DARK/_LIGHT (the
// Tokyonight-blue family): the route out when every pixel gets filtered away
// (an all-black or all-white wallpaper) and no hue bucket ever gets a vote.
const DEFAULT_ACCENT = "#7aa2f7";
const DEFAULT_ACCENT_DARK = "#3b4261";
const DEFAULT_ACCENT_LIGHT = "#a9b1d6";

const BIN_COUNT = 16;

// accent.rs's pixel filter: lightness must sit in the mid range and
// saturation must clear a floor, or the pixel is near-black, near-white or
// already grey and would only dilute the hue vote.
function isUsable(l, s) {
    return l >= 0.1 && l <= 0.9 && s >= 0.2;
}

// config.rs's clamp_byte: `int(round(c * 255))` clamped to a byte. Math.round
// is Rust's round-half-away-from-zero here too — the remap below only ever
// produces values off `Hls.hlsToRgb`'s trig, which never land on an exact
// half, so the two round functions cannot disagree in practice.
function toByte(c) {
    const v = Math.round(c * 255);
    if (v < 0)
        return 0;
    if (v > 255)
        return 255;
    return v;
}

function toHex(r, g, b) {
    const pad = c => c.toString(16).padStart(2, "0");
    return "#" + pad(toByte(r)) + pad(toByte(g)) + pad(toByte(b));
}

// config.rs's hls_to_hex, so the winning accent and its dark/light
// companions all share the one rounding path.
function hlsToHex(h, l, s) {
    const rgb = Hls.hlsToRgb(h, l, s);
    return toHex(rgb.r, rgb.g, rgb.b);
}

// `pixels` is an RGBA quad stream — a Uint8ClampedArray straight off
// Canvas's getImageData, or anything else shaped like one. Four bytes per
// pixel; alpha is ignored, since the source thumbnail is always opaque.
function accentFrom(pixels) {
    const weight = new Float64Array(BIN_COUNT);
    const hueSum = new Float64Array(BIN_COUNT);
    const count = new Uint32Array(BIN_COUNT);

    for (let i = 0; i < pixels.length; i += 4) {
        const hls = Hls.rgbToHls(pixels[i] / 255, pixels[i + 1] / 255, pixels[i + 2] / 255);
        if (!isUsable(hls.l, hls.s))
            continue;

        let bin = Math.floor(hls.h * BIN_COUNT);
        if (bin >= BIN_COUNT)
            bin = BIN_COUNT - 1;

        weight[bin] += hls.s;
        hueSum[bin] += hls.h;
        count[bin] += 1;
    }

    // Rust's `Iterator::max_by` returns the LAST of equally-maximum
    // elements, not the first — `>=` here (not `>`) is what keeps a tie
    // resolving to the same bin the Rust port would pick.
    let best = -1;
    for (let bin = 0; bin < BIN_COUNT; bin++) {
        if (count[bin] > 0 && (best === -1 || weight[bin] >= weight[best]))
            best = bin;
    }

    if (best === -1)
        return { accent: DEFAULT_ACCENT, dark: DEFAULT_ACCENT_DARK, light: DEFAULT_ACCENT_LIGHT };

    const hue = hueSum[best] / count[best];
    return {
        accent: hlsToHex(hue, 0.62, 0.55),
        dark: hlsToHex(hue, 0.40, 0.55),
        light: hlsToHex(hue, 0.78, 0.55)
    };
}
