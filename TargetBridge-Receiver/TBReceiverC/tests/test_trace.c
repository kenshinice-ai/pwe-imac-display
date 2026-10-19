/* Unit tests for tb_trace.c: percentiles, the frame record life cycle, and the
 * per-second summary line. Pure C, no SDL/FFmpeg. */

#include "tb_trace.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int g_checks = 0;
static int g_failures = 0;

#define CHECK(cond) do { \
    g_checks++; \
    if (!(cond)) { g_failures++; fprintf(stdout, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } \
} while (0)

static int near(double a, double b) { return a - b < 1e-9 && b - a < 1e-9; }

static void test_percentile(void) {
    double one[] = { 7.0 };
    CHECK(near(tb_trace_percentile(one, 1, 50.0), 7.0));
    CHECK(near(tb_trace_percentile(one, 1, 95.0), 7.0));

    double v[20];
    for (int i = 0; i < 20; i++) v[i] = (double)(20 - i);   /* 20..1, unsorted */
    CHECK(near(tb_trace_percentile(v, 20, 50.0), 10.0));
    CHECK(near(tb_trace_percentile(v, 20, 95.0), 19.0));
    CHECK(near(tb_trace_percentile(v, 20, 100.0), 20.0));
    CHECK(near(tb_trace_percentile(v, 20, 0.0), 1.0));
    CHECK(near(tb_trace_percentile(NULL, 0, 50.0), 0.0));
}

/* Runs one second of fake frames and returns the summary line. */
static void capture_summary(char *out, size_t size) {
    const uint64_t ms = 1000000ull;
    uint64_t base = tb_trace_now_ns();
    tb_trace_tick(base);                         /* opens the window */

    uint32_t a = tb_trace_frame_arrived();
    tb_trace_mark(a, TB_TRACE_DECODED,   base + 4 * ms);
    tb_trace_mark(a, TB_TRACE_TEX_READY, base + 6 * ms);
    tb_trace_mark(a, TB_TRACE_SUBMITTED, base + 7 * ms);
    tb_trace_mark(a, TB_TRACE_PRESENTED, base + 20 * ms);
    tb_trace_mark(a, TB_TRACE_PRESENTED, base + 40 * ms);   /* a redraw: ignored */

    uint32_t b = tb_trace_frame_arrived();
    tb_trace_mark(b, TB_TRACE_DECODED, base + 5 * ms);
    tb_trace_frame_replaced(b);
    tb_trace_mark(b, TB_TRACE_PRESENTED, base + 30 * ms);   /* replaced: ignored */

    uint32_t c = tb_trace_frame_arrived();
    tb_trace_mark(c, TB_TRACE_DECODED,   base + 1 * ms);
    tb_trace_mark(c, TB_TRACE_PRESENTED, base + 60 * ms);   /* 59 ms after decode: late */

    tb_trace_mark(0, TB_TRACE_PRESENTED, base);              /* id 0: ignored */
    tb_trace_repeat(3);

    FILE *tmp = tmpfile();
    CHECK(tmp != NULL);
    if (!tmp) return;
    fflush(stderr);
    int saved = dup(fileno(stderr));
    dup2(fileno(tmp), fileno(stderr));
    tb_trace_tick(base + 500 * ms);              /* too early: prints nothing */
    tb_trace_tick(base + 1001 * ms);
    tb_trace_tick(base + 1500 * ms);             /* new window, nothing in it yet */
    fflush(stderr);
    dup2(saved, fileno(stderr));
    close(saved);

    rewind(tmp);
    size_t n = fread(out, 1, size - 1, tmp);
    out[n] = '\0';
    fclose(tmp);
}

static void test_summary(void) {
    char text[2048];
    capture_summary(text, sizeof(text));
    fprintf(stdout, "summary: %s", text);
    CHECK(strstr(text, "in=3 shown=2 replaced=1 repeat=3 late=1") != NULL);
    CHECK(strstr(text, "decode 1.0/4.0") != NULL);
    CHECK(strstr(text, "upload 2.0/2.0") != NULL);
    CHECK(strstr(text, "display 13.0/13.0") != NULL);
    CHECK(strstr(text, "total 20.0/60.0") != NULL);
    /* exactly one summary line */
    const char *first = strstr(text, "[trace]");
    CHECK(first != NULL && strstr(first + 1, "[trace]") == NULL);
}

static void test_disabled(void) {
    /* The trace reads the environment once; this process enabled it, so only
     * the id-0 contract can be checked here. */
    tb_trace_mark_now(0, TB_TRACE_DECODED);
    tb_trace_frame_replaced(0);
    CHECK(1);
}

int main(void) {
    setenv("TB_RECEIVER_TRACE", "1", 1);
    CHECK(tb_trace_enabled() == 1);
    test_percentile();
    test_summary();
    test_disabled();
    fprintf(stdout, "trace tests: %d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
