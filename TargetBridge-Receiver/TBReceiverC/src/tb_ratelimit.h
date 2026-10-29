/* tb_ratelimit.h — one log line per window for an event that repeats (PWE 1.1.1).
 *
 * A bad stream or a stalled sender can repeat the same event 60 times a
 * second; one line per event would rotate the log away within minutes. Each
 * kind of event keeps its own limiter, so a flood of one kind never hides the
 * first line of another:
 *
 *   static struct tb_ratelimit limit;
 *   unsigned long quiet;
 *   if (tb_ratelimit_allow(&limit, now_ms, 10000, &quiet))
 *       fprintf(stderr, "... ; %lu more since the last report\n", quiet);
 *
 * Not thread-safe: one limiter per thread that logs. Header only, so the
 * pure-C tests need nothing else.
 */

#ifndef TB_RATELIMIT_H
#define TB_RATELIMIT_H

#include <stdint.h>

struct tb_ratelimit {
    int           started;   /* a line was written */
    uint64_t      last_ms;   /* when */
    unsigned long quiet;     /* events held back since */
};

/* 1: write the line now; *quiet_out gets how many events were held back since
 * the last line, and the window starts again. 0: hold this one back (counted).
 * The first event always gets its line. A clock that went backwards counts as
 * a window that has passed. */
static inline int tb_ratelimit_allow(struct tb_ratelimit *r, uint64_t now_ms, uint64_t window_ms,
                                     unsigned long *quiet_out) {
    if (r->started && now_ms >= r->last_ms && now_ms - r->last_ms < window_ms) {
        r->quiet++;
        return 0;
    }
    if (quiet_out) *quiet_out = r->quiet;
    r->started = 1;
    r->last_ms = now_ms;
    r->quiet = 0;
    return 1;
}

#endif
