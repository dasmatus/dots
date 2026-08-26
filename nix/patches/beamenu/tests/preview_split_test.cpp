/**
 * Tests for bm_preview_columns(), the preview column's geometry.
 *
 * The function itself is added to bemenu by 10-preview-pane.patch as
 * lib/renderers/preview.cpp. This driver lives outside the patch for the same
 * reason pills_scroll_test.cpp and rows_fit_test.cpp do: the series has to
 * keep applying cleanly to upstream bemenu, and a test file in the patched
 * tree is one more hunk to rebase for no benefit. Built and run by
 * `nix run .#beamenu-patch-test`, which compiles it against the patched
 * source under -fsanitize=address,undefined.
 */

#include <cassert>
#include <cstdint>
#include <cstdio>

#define BM_PREVIEW_MIN_LIST 260u
#define BM_PREVIEW_MIN_COLUMN 200u

struct bm_preview_split {
    std::uint32_t list_width;
    std::uint32_t preview_width;
};

extern "C" struct bm_preview_split bm_preview_columns(std::uint32_t panel_width,
                                                      std::uint32_t wanted);

namespace {

/* A panel wide enough for both columns gets exactly what it asked for. */
void a_width_that_fits_is_honoured()
{
    const auto split = bm_preview_columns(1200, 600);
    assert(split.preview_width == 600);
    assert(split.list_width == 600);
}

/* Asking for nothing is how the column is turned off. */
void zero_means_no_column()
{
    const auto split = bm_preview_columns(1200, 0);
    assert(split.preview_width == 0);
    assert(split.list_width == 1200);
}

/* The list keeps BM_PREVIEW_MIN_LIST even when the request would eat it. */
void a_greedy_request_is_clamped_to_the_list_floor()
{
    const auto split = bm_preview_columns(1000, 900);
    assert(split.list_width == BM_PREVIEW_MIN_LIST);
    assert(split.preview_width == 1000 - BM_PREVIEW_MIN_LIST);
}

/* Clamping that leaves a sliver drops the column rather than draw one. */
void a_clamped_sliver_is_dropped()
{
    /* 400 - 260 = 140 of room, under the 200 column floor. */
    const auto split = bm_preview_columns(400, 300);
    assert(split.preview_width == 0);
    assert(split.list_width == 400);
}

/* A request under the column floor is dropped before any clamping. */
void a_request_under_the_column_floor_is_dropped()
{
    const auto split = bm_preview_columns(1200, BM_PREVIEW_MIN_COLUMN - 1);
    assert(split.preview_width == 0);
    assert(split.list_width == 1200);
}

/* Exactly at the column floor is still a column. */
void the_column_floor_itself_is_kept()
{
    const auto split = bm_preview_columns(1200, BM_PREVIEW_MIN_COLUMN);
    assert(split.preview_width == BM_PREVIEW_MIN_COLUMN);
    assert(split.list_width == 1200 - BM_PREVIEW_MIN_COLUMN);
}

/* A panel no wider than the list floor never splits, whatever it is asked. */
void a_panel_too_narrow_to_split_never_does()
{
    const std::uint32_t narrow[] = { 0, 1, BM_PREVIEW_MIN_LIST - 1, BM_PREVIEW_MIN_LIST };
    for (std::uint32_t width : narrow) {
        const auto split = bm_preview_columns(width, 400);
        assert(split.preview_width == 0);
        assert(split.list_width == width);
    }
}

/* The two columns always account for the whole panel, split or not. */
void the_columns_always_sum_to_the_panel()
{
    for (std::uint32_t width = 0; width <= 2000; width += 37) {
        const std::uint32_t wanted_widths[] = { 0, 150, 200, 480, 5000 };
        for (std::uint32_t wanted : wanted_widths) {
            const auto split = bm_preview_columns(width, wanted);
            assert(split.list_width + split.preview_width == width);
        }
    }
}

} // namespace

int main()
{
    a_width_that_fits_is_honoured();
    zero_means_no_column();
    a_greedy_request_is_clamped_to_the_list_floor();
    a_clamped_sliver_is_dropped();
    a_request_under_the_column_floor_is_dropped();
    the_column_floor_itself_is_kept();
    a_panel_too_narrow_to_split_never_does();
    the_columns_always_sum_to_the_panel();
    std::puts("preview_split_test: ok");
    return 0;
}
