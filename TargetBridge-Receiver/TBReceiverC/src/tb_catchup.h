/* tb_catchup.h — whether the receiver has fallen behind the sender (PWE 1.1.1).
 *
 * After the main loop stalls (2-2.8 s inside the decoder on an iMac18,3,
 * 2026-10-24), the socket holds a backlog of frames. Shown one by one, they
 * play back as a fast-forward: 145 pictures in about a second. Every frame must
 * still be decoded (later frames refer to earlier ones), but only the newest
 * of a backlog needs to reach the screen.
 *
 * main.c reads the socket in chunks. Before handing a chunk to the parser it
 * asks tb_catchup_behind with the chunk's size plus what the kernel still
 * holds: more than two frames' worth means the receiver is behind, and the
 * pictures decoded from that chunk wait, newest first, until the read pass
 * ends. In the normal case a read returns at most one frame and nothing
 * waits, so this adds no latency.
 *
 * A frame's worth is a moving average of frame packet sizes that rises fast
 * (half way to a bigger frame) and falls slowly (1/8 per frame), so a still
 * desktop's tiny frames do not make the first moving frames look like a
 * backlog. A bigger frame counts as at most 4 frames' worth (or 128 KB), so
 * one keyframe does not raise the bar for long. "Behind" also needs at least
 * 256 KB waiting.
 *
 * While behind, main.c reads about one frame's worth at a time
 * (tb_catchup_read_size), so the pass budget is checked about once a frame:
 * the parser hands over every packet in a chunk before it returns.
 *
 * The waiting picture itself is a tb_catchup_slot; main.c fills it with a
 * retained CVPixelBuffer. Header only, for the tests.
 */

#ifndef TB_CATCHUP_H
#define TB_CATCHUP_H

#include <stddef.h>
#include <stdint.h>

/* Frames seen before the average means anything. */
#define TB_CATCHUP_MIN_FRAMES 4u
/* Behind: more than this many frames' worth waiting to be read, */
#define TB_CATCHUP_BEHIND_FRAMES 2u
/* and at least this much. */
#define TB_CATCHUP_MIN_BEHIND_BYTES (256u * 1024u)
/* A bigger frame counts as at most this many frames' worth, or this much. */
#define TB_CATCHUP_MAX_RISE_FRAMES 4u
#define TB_CATCHUP_MIN_RISE_BYTES (128u * 1024u)
/* While behind, read at least this much at a time. */
#define TB_CATCHUP_MIN_READ_BYTES (64u * 1024u)
/* The longest one read pass keeps decoding before the loop turns (shows the
 * newest picture, answers window and input events) and reads on. */
#define TB_CATCHUP_PASS_BUDGET_MS 50u

struct tb_catchup {
    uint64_t avg_frame_bytes;   /* moving average: up by 1/2, down by 1/8 per frame */
    unsigned frames_seen;
};

static inline void tb_catchup_reset(struct tb_catchup *c) {
    c->avg_frame_bytes = 0;
    c->frames_seen = 0;
}

/* A frame packet of `bytes` arrived. */
static inline void tb_catchup_note_frame(struct tb_catchup *c, size_t bytes) {
    uint64_t sample = (uint64_t)bytes;
    if (c->frames_seen == 0) {
        c->avg_frame_bytes = sample;
    } else if (sample > c->avg_frame_bytes) {
        uint64_t cap = TB_CATCHUP_MAX_RISE_FRAMES * c->avg_frame_bytes;
        if (cap < TB_CATCHUP_MIN_RISE_BYTES) cap = TB_CATCHUP_MIN_RISE_BYTES;
        if (sample > cap) sample = cap;
        c->avg_frame_bytes = (c->avg_frame_bytes + sample + 1) / 2;
    } else {
        c->avg_frame_bytes = (c->avg_frame_bytes * 7 + sample) / 8;
    }
    if (c->frames_seen < UINT32_MAX) c->frames_seen++;
}

/* The bytes waiting above which the receiver is behind. */
static inline uint64_t tb_catchup_threshold(const struct tb_catchup *c) {
    const uint64_t frames = TB_CATCHUP_BEHIND_FRAMES * c->avg_frame_bytes;
    return frames > TB_CATCHUP_MIN_BEHIND_BYTES ? frames : TB_CATCHUP_MIN_BEHIND_BYTES;
}

/* Whether `backlog_bytes` waiting to be parsed means the receiver is behind. */
static inline int tb_catchup_behind(const struct tb_catchup *c, uint64_t backlog_bytes) {
    if (c->frames_seen < TB_CATCHUP_MIN_FRAMES || c->avg_frame_bytes == 0) return 0;
    return backlog_bytes > tb_catchup_threshold(c);
}

/* How much the next read asks for: everything (`buf_size`) normally, about
 * one frame's worth while behind. */
static inline size_t tb_catchup_read_size(const struct tb_catchup *c, int behind, size_t buf_size) {
    if (!behind) return buf_size;
    uint64_t want = c->avg_frame_bytes;
    if (want < TB_CATCHUP_MIN_READ_BYTES) want = TB_CATCHUP_MIN_READ_BYTES;
    return want < buf_size ? (size_t)want : buf_size;
}

/* ---- The waiting picture ------------------------------------------------ */

/* What to do with a picture: drop it (never shown) or show it. Either way
 * the callback takes the slot's reference. */
typedef void (*tb_catchup_frame_fn)(void *frame, uint32_t trace_id, void *ctx);

struct tb_catchup_slot {
    void         *frame;     /* NULL when none waits */
    uint32_t      trace_id;
    unsigned long skipped;   /* pictures dropped, for the report */
};

/* A newer picture is on its way to the screen: the waiting one is dropped. */
static inline void tb_catchup_drop(struct tb_catchup_slot *s, tb_catchup_frame_fn drop, void *ctx) {
    if (!s->frame) return;
    void *frame = s->frame;
    const uint32_t id = s->trace_id;
    s->frame = NULL;
    s->trace_id = 0;
    s->skipped++;
    drop(frame, id, ctx);
}

/* `frame` (a reference the slot now owns) waits; the one before it is dropped. */
static inline void tb_catchup_hold(struct tb_catchup_slot *s, void *frame, uint32_t trace_id,
                                   tb_catchup_frame_fn drop, void *ctx) {
    tb_catchup_drop(s, drop, ctx);
    s->frame = frame;
    s->trace_id = trace_id;
}

/* The read pass ended: show the waiting picture, if any. */
static inline void tb_catchup_show(struct tb_catchup_slot *s, tb_catchup_frame_fn show, void *ctx) {
    if (!s->frame) return;
    void *frame = s->frame;
    const uint32_t id = s->trace_id;
    s->frame = NULL;
    s->trace_id = 0;
    show(frame, id, ctx);
}

#endif
