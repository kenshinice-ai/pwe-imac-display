/* tb_input_rate.h — how fast the iMac's input reaches the Mac (PWE 1.1.1, A15).
 *
 * While the iMac's keyboard and mouse drive the Mac (receiverMaster), the event
 * tap notes every event it forwards and how old the event was when it was
 * sent (from the event's own timestamp). Every 10 s with input, one line:
 *
 *   [input] forwarded to the Mac over 8 s with input: 2310 events, avg 289/s,
 *           busiest second 498; event to send p50 0.1 ms, p95 0.4 ms, max 1.9 ms
 *
 * With the tap on the main run loop (1.1.0) events left in bursts at the frame
 * rate and waited up to a frame (17-35 ms) or a whole decoder stall; on its own
 * thread they leave as they come. TB_RECEIVER_TAP_ON_MAIN=1 puts the tap back
 * on the main run loop, so one build can show both on the same iMac.
 *
 * Not thread-safe: the tap's thread owns its tb_input_rate.
 */

#ifndef TB_INPUT_RATE_H
#define TB_INPUT_RATE_H

#include <stddef.h>
#include <stdint.h>

#define TB_INPUT_RATE_SAMPLES 2048   /* delay samples per report; later ones count but are not sampled */

struct tb_input_rate {
    uint64_t      window_start_ns;   /* first event of this report; 0 = none yet */
    uint64_t      second_start_ns;   /* the current one-second bucket */
    unsigned      second_count;
    unsigned      busiest_second;
    unsigned      seconds_with_input;
    unsigned long events;
    int           delay_count;
    double        delays_ms[TB_INPUT_RATE_SAMPLES];
    double        max_delay_ms;
};

void tb_input_rate_reset(struct tb_input_rate *r);

/* One event forwarded at `now_ns` (any monotonic clock); `delay_ms` is how old
 * it was, or negative when unknown. */
void tb_input_rate_note(struct tb_input_rate *r, uint64_t now_ns, double delay_ms);

/* When `window_ns` has passed since the report's first event: write the line
 * (without the "[input] " prefix) into `line`, start a new report and return
 * 1. Otherwise 0. */
int  tb_input_rate_report(struct tb_input_rate *r, uint64_t now_ns, uint64_t window_ns,
                          char *line, size_t size);

#endif
