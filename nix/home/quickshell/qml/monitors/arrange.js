// Arrange.qml's own pure logic: the canvas <-> real-pixel coordinate
// transform, edge snapping, the overrides.json merge, and the handful of
// edit-form field parsers — kept out of the component so
// tests/qml/tst_arrange.qml can exercise the coordinate math and the merge
// directly, with no live PanelWindow, MouseArea drag, or Hyprland singleton
// anywhere near the test.
.pragma library

// Real pixel geometry -> canvas-pixel offset/scale that fits every monitor's
// bounding box within canvasWidth x canvasHeight, with a 0.9 margin so an
// edge monitor's rectangle never touches the panel's own border.
function fitTransform(monitors, canvasWidth, canvasHeight) {
    if (monitors.length === 0)
        return { originX: 0, originY: 0, scale: 1 };

    let minX = monitors[0].x;
    let minY = monitors[0].y;
    let maxX = monitors[0].x + monitors[0].width;
    let maxY = monitors[0].y + monitors[0].height;
    for (const m of monitors) {
        minX = Math.min(minX, m.x);
        minY = Math.min(minY, m.y);
        maxX = Math.max(maxX, m.x + m.width);
        maxY = Math.max(maxY, m.y + m.height);
    }

    const spanX = Math.max(1, maxX - minX);
    const spanY = Math.max(1, maxY - minY);
    const scale = Math.min(canvasWidth / spanX, canvasHeight / spanY) * 0.9;
    return { originX: minX, originY: minY, scale: scale };
}

function toScreen(monitor, transform) {
    return {
        x: (monitor.x - transform.originX) * transform.scale,
        y: (monitor.y - transform.originY) * transform.scale
    };
}

// Inverse of toScreen, rounded to a whole pixel — Hyprland's own `position`
// field is always integral.
function toWorldPosition(itemX, itemY, transform) {
    const wx = Math.round(itemX / transform.scale + transform.originX);
    const wy = Math.round(itemY / transform.scale + transform.originY);
    return `${wx}x${wy}`;
}

// Inverse of toWorldPosition: the edit form's typed "XxY" position text back
// into real-pixel coordinates, or null when the text is not that shape.
// Arrange.qml uses this to move the dragged rectangle to match a typed
// position, so the rectangle stays the one place a monitor's position
// actually lives instead of the drag and the form disagreeing about it.
function parseWorldPosition(text) {
    const match = /^\s*(-?\d+)x(-?\d+)\s*$/.exec(text || "");
    if (!match)
        return null;
    return { x: Number(match[1]), y: Number(match[2]) };
}

// The nearest value in targets within threshold of value, or value
// unchanged when nothing is close enough.
function closestWithin(value, targets, threshold) {
    let best = value;
    let bestDist = threshold;
    for (const t of targets) {
        const dist = Math.abs(value - t);
        if (dist <= bestDist) {
            best = t;
            bestDist = dist;
        }
    }
    return best;
}

// Snap one dragged rectangle's x/y to whichever neighbour edge (of every
// OTHER rectangle currently on the canvas) is within threshold —
// left-to-left, left-to-right, top-to-top and top-to-bottom, so two
// monitors dragged flush against each other land exactly flush rather than
// a pixel or two off. Axes snap independently: a drag that only lines up
// vertically still gets that snap even if the horizontal position stays
// free. `rect`/`others` are plain {x, y, width, height} objects (or, from
// Arrange.qml, the live delegate Items themselves — this reads and returns
// only x/y, so either works).
function snappedPosition(rect, others, threshold) {
    const xTargets = [];
    const yTargets = [];
    for (const other of others) {
        if (other === rect)
            continue;
        xTargets.push(other.x, other.x + other.width, other.x - rect.width, other.x + other.width - rect.width);
        yTargets.push(other.y, other.y + other.height, other.y - rect.height, other.y + other.height - rect.height);
    }
    return {
        x: closestWithin(rect.x, xTargets, threshold),
        y: closestWithin(rect.y, yTargets, threshold)
    };
}

// Every settable override field besides name/description, which the edit
// form shows read-only — overrides.rs's own schema, kept as one list so
// mergedOverrides and the field parsers below all agree on it.
const SETTABLE_FIELDS = ["resolution", "position", "scale", "transform", "vrr"];

// A field counts as set by the form when it is neither absent nor an empty
// string. 0 must still count as set (transform 0 is a real, meaningful
// value, not "the form left this blank"), which is why this isn't a plain
// truthiness check — applyOverrides in plan.js already relies on the same
// distinction the other direction, testing each field with `!= null`.
function isSet(value) {
    if (value === undefined || value === null)
        return false;
    if (typeof value === "string" && value.length === 0)
        return false;
    return true;
}

// Text -> number for the scale/transform fields, or undefined for blank or
// unparseable text. undefined rather than NaN or 0 so isSet() above treats
// an untouched field as absent instead of writing a bogus 0. Number.isFinite
// rather than Number.isNaN: a bare Number.isNaN check lets "Infinity" and
// "-Infinity" through as real values, and JSON.stringify renders either as
// `null` — the exact thing this function exists to keep out of an entry.
function numberField(text) {
    if (text === undefined || text === null)
        return undefined;
    const trimmed = String(text).trim();
    if (trimmed.length === 0)
        return undefined;
    const n = Number(trimmed);
    return Number.isFinite(n) ? n : undefined;
}

// numberField, truncated to an integer — used as-is for a generic integer
// field; transform's own narrower 0-7 range is enforced by parseTransform
// below, not here.
function integerField(text) {
    const n = numberField(text);
    return n === undefined ? undefined : Math.trunc(n);
}

// The vrr enum overrides.json allows, exactly. Anything else — a typo like
// "on", a stray label copy-pasted in, blank text — becomes undefined rather
// than a value written raw: overrides.rs's own parse_vrr had the same
// contract (trim, lowercase, then match), so this lowercases too — a field
// this merge-only ever adds to but never clears (see mergedOverrides' own
// comment) makes a case mismatch worse than an ordinary typo: typing "Off"
// over an existing "left" would silently drop the field and leave "left" in
// place, with no error and the value still showing off|left|right|auto in
// the label as if it worked. Without this check at all, plan.js's own
// vrrToken would treat an unrecognised string as "off" with no explicit
// token, so a typo'd override would sit in the file looking correct while
// quietly never taking effect.
const VRR_VALUES = ["off", "left", "right", "auto"];

function parseVrr(text) {
    const trimmed = (text || "").trim().toLowerCase();
    return VRR_VALUES.includes(trimmed) ? trimmed : undefined;
}

// Transform, restricted to Hyprland's own 0-7 range — overrides.rs's own
// s.parse::<u8>().ok() plus this schema's tighter bound (u8 alone would
// still let 200 through). An out-of-range value is worth dropping rather
// than forwarding: Hyprland rejects a bad transform outright and takes the
// whole monitor's config down with it, not just this one field.
function parseTransform(text) {
    const n = integerField(text);
    return (n !== undefined && n >= 0 && n <= 7) ? n : undefined;
}

// Every currently-connected monitor's dragged position, merged over
// whatever overrides.json already held, widened to also carry whichever of
// the other four settable fields the edit form set for the
// currently-selected monitor. A name-matched entry keeps its other fields (a
// resolution or vrr an earlier, hand-written override set, or a field this
// save's form left untouched) and only the fields present on `item` are
// replaced; an entry for a monitor not on the canvas right now (unplugged
// since the last edit) is left alone rather than dropped. `items` is
// `[{name, position, resolution?, scale?, transform?, vrr?}]` — position
// always present (rendered as "XxY" by toWorldPosition), the rest present
// only when the form actually set them, already carrying the types
// overrides.json wants (see numberField/integerField above).
//
// This one-way merge means a blank field can never clear a value an earlier
// save already wrote — isSet() treats "" the same as "the form never
// touched this", so an existing entry's field survives untouched rather
// than being erased. That is deliberate (see isSet()'s own comment), but it
// means the only way to actually remove a field, short of hand-editing the
// JSON, is Arrange.qml's reset(), which drops the whole entry rather than
// one field at a time.
function mergedOverrides(existingRoot, items) {
    const byName = {};
    const existingEntries = (existingRoot && existingRoot.entries) || [];
    for (const entry of existingEntries) {
        if (entry.name)
            byName[entry.name] = Object.assign({}, entry);
    }
    for (const item of items) {
        const entry = byName[item.name] || { name: item.name };
        for (const field of SETTABLE_FIELDS) {
            if (isSet(item[field]))
                entry[field] = item[field];
        }
        byName[item.name] = entry;
    }
    return { entries: Object.values(byName) };
}
