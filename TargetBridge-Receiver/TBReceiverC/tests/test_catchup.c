/* test_catchup.c — when the receiver counts as behind the sender (tb_catchup.h). */

#include "tb_catchup.h"

#include <stdio.h>
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

/* 5K HEVC at about 150 Mbit/s and 35 fps: about 530 KB a frame. */
#define FRAME 530000u

static void test_normal_stream_never_behind(void) {
    struct tb_catchup c;
    tb_catchup_reset(&c);
    /* No average yet: never behind, whatever is waiting. */
    CHECK(!tb_catchup_behind(&c, 100u * FRAME));
    for (int i = 0; i < 3; i++) tb_catchup_note_frame(&c, FRAME);
    CHECK(!tb_catchup_behind(&c, 100u * FRAME));
    tb_catchup_note_frame(&c, FRAME);
    /* A read that returns one frame, with sound and pointer packets around it. */
    CHECK(!tb_catchup_behind(&c, FRAME + 20000));
    /* Two frames waiting is still not behind; more than two is. */
    CHECK(!tb_catchup_behind(&c, 2u * FRAME));
    CHECK(tb_catchup_behind(&c, 2u * FRAME + 1));
    /* After a 2.8 s stall at 35 fps: about 100 frames waiting. */
    CHECK(tb_catchup_behind(&c, 100u * FRAME));
}

static void test_keyframe_counts_at_most_four(void) {
    struct tb_catchup c;
    tb_catchup_reset(&c);
    for (int i = 0; i < 20; i++) tb_catchup_note_frame(&c, FRAME);
    CHECK(c.avg_frame_bytes == FRAME);
    /* A 6 MB keyframe moves the average as a 4-frame packet would. */
    tb_catchup_note_frame(&c, 6000000u);
    CHECK(c.avg_frame_bytes == (FRAME * 7 + 4u * FRAME) / 8);
    /* and it settles back within a couple of dozen frames. */
    for (int i = 0; i < 24; i++) tb_catchup_note_frame(&c, FRAME);
    CHECK(c.avg_frame_bytes < FRAME + FRAME / 10);
}

static void test_reset(void) {
    struct tb_catchup c;
    tb_catchup_reset(&c);
    for (int i = 0; i < 10; i++) tb_catchup_note_frame(&c, FRAME);
    CHECK(tb_catchup_behind(&c, 10u * FRAME));
    tb_catchup_reset(&c);   /* a new session starts with no average */
    CHECK(!tb_catchup_behind(&c, 10u * FRAME));
    CHECK(c.frames_seen == 0);
}

int main(void) {
    test_normal_stream_never_behind();
    test_keyframe_counts_at_most_four();
    test_reset();
    if (failures) {
        fprintf(stderr, "test_catchup: %d of %d checks failed\n", failures, checks);
        return 1;
    }
    printf("test_catchup: %d checks passed\n", checks);
    return 0;
}
