#include "audio_ring.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
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

/* The ring's storage sits between two guard regions; any write outside it
 * shows up as a changed guard byte, with or without AddressSanitizer. */
#define GUARD 64
#define GUARD_BYTE 0xA5

static uint8_t *guarded_alloc(int cap) {
    uint8_t *mem = malloc((size_t)cap + 2 * GUARD);
    memset(mem, GUARD_BYTE, (size_t)cap + 2 * GUARD);
    return mem;
}

static int guards_intact(const uint8_t *mem, int cap) {
    for (int i = 0; i < GUARD; i++) {
        if (mem[i] != GUARD_BYTE || mem[GUARD + cap + i] != GUARD_BYTE) return 0;
    }
    return 1;
}

static void fill(uint8_t *p, size_t n, uint32_t seed) {
    for (size_t i = 0; i < n; i++) p[i] = (uint8_t)(seed + i * 7u);
}

static int invariant(const struct tb_audio_ring *r) {
    return r->size >= 0 && r->size <= r->cap &&
           r->head >= 0 && r->head < r->cap &&
           r->tail >= 0 && r->tail < r->cap &&
           (r->tail + r->size) % r->cap == r->head;
}

static void test_basic_and_wrap(void) {
    int cap = 64;
    uint8_t *mem = guarded_alloc(cap);
    struct tb_audio_ring r;
    tb_audio_ring_init(&r, mem + GUARD, cap);

    uint8_t in[64], out[64];
    fill(in, sizeof(in), 1);
    CHECK(tb_audio_ring_push(&r, in, 40, 64) == 40);
    CHECK(r.size == 40);
    CHECK(tb_audio_ring_pop(&r, out, 32) == 32);
    CHECK(memcmp(out, in, 32) == 0);

    /* Wraps around the end of the buffer. */
    fill(in, sizeof(in), 50);
    CHECK(tb_audio_ring_push(&r, in, 48, 64) == 48);
    CHECK(r.size == 56);
    CHECK(invariant(&r));
    uint8_t expect[56];
    /* The 8 bytes left from the first packet, then the whole second one. */
    for (int i = 0; i < 8; i++) expect[i] = (uint8_t)(1 + (32 + i) * 7u);
    memcpy(expect + 8, in, 48);
    CHECK(tb_audio_ring_pop(&r, out, 64) == 56);
    CHECK(memcmp(out, expect, 56) == 0);
    CHECK(r.size == 0);
    CHECK(tb_audio_ring_pop(&r, out, 8) == 0);
    CHECK(guards_intact(mem, cap));
    free(mem);
}

static void test_backlog_drops_oldest(void) {
    int cap = 64;
    uint8_t *mem = guarded_alloc(cap);
    struct tb_audio_ring r;
    tb_audio_ring_init(&r, mem + GUARD, cap);

    uint8_t a[16], b[16], out[64];
    fill(a, sizeof(a), 10);
    fill(b, sizeof(b), 90);
    CHECK(tb_audio_ring_push(&r, a, 16, 24) == 16);
    CHECK(tb_audio_ring_push(&r, b, 16, 24) == 16);
    CHECK(r.size == 24);                    /* 8 oldest bytes of `a` dropped */
    CHECK(tb_audio_ring_pop(&r, out, 64) == 24);
    CHECK(memcmp(out, a + 8, 8) == 0);
    CHECK(memcmp(out + 8, b, 16) == 0);
    CHECK(guards_intact(mem, cap));
    free(mem);
}

static void test_oversized_packets(void) {
    /* The receiver's real sizes: one second of buffer, 150 ms of backlog. */
    int cap = 192000, backlog = 28800;
    uint8_t *mem = guarded_alloc(cap);
    struct tb_audio_ring r;
    tb_audio_ring_init(&r, mem + GUARD, cap);

    size_t sizes[] = { 28800, 28804, 192000, 192004, 400000, 1u << 20 };
    for (size_t i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++) {
        uint8_t *in = malloc(sizes[i]);
        fill(in, sizes[i], (uint32_t)i);
        int queued = tb_audio_ring_push(&r, in, sizes[i], backlog);
        CHECK(queued == backlog);
        CHECK(r.size == backlog);
        CHECK(invariant(&r));
        CHECK(guards_intact(mem, cap));

        /* What is kept is the newest audio of the packet. */
        uint8_t *out = malloc((size_t)backlog);
        CHECK(tb_audio_ring_pop(&r, out, backlog) == backlog);
        size_t whole = sizes[i] - sizes[i] % TB_AUDIO_FRAME_BYTES;
        CHECK(memcmp(out, in + whole - (size_t)backlog, (size_t)backlog) == 0);
        free(out);
        free(in);
    }

    /* A backlog larger than the buffer is clamped to the buffer. */
    uint8_t *big = malloc(400000);
    fill(big, 400000, 3);
    CHECK(tb_audio_ring_push(&r, big, 400000, 1 << 30) == cap);
    CHECK(r.size == cap);
    CHECK(invariant(&r));
    CHECK(guards_intact(mem, cap));
    free(big);
    free(mem);
}

static void test_edges(void) {
    int cap = 64;
    uint8_t *mem = guarded_alloc(cap);
    struct tb_audio_ring r;
    tb_audio_ring_init(&r, mem + GUARD, cap);
    uint8_t in[8] = {1, 2, 3, 4, 5, 6, 7, 8}, out[8];

    CHECK(tb_audio_ring_push(&r, in, 0, 64) == 0);
    CHECK(tb_audio_ring_push(&r, in, 3, 64) == 0);   /* less than one frame */
    CHECK(tb_audio_ring_push(&r, in, 7, 64) == 4);   /* trailing partial frame ignored */
    CHECK(tb_audio_ring_push(&r, NULL, 8, 64) == 0);
    CHECK(tb_audio_ring_push(&r, in, 8, 0) == 8);    /* non-positive backlog means the whole buffer */
    CHECK(r.size == 12);
    CHECK(tb_audio_ring_pop(&r, out, 0) == 0);
    CHECK(tb_audio_ring_pop(&r, NULL, 4) == 0);
    tb_audio_ring_reset(&r);
    CHECK(r.size == 0 && r.head == 0 && r.tail == 0);
    CHECK(guards_intact(mem, cap));
    free(mem);
}

/* Random pushes and pops against a plain reference queue. */
static void test_against_reference(void) {
    int cap = 96;
    uint8_t *mem = guarded_alloc(cap);
    struct tb_audio_ring r;
    tb_audio_ring_init(&r, mem + GUARD, cap);

    uint8_t ref[4096];
    int ref_len = 0;
    uint32_t seed = 12345;
    for (int step = 0; step < 20000; step++) {
        seed = seed * 1103515245u + 12345u;
        int backlog = 4 + (int)((seed >> 8) % 120);
        int len = (int)((seed >> 16) % 300);
        if ((seed >> 4) % 3 != 0) {
            uint8_t in[300];
            fill(in, (size_t)len, seed);
            tb_audio_ring_push(&r, in, (size_t)len, backlog);

            /* Reference: append whole frames, then keep the newest `limit`. */
            int limit = backlog > cap ? cap : backlog;
            limit -= limit % TB_AUDIO_FRAME_BYTES;
            int whole = len - len % TB_AUDIO_FRAME_BYTES;
            if (whole > 0 && limit > 0) {
                memcpy(ref + ref_len, in, (size_t)whole);
                ref_len += whole;
                if (ref_len > limit) {
                    memmove(ref, ref + ref_len - limit, (size_t)limit);
                    ref_len = limit;
                }
            }
        } else {
            uint8_t out[300], expect[300];
            int got = tb_audio_ring_pop(&r, out, len);
            int want = len < ref_len ? len : ref_len;
            memcpy(expect, ref, (size_t)want);
            memmove(ref, ref + want, (size_t)(ref_len - want));
            ref_len -= want;
            if (got != want || memcmp(out, expect, (size_t)want) != 0) {
                CHECK(got == want);
                CHECK(memcmp(out, expect, (size_t)want) == 0);
                break;
            }
        }
        if (!invariant(&r) || r.size != ref_len) {
            CHECK(invariant(&r));
            CHECK(r.size == ref_len);
            break;
        }
    }
    CHECK(guards_intact(mem, cap));
    checks++;
    free(mem);
}

int main(void) {
    test_basic_and_wrap();
    test_backlog_drops_oldest();
    test_oversized_packets();
    test_edges();
    test_against_reference();
    printf("audio ring tests: %d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
