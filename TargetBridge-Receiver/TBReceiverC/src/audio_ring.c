/* audio_ring.c — see audio_ring.h. */

#include "audio_ring.h"

#include <string.h>

void tb_audio_ring_init(struct tb_audio_ring *r, uint8_t *buf, int cap) {
    r->buf = buf;
    r->cap = cap > 0 ? cap - cap % TB_AUDIO_FRAME_BYTES : 0;
    tb_audio_ring_reset(r);
}

void tb_audio_ring_reset(struct tb_audio_ring *r) {
    r->head = 0;
    r->tail = 0;
    r->size = 0;
}

static void drop_oldest(struct tb_audio_ring *r, int n) {
    if (n > r->size) n = r->size;
    r->tail = (r->tail + n) % r->cap;
    r->size -= n;
}

int tb_audio_ring_push(struct tb_audio_ring *r, const uint8_t *data, size_t len, int max_backlog) {
    if (!r || !r->buf || r->cap <= 0 || !data || len == 0) return 0;

    if (max_backlog <= 0 || max_backlog > r->cap) max_backlog = r->cap;
    max_backlog -= max_backlog % TB_AUDIO_FRAME_BYTES;
    if (max_backlog <= 0) return 0;

    size_t whole = len - len % TB_AUDIO_FRAME_BYTES;
    if (whole == 0) return 0;

    /* A packet longer than the whole backlog: only its newest part can be
     * kept, and nothing already queued survives it. */
    if (whole > (size_t)max_backlog) {
        data += whole - (size_t)max_backlog;
        whole = (size_t)max_backlog;
        tb_audio_ring_reset(r);
    }
    int n = (int)whole;

    if (r->size + n > max_backlog) drop_oldest(r, r->size + n - max_backlog);

    int first = r->cap - r->head;
    if (first >= n) {
        memcpy(r->buf + r->head, data, (size_t)n);
    } else {
        memcpy(r->buf + r->head, data, (size_t)first);
        memcpy(r->buf, data + first, (size_t)(n - first));
    }
    r->head = (r->head + n) % r->cap;
    r->size += n;
    return n;
}

int tb_audio_ring_pop(struct tb_audio_ring *r, uint8_t *dst, int len) {
    if (!r || !dst || len <= 0 || r->size <= 0) return 0;
    int n = len < r->size ? len : r->size;
    int first = r->cap - r->tail;
    if (first >= n) {
        memcpy(dst, r->buf + r->tail, (size_t)n);
    } else {
        memcpy(dst, r->buf + r->tail, (size_t)first);
        memcpy(dst + first, r->buf, (size_t)(n - first));
    }
    r->tail = (r->tail + n) % r->cap;
    r->size -= n;
    return n;
}
