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
    /* Centre in a gap between displays: the larger overlap decides. */
    CGRect gap = CGRectMake(2300, 1300, 600, 400);   /* centre (2600, 1500): below both */
    CHECK(tb_brightness_pick_display(gap, ids, bounds, 2, 99) == 1);
    /* Off every display, or no list: the fallback. */
    CHECK(tb_brightness_pick_display(CGRectMake(-5000, -5000, 10, 10), ids, bounds, 2, 99) == 99);
    CHECK(tb_brightness_pick_display(CGRectMake(0, 0, 10, 10), NULL, bounds, 2, 99) == 99);
    CHECK(tb_brightness_pick_display(CGRectMake(0, 0, 10, 10), ids, bounds, 0, 99) == 99);

    if (failures) {
        fprintf(stderr, "test_brightness: %d of %d checks failed\n", failures, checks);
        return 1;
    }
    printf("test_brightness: %d checks passed\n", checks);
    return 0;
}
