/* tb_loopwatch.h — the main loop's watchdog (PWE 1.1, T40).
 *
 * The receiver does everything on one thread: network, decoding, drawing,
 * sound, the window. A call that blocks there freezes the picture and stops
 * the receiver answering the Mac, and the log says nothing about why. This
 * names it.
 *
 * The main thread says what it is about to do (TB_LOOP_PHASE, a string literal
 * with its file and line) and marks the start of every loop iteration
 * (tb_loopwatch_iteration). A background thread looks every 200 ms. When one
 * iteration has run longer than the threshold (2 s) it writes
 *
 *   [watchdog] main loop stuck 2.0 s in <phase> (main.c:1234)
 *   [watchdog]   #0 libsystem_kernel.dylib mach_msg2_trap+8
 *   [watchdog]   #1 ...                                  (the main thread's stack)
 *
 * then "still stuck" every 10 s, and when the loop turns again
 *
 *   [watchdog] main loop ran again after 46.6 s (stuck in <phase>)
 *
 * The stack is taken by suspending the main thread for a few microseconds and
 * walking its frame pointers; nothing that takes a lock runs while it is
 * suspended. Lines go to stderr with write(2), not stdio: the main thread may
 * be the one holding stderr's lock.
 *
 * Costs one relaxed atomic store per phase. main.c leaves the thread off
 * when TB_RECEIVER_LOOPWATCH=0 or the defaults key MainLoopWatchdog is false.
 * Times are uptime (CLOCK_UPTIME_RAW): a system sleep is not a stall.
 */

#ifndef TB_LOOPWATCH_H
#define TB_LOOPWATCH_H

#include <stdatomic.h>
#include <stdint.h>

#define TB_LOOPWATCH_STUCK_MS   2000u
#define TB_LOOPWATCH_REPEAT_MS 10000u

/* The phase the main thread is in; written by the macros below. */
extern _Atomic(const char *) tb_loopwatch_phase_now;

#define TB_LOOPWATCH_STR2(x) #x
#define TB_LOOPWATCH_STR(x) TB_LOOPWATCH_STR2(x)
#define TB_LOOPWATCH_HERE(what) what " (" __FILE_NAME__ ":" TB_LOOPWATCH_STR(__LINE__) ")"

/* Name what the main thread does next. `what` must be a string literal. */
#define TB_LOOP_PHASE(what) \
    atomic_store_explicit(&tb_loopwatch_phase_now, TB_LOOPWATCH_HERE(what), memory_order_relaxed)

/* For code called from several phases: name a nested step and give the
 * caller's phase back afterwards.
 *   const char *outer = TB_LOOP_ENTER("metal: next drawable"); ... TB_LOOP_LEAVE(outer); */
#define TB_LOOP_ENTER(what) \
    atomic_exchange_explicit(&tb_loopwatch_phase_now, TB_LOOPWATCH_HERE(what), memory_order_relaxed)
#define TB_LOOP_LEAVE(outer) \
    atomic_store_explicit(&tb_loopwatch_phase_now, (outer), memory_order_relaxed)

/* Start the watchdog. Call once, on the main thread (it watches the caller).
 * 0 on success; -1 when the thread could not start. */
int  tb_loopwatch_start(void);

/* The main loop starts an iteration. */
void tb_loopwatch_iteration(void);

/* Stop the thread (at exit). */
void tb_loopwatch_stop(void);

/* ---- The decision, separate so the unit test can drive it ---------------- */

enum tb_loopwatch_event {
    TB_LOOPWATCH_NONE = 0,
    TB_LOOPWATCH_STUCK,        /* first report of this stall */
    TB_LOOPWATCH_STILL_STUCK,  /* every repeat_ms after that */
    TB_LOOPWATCH_RECOVERED     /* the loop turned after a reported stall */
};

struct tb_loopwatch_track {
    int      stuck;            /* a stall of iteration `seq` was reported */
    uint64_t seq;
    uint64_t started_ms;       /* when that iteration started */
    uint64_t next_report_ms;
};

/* One look: `seq` and `started_ms` are the current iteration's number and
 * start time. *for_ms gets how long the stalled iteration ran (or has run). */
enum tb_loopwatch_event tb_loopwatch_decide(struct tb_loopwatch_track *t, uint64_t seq,
                                            uint64_t started_ms, uint64_t now_ms,
                                            uint64_t stuck_ms, uint64_t repeat_ms,
                                            uint64_t *for_ms);

#endif
