/* tb_trace.c — per-frame timing of the receiver's video path. See tb_trace.h. */

#include "tb_trace.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define TB_TRACE_SLOTS   256   /* frames in flight that can still be stamped */
#define TB_TRACE_SAMPLES 1024  /* per stage per second; 1024 > any real frame rate */

enum { STAGE_DECODE, STAGE_UPLOAD, STAGE_SUBMIT, STAGE_DISPLAY, STAGE_TOTAL, STAGE_GAP, STAGE_COUNT };
static const char *const k_stage_names[STAGE_COUNT] = {
    "decode", "upload", "submit", "display", "total", "gap"
};

struct tb_trace_slot {
    uint32_t id;
    uint64_t t[TB_TRACE_MARK_COUNT];
};

struct tb_trace_window {
    double   samples[STAGE_COUNT][TB_TRACE_SAMPLES];
    int      count[STAGE_COUNT];
    unsigned in, shown, replaced, repeat, late;
};

static int              g_enabled = -1;     /* -1 = not read from the environment yet */
static pthread_mutex_t  g_lock = PTHREAD_MUTEX_INITIALIZER;
static struct tb_trace_slot g_slots[TB_TRACE_SLOTS];
static struct tb_trace_window g_win;
static uint32_t         g_next_id = 1;
static uint64_t         g_last_arrive_ns;
static uint64_t         g_window_start_ns;
static uint64_t         g_refresh_ns = 16666667;

int tb_trace_enabled(void) {
    if (g_enabled < 0) {
        const char *v = getenv("TB_RECEIVER_TRACE");
        g_enabled = (v && v[0] && strcmp(v, "0") != 0) ? 1 : 0;
    }
    return g_enabled;
}

uint64_t tb_trace_now_ns(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

void tb_trace_configure(const char *renderer, const char *pacing, uint64_t refresh_ns) {
    if (!tb_trace_enabled()) return;
    pthread_mutex_lock(&g_lock);
    if (refresh_ns > 0) g_refresh_ns = refresh_ns;
    fprintf(stderr, "[trace] on: renderer=%s pacing=%s refresh=%.2fms\n",
            renderer ? renderer : "?", pacing ? pacing : "?", (double)g_refresh_ns / 1e6);
    pthread_mutex_unlock(&g_lock);
}

static void push_sample(int stage, uint64_t from, uint64_t to) {
    if (from == 0 || to == 0 || to < from) return;
    if (g_win.count[stage] >= TB_TRACE_SAMPLES) return;
    g_win.samples[stage][g_win.count[stage]++] = (double)(to - from) / 1e6;
}

uint32_t tb_trace_frame_arrived(void) {
    if (!tb_trace_enabled()) return 0;
    uint64_t now = tb_trace_now_ns();
    pthread_mutex_lock(&g_lock);
    uint32_t id = g_next_id++;
    if (g_next_id == 0) g_next_id = 1;
    struct tb_trace_slot *s = &g_slots[id % TB_TRACE_SLOTS];
    memset(s, 0, sizeof(*s));
    s->id = id;
    s->t[TB_TRACE_ARRIVE] = now;
    push_sample(STAGE_GAP, g_last_arrive_ns, now);
    g_last_arrive_ns = now;
    g_win.in++;
    pthread_mutex_unlock(&g_lock);
    return id;
}

/* Fold a presented frame into this second's samples. Lock held. */
static void close_slot(struct tb_trace_slot *s) {
    const uint64_t *t = s->t;
    push_sample(STAGE_DECODE,  t[TB_TRACE_ARRIVE],    t[TB_TRACE_DECODED]);
    push_sample(STAGE_UPLOAD,  t[TB_TRACE_DECODED],   t[TB_TRACE_TEX_READY]);
    push_sample(STAGE_SUBMIT,  t[TB_TRACE_TEX_READY], t[TB_TRACE_SUBMITTED]);
    push_sample(STAGE_DISPLAY, t[TB_TRACE_SUBMITTED], t[TB_TRACE_PRESENTED]);
    push_sample(STAGE_TOTAL,   t[TB_TRACE_ARRIVE],    t[TB_TRACE_PRESENTED]);
    g_win.shown++;
    if (t[TB_TRACE_DECODED] && t[TB_TRACE_PRESENTED] > t[TB_TRACE_DECODED] &&
        t[TB_TRACE_PRESENTED] - t[TB_TRACE_DECODED] > 2 * g_refresh_ns) {
        g_win.late++;
    }
    s->id = 0;
}

void tb_trace_mark(uint32_t id, enum tb_trace_mark mark, uint64_t t_ns) {
    if (id == 0 || !tb_trace_enabled() || mark >= TB_TRACE_MARK_COUNT) return;
    pthread_mutex_lock(&g_lock);
    struct tb_trace_slot *s = &g_slots[id % TB_TRACE_SLOTS];
    if (s->id == id && s->t[mark] == 0) {
        s->t[mark] = t_ns;
        if (mark == TB_TRACE_PRESENTED) close_slot(s);
    }
    pthread_mutex_unlock(&g_lock);
}

void tb_trace_mark_now(uint32_t id, enum tb_trace_mark mark) {
    if (id == 0 || !tb_trace_enabled()) return;
    tb_trace_mark(id, mark, tb_trace_now_ns());
}

void tb_trace_frame_replaced(uint32_t id) {
    if (id == 0 || !tb_trace_enabled()) return;
    pthread_mutex_lock(&g_lock);
    struct tb_trace_slot *s = &g_slots[id % TB_TRACE_SLOTS];
    if (s->id == id) {
        s->id = 0;
        g_win.replaced++;
    }
    pthread_mutex_unlock(&g_lock);
}

void tb_trace_repeat(unsigned count) {
    if (count == 0 || !tb_trace_enabled()) return;
    pthread_mutex_lock(&g_lock);
    g_win.repeat += count;
    pthread_mutex_unlock(&g_lock);
}

static int cmp_double(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

double tb_trace_percentile(double *values, int n, double pct) {
    if (!values || n <= 0) return 0.0;
    qsort(values, (size_t)n, sizeof(double), cmp_double);
    /* Nearest rank: the smallest value with at least pct% of samples at or below it. */
    int rank = (int)((pct / 100.0) * (double)n + 0.999999);
    if (rank < 1) rank = 1;
    if (rank > n) rank = n;
    return values[rank - 1];
}

void tb_trace_tick(uint64_t now_ns) {
    if (!tb_trace_enabled()) return;
    pthread_mutex_lock(&g_lock);
    if (g_window_start_ns == 0) g_window_start_ns = now_ns;
    if (now_ns - g_window_start_ns < 1000000000ull) {
        pthread_mutex_unlock(&g_lock);
        return;
    }
    g_window_start_ns = now_ns;
    struct tb_trace_window w = g_win;
    memset(&g_win, 0, sizeof(g_win));
    pthread_mutex_unlock(&g_lock);

    if (w.in == 0 && w.shown == 0 && w.replaced == 0) return;   /* nothing streamed */

    char line[512];
    int len = snprintf(line, sizeof(line), "[trace] in=%u shown=%u replaced=%u repeat=%u late=%u | ms p50/p95",
                       w.in, w.shown, w.replaced, w.repeat, w.late);
    for (int s = 0; s < STAGE_COUNT && len > 0 && (size_t)len < sizeof(line); s++) {
        if (w.count[s] == 0) {
            len += snprintf(line + len, sizeof(line) - (size_t)len, " %s -", k_stage_names[s]);
            continue;
        }
        double p50 = tb_trace_percentile(w.samples[s], w.count[s], 50.0);
        double p95 = tb_trace_percentile(w.samples[s], w.count[s], 95.0);
        len += snprintf(line + len, sizeof(line) - (size_t)len, " %s %.1f/%.1f", k_stage_names[s], p50, p95);
    }
    fprintf(stderr, "%s\n", line);
}
