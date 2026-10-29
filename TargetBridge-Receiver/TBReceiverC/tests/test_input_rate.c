/* test_input_rate.c — the forwarded-input summary line (tb_input_rate.h). */

#include "tb_input_rate.h"

#include <stdio.h>
#include <string.h>

static int checks;
static int failures;

#define CHECK(condition) do { \
    checks++; \
    if (!(condition)) { \
        failures++; \
        fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); \
    } \
} while (0)

#define S 1000000000ull
#define MS 1000000ull

static struct tb_input_rate r;

int main(void) {
    char line[256];
    tb_input_rate_reset(&r);
    CHECK(tb_input_rate_report(&r, 100 * S, 10 * S, line, sizeof(line)) == 0);   /* nothing yet */

    /* Second 0: 100 events 1 ms old. Second 1: 300 events. Seconds 2-4: none.
     * Second 5: 50 events, one of them 40 ms old. */
    const uint64_t t0 = 1000 * S;
    for (int i = 0; i < 100; i++) tb_input_rate_note(&r, t0 + (uint64_t)i * 5 * MS, 1.0, i < 10);
    for (int i = 0; i < 300; i++) tb_input_rate_note(&r, t0 + S + (uint64_t)i * 3 * MS, 1.0, 0);
    for (int i = 0; i < 50; i++) tb_input_rate_note(&r, t0 + 5 * S + (uint64_t)i * 10 * MS, i == 7 ? 40.0 : -1.0, 0);
    CHECK(tb_input_rate_report(&r, t0 + 9 * S, 10 * S, line, sizeof(line)) == 0);   /* not 10 s yet */
    CHECK(tb_input_rate_report(&r, t0 + 10 * S, 10 * S, line, sizeof(line)) == 1);
    printf("test_input_rate: %s\n", line);
    CHECK(strstr(line, "over 3 s with input: 450 events (keys 10), avg 150/s, busiest second 300") != NULL);
    CHECK(strstr(line, "p50 1.0 ms") != NULL);
    CHECK(strstr(line, "max 40.0 ms") != NULL);
    /* A new report starts empty. */
    CHECK(tb_input_rate_report(&r, t0 + 30 * S, 10 * S, line, sizeof(line)) == 0);
    tb_input_rate_note(&r, t0 + 40 * S, -1.0, 1);
    CHECK(tb_input_rate_report(&r, t0 + 50 * S, 10 * S, line, sizeof(line)) == 1);
    CHECK(strstr(line, "1 events (keys 1)") != NULL);
    CHECK(strstr(line, "event to send") == NULL);   /* no ages known */

    if (failures) {
        fprintf(stderr, "test_input_rate: %d of %d checks failed\n", failures, checks);
        return 1;
    }
    printf("test_input_rate: %d checks passed\n", checks);
    return 0;
}
