/* test_brightness.c — which display the brightness goes to (tb_brightness.h). */

#include "tb_brightness.h"

#include <stdio.h>

static int checks;
static int failures;

#define CHECK(condition) do { \
    checks++; \
    if (!(condition)) { \
        failures++; \
        fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); \
    } \
} while (0)

int main(void) {
    /* The iMac's panel (looks like 2560 x 1440) and a second monitor to its right. */
    const CGDirectDisplayID ids[2] = { 1, 7 };
    const CGRect bounds[2] = { CGRectMake(0, 0, 2560, 1440), CGRectMake(2560, 200, 1920, 1080) };

    /* Fullscreen on the iMac: the iMac only, never the second monitor. */
    CHECK(tb_brightness_pick_display(CGRectMake(0, 0, 2560, 1440), ids, bounds, 2, 99) == 1);
    /* The window moved to the second monitor. */
    CHECK(tb_brightness_pick_display(CGRectMake(3000, 400, 980, 620), ids, bounds, 2, 99) == 7);
    /* Straddling: the centre decides. */
    CGRect straddle = CGRectMake(2000, 300, 980, 620);   /* centre x 2490: on the iMac */
    CHECK(tb_brightness_pick_display(straddle, ids, bounds, 2, 99) == 1);
    /* Centre in a gap between displays: the larger overlap decides. Here the
     * second monitor sits lower, below a gap; a window across the gap with its
     * centre in it overlaps both. */
    const CGRect low[2] = { CGRectMake(0, 0, 2560, 1440), CGRectMake(2560, 1520, 1920, 1080) };
    CGRect mostly_low = CGRectMake(2400, 1300, 1000, 400);   /* centre (2900, 1500): on neither */
    CHECK(tb_brightness_pick_display(mostly_low, ids, low, 2, 99) == 7);   /* 840 x 180 beats 160 x 140 */
    CGRect mostly_high = CGRectMake(1800, 1380, 1000, 240);  /* centre (2300, 1500): on neither */
    CHECK(tb_brightness_pick_display(mostly_high, ids, low, 2, 99) == 1);  /* 760 x 60 beats 240 x 100 */
    /* Off every display, or no list: the fallback. */
    CHECK(tb_brightness_pick_display(CGRectMake(-5000, -5000, 10, 10), ids, bounds, 2, 99) == 99);
    CHECK(tb_brightness_pick_display(CGRectMake(0, 0, 10, 10), NULL, bounds, 2, 99) == 99);
    CHECK(tb_brightness_pick_display(CGRectMake(0, 0, 10, 10), ids, bounds, 0, 99) == 99);

    /* Mirror sets: the iMac (1) mirrored onto a projector (9, primary 1); a
     * second monitor (7) on its own. */
    const CGDirectDisplayID online[3] = { 1, 7, 9 };
    const CGDirectDisplayID primaries[3] = { 1, 7, 1 };
    CGDirectDisplayID out[4] = { 0, 0, 0, 0 };
    CHECK(tb_brightness_mirror_set(1, 1, online, primaries, 3, out, 4) == 2 && out[0] == 1 && out[1] == 9);
    CHECK(tb_brightness_mirror_set(7, 7, online, primaries, 3, out, 4) == 1 && out[0] == 7);
    /* Asked from the mirror's side, the primary follows too. */
    CHECK(tb_brightness_mirror_set(9, 1, online, primaries, 3, out, 4) == 2 && out[0] == 9 && out[1] == 1);
    CHECK(tb_brightness_mirror_set(1, 1, NULL, primaries, 3, out, 4) == 1);
    CHECK(tb_brightness_mirror_set(1, 1, online, primaries, 3, out, 1) == 1);

    if (failures) {
        fprintf(stderr, "test_brightness: %d of %d checks failed\n", failures, checks);
        return 1;
    }
    printf("test_brightness: %d checks passed\n", checks);
    return 0;
}
