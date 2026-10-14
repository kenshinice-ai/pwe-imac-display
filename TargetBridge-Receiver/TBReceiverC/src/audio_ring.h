/* audio_ring.h — bounded PCM ring buffer for streamed sender audio.
 *
 * Pure C, no SDL: the caller holds the audio device lock around every call.
 * Every operation keeps 0 <= size <= cap, whatever the packet length.
 */

#ifndef TB_AUDIO_RING_H
#define TB_AUDIO_RING_H

#include <stddef.h>
#include <stdint.h>

/* 48 kHz stereo signed 16-bit: one frame is 4 bytes. Writes and drops stay
 * frame-aligned so the two channels never swap. */
#define TB_AUDIO_FRAME_BYTES 4

struct tb_audio_ring {
    uint8_t *buf;
    int      cap;
    int      head;   /* next write position */
    int      tail;   /* next read position */
    int      size;   /* bytes queued */
};

void tb_audio_ring_init(struct tb_audio_ring *r, uint8_t *buf, int cap);
void tb_audio_ring_reset(struct tb_audio_ring *r);

/* Queue `len` bytes, keeping at most `max_backlog` bytes queued afterwards.
 * Oldest audio is dropped first; a packet longer than the backlog keeps only
 * its newest part. A trailing partial frame is ignored. Returns the number of
 * bytes queued from this packet. */
int  tb_audio_ring_push(struct tb_audio_ring *r, const uint8_t *data, size_t len, int max_backlog);

/* Copy up to `len` queued bytes into `dst`, oldest first. Returns bytes copied. */
int  tb_audio_ring_pop(struct tb_audio_ring *r, uint8_t *dst, int len);

#endif
