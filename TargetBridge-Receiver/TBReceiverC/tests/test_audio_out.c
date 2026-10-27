/* test_audio_out.c — the receiver's sound output thread (audio_out.h).
 *
 * Runs on SDL's dummy audio driver: no sound device is opened and the system
 * volume is never touched (tb_audio_out_set_volume is not called here). */

#include "audio_out.h"

#include <SDL.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int checks;
static int failures;

#define CHECK(condition) do { \
    checks++; \
    if (!(condition)) { \
        failures++; \
        fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); \
    } \
} while (0)

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

static void sleep_ms(unsigned ms) {
    struct timespec ts = { (time_t)(ms / 1000u), (long)(ms % 1000u) * 1000000L };
    nanosleep(&ts, NULL);
}

/* Wait up to `ms` for the device to be open (1) or closed (0). */
static int wait_open(struct tb_audio_out *o, int want, unsigned ms) {
    const uint64_t until = now_ms() + ms;
    while (now_ms() < until) {
        if (tb_audio_out_device_open(o) == want) return 1;
        sleep_ms(10);
    }
    return tb_audio_out_device_open(o) == want;
}

static void test_decide(void) {
    const uint64_t close_after = TB_AUDIO_OUT_CLOSE_AFTER_MS;
    /* Wanted and closed: open, unless a failed open waits for its retry. */
    CHECK(tb_audio_out_decide(1, 0, 0, 0, 1000) == TB_AUDIO_OUT_OPEN);
    CHECK(tb_audio_out_decide(1, 0, 0, 5000, 4999) == TB_AUDIO_OUT_NOTHING);
    CHECK(tb_audio_out_decide(1, 0, 0, 5000, 5000) == TB_AUDIO_OUT_OPEN);
    /* Wanted and open: nothing. */
    CHECK(tb_audio_out_decide(1, 1, 0, 0, 1000) == TB_AUDIO_OUT_NOTHING);
    /* Unwanted and open: close only after the grace period. */
    CHECK(tb_audio_out_decide(0, 1, 10000, 0, 10000 + close_after - 1) == TB_AUDIO_OUT_NOTHING);
    CHECK(tb_audio_out_decide(0, 1, 10000, 0, 10000 + close_after) == TB_AUDIO_OUT_CLOSE);
    /* Unwanted and closed: nothing. */
    CHECK(tb_audio_out_decide(0, 0, 10000, 0, 99999) == TB_AUDIO_OUT_NOTHING);
}

static void test_worker(void) {
    setenv("SDL_AUDIODRIVER", "dummy", 1);
    if (SDL_Init(SDL_INIT_AUDIO) < 0) {
        printf("test_audio_out: SKIP the worker (SDL_Init: %s)\n", SDL_GetError());
        return;
    }
    struct tb_audio_out *o = tb_audio_out_create();
    CHECK(o != NULL);
    if (!o) return;

    uint8_t pcm[1920];   /* 10 ms of silence */
    memset(pcm, 0, sizeof(pcm));
    CHECK(!tb_audio_out_device_open(o));

    /* The first packet opens the device, on the worker. */
    const uint64_t t0 = now_ms();
    tb_audio_out_push(o, pcm, sizeof(pcm));
    CHECK(now_ms() - t0 < 100);   /* the caller never waits for the open */
    CHECK(wait_open(o, 1, 2000));

    /* A session ends and the next one's sound comes within the grace period
     * (a picture change): the device stays open throughout. */
    tb_audio_out_idle(o);
    sleep_ms(500);
    CHECK(tb_audio_out_device_open(o));
    tb_audio_out_push(o, pcm, sizeof(pcm));
    sleep_ms(TB_AUDIO_OUT_CLOSE_AFTER_MS + 300);
    CHECK(tb_audio_out_device_open(o));

    /* Idle for longer: the device closes after the grace period, not before. */
    const uint64_t idle_at = now_ms();
    tb_audio_out_idle(o);
    CHECK(wait_open(o, 0, TB_AUDIO_OUT_CLOSE_AFTER_MS + 1000));
    CHECK(now_ms() - idle_at >= TB_AUDIO_OUT_CLOSE_AFTER_MS - 50);

    /* Sound again: it opens again. Then exit closes it within the wait. */
    tb_audio_out_push(o, pcm, sizeof(pcm));
    CHECK(wait_open(o, 1, 2000));
    const uint64_t t1 = now_ms();
    CHECK(tb_audio_out_destroy(o, 1000) == 1);
    CHECK(now_ms() - t1 < 1000);
    SDL_Quit();
}

/* Quit while the device is still closing (a stuck CoreAudio): destroy gives
 * up after its wait and says so, so the caller leaves SDL's audio alone.
 * Needs the test hook that slows the close. Runs last: the worker is left
 * behind inside the close, and SDL is not shut down under it. */
static void test_quit_while_closing(void) {
#if TB_RECEIVER_TEST_HOOKS
    setenv("SDL_AUDIODRIVER", "dummy", 1);
    if (SDL_Init(SDL_INIT_AUDIO) < 0) return;
    setenv("TB_RECEIVER_TEST_AUDIO_CLOSE_DELAY_MS", "2000", 1);
    struct tb_audio_out *o = tb_audio_out_create();
    CHECK(o != NULL);
    if (!o) return;
    uint8_t pcm[1920];
    memset(pcm, 0, sizeof(pcm));
    tb_audio_out_push(o, pcm, sizeof(pcm));
    CHECK(wait_open(o, 1, 2000));
    const uint64_t t0 = now_ms();
    CHECK(tb_audio_out_destroy(o, 300) == 0);   /* left behind, not freed */
    const uint64_t took = now_ms() - t0;
    CHECK(took >= 280 && took < 1000);
#endif
}

int main(void) {
    test_decide();
    test_worker();
    test_quit_while_closing();
    if (failures) {
        fprintf(stderr, "test_audio_out: %d of %d checks failed\n", failures, checks);
        return 1;
    }
    printf("test_audio_out: %d checks passed\n", checks);
    return 0;
}
