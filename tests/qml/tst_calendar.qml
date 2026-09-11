// The calendar grid's date arithmetic, behind Clock.qml's popup.
//
// Every fixture below is a real calendar date, checked against `date -d`
// rather than invented: 1 September 2026 is a Tuesday, 1 February 2026 is a
// Sunday, 2024 is a leap year and 2023 is not. Weeks start Monday, this
// repo's own locale, so getWeekdayIndex and firstWeekdayOffset are the two
// functions most worth pinning: a Sunday-first assumption anywhere upstream
// would shift every offset below by one and still "look" like a calendar.
//
// "wiring" reads Clock.qml as text, the idiom tst_focusedwindow_wiring.qml
// and tst_idle.qml's own final section use for the same reason: a correct
// buildGrid() proves nothing about whether the popup actually calls it with
// the page it is showing, or reset that page back to today on reopen.
import QtQuick
import QtTest
import "../../nix/home/desktop/quickshell/qml/bar/calendar.js" as CalendarMath
import "sourcescan.js" as Scan

TestCase {
    name: "Calendar"

    // ---- getWeekdayIndex ----

    function test_getWeekdayIndex_remaps_sunday_first_to_monday_first_data() {
        return [
            { tag: "Sunday", jsDay: 0, expected: 6 },
            { tag: "Monday", jsDay: 1, expected: 0 },
            { tag: "Tuesday", jsDay: 2, expected: 1 },
            { tag: "Saturday", jsDay: 6, expected: 5 }
        ];
    }

    function test_getWeekdayIndex_remaps_sunday_first_to_monday_first(row) {
        compare(CalendarMath.getWeekdayIndex(row.jsDay), row.expected, row.tag);
    }

    // ---- daysInMonth ----

    function test_daysInMonth_data() {
        return [
            { tag: "September, 30 days", year: 2026, month: 9, expected: 30 },
            { tag: "February in a leap year", year: 2024, month: 2, expected: 29 },
            { tag: "February in a common year", year: 2023, month: 2, expected: 28 },
            { tag: "February in 2026, also common", year: 2026, month: 2, expected: 28 },
            { tag: "December", year: 2026, month: 12, expected: 31 }
        ];
    }

    function test_daysInMonth(row) {
        compare(CalendarMath.daysInMonth(row.year, row.month), row.expected, row.tag);
    }

    // ---- monthLabel ----

    function test_monthLabel_names_the_month_and_year() {
        compare(CalendarMath.monthLabel(2026, 9), "September 2026");
        compare(CalendarMath.monthLabel(2027, 1), "January 2027");
    }

    // ---- firstWeekdayOffset ----

    function test_firstWeekdayOffset_data() {
        return [
            { tag: "September 2026 opens on a Tuesday", year: 2026, month: 9, expected: 1 },
            { tag: "February 2026 opens on a Sunday", year: 2026, month: 2, expected: 6 },
            { tag: "February 2024 (leap) opens on a Thursday", year: 2024, month: 2, expected: 3 },
            { tag: "February 2023 opens on a Wednesday", year: 2023, month: 2, expected: 2 }
        ];
    }

    function test_firstWeekdayOffset(row) {
        compare(CalendarMath.firstWeekdayOffset(row.year, row.month), row.expected, row.tag);
    }

    // ---- nextMonth / previousMonth ----

    function test_nextMonth_rolls_the_year_over_at_december() {
        const result = CalendarMath.nextMonth(2026, 12);
        compare(result.year, 2027);
        compare(result.month, 1);
    }

    function test_nextMonth_otherwise_just_advances() {
        const result = CalendarMath.nextMonth(2026, 9);
        compare(result.year, 2026);
        compare(result.month, 10);
    }

    function test_previousMonth_rolls_the_year_back_at_january() {
        const result = CalendarMath.previousMonth(2026, 1);
        compare(result.year, 2025);
        compare(result.month, 12);
    }

    function test_previousMonth_otherwise_just_retreats() {
        const result = CalendarMath.previousMonth(2026, 9);
        compare(result.year, 2026);
        compare(result.month, 8);
    }

    // ---- buildGrid ----

    // September 2026 is the month this test suite itself was written
    // against: 30 days, opening on a Tuesday (offset 1), so the grid is one
    // August day, thirty September days, and eleven October days.
    function test_buildGrid_is_always_a_full_six_week_grid() {
        const grid = CalendarMath.buildGrid(2026, 9, null);
        compare(grid.length, 42);
    }

    function test_buildGrid_leads_with_the_previous_months_trailing_days() {
        const grid = CalendarMath.buildGrid(2026, 9, null);

        compare(grid[0].day, 31, "the one leading cell must be August's last day");
        verify(!grid[0].inMonth, "a leading cell belongs to the previous month");
    }

    function test_buildGrid_places_the_first_of_the_month_at_its_real_offset() {
        const grid = CalendarMath.buildGrid(2026, 9, null);

        compare(grid[1].day, 1);
        verify(grid[1].inMonth, "the 1st itself is in-month");
    }

    function test_buildGrid_trails_with_the_next_months_leading_days() {
        const grid = CalendarMath.buildGrid(2026, 9, null);

        // 42 cells - 1 leading - 30 in-month = 11 trailing, so the grid ends
        // on October's 11th.
        compare(grid[41].day, 11);
        verify(!grid[41].inMonth, "a trailing cell belongs to the next month");
    }

    function test_buildGrid_marks_only_the_matching_day_as_today() {
        const grid = CalendarMath.buildGrid(2026, 9, {
            year: 2026,
            month: 9,
            day: 10
        });

        const todays = grid.filter(cell => cell.isToday);
        compare(todays.length, 1, "exactly one cell may be today");
        compare(todays[0].day, 10);
    }

    function test_buildGrid_marks_nothing_as_today_when_paging_to_another_month() {
        // Viewing October while "today" is still 10 September must not
        // highlight October's own 10th as if it were today.
        const grid = CalendarMath.buildGrid(2026, 10, {
            year: 2026,
            month: 9,
            day: 10
        });

        verify(grid.every(cell => !cell.isToday), "no cell in a month that is not today's may be marked today");
    }

    function test_buildGrid_marks_nothing_as_today_with_no_reference_date_data() {
        return [
            { tag: "null", today: null },
            { tag: "undefined", today: undefined }
        ];
    }

    function test_buildGrid_marks_nothing_as_today_with_no_reference_date(row) {
        const grid = CalendarMath.buildGrid(2026, 9, row.today);
        verify(grid.every(cell => !cell.isToday), row.tag);
    }

    // ---- wiring ----

    function clockSource() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("../../nix/home/desktop/quickshell/qml/bar/Clock.qml"), false);
        xhr.send();
        compare(xhr.status, 200, "Clock.qml must be readable (needs QML_XHR_ALLOW_FILE_READ=1)");
        return Scan.stripComments(xhr.responseText);
    }

    function test_the_grid_is_built_from_the_page_being_viewed_not_today() {
        verify(clockSource().indexOf("CalendarMath.buildGrid(root.viewYear, root.viewMonth, root.today)") !== -1, "the grid must reflect whichever month is being paged to");
    }

    // The regression this guards against: a popup that keeps whatever page
    // it was last left on would show last week's "next month" excursion to
    // someone who only wanted to check today's date.
    function test_reopening_the_popup_resets_the_page_to_today() {
        const body = Scan.blockAfter(clockSource(), "onExpandedChanged: {");

        verify(body !== "", "onExpandedChanged must exist");
        verify(body.indexOf("root.viewYear = root.today.year") !== -1, "reopening must reset the year to today's");
        verify(body.indexOf("root.viewMonth = root.today.month") !== -1, "reopening must reset the month to today's");
    }

    function test_paging_uses_the_pure_month_arithmetic_data() {
        return [
            { tag: "previous", call: "CalendarMath.previousMonth(root.viewYear, root.viewMonth)" },
            { tag: "next", call: "CalendarMath.nextMonth(root.viewYear, root.viewMonth)" }
        ];
    }

    function test_paging_uses_the_pure_month_arithmetic(row) {
        verify(clockSource().indexOf(row.call) !== -1, `paging must call ${row.call}`);
    }

    function test_the_popup_is_its_own_layer_shell_surface() {
        const src = clockSource();

        verify(src.indexOf("WlrLayershell.namespace: \"dots-calendar\"") !== -1, "the popup needs its own namespace, distinct from every other overlay");
        verify(src.indexOf("PanelWindow {") !== -1, "the popup must be a real top-level surface, not an Item drawn over the bar");
    }
}
