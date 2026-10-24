/* tb_input_rate.c — how fast the iMac's input reaches the Mac. See tb_input_rate.h. */

#include "tb_input_rate.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NS_PER_S 1000000000ull

void tb_input_rate_reset(struct tb_input_rate *r) {
    memset(r, 0, sizeof(*r));
}

/* Close the current one-second bucket into the busiest-second figure. */
static void close_second(struct tb_input_rate *r) {
    if (r->second_count == 0) return;
    if (r->second_count > r->busiest_second) r->busiest_second = r->second_count;
    r->seconds_with_input++;
    r->second_count = 0;
}

void tb_input_rate_note(struct tb_input_rate *r, uint64_t now_ns, double delay_ms, int is_key) {
    if (r->window_start_ns == 0) {
        r->window_start_ns = now_ns ? now_ns : 1;
        r->second_start_ns = r->window_start_ns;
    }
    if (now_ns >= r->second_start_ns + NS_PER_S) {
        close_second(r);
        /* Buckets are whole seconds from the report's start. */
        r->second_start_ns += (now_ns - r->second_start_ns) / NS_PER_S * NS_PER_S;
    }
    r->second_count++;
    r->events++;
    if (is_key) r->keys++;
    if (delay_ms >= 0) {
        if (r->delay_count < TB_INPUT_RATE_SAMPLES) r->delays_ms[r->delay_count++] = delay_ms;
        if (delay_ms > r->max_delay_ms) r->max_delay_ms = delay_ms;
    }
}

static int cmp_double(const void *a, const void *b) {
    const double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

/* Nearest rank, on sorted values. */
static double percentile(const double *sorted, int n, double pct) {
    int rank = (int)((pct / 100.0) * (double)n + 0.999999);
    if (rank < 1) rank = 1;
    if (rank > n) rank = n;
    return sorted[rank - 1];
}

int tb_input_rate_report(struct tb_input_rate *r, uint64_t now_ns, uint64_t window_ns,
                         char *line, size_t size) {
    if (r->window_start_ns == 0 || now_ns < r->window_start_ns + window_ns) return 0;
    close_second(r);
    const unsigned seconds = r->seconds_with_input ? r->seconds_with_input : 1;
    int len = snprintf(line, size, "forwarded to the Mac over %u s with input: %lu events (keys %lu), "
                                   "avg %lu/s, busiest second %u",
                       seconds, r->events, r->keys, r->events / seconds, r->busiest_second);
    if (r->delay_count > 0 && len > 0 && (size_t)len < size) {
        qsort(r->delays_ms, (size_t)r->delay_count, sizeof(double), cmp_double);
        snprintf(line + len, size - (size_t)len, "; event to send p50 %.1f ms, p95 %.1f ms, max %.1f ms",
                 percentile(r->delays_ms, r->delay_count, 50.0), percentile(r->delays_ms, r->delay_count, 95.0),
                 r->max_delay_ms);
    }
    tb_input_rate_reset(r);
    return 1;
}
