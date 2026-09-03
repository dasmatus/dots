// Usage-based ranking for the launcher's ambient (unprefixed) query path,
// replacing the plain prefix-then-alphabetical sort Launcher.qml used to run
// inline. Pulled out for the same reason pills.js and status.js were: pure
// score arithmetic over plain objects, so tests/qml/tst_rank.qml can drive it
// with synthetic records and fixed timestamps instead of a live launcher, a
// FileView-backed frecency.json, and the wall clock.
//
// Frecency here is stored as (score, last) rather than as a literal log of
// recent uses, and it decays lazily: a record only remembers its own score
// as of its own `last` write, and every reader — order(), evictOverCap() —
// recomputes that score decayed forward to `now` on demand. Writers (bump())
// do the opposite: decay to `now` once, add the new use, and store the sum
// as the new baseline. This "decay-on-read, accumulate-on-write" split means
// nothing here ever has to walk every stored record just because time
// passed — a record nobody has looked up in months is left exactly as it
// was last written and only decays the moment something actually asks for
// its current score.
.pragma library

// One week. Frecency's "half of a use's weight is gone after this long"
// knob — long enough that a program run every workday stays near the top
// across a weekend, short enough that one used a month ago has mostly faded
// by now.
const HALF_LIFE_MS = 7 * 24 * 60 * 60 * 1000;

// Matches Providers.qml's clipboardLimit (`clipboardLimit: 500`) — both are
// "how much per-item history is this shell willing to keep forever" caps,
// and reusing that number means one already-reasoned-about constant instead
// of a second, unrelated one nobody could explain the difference of.
const RECORD_CAP = 500;

// A record's score decayed from `record.last` forward to `now`. Missing or
// falsy decays to 0 rather than throwing: order() calls this for every row
// on every keystroke, and a row with no usage history yet — or ever — is
// the common case here, not an error.
//
// Exponential decay with half-life H means multiplying by 0.5 for every H
// of elapsed time, i.e. score * 0.5^(elapsed / H) — continuous rather than
// "halve it once a week on a timer", so a record decays by the same factor
// whether something reads it once a day or once a year.
function effectiveScore(record, now) {
    if (!record)
        return 0;

    const elapsed = now - record.last;
    return record.score * Math.pow(0.5, elapsed / HALF_LIFE_MS);
}

// Records one use of `key`: reads its current effective score, adds one,
// and stores the sum as a fresh baseline at `now`. The `+ 1` is added after
// decay rather than before, so a key used once a year ago and once again
// right now reads as "one old, mostly-faded use plus one brand new one",
// not as if the old use never faded at all.
//
// Returns a new object. `records` is Providers.qml's own live
// JsonAdapter-backed frecency store, and reassigning that property (rather
// than mutating it in place) is what re-fires the sort binding that reads
// it — mutating here would leave the display stale until something else
// happened to touch the property.
function bump(records, key, now) {
    const before = effectiveScore(records[key], now);
    const next = Object.assign({}, records);
    next[key] = { score: before + 1, last: now };
    return next;
}

// Keeps the `cap` records with the highest effective score at `now` and
// drops the rest. Ties are broken by key — not because key order carries
// any meaning, but because leaving a tie in effective score unresolved
// would let which record survives depend on whatever order a JS engine's
// sort happens to hand equal-eff entries in, which itself traces back to
// `Object.keys(records)`'s own enumeration order. This function's own
// contract is "deterministic for a given input", so the tiebreak is
// spelled out explicitly instead of resting on an enumeration order this
// function has no real need to depend on.
function evictOverCap(records, cap, now) {
    const ranked = Object.keys(records)
        .map(key => ({ key: key, eff: effectiveScore(records[key], now) }))
        .sort((a, b) => b.eff - a.eff || a.key.localeCompare(b.key))
        .slice(0, cap);

    const kept = {};
    for (const entry of ranked)
        kept[entry.key] = records[entry.key];

    return kept;
}

// A row's own record, or undefined if it has no usage history at all: no
// `key` property — most providers' rows (files, clipboard, calc, ...) never
// carry one — or a `key` that `records` has never seen. Both fall through
// to effectiveScore's own `!record` branch and score 0, per this file's
// contract that a row with no history ranks by prefix and input order
// alone, never by a `key` that merely happens to be present.
function recordFor(row, records) {
    if (typeof row.key !== "string")
        return undefined;

    return records[row.key];
}

// Ranks `rows` for display: a prefix match on `needle` first, then usage
// frecency, then most-recently-used, then the row's own position in `rows`
// as the last resort. `needle` arrives already trimmed and already
// lowercased — Launcher.qml computes `text.trim().toLowerCase()` once per
// keystroke before calling this — and this function must not re-normalise
// it: doing so would repeat work every caller already did, and would hide a
// caller that forgot to normalise at all behind a rank.js that silently
// fixed it for them instead of a launcher that visibly stopped
// prefix-matching. Row titles still get lowercased here, once each, because
// those come from providers verbatim and genuinely do need it.
//
// Sorting runs over a decorated array (`{row, prefix, eff, last, i}`)
// compared on all four fields in that order, with `i` — the row's own index
// in the *input* `rows` array — as the final tiebreaker, rather than
// leaving a tie to fall out of whatever Array.prototype.sort's stability
// happens to do with it. Two rows tied on prefix, eff and last are exactly
// the case this signature exists to make deterministic without reaching
// for an alphabetical tiebreak nothing here actually promises.
//
// Returns a new array. Mutates neither `rows` — shared with pills.js's own
// read of `ambientRows` (Launcher.qml:91-99) — nor `records`.
function order(rows, records, needle, now) {
    const decorated = rows.map((row, i) => {
        const record = recordFor(row, records);
        const title = typeof row.title === "string" ? row.title.toLowerCase() : "";

        return {
            row: row,
            prefix: title.startsWith(needle) ? 0 : 1,
            eff: record ? effectiveScore(record, now) : 0,
            last: record ? record.last : 0,
            i: i
        };
    });

    decorated.sort((a, b) => {
        if (a.prefix !== b.prefix)
            return a.prefix - b.prefix;

        if (a.eff !== b.eff)
            return b.eff - a.eff;

        if (a.last !== b.last)
            return b.last - a.last;

        return a.i - b.i;
    });

    return decorated.map(entry => entry.row);
}
