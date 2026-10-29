/* test_decthreads.c — threads for FFmpeg's software decoder (tb_decthreads.h). */

#include "tb_decthreads.h"

#include <stdio.h>

static int checks;
static int failures;

#define CHECK(condition) do { \
    checks++; \
    if (!(condition)) { \
        failures++; \
        fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); \
    } \
} while (0)

int main(void) {
    enum tb_dec_threading how = TB_DEC_THREADS_FRAME;

    /* min(4, CPUs), slice threads first (HEVC and H.264 can do both). */
    CHECK(tb_dec_thread_plan(8, 1, 1, 0, &how) == 4 && how == TB_DEC_THREADS_SLICE);
    CHECK(tb_dec_thread_plan(4, 1, 1, 0, &how) == 4 && how == TB_DEC_THREADS_SLICE);
    CHECK(tb_dec_thread_plan(2, 1, 1, 0, &how) == 2 && how == TB_DEC_THREADS_SLICE);
    /* One CPU, or an unknown count: no threading. */
    CHECK(tb_dec_thread_plan(1, 1, 1, 0, &how) == 1 && how == TB_DEC_THREADS_ONE);
    CHECK(tb_dec_thread_plan(0, 1, 1, 0, &how) == 1 && how == TB_DEC_THREADS_ONE);
    CHECK(tb_dec_thread_plan(-1, 1, 1, 0, &how) == 1 && how == TB_DEC_THREADS_ONE);
    /* Frame threads when asked for, or when slices are not supported. */
    CHECK(tb_dec_thread_plan(8, 1, 1, 1, &how) == 4 && how == TB_DEC_THREADS_FRAME);
    CHECK(tb_dec_thread_plan(8, 0, 1, 0, &how) == 4 && how == TB_DEC_THREADS_FRAME);
    /* Asked for frames the codec cannot do: slices. Neither: one thread. */
    CHECK(tb_dec_thread_plan(8, 1, 0, 1, &how) == 4 && how == TB_DEC_THREADS_SLICE);
    CHECK(tb_dec_thread_plan(8, 0, 0, 0, &how) == 1 && how == TB_DEC_THREADS_ONE);

    /* Review 2026-10-24: without the setting (FFmpeg's own software decoding,
     * after VideoToolbox refused a stream) frame threads come first. */
    CHECK(tb_dec_prefer_frame(NULL) == 1);
    CHECK(tb_dec_prefer_frame("") == 1);
    CHECK(tb_dec_prefer_frame("frame") == 1);
    CHECK(tb_dec_prefer_frame("1") == 0);
    CHECK(tb_dec_prefer_frame("slice") == 0);
    CHECK(tb_dec_prefer_frame("slices") == 1);
    CHECK(tb_dec_thread_plan(8, 1, 1, tb_dec_prefer_frame(NULL), &how) == 4 && how == TB_DEC_THREADS_FRAME);
    CHECK(tb_dec_thread_plan(8, 1, 1, tb_dec_prefer_frame("slice"), &how) == 4 && how == TB_DEC_THREADS_SLICE);

    if (failures) {
        fprintf(stderr, "test_decthreads: %d of %d checks failed\n", failures, checks);
        return 1;
    }
    printf("test_decthreads: %d checks passed\n", checks);
    return 0;
}
