/* test_pairing_hint.c — when the idle screen says no one typed the code (tb_pairing_hint.h). */

#include "tb_pairing_hint.h"

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
    const uint64_t expires = 100000;   /* the code shown at 40 s runs out at 100 s */
    /* No code on this connection: nothing to say. */
    CHECK(!tb_pairing_code_went_unanswered(0, 0, 200000));
    /* The Mac gave up after the code ran out (it waits a second longer). */
    CHECK(tb_pairing_code_went_unanswered(expires, 0, expires + 1000));
    CHECK(tb_pairing_code_went_unanswered(expires, 0, expires + 60000));
    /* or a moment before the iMac's own countdown ended. */
    CHECK(tb_pairing_code_went_unanswered(expires, 0, expires - 2000));
    /* Ended well before: someone stopped it on the Mac, or the cable came out. */
    CHECK(!tb_pairing_code_went_unanswered(expires, 0, expires - 2001));
    CHECK(!tb_pairing_code_went_unanswered(expires, 0, expires - 30000));
    /* A code was typed (right or wrong): someone is there. */
    CHECK(!tb_pairing_code_went_unanswered(expires, 1, expires + 1000));
    if (failures) {
        fprintf(stderr, "test_pairing_hint: %d of %d checks failed\n", failures, checks);
        return 1;
    }
    printf("test_pairing_hint: %d checks passed\n", checks);
    return 0;
}
