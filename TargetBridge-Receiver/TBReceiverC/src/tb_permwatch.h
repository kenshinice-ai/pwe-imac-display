/* tb_permwatch.h — Input Monitoring and Accessibility, re-checked off the main
 * loop (PWE 1.1.1, A8).
 *
 * The receiver asked macOS for both permissions 4 times a second on its main
 * loop. Each answer is a round trip to the privacy service: on a 2021
 * MacBook Pro, CGPreflightListenEventAccess took 7.3 ms and AXIsProcessTrusted
 * 1.2 ms (measured 2026-10-24), so the loop lost about 10 ms in every 250 —
 * more on an old iMac, a hitch in the picture each time. A thread now asks
 * every 5 s, or soon after a kick (the window came to the front, the event
 * tap was switched off), never more than once a second, and the main loop
 * reads the latest answer for free.
 */

#ifndef TB_PERMWATCH_H
#define TB_PERMWATCH_H

#include <stdint.h>

#define TB_PERMWATCH_INTERVAL_MS 5000u
#define TB_PERMWATCH_MIN_GAP_MS  1000u

/* Asks macOS; runs on the watcher's thread. */
typedef void (*tb_permwatch_check_fn)(int *input_monitoring, int *accessibility);

struct tb_permwatch;

/* Start the thread; the first check runs at once. NULL on failure. */
struct tb_permwatch *tb_permwatch_start(tb_permwatch_check_fn check, uint64_t interval_ms, uint64_t min_gap_ms);

/* Check again soon: now, or min_gap_ms after the last check. */
void tb_permwatch_kick(struct tb_permwatch *w);

/* The latest answer. Returns its number (1, 2, ...), or 0 before the first. */
uint64_t tb_permwatch_read(struct tb_permwatch *w, int *input_monitoring, int *accessibility);

/* Stop and join the thread (waits for a check in progress). NULL is a no-op. */
void tb_permwatch_stop(struct tb_permwatch *w);

/* ---- When to check, separate so the unit test can drive it --------------- */

/* Milliseconds until the next check is due, 0 = now. `last_ms` 0 = never. */
uint64_t tb_permwatch_due_in(uint64_t now_ms, uint64_t last_ms, int kicked,
                             uint64_t interval_ms, uint64_t min_gap_ms);

#endif
