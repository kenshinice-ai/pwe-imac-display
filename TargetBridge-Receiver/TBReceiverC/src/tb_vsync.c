/* tb_vsync.c — refresh ticks of the receiver's display. See tb_vsync.h. */

#include "tb_vsync.h"

#include <CoreVideo/CoreVideo.h>

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>

struct tb_vsync {
    CVDisplayLinkRef link;
    uint32_t         display_id;
    int              running;
    _Atomic uint64_t count;
    _Atomic uint64_t period_ns;
};

static CVReturn tb_vsync_callback(CVDisplayLinkRef link,
                                  const CVTimeStamp *now,
                                  const CVTimeStamp *output_time,
                                  CVOptionFlags flags_in,
                                  CVOptionFlags *flags_out,
                                  void *context) {
    (void)link; (void)now; (void)flags_in; (void)flags_out;
    struct tb_vsync *v = (struct tb_vsync *)context;
    if (output_time && output_time->videoTimeScale > 0 && output_time->videoRefreshPeriod > 0) {
        uint64_t ns = (uint64_t)((double)output_time->videoRefreshPeriod * 1e9 /
                                 (double)output_time->videoTimeScale);
        if (ns >= 4000000ull && ns <= 100000000ull) atomic_store(&v->period_ns, ns);
    }
    atomic_fetch_add(&v->count, 1);
    return kCVReturnSuccess;
}

struct tb_vsync *tb_vsync_create(uint32_t display_id) {
    struct tb_vsync *v = (struct tb_vsync *)calloc(1, sizeof(*v));
    if (!v) return NULL;
    atomic_store(&v->period_ns, 16666667ull);
    if (CVDisplayLinkCreateWithCGDisplay((CGDirectDisplayID)display_id, &v->link) != kCVReturnSuccess || !v->link) {
        fprintf(stderr, "[vsync] no display link for display %u\n", display_id);
        free(v);
        return NULL;
    }
    v->display_id = display_id;
    CVDisplayLinkSetOutputCallback(v->link, tb_vsync_callback, v);
    double period = CVDisplayLinkGetActualOutputVideoRefreshPeriod(v->link);
    if (period > 0.004 && period < 0.1) atomic_store(&v->period_ns, (uint64_t)(period * 1e9));
    return v;
}

void tb_vsync_destroy(struct tb_vsync *v) {
    if (!v) return;
    tb_vsync_stop(v);
    CVDisplayLinkRelease(v->link);
    free(v);
}

void tb_vsync_set_display(struct tb_vsync *v, uint32_t display_id) {
    if (!v || display_id == 0 || display_id == v->display_id) return;
    if (CVDisplayLinkSetCurrentCGDisplay(v->link, (CGDirectDisplayID)display_id) == kCVReturnSuccess) {
        v->display_id = display_id;
        fprintf(stderr, "[vsync] following display %u\n", display_id);
    }
}

int tb_vsync_start(struct tb_vsync *v) {
    if (!v) return kCVReturnInvalidArgument;
    if (v->running) return 0;
    const CVReturn r = CVDisplayLinkStart(v->link);
    if (r != kCVReturnSuccess) return (int)r;
    v->running = 1;
    return 0;
}

void tb_vsync_stop(struct tb_vsync *v) {
    if (!v || !v->running) return;
    CVDisplayLinkStop(v->link);
    v->running = 0;
}

uint64_t tb_vsync_count(const struct tb_vsync *v) {
    return v ? atomic_load(&((struct tb_vsync *)v)->count) : 0;
}

uint64_t tb_vsync_period_ns(const struct tb_vsync *v) {
    return v ? atomic_load(&((struct tb_vsync *)v)->period_ns) : 16666667ull;
}
