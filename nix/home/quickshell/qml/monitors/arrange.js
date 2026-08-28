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
// string. 0 and other falsy-but-real values (transform 0, the not-yet-typed
// case aside) must still count as set, which is why this isn't a plain
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
// an untouched field as absent instead of writing a bogus 0.
function numberField(text) {
    if (text === undefined || text === null)
        return undefined;
    const trimmed = String(text).trim();
    if (trimmed.length === 0)
        return undefined;
    const n = Number(trimmed);
    return Number.isNaN(n) ? undefined : n;
}

// numberField, truncated to an integer — the transform field's own type.
function integerField(text) {
    const n = numberField(text);
    return n === undefined ? undefined : Math.trunc(n);
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
