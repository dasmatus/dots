/**
 * Tests for bm_pills_scroll_offset(), the pill bar's scroll geometry.
 *
 * The function itself is added to bemenu by 06-filter-pills.patch as
 * lib/renderers/pills.cpp. This driver lives outside the patch on purpose: the
 * series has to keep applying cleanly to upstream bemenu, and a test file in
 * the patched tree is one more hunk to rebase for no benefit. Built and run by
 * `nix run .#beamenu-patch-test`, which compiles it against the patched source
 * under -fsanitize=address,undefined.
 */

#include <cassert>
#include <cstdint>
#include <cstdio>

extern "C" std::uint32_t bm_pills_scroll_offset(const std::uint32_t *widths, std::uint32_t count,
                                                std::uint32_t focus, std::uint32_t gap,
                                                std::uint32_t viewport);

#define BM_PILLS_NO_HIT UINT32_MAX
extern "C" std::uint32_t bm_pills_hit(const std::int32_t *xs, const std::uint32_t *widths,
                                     std::uint32_t count, std::int32_t px);

namespace {

constexpr std::uint32_t GAP = 8;

void a_run_that_fits_never_scrolls()
{
    const std::uint32_t widths[] = { 100, 100, 100 };
    /* 3 capsules + 2 gaps = 316, comfortably inside 500. */
    assert(bm_pills_scroll_offset(widths, 3, 0, GAP, 500) == 0);
    assert(bm_pills_scroll_offset(widths, 3, 2, GAP, 500) == 0);
}

void the_first_capsule_never_scrolls_off_the_left()
{
    const std::uint32_t widths[] = { 100, 100, 100, 100, 100 };
    assert(bm_pills_scroll_offset(widths, 5, 0, GAP, 300) == 0);
}

void a_middle_capsule_is_centred()
{
    const std::uint32_t widths[] = { 100, 100, 100, 100, 100 };
    /* Capsule 2 starts at 2 * 108 = 216 and its centre is 266; centring it in
     * a 300px viewport puts the run 116px to the left. */
    assert(bm_pills_scroll_offset(widths, 5, 2, GAP, 300) == 116);
}

void the_last_capsule_stops_at_the_end_of_the_run()
{
    const std::uint32_t widths[] = { 100, 100, 100, 100, 100 };
    /* Total is 5 * 100 + 4 * 8 = 532. Centring capsule 4 would want 332, but
     * the run may not scroll past 532 - 300 = 232. */
    assert(bm_pills_scroll_offset(widths, 5, 4, GAP, 300) == 232);
}

void a_capsule_wider_than_the_viewport_shows_its_left_edge()
{
    const std::uint32_t widths[] = { 50, 400 };
    /* Centring the 400px capsule inside a 100px viewport would cut off its
     * start; the offset clamps back to its left edge at 58. */
    assert(bm_pills_scroll_offset(widths, 2, 1, GAP, 100) == 58);
}

void degenerate_inputs_do_not_scroll()
{
    const std::uint32_t widths[] = { 100, 100 };
    assert(bm_pills_scroll_offset(nullptr, 2, 0, GAP, 100) == 0);
    assert(bm_pills_scroll_offset(widths, 0, 0, GAP, 100) == 0);
    assert(bm_pills_scroll_offset(widths, 2, 9, GAP, 100) == 0);
}

void a_zero_viewport_pins_the_focus_capsule_to_its_left_edge()
{
    const std::uint32_t widths[] = { 100, 100, 100 };
    /* Nothing is visible, but the offset must stay in range rather than
     * underflow: capsule 1 starts at 108. */
    assert(bm_pills_scroll_offset(widths, 3, 1, GAP, 0) == 108);
}

void a_single_capsule_narrower_than_the_viewport_stays_put()
{
    const std::uint32_t widths[] = { 40 };
    assert(bm_pills_scroll_offset(widths, 1, 0, GAP, 300) == 0);
}

} // namespace

void a_click_inside_a_capsule_finds_it()
{
    const std::int32_t xs[] = { 10, 130, 250 };
    const std::uint32_t ws[] = { 100, 100, 100 };
    assert(bm_pills_hit(xs, ws, 3, 10) == 0);
    assert(bm_pills_hit(xs, ws, 3, 109) == 0);
    assert(bm_pills_hit(xs, ws, 3, 130) == 1);
    assert(bm_pills_hit(xs, ws, 3, 349) == 2);
}

void a_click_in_a_gap_or_off_the_run_hits_nothing()
{
    const std::int32_t xs[] = { 10, 130 };
    const std::uint32_t ws[] = { 100, 100 };
    /* The 20px between capsule 0's right edge and capsule 1's left. */
    assert(bm_pills_hit(xs, ws, 2, 115) == BM_PILLS_NO_HIT);
    assert(bm_pills_hit(xs, ws, 2, 9) == BM_PILLS_NO_HIT);
    assert(bm_pills_hit(xs, ws, 2, 230) == BM_PILLS_NO_HIT);
}

void a_capsule_scrolled_out_of_sight_cannot_be_clicked()
{
    /* The painter leaves draw_x/draw_w at 0 for capsules it skipped, so a
     * zero-width entry must never swallow a click at x = 0. */
    const std::int32_t xs[] = { 0, 130 };
    const std::uint32_t ws[] = { 0, 100 };
    assert(bm_pills_hit(xs, ws, 2, 0) == BM_PILLS_NO_HIT);
    assert(bm_pills_hit(xs, ws, 2, 130) == 1);
}

void a_hit_test_with_no_capsules_is_not_a_crash()
{
    const std::int32_t xs[] = { 0 };
    const std::uint32_t ws[] = { 0 };
    assert(bm_pills_hit(xs, ws, 0, 5) == BM_PILLS_NO_HIT);
    assert(bm_pills_hit(nullptr, nullptr, 0, 5) == BM_PILLS_NO_HIT);
}

int main()
{
    a_run_that_fits_never_scrolls();
    the_first_capsule_never_scrolls_off_the_left();
    a_middle_capsule_is_centred();
    the_last_capsule_stops_at_the_end_of_the_run();
    a_capsule_wider_than_the_viewport_shows_its_left_edge();
    degenerate_inputs_do_not_scroll();
    a_zero_viewport_pins_the_focus_capsule_to_its_left_edge();
    a_single_capsule_narrower_than_the_viewport_stays_put();

    a_click_inside_a_capsule_finds_it();
    a_click_in_a_gap_or_off_the_run_hits_nothing();
    a_capsule_scrolled_out_of_sight_cannot_be_clicked();
    a_hit_test_with_no_capsules_is_not_a_crash();
    std::puts("pills_scroll_test: all cases passed");
    return 0;
}
