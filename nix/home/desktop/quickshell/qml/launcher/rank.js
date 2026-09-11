// Usage-based ranking for the launcher's ambient (unprefixed) query path,
// replacing the plain prefix-then-alphabetical sort Launcher.qml used to run
// inline. Pulled out for the same reason pills.js and status.js were: pure
// score arithmetic over plain objects, so tests/qml/tst_rank.qml can drive it
// with synthetic records and fixed timestamps instead of a live launcher, a
// FileView-backed frecency.json, and the wall clock.
//
// Frecency here is stored as (score, last) rather than as a literal log of
// recent uses, and it decays lazily: a record only remembers its own score
// as of its own `last` write, and every reader (order(), evictOverCap())
// recomputes that score decayed forward to `now` on demand. Writers (bump())
// do the opposite: decay to `now` once, add the new use, and store the sum
// as the new baseline. This "decay-on-read, accumulate-on-write" split means
// nothing here ever has to walk every stored record just because time
// passed. A record nobody has looked up in months is left exactly as it
// was last written and only decays the moment something actually asks for
// its current score.
.pragma library

// One week. Frecency's "half of a use's weight is gone after this long"
// knob: long enough that a program run every workday stays near the top
// across a weekend, short enough that one used a month ago has mostly faded
// by now.
const HALF_LIFE_MS = 7 * 24 * 60 * 60 * 1000;

// Not a limit on anything the user can see: the keyed universe is bounded
// by what is installed (desktop entries and their actions, plus the fixed
// system commands and whatever quicklinks and snippets are declared), so
// this is only a backstop against records for things that no longer exist
// accumulating across years of installs and removals. Set well clear of a
// large but ordinary machine's real key count so that eviction is
// effectively never reached in normal use: an eviction that fires
// routinely would be making ranking decisions, which is order()'s job.
const RECORD_CAP = 4000;

// A record's score decayed from `record.last` forward to `now`. Missing or
// malformed decays to 0 rather than throwing or poisoning a comparison:
// order() calls this for every row on every keystroke, and a row with no
// usage history yet, or ever, is the common case here, not an error.
//
// Exponential decay with half-life H means multiplying by 0.5 for every H
// of elapsed time, i.e. score * 0.5^(elapsed / H): continuous rather than
// "halve it once a week on a timer", so a record decays by the same factor
// whether something reads it once a day or once a year.
//
// The shape check is not defensive padding. frecency.json is a real file on
// disk that a user can edit, a half-written older schema can leave behind,
// or a future version of this code can write differently. A record whose
// score or last is not a finite number would make this return NaN, and NaN
// in order()'s comparator reads as "equal" for every key at once, which
// silently discards the input-order tiebreak the whole sort rests on. It is
// cheaper to treat a nonsense record as no history than to let one poison
// the ordering of every row beside it.
//
// elapsed is clamped at zero because it is a difference of two clocks that
// need not agree. A record written while the system clock was ahead (an
// unset RTC before NTP corrects it is the ordinary way this happens) has
// `last` in the future, making elapsed negative and 0.5^negative a
// multiplier ABOVE one. bump() then stores that inflated value as the new
// baseline, so a single launch during the wrong-clock window could pin a
// row to the top of the list for months of real time. Clamping costs
// nothing and makes a future timestamp mean "just used", which is the
// closest true statement available.
function effectiveScore(record, now) {
    // Number.isFinite, not the global isFinite: the global coerces, so it
    // answers true for the string "3" and for null, and the point of this
    // guard is to accept only what this file actually wrote.
    if (!record || !Number.isFinite(record.score) || !Number.isFinite(record.last))
        return 0;

    const elapsed = Math.max(0, now - record.last);
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
// it; mutating here would leave the display stale until something else
// happened to touch the property.
function bump(records, key, now) {
    const before = effectiveScore(records[key], now);
    const next = Object.assign({}, records);
    next[key] = { score: before + 1, last: now };
    return next;
}

// Keeps the `cap` records with the highest effective score at `now` and
// drops the rest. Ties are broken by key, not because key order carries
// any meaning, but because leaving a tie in effective score unresolved
// would let which record survives depend on whatever order a JS engine's
// sort happens to hand equal-eff entries in, which itself traces back to
// `Object.keys(records)`'s own enumeration order. This function's own
// contract is "deterministic for a given input", so the tiebreak is
// spelled out explicitly instead of resting on an enumeration order this
// function has no real need to depend on.
//
// `protect` lists the keys that must survive regardless of where they
// score, and it exists to close a starvation bug rather than as a
// convenience. Callers bump first and evict second, so a key being
// recorded for the very first time is in the candidate set at the lowest
// score any record can have: exactly 1.0, since 0 + 1 decayed across zero
// elapsed time. Against a full store of keys launched even twice within a
// half-life it loses every time. Because it was dropped before being
// written, the next launch starts it from 1.0 again, and the one after
// that. The app could be run daily forever and never enter the store or
// rank above anything. Exempting the keys the caller just recorded means
// an eviction can only ever drop something the user has not just reached
// for. It is a list rather than one key because recording an app's action
// bumps the action and the app together, and either can be the new one.
// The protected list is deduplicated and itself capped, so `cap` holds
// whatever a caller passes. Neither case can arise from recordUse, which
// passes at most an action key and its distinct parent against a cap in the
// thousands, but a function whose whole contract is "returns at most `cap`
// records" should not be one wider use away from returning more, or from
// under-filling because a caller repeated a key.
function evictOverCap(records, cap, now, protect) {
    const protectedKeys = (protect || [])
        .filter((key, i, all) => key in records && all.indexOf(key) === i)
        .slice(0, cap);

    const keys = Object.keys(records);

    if (keys.length <= cap)
        return Object.assign({}, records);

    const kept = {};
    for (const key of protectedKeys)
        kept[key] = records[key];

    const ranked = keys.filter(key => protectedKeys.indexOf(key) === -1)
        .map(key => ({ key: key, eff: effectiveScore(records[key], now) }))
        .sort((a, b) => b.eff - a.eff || a.key.localeCompare(b.key))
        .slice(0, Math.max(0, cap - protectedKeys.length));

    for (const entry of ranked)
        kept[entry.key] = records[entry.key];

    return kept;
}

// A row's own usable record, or undefined when it has no usage history to
// rank on: no `key` property (most providers' rows, e.g. files, clipboard,
// calc, ..., never carry one), a `key` that `records` has never seen, or a
// stored record that is not the two finite numbers this file writes.
//
// The shape check lives here as well as in effectiveScore because the two
// sort keys read different fields. effectiveScore guarding `score` keeps
// NaN out of the `eff` comparison, but `last` is compared directly, and
// `b.last - a.last` on a non-finite `last` is NaN just the same, which the
// comparator reads as "these are equal" and so skips the input-index
// tiebreak the whole sort rests on. Returning undefined for a malformed
// record means both keys fall to the same 0 that a row with no history
// gets, which is the honest answer: an unreadable record is not history.
function recordFor(row, records) {
    if (typeof row.key !== "string")
        return undefined;

    const record = records[row.key];
    if (!record || !Number.isFinite(record.score) || !Number.isFinite(record.last))
        return undefined;

    return record;
}

// Ranks `rows` for display: a prefix match on `needle` first, then usage
// frecency, then most-recently-used, then the row's own position in `rows`
// as the last resort. `needle` arrives already trimmed and already
// lowercased (Launcher.qml computes `text.trim().toLowerCase()` once per
// keystroke before calling this), and this function must not re-normalise
// it: doing so would repeat work every caller already did, and would hide a
// caller that forgot to normalise at all behind a rank.js that silently
// fixed it for them instead of a launcher that visibly stopped
// prefix-matching. Row titles still get lowercased here, once each, because
// those come from providers verbatim and genuinely do need it.
//
// Sorting runs over a decorated array (`{row, prefix, eff, last, i}`)
// compared on all four fields in that order, with `i`, the row's own index
// in the *input* `rows` array, as the final tiebreaker, rather than
// leaving a tie to fall out of whatever Array.prototype.sort's stability
// happens to do with it. Two rows tied on prefix, eff and last are exactly
// the case this signature exists to make deterministic without reaching
// for an alphabetical tiebreak nothing here actually promises.
//
// Returns a new array. Mutates neither `rows`, shared with pills.js's own
// read of `ambientRows` (Launcher.qml:91-99), nor `records`.
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
