/* test_loopwatch.c — the main-loop watchdog (tb_loopwatch.h): when it reports,
 * and that a real stall of this thread is reported with its phase and stack. */

#include "tb_loopwatch.h"

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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

static void test_decide(void) {
    struct tb_loopwatch_track t;
    memset(&t, 0, sizeof(t));
    uint64_t for_ms = 99;

    /* Iteration 1 started at 1000: quiet below 2 s. */
    CHECK(tb_loopwatch_decide(&t, 1, 1000, 2999, 2000, 10000, &for_ms) == TB_LOOPWATCH_NONE);
    /* At 2 s: one report. */
    CHECK(tb_loopwatch_decide(&t, 1, 1000, 3000, 2000, 10000, &for_ms) == TB_LOOPWATCH_STUCK);
    CHECK(for_ms == 2000);
    /* Not again until 10 s later. */
    CHECK(tb_loopwatch_decide(&t, 1, 1000, 12999, 2000, 10000, &for_ms) == TB_LOOPWATCH_NONE);
    CHECK(for_ms == 11999);
    CHECK(tb_loopwatch_decide(&t, 1, 1000, 13000, 2000, 10000, &for_ms) == TB_LOOPWATCH_STILL_STUCK);
    CHECK(for_ms == 12000);
    /* The loop turns: iteration 2 started at 47600, so iteration 1 ran 46.6 s. */
    CHECK(tb_loopwatch_decide(&t, 2, 47600, 47700, 2000, 10000, &for_ms) == TB_LOOPWATCH_RECOVERED);
    CHECK(for_ms == 46600);
    CHECK(tb_loopwatch_decide(&t, 2, 47600, 47800, 2000, 10000, &for_ms) == TB_LOOPWATCH_NONE);

    /* A busy loop that turns quickly is never reported. */
    for (uint64_t seq = 3, now = 50000; seq < 200; seq++, now += 50) {
        CHECK(tb_loopwatch_decide(&t, seq, now - 10, now, 2000, 10000, &for_ms) == TB_LOOPWATCH_NONE);
    }
    /* A start time later than "now" (read across a new iteration) is no stall. */
    CHECK(tb_loopwatch_decide(&t, 300, 90000, 89999, 2000, 10000, &for_ms) == TB_LOOPWATCH_NONE);
    /* Missing arguments are no stall. */
    CHECK(tb_loopwatch_decide(NULL, 1, 0, 99999, 2000, 10000, &for_ms) == TB_LOOPWATCH_NONE);
    CHECK(tb_loopwatch_decide(&t, 1, 0, 99999, 2000, 10000, NULL) == TB_LOOPWATCH_NONE);
}

/* This thread is the "main loop": it stalls in a named phase for 2.6 s while
 * stderr goes to a file, then reads what the watchdog wrote. */
__attribute__((noinline)) static void test_real_stall(void) {
#if defined(__APPLE__)
    char path[] = "/tmp/test_loopwatch.XXXXXX";
    int fd = mkstemp(path);
    CHECK(fd >= 0);
    if (fd < 0) return;
    fflush(stderr);
    int saved = dup(STDERR_FILENO);
    dup2(fd, STDERR_FILENO);

    CHECK(tb_loopwatch_start() == 0);
    tb_loopwatch_iteration();
    TB_LOOP_PHASE("test: a long sleep");
    usleep(2600 * 1000);
    tb_loopwatch_iteration();
    TB_LOOP_PHASE("test: idle");
    usleep(400 * 1000);   /* the watchdog looks every 200 ms */
    tb_loopwatch_stop();

    fflush(stderr);
    dup2(saved, STDERR_FILENO);
    close(saved);

    char out[16384];
    lseek(fd, 0, SEEK_SET);
    ssize_t n = read(fd, out, sizeof(out) - 1);
    close(fd);
    unlink(path);
    out[n > 0 ? n : 0] = '\0';

    CHECK(strstr(out, "[watchdog] main loop stuck 2.") != NULL);
    CHECK(strstr(out, "in test: a long sleep (test_loopwatch.c:") != NULL);
    /* The stack names the call it is blocked in and the test that made it. */
    CHECK(strstr(out, "[watchdog]   #0 ") != NULL);
    CHECK(strstr(out, "test_real_stall") != NULL);
    CHECK(strstr(out, "[watchdog] main loop ran again after 2.") != NULL);
    CHECK(strstr(out, "(stuck in test: a long sleep") != NULL);
    if (failures || getenv("TEST_LOOPWATCH_SHOW")) fprintf(stderr, "--- watchdog output ---\n%s---\n", out);
#endif
}

int main(void) {
    test_decide();
    test_real_stall();
    if (failures) {
        fprintf(stderr, "test_loopwatch: %d of %d checks failed\n", failures, checks);
        return 1;
    }
    printf("test_loopwatch: %d checks passed\n", checks);
    return 0;
}
