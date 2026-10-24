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
 * A frame's worth is a moving average of frame packet sizes. A keyframe
 * (several frames' worth on its own) counts as at most four frames in it, so
 * one keyframe does not raise the bar for long. Header only, for the tests.
 */

#ifndef TB_CATCHUP_H
#define TB_CATCHUP_H

#include <stddef.h>
#include <stdint.h>

/* Frames seen before the average means anything. */
#define TB_CATCHUP_MIN_FRAMES 4u
/* Behind: more than this many frames' worth waiting to be read. */
#define TB_CATCHUP_BEHIND_FRAMES 2u
/* The longest one read pass keeps decoding before the loop turns (shows the
 * newest picture, answers window and input events) and reads on. */
#define TB_CATCHUP_PASS_BUDGET_MS 50u

struct tb_catchup {
    uint64_t avg_frame_bytes;   /* moving average, weight 1/8 per frame */
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
    } else {
        if (sample > 4 * c->avg_frame_bytes) sample = 4 * c->avg_frame_bytes;
        c->avg_frame_bytes = (c->avg_frame_bytes * 7 + sample) / 8;
    }
    if (c->frames_seen < UINT32_MAX) c->frames_seen++;
}

/* Whether `backlog_bytes` waiting to be parsed means the receiver is behind. */
static inline int tb_catchup_behind(const struct tb_catchup *c, uint64_t backlog_bytes) {
    if (c->frames_seen < TB_CATCHUP_MIN_FRAMES || c->avg_frame_bytes == 0) return 0;
    return backlog_bytes > TB_CATCHUP_BEHIND_FRAMES * c->avg_frame_bytes;
}

#endif
