/* tb_decthreads.h — how many threads FFmpeg's software decoder gets (PWE 1.1.1, A5).
 *
 * VideoToolbox decodes on the GPU's media engine and needs no CPU threads. When
 * FFmpeg decodes in software instead (no hardware configuration for the codec,
 * VideoToolbox refusing the stream, or TB_RECEIVER_SOFTWARE_DECODE), one thread
 * decodes a 5K picture at a few frames a second. min(4, CPUs) threads:
 *
 *   slice threading first: the threads share one picture, so no frame waits
 *     longer than it would on one thread. It only helps when the encoder cut
 *     the picture into slices (or HEVC wavefront rows); Apple's encoders may not.
 *   frame threading otherwise, or when asked for (TB_RECEIVER_SOFTWARE_DECODE=
 *     frame): the threads decode successive pictures, and each picture leaves
 *     the decoder threads - 1 frames later (3 frames, 50-100 ms, with 4).
 *
 * Header only, so the plan is tested without FFmpeg.
 */

#ifndef TB_DECTHREADS_H
#define TB_DECTHREADS_H

#define TB_DEC_MAX_SOFTWARE_THREADS 4

enum tb_dec_threading {
    TB_DEC_THREADS_ONE = 0,    /* one thread: no threading */
    TB_DEC_THREADS_SLICE,
    TB_DEC_THREADS_FRAME
};

/* The plan for `ncpu` CPUs and what the codec can do. Returns the thread count
 * (1 with TB_DEC_THREADS_ONE) and sets *how. */
static inline int tb_dec_thread_plan(int ncpu, int can_slice, int can_frame, int want_frame,
                                     enum tb_dec_threading *how) {
    int n = ncpu < TB_DEC_MAX_SOFTWARE_THREADS ? ncpu : TB_DEC_MAX_SOFTWARE_THREADS;
    *how = TB_DEC_THREADS_ONE;
    if (n < 2) return 1;
    if (want_frame && can_frame) *how = TB_DEC_THREADS_FRAME;
    else if (can_slice) *how = TB_DEC_THREADS_SLICE;
    else if (can_frame) *how = TB_DEC_THREADS_FRAME;
    else return 1;
    return n;
}

#endif
