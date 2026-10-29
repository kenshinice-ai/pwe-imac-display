/* tb_pairing_hint.h — when the idle screen says no one typed the pairing code
 * (PWE 1.1.1, R5).
 *
 * A Mac with no screen of its own asks the iMac for a pairing code; when a
 * code runs out with no one typing it, the Mac drops the connection and asks
 * again, and after a few unanswered codes it stops asking. The iMac then sat
 * on its idle screen with no word of what happened. From its own pairing
 * state alone (no change to the protocol): a connection that showed a code
 * and ends when that code has run out, or within 2 s of it, with no code typed
 * (right or wrong) leaves a hint on the idle screen until the next connection:
 * "No one typed the code. Unplug the cable and plug it back in to try again."
 * The Mac gives up a moment after the iMac's own countdown, so "within 2 s"
 * covers both orders. Header only, for the tests.
 */

#ifndef TB_PAIRING_HINT_H
#define TB_PAIRING_HINT_H

#include <stdint.h>

#define TB_PAIRING_HINT_SLACK_MS 2000u

/* code_expires_ms: when the last code this connection showed runs out (0:
 * none shown). answered: a code was typed on this connection, right or wrong.
 * now_ms: the connection is closing. */
static inline int tb_pairing_code_went_unanswered(uint64_t code_expires_ms, int answered, uint64_t now_ms) {
    if (code_expires_ms == 0 || answered) return 0;
    return now_ms + TB_PAIRING_HINT_SLACK_MS >= code_expires_ms;
}

#endif
