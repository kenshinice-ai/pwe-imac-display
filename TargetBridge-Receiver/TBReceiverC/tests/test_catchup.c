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
    /* A 6 MB keyframe counts as a 4-frame packet: half way there. */
    tb_catchup_note_frame(&c, 6000000u);
    CHECK(c.avg_frame_bytes == (FRAME + 4u * FRAME + 1) / 2);
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

/* Review 2026-10-24: a still desktop sends tiny frames (a few KB). One
 * ordinary frame must not count as a backlog, and the average must catch up
 * within a few frames once the picture moves. */
static void test_still_desktop(void) {
    struct tb_catchup c;
    tb_catchup_reset(&c);
    for (int i = 0; i < 50; i++) tb_catchup_note_frame(&c, 3000);
    CHECK(c.avg_frame_bytes == 3000);
    CHECK(tb_catchup_threshold(&c) == TB_CATCHUP_MIN_BEHIND_BYTES);
    /* A handful of small frames waiting, or one 200 KB frame: not behind. */
    CHECK(!tb_catchup_behind(&c, 10u * 3000u));
    CHECK(!tb_catchup_behind(&c, 200000u));
    /* A real backlog of small frames is still found by size: over 256 KB. */
    CHECK(tb_catchup_behind(&c, 300000u));
    /* The picture starts to move: 530 KB frames. Within 4 frames the average
     * is most of the way there, and a single frame no longer counts. */
    for (int i = 0; i < 4; i++) tb_catchup_note_frame(&c, FRAME);
    CHECK(c.avg_frame_bytes > FRAME * 3 / 4);
    CHECK(!tb_catchup_behind(&c, FRAME + 20000));
    CHECK(tb_catchup_behind(&c, 3u * FRAME));
}

static void test_read_size(void) {
    struct tb_catchup c;
    tb_catchup_reset(&c);
    for (int i = 0; i < 10; i++) tb_catchup_note_frame(&c, FRAME);
    const size_t buf = 1024u * 1024u;
    CHECK(tb_catchup_read_size(&c, 0, buf) == buf);       /* not behind: all there is */
    CHECK(tb_catchup_read_size(&c, 1, buf) == FRAME);     /* behind: about one frame */
    tb_catchup_reset(&c);
    for (int i = 0; i < 10; i++) tb_catchup_note_frame(&c, 2000);
    CHECK(tb_catchup_read_size(&c, 1, buf) == TB_CATCHUP_MIN_READ_BYTES);
    for (int i = 0; i < 10; i++) tb_catchup_note_frame(&c, 4000000u);
    CHECK(tb_catchup_read_size(&c, 1, buf) == buf);       /* never more than the buffer */
}

/* The waiting picture, as main.c uses it in one read pass. */
static int shown[16], dropped[16], n_shown, n_dropped;
static void show(void *frame, uint32_t id, void *ctx) { (void)ctx; (void)frame; shown[n_shown++] = (int)id; }
static void drop(void *frame, uint32_t id, void *ctx) { (void)ctx; (void)frame; dropped[n_dropped++] = (int)id; }

static void test_slot(void) {
    struct tb_catchup_slot slot = { NULL, 0, 0 };
    int pictures[8];
    n_shown = n_dropped = 0;
    /* Behind: pictures 1, 2, 3 decoded in one pass; the pass ends. */
    tb_catchup_hold(&slot, &pictures[1], 1, drop, NULL);
    tb_catchup_hold(&slot, &pictures[2], 2, drop, NULL);
    tb_catchup_hold(&slot, &pictures[3], 3, drop, NULL);
    tb_catchup_show(&slot, show, NULL);
    CHECK(n_shown == 1 && shown[0] == 3);
    CHECK(n_dropped == 2 && dropped[0] == 1 && dropped[1] == 2);
    CHECK(slot.frame == NULL && slot.skipped == 2);
    tb_catchup_show(&slot, show, NULL);   /* nothing waits: nothing shown */
    CHECK(n_shown == 1);
    /* Picture 4 waits, then a later chunk is not behind: picture 5 is shown
     * at once and 4 is dropped, never shown after it (also a RAW frame). */
    tb_catchup_hold(&slot, &pictures[4], 4, drop, NULL);
    tb_catchup_drop(&slot, drop, NULL);
    shown[n_shown++] = 5;
    tb_catchup_show(&slot, show, NULL);
    CHECK(n_shown == 2 && shown[1] == 5);
    CHECK(n_dropped == 3 && dropped[2] == 4 && slot.skipped == 3);
}

int main(void) {
    test_still_desktop();
    test_read_size();
    test_slot();
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
