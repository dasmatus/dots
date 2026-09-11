// Pure date arithmetic behind Clock.qml's calendar grid.
//
// Split out for the reason battery.js and idle.js give in tests/README.md:
// nothing here binds a single Quickshell or Qt type, so unlike most of this
// tree's split-out logic this file is not dodging an unresolvable import —
// it is dodging the real clock. Every function takes the year, month and
// "today" it should reason about as plain numbers rather than reading
// Date.now() itself, so a test run at any hour of any day gets the same
// answer a run on 10 September 2026 did.
//
// Weeks start on Monday, this repo's own locale rather than the ISO
// calendar default of Sunday-first US layouts. getWeekdayIndex is where
// that choice lives; everything downstream of it is generic.
.pragma library

var MONTH_NAMES = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

// Total cells a 6-row grid always carries, whatever the month. A fixed cell
// count is what keeps the popup from resizing (and the pill under it from
// jumping) as the calendar pages between a 28-day February and a 31-day
// month either side of it.
var GRID_CELLS = 42;

// JS's own Date.getDay() is Sunday-first (0-6). Remapped to Monday-first
// (0-6, Monday = 0) once here so every function below can stay agnostic of
// which day starts the week.
function getWeekdayIndex(jsDay) {
    return (jsDay + 6) % 7;
}

// Calendar month is 1-12 throughout this file, not JS Date's own 0-11 — the
// one deliberate mismatch with the platform type this file otherwise
// mirrors, chosen because every caller in Clock.qml already thinks in
// human month numbers and translating at this boundary once beats every
// caller subtracting 1 for itself.
function daysInMonth(year, month) {
    return new Date(year, month, 0).getDate();
}

function monthLabel(year, month) {
    return `${MONTH_NAMES[month - 1]} ${year}`;
}

function firstWeekdayOffset(year, month) {
    return getWeekdayIndex(new Date(year, month - 1, 1).getDay());
}

function nextMonth(year, month) {
    return month === 12 ? {
        year: year + 1,
        month: 1
    } : {
        year: year,
        month: month + 1
    };
}

function previousMonth(year, month) {
    return month === 1 ? {
        year: year - 1,
        month: 12
    } : {
        year: year,
        month: month - 1
    };
}

// The full 6x7 grid for one month: GRID_CELLS cells, always, each
// { day, inMonth, isToday }. Leading cells before day 1 carry the previous
// month's trailing days and trailing cells after the last day carry the
// next month's leading days, both with inMonth: false, so a caller can dim
// them without special-casing "there is no day 32".
//
// `today`, when given, is { year, month, day } — the same shape this
// function's own cells use, deliberately, so Clock.qml can build it once
// from SystemClock's live date and hand it straight through.
function buildGrid(year, month, today) {
    const offset = firstWeekdayOffset(year, month);
    const daysThisMonth = daysInMonth(year, month);
    const previous = previousMonth(year, month);
    const daysPreviousMonth = daysInMonth(previous.year, previous.month);

    const cells = [];

    for (let i = 0; i < offset; i++) {
        cells.push({
            day: daysPreviousMonth - offset + 1 + i,
            inMonth: false,
            isToday: false
        });
    }

    for (let day = 1; day <= daysThisMonth; day++) {
        cells.push({
            day: day,
            inMonth: true,
            isToday: !!today && today.year === year && today.month === month && today.day === day
        });
    }

    let overflow = 1;
    while (cells.length < GRID_CELLS) {
        cells.push({
            day: overflow,
            inMonth: false,
            isToday: false
        });
        overflow++;
    }

    return cells;
}
