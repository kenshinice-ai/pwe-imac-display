/* test_clipboard.m — the clipboard worker (PWE 1.1, T40): change detection,
 * no echo of the Mac's own text, sessions, polling on and off, the size bound,
 * and an exit that does not wait for a stuck clipboard.
 *
 * Uses named pasteboards of its own, never the system clipboard. Needs a
 * logged-in session (the pasteboard server); prints SKIP without one. */

#include "../src/tb_clipboard.h"

#import <AppKit/AppKit.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg) do {                                              \
    g_checks++;                                                            \
    if (!(cond)) {                                                         \
        g_failures++;                                                      \
        fprintf(stderr, "FAIL %s:%d — %s\n", __FILE__, __LINE__, (msg));   \
    }                                                                      \
} while (0)

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

/* Another app copies text: a separate pasteboard object, as another process. */
static void other_app_copies(NSString *name, NSString *text) {
    @autoreleasepool {
        NSPasteboard *pb = [NSPasteboard pasteboardWithName:name];
        [pb clearContents];
        [pb setString:text forType:NSPasteboardTypeString];
    }
}

static NSString *pasteboard_text(NSString *name) {
    @autoreleasepool {
        return [[NSPasteboard pasteboardWithName:name] stringForType:NSPasteboardTypeString];
    }
}

/* Takes for up to `ms`; 1 and the text at the first take. */
static int take_within(struct tb_clipboard *c, unsigned ms, char *out, size_t size) {
    const uint64_t until = now_ms() + ms;
    do {
        if (tb_clipboard_take(c, out, size)) return 1;
        usleep(10000);
    } while (now_ms() < until);
    return 0;
}

static NSString *fresh_name(const char *what) {
    return [NSString stringWithFormat:@"com.pwegroup.pweimacdisplay.test.clipboard.%d.%s", getpid(), what];
}

static void release_pasteboard(NSString *name) {
    @autoreleasepool { [[NSPasteboard pasteboardWithName:name] releaseGlobally]; }
}

static void test_change_detection_and_echo(void) {
    NSString *name = fresh_name("echo");
    struct tb_clipboard *c = tb_clipboard_create(name.UTF8String);
    CHECK(c != NULL, "worker starts");
    char text[TB_CLIPBOARD_MAX_TEXT];

    tb_clipboard_set_polling(c, 1);
    CHECK(!take_within(c, 300, text, sizeof(text)), "an empty clipboard sends nothing");

    other_app_copies(name, @"copied on the iMac");
    CHECK(take_within(c, 1000, text, sizeof(text)) && strcmp(text, "copied on the iMac") == 0,
          "a copy on the iMac is taken within 1 s");
    CHECK(!take_within(c, 300, text, sizeof(text)), "and taken once");

    other_app_copies(name, @"copied on the iMac");
    CHECK(!take_within(c, 400, text, sizeof(text)), "copying the same text again sends nothing");

    tb_clipboard_write(c, "from the Mac");
    const uint64_t until = now_ms() + 1000;
    while (now_ms() < until && ![pasteboard_text(name) isEqualToString:@"from the Mac"]) usleep(10000);
    CHECK([pasteboard_text(name) isEqualToString:@"from the Mac"], "the Mac's text is on the iMac within 1 s");
    CHECK(!take_within(c, 500, text, sizeof(text)), "the Mac's own text is not sent back");

    other_app_copies(name, @"copied on the iMac");
    CHECK(take_within(c, 1000, text, sizeof(text)) && strcmp(text, "copied on the iMac") == 0,
          "after the Mac's text, the earlier iMac text is new again and sent");

    CHECK(tb_clipboard_destroy(c, 1000) == 1, "worker stops");
    release_pasteboard(name);
}

static void test_polling_and_sessions(void) {
    NSString *name = fresh_name("sessions");
    other_app_copies(name, @"there before the session");
    struct tb_clipboard *c = tb_clipboard_create(name.UTF8String);
    char text[TB_CLIPBOARD_MAX_TEXT];

    CHECK(!take_within(c, 300, text, sizeof(text)), "not polling: nothing taken");
    tb_clipboard_set_polling(c, 1);
    CHECK(take_within(c, 1000, text, sizeof(text)) && strcmp(text, "there before the session") == 0,
          "the session's first poll sends the current text (upstream)");

    tb_clipboard_set_polling(c, 0);
    other_app_copies(name, @"copied while off");
    usleep(300000);
    CHECK(!take_within(c, 200, text, sizeof(text)), "polling off: a copy is not taken");
    tb_clipboard_set_polling(c, 1);
    CHECK(take_within(c, 1000, text, sizeof(text)) && strcmp(text, "copied while off") == 0,
          "polling on again: the copy made meanwhile is sent");

    tb_clipboard_set_polling(c, 0);
    tb_clipboard_new_session(c);
    tb_clipboard_set_polling(c, 1);
    CHECK(take_within(c, 1000, text, sizeof(text)) && strcmp(text, "copied while off") == 0,
          "a new session sends the current text again");

    CHECK(tb_clipboard_destroy(c, 1000) == 1, "worker stops");
    release_pasteboard(name);
}

static void test_size_bound(void) {
    NSString *name = fresh_name("size");
    struct tb_clipboard *c = tb_clipboard_create(name.UTF8String);
    tb_clipboard_set_polling(c, 1);
    usleep(200000);
    /* 4094 ASCII bytes, then a 3-byte character that does not fit. */
    NSMutableString *big = [NSMutableString string];
    for (int i = 0; i < 4094; i++) [big appendString:@"a"];
    [big appendString:@"中"];
    [big appendString:@"tail"];
    other_app_copies(name, big);
    char text[TB_CLIPBOARD_MAX_TEXT];
    CHECK(take_within(c, 1000, text, sizeof(text)), "long text is taken");
    CHECK(strlen(text) == 4094, "cut before a character that does not fit in 4095 bytes");
    /* The Mac's text cut inside a character (the 4096-byte packet field). */
    char cut[16];
    snprintf(cut, sizeof(cut), "abc\xe4\xb8");   /* "abc" and two of the three bytes of U+4E2D */
    tb_clipboard_write(c, cut);
    const uint64_t until = now_ms() + 1000;
    while (now_ms() < until && ![pasteboard_text(name) isEqualToString:@"abc"]) usleep(10000);
    CHECK([pasteboard_text(name) isEqualToString:@"abc"], "a character cut short is dropped, the rest written");
    CHECK(!take_within(c, 300, text, sizeof(text)), "and not sent back");
    tb_clipboard_write(c, "\xff\xfe not text");
    usleep(300000);
    CHECK([pasteboard_text(name) isEqualToString:@"abc"], "bytes that are not UTF-8 leave the clipboard alone");

    CHECK(tb_clipboard_destroy(c, 1000) == 1, "worker stops");
    release_pasteboard(name);
}

static void test_main_loop_never_waits(void) {
    /* A clipboard that takes 3 s to give its text, as with Screen Sharing. */
    setenv("TB_RECEIVER_TEST_CLIPBOARD_READ_DELAY_MS", "3000", 1);
    NSString *name = fresh_name("stuck");
    struct tb_clipboard *c = tb_clipboard_create(name.UTF8String);
    unsetenv("TB_RECEIVER_TEST_CLIPBOARD_READ_DELAY_MS");
    char text[TB_CLIPBOARD_MAX_TEXT];

    tb_clipboard_set_polling(c, 1);
    other_app_copies(name, @"slow text");
    usleep(300000);   /* the worker is inside the slow read now */
    uint64_t t0 = now_ms();
    for (int i = 0; i < 100; i++) (void)tb_clipboard_take(c, text, sizeof(text));
    tb_clipboard_write(c, "queued behind the read");
    tb_clipboard_set_polling(c, 0);
    tb_clipboard_set_polling(c, 1);
    CHECK(now_ms() - t0 < 50, "take, write and polling calls return at once during a slow read");

    t0 = now_ms();
    CHECK(tb_clipboard_destroy(c, 200) == 0, "exit leaves a worker stuck in a read behind");
    CHECK(now_ms() - t0 < 500, "and waits no longer than asked");
    /* The worker still owns `c`; the process would _exit here. */
    release_pasteboard(name);
}

/* PWE (1.1.1, R1; AUDIT-RELEASE-2026-10-22 R1): the Mac's text queued while
 * the worker was inside a slow read, then the session ends (disconnect,
 * forget, re-pair) and someone copies on the iMac. 1.1.0 wrote the stale text
 * over the newer copy once the read ended, and took it as the new session's
 * Mac copy. Now the queued write belongs to its session and is dropped. */
static void test_stale_write_after_session_change(void) {
    setenv("TB_RECEIVER_TEST_CLIPBOARD_READ_DELAY_MS", "1500", 1);
    NSString *name = fresh_name("stale");
    struct tb_clipboard *c = tb_clipboard_create(name.UTF8String);
    unsetenv("TB_RECEIVER_TEST_CLIPBOARD_READ_DELAY_MS");
    char text[TB_CLIPBOARD_MAX_TEXT];

    tb_clipboard_set_polling(c, 1);
    other_app_copies(name, @"before");
    usleep(300000);                                   /* the worker is in the 1.5 s read */
    tb_clipboard_write(c, "the old session's Mac text");   /* queued behind the read */
    tb_clipboard_set_polling(c, 0);                   /* the session ends */
    tb_clipboard_new_session(c);
    other_app_copies(name, @"copied on the iMac after the session");
    usleep(2500000);                                  /* the read is long over */
    CHECK([pasteboard_text(name) isEqualToString:@"copied on the iMac after the session"],
          "a write queued in an ended session never overwrites newer iMac text");

    /* The next session: the iMac's current text goes to its Mac, never the old text. */
    tb_clipboard_set_polling(c, 1);
    CHECK(take_within(c, 4000, text, sizeof(text)) && strcmp(text, "copied on the iMac after the session") == 0,
          "the new session is sent the iMac's text, not the old session's");
    CHECK(tb_clipboard_destroy(c, 3000) == 1, "worker stops");
    release_pasteboard(name);
}

/* PWE (1.1.1, R1): a write already inside the pasteboard call when the
 * session ends finishes, but its text is not the next session's to have. */
static void test_write_in_flight_at_session_change(void) {
    NSString *name = fresh_name("inflight");
    struct tb_clipboard *c = tb_clipboard_create(name.UTF8String);
    char text[TB_CLIPBOARD_MAX_TEXT];
    tb_clipboard_set_polling(c, 1);
    usleep(200000);
    tb_clipboard_write(c, "written as the session ends");
    tb_clipboard_set_polling(c, 0);
    tb_clipboard_new_session(c);
    usleep(300000);
    tb_clipboard_set_polling(c, 1);
    /* Either it was dropped before the call, or it was written and is then
     * not sent to the new session as the iMac's copy. */
    const int took = take_within(c, 600, text, sizeof(text));
    CHECK(!took || strcmp(text, "written as the session ends") != 0,
          "the old session's Mac text is never sent to the new session");
    CHECK(tb_clipboard_destroy(c, 1000) == 1, "worker stops");
    release_pasteboard(name);
}

int main(void) {
    @autoreleasepool {
        NSPasteboard *probe = [NSPasteboard pasteboardWithUniqueName];
        if (!probe) {
            printf("SKIP test_clipboard: no pasteboard server\n");
            return 0;
        }
        [probe releaseGlobally];
    }
    test_change_detection_and_echo();
    test_polling_and_sessions();
    test_size_bound();
    test_stale_write_after_session_change();
    test_write_in_flight_at_session_change();
    test_main_loop_never_waits();
    if (g_failures) {
        fprintf(stderr, "test_clipboard: %d of %d checks FAILED\n", g_failures, g_checks);
        return 1;
    }
    printf("test_clipboard: all %d checks passed\n", g_checks);
    return 0;
}
