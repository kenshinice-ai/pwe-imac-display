/* test_permwatch.c — permissions re-checked off the main loop (tb_permwatch.h). */

#include "tb_permwatch.h"

#include <stdatomic.h>
#include <stdio.h>
#include <unistd.h>

static int checks;
static int failures;

#define CHECK(condition) do { \
    checks++; \
    if (!(condition)) { \
        failures++; \
        fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); \
    } \
} while (0)

static void test_due(void) {
    /* Never checked: now. */
    CHECK(tb_permwatch_due_in(1000, 0, 0, 5000, 1000) == 0);
    /* Every 5 s, not sooner. */
    CHECK(tb_permwatch_due_in(10000, 8000, 0, 5000, 1000) == 3000);
    CHECK(tb_permwatch_due_in(13000, 8000, 0, 5000, 1000) == 0);
    /* A kick: at once if the last check was 1 s ago or more, else when it is. */
    CHECK(tb_permwatch_due_in(9500, 9000, 1, 5000, 1000) == 500);
    CHECK(tb_permwatch_due_in(10000, 9000, 1, 5000, 1000) == 0);
    /* A clock that went backwards: check now. */
    CHECK(tb_permwatch_due_in(100, 9000, 0, 5000, 1000) == 0);
}

static atomic_int calls;
static atomic_int granted = 1;

static void fake_check(int *input_monitoring, int *accessibility) {
    atomic_fetch_add(&calls, 1);
    *input_monitoring = atomic_load(&granted);
    *accessibility = 1;
}

static void test_thread(void) {
    struct tb_permwatch *w = tb_permwatch_start(fake_check, 300, 100);
    CHECK(w != NULL);
    if (!w) return;
    int im = -1, ax = -1;
    uint64_t seq = 0;
    for (int i = 0; i < 100 && seq == 0; i++) { usleep(10000); seq = tb_permwatch_read(w, &im, &ax); }
    CHECK(seq >= 1 && im == 1 && ax == 1);   /* the first check runs at once */

    /* Removed: noticed within one interval, without restarting anything. */
    atomic_store(&granted, 0);
    usleep(450 * 1000);
    CHECK(tb_permwatch_read(w, &im, &ax) > seq && im == 0);

    /* Paced: about one check per 300 ms over 1.2 s, not a busy loop. */
    const int before = atomic_load(&calls);
    usleep(1200 * 1000);
    const int during = atomic_load(&calls) - before;
    CHECK(during >= 2 && during <= 6);

    /* A kick checks again within the minimum gap, not the interval. */
    atomic_store(&granted, 1);
    tb_permwatch_kick(w);
    usleep(150 * 1000);
    CHECK(tb_permwatch_read(w, &im, &ax) > 0 && im == 1);
    tb_permwatch_stop(w);
    tb_permwatch_stop(NULL);
    CHECK(tb_permwatch_read(NULL, &im, &ax) == 0);
}

int main(void) {
    test_due();
    test_thread();
    if (failures) {
        fprintf(stderr, "test_permwatch: %d of %d checks failed\n", failures, checks);
        return 1;
    }
    printf("test_permwatch: %d checks passed\n", checks);
    return 0;
}
