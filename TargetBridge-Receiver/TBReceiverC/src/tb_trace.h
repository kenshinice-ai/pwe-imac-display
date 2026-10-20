/* tb_trace.h — per-frame timing of the receiver's video path.
 *
 * Off by default. TB_RECEIVER_TRACE=1 turns it on: every video frame gets an
 * id when its packet is complete, each stage stamps that id, and once a second
 * one summary line goes to stderr:
 *
 *   [trace] in=60 shown=60 replaced=0 repeat=0 late=0 | ms p50/p95 decode 4.1/6.0
 *           upload 2.3/3.1 submit 0.2/0.4 display 9.8/16.1 total 17.0/24.3 gap 16.6/18.2
 *           handoff 6.6/9.5
 *
 * Stages (each the time from the previous mark):
 *   decode   packet complete  -> decoded frame handed to the display
 *   upload   decoded          -> texture ready (GL: SDL_UpdateNVTexture done;
 *                                Metal: waiting for the refresh + texture creation)
 *   submit   texture ready    -> frame handed to the GPU (present called / committed)
 *   display  submitted        -> presented (GL: SDL_RenderPresent returned;
 *                                Metal: the drawable's presentedTime)
 *   total    packet complete  -> presented
 *   gap      time between two complete frame packets
 *   handoff  packet complete  -> submitted: the one end-to-end figure that means
 *            the same on both renderers. "display" and "total" do not: on GL
 *            they stop when SDL_RenderPresent returns, before the window
 *            server composites the frame; on Metal they run to the screen.
 *            Compare OpenGL and Metal on handoff, not on total.
 * Counters: in = frame packets, shown = frames presented, replaced = decoded
 * frames overwritten before they were shown, repeat = refreshes while streaming
 * that had no new frame, late = frames shown more than two refreshes after they
 * were decoded.
 *
 * Every function is safe to call from any thread and costs one branch when the
 * trace is off. Times are nanoseconds on CLOCK_UPTIME_RAW, the clock behind
 * mach_absolute_time() and CACurrentMediaTime().
 */

#ifndef TB_TRACE_H
#define TB_TRACE_H

#include <stdint.h>

enum tb_trace_mark {
    TB_TRACE_ARRIVE = 0,
    TB_TRACE_DECODED,
    TB_TRACE_TEX_READY,
    TB_TRACE_SUBMITTED,
    TB_TRACE_PRESENTED,
    TB_TRACE_MARK_COUNT
};

int      tb_trace_enabled(void);
uint64_t tb_trace_now_ns(void);

/* Labels for the first line and the refresh period used to judge "late". */
void     tb_trace_configure(const char *renderer, const char *pacing, uint64_t refresh_ns);

/* A frame packet is complete: returns its id (0 when the trace is off). */
uint32_t tb_trace_frame_arrived(void);

/* Stamp one stage of frame `id`. Id 0 is ignored. The first PRESENTED closes
 * the record; later marks for the same id (a redraw) are ignored. */
void     tb_trace_mark(uint32_t id, enum tb_trace_mark mark, uint64_t t_ns);
void     tb_trace_mark_now(uint32_t id, enum tb_trace_mark mark);

void     tb_trace_frame_replaced(uint32_t id);
void     tb_trace_repeat(unsigned count);

/* Print the summary if a second has passed. Call from the main loop. */
void     tb_trace_tick(uint64_t now_ns);

/* For the unit test: percentile (0..100) of `n` values, sorting them in place. */
double   tb_trace_percentile(double *values, int n, double pct);

#endif
