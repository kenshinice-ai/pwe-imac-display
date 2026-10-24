/* tb_runloop_thread.h — a thread with its own CFRunLoop (PWE 1.1.1, A15).
 *
 * The global event tap that lets the iMac's keyboard and mouse drive the Mac
 * (receiverMaster) used to sit on the main run loop. The main loop services
 * run-loop sources once per pass, between decoding and drawing frames (17-35
 * ms a pass at 5K), so pointer events reached the Mac in bursts at the frame
 * rate, and a decoder stall froze them for seconds. On this thread the tap's
 * callback runs the moment macOS delivers an event, whatever the main loop is
 * doing.
 *
 *   struct tb_rlthread *t = tb_rlthread_start("PWE input tap");
 *   tb_rlthread_call(t, add_my_source, ctx);   // runs on t, returns when done
 *   ...                                        // the source fires on t
 *   tb_rlthread_call(t, remove_my_source, ctx);
 *   tb_rlthread_stop(t);
 *
 * tb_rlthread_call runs between the thread's callbacks, never during one: once
 * a call that removes a source returns, that source's callback is not running
 * and will not run again, so its state can be freed. Never call it while
 * holding a lock that the thread's callbacks take.
 */

#ifndef TB_RUNLOOP_THREAD_H
#define TB_RUNLOOP_THREAD_H

struct tb_rlthread;

/* Start the thread and wait until its run loop is ready. NULL on failure. */
struct tb_rlthread *tb_rlthread_start(const char *name);

/* Run fn(ctx) on the thread, in its run loop's default mode, and wait for it.
 * CFRunLoopGetCurrent() inside fn is the thread's run loop. 0, or -1 when
 * `t` is NULL or stopped (fn did not run). Callers are served one at a time. */
int tb_rlthread_call(struct tb_rlthread *t, void (*fn)(void *ctx), void *ctx);

/* Whether the calling thread is `t`'s thread. */
int tb_rlthread_is_current(const struct tb_rlthread *t);

/* Stop the run loop, join the thread and free `t`. NULL is a no-op. Remove
 * every source first: a source still attached is left to the run loop. Not
 * from the thread itself. */
void tb_rlthread_stop(struct tb_rlthread *t);

#endif
