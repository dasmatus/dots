/**
 * Tests for bm_rows_fit(), the variable-height row layout.
 *
 * The function itself is added to bemenu by 08-nested-rows.patch as
 * lib/renderers/rows.cpp. This driver lives outside the patch for the same
 * reason pills_scroll_test.cpp does: the series has to keep applying cleanly
 * to upstream bemenu, and a test file in the patched tree is one more hunk to
 * rebase for no benefit. Built and run by `nix run .#beamenu-patch-test`,
 * which compiles it against the patched source under
 * -fsanitize=address,undefined.
 */

#include <cassert>
#include <cstdint>
#include <cstdio>

struct bm_rows_window {
    std::uint32_t first;
    std::uint32_t count;
    std::uint32_t height;
};

extern "C" struct bm_rows_window bm_rows_fit(const std::uint32_t *heights, std::uint32_t count,
                                             std::uint32_t highlight, std::uint32_t viewport);

namespace {

void a_list_that_fits_shows_all_of_it()
{
    const std::uint32_t heights[] = { 50, 50, 50 };
    const auto w = bm_rows_fit(heights, 3, 0, 500);
    assert(w.first == 0);
    assert(w.count == 3);
    assert(w.height == 150);
}

void the_height_is_the_rows_drawn_not_the_room_available()
{
    /* The panel sizes itself from this, so a short last row must not leave
     * the viewport's leftover space as a gap under it. */
    const std::uint32_t heights[] = { 50, 35, 35 };
    const auto w = bm_rows_fit(heights, 3, 0, 500);
    assert(w.height == 120);
}

void a_page_holds_still_until_the_highlight_leaves_it()
{
    const std::uint32_t heights[] = { 50, 50, 50, 50, 50, 50 };
    /* 200px viewport holds exactly four 50px rows. */
    for (std::uint32_t highlight = 0; highlight < 4; ++highlight) {
        const auto w = bm_rows_fit(heights, 6, highlight, 200);
        assert(w.first == 0);
        assert(w.count == 4);
    }
    const auto next = bm_rows_fit(heights, 6, 4, 200);
    assert(next.first == 4);
    assert(next.count == 2);
}

void pages_are_cut_by_height_not_by_row_count()
{
    /* Two tall rows then four short ones. A 100px viewport takes two tall
     * rows, then all four short ones, so the second page is twice as long as
     * the first. Counting rows instead of summing heights would split them
     * evenly and scroll early. */
    const std::uint32_t heights[] = { 50, 50, 25, 25, 25, 25 };
    const auto first = bm_rows_fit(heights, 6, 1, 100);
    assert(first.first == 0);
    assert(first.count == 2);

    const auto second = bm_rows_fit(heights, 6, 2, 100);
    assert(second.first == 2);
    assert(second.count == 4);
    assert(second.height == 100);
}

void a_row_taller_than_the_viewport_still_gets_drawn()
{
    /* Better one clipped row than an empty panel, and the walk must still
     * terminate rather than spinning on a page it cannot fill. */
    const std::uint32_t heights[] = { 500, 50 };
    const auto w = bm_rows_fit(heights, 2, 0, 100);
    assert(w.first == 0);
    assert(w.count == 1);
    assert(w.height == 500);

    const auto after = bm_rows_fit(heights, 2, 1, 100);
    assert(after.first == 1);
    assert(after.count == 1);
}

void a_highlight_past_the_end_is_clamped()
{
    /* The client's index against a list that has since shrunk. Reading off
     * the end here is what ASan is watching for. */
    const std::uint32_t heights[] = { 50, 50 };
    const auto w = bm_rows_fit(heights, 2, 99, 500);
    assert(w.first == 0);
    assert(w.count == 2);
}

void an_empty_list_draws_nothing()
{
    const std::uint32_t heights[] = { 50 };
    const auto w = bm_rows_fit(heights, 0, 0, 500);
    assert(w.count == 0);
    assert(w.height == 0);

    const auto null_run = bm_rows_fit(nullptr, 0, 0, 500);
    assert(null_run.count == 0);
}

void a_zero_viewport_does_not_hang()
{
    const std::uint32_t heights[] = { 50, 50, 50 };
    const auto w = bm_rows_fit(heights, 3, 2, 0);
    assert(w.count == 1);
    assert(w.first == 2);
}

} // namespace

int main()
{
    a_list_that_fits_shows_all_of_it();
    the_height_is_the_rows_drawn_not_the_room_available();
    a_page_holds_still_until_the_highlight_leaves_it();
    pages_are_cut_by_height_not_by_row_count();
    a_row_taller_than_the_viewport_still_gets_drawn();
    a_highlight_past_the_end_is_clamped();
    an_empty_list_draws_nothing();
    a_zero_viewport_does_not_hang();
    std::puts("rows_fit_test: all cases passed");
    return 0;
}
