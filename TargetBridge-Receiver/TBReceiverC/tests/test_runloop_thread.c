/* test_runloop_thread.c — the event tap's own run-loop thread
 * (tb_runloop_thread.h, PWE 1.1.1, A15).
 *
 * The tap's events arrive as Mach messages on a CFMachPort. This sends Mach
 * messages at 400 a second, like a fast mouse, and compares:
 *   before: the port on the main run loop, serviced once per pass of a loop
 *           that spends 17 ms a pass on a frame (how 1.1.0 ran the tap);
 *   after:  the port on its own tb_rlthread while the main thread is stuck
 *           for the whole run (a decoder stall).
 * It prints events handled a second and how long each waited, and checks that
 * the thread handles every event promptly however busy the main thread is. */

#include "tb_runloop_thread.h"

#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int checks;
static int failures;

#define CHECK(condition) do { \
    checks++; \
    if (!(condition)) { \
        failures++; \
        fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); \
    } \
} while (0)

static uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

struct msg {
    mach_msg_header_t header;
    uint64_t          sent_ns;
};

#define MAX_EVENTS 1024

struct sink {
    atomic_int handled;
    double     delays_ms[MAX_EVENTS];
    pthread_t  handled_on;
};

static void on_message(CFMachPortRef port, void *raw, CFIndex size, void *info) {
    (void)port;
    struct sink *s = (struct sink *)info;
    const struct msg *m = (const struct msg *)raw;
    if ((size_t)size < sizeof(*m)) return;
    const int i = atomic_load(&s->handled);
    if (i < MAX_EVENTS) s->delays_ms[i] = (double)(now_ns() - m->sent_ns) / 1e6;
    s->handled_on = pthread_self();
    atomic_fetch_add(&s->handled, 1);
}

struct producer {
    mach_port_t port;
    int         count;
    unsigned    interval_us;
    int         sent;
};

static void *produce(void *arg) {
    struct producer *p = (struct producer *)arg;
    for (int i = 0; i < p->count; i++) {
        struct msg m;
        memset(&m, 0, sizeof(m));
        m.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MAKE_SEND, 0);
        m.header.msgh_size = sizeof(m);
        m.header.msgh_remote_port = p->port;
        m.header.msgh_id = i;
        m.sent_ns = now_ns();
        if (mach_msg(&m.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(m), 0, MACH_PORT_NULL, 2000,
                     MACH_PORT_NULL) == MACH_MSG_SUCCESS) {
            p->sent++;
        }
        usleep(p->interval_us);
    }
    return NULL;
}

static CFMachPortRef make_port(struct sink *s) {
    CFMachPortContext context = { 0, s, NULL, NULL, NULL };
    CFMachPortRef port = CFMachPortCreate(NULL, on_message, &context, NULL);
    if (!port) return NULL;
    /* Room for every message, so the comparison is about waiting, not loss. */
    mach_port_limits_t limits = { MACH_PORT_QLIMIT_LARGE };
    mach_port_set_attributes(mach_task_self(), CFMachPortGetPort(port), MACH_PORT_LIMITS_INFO,
                             (mach_port_info_t)&limits, MACH_PORT_LIMITS_INFO_COUNT);
    return port;
}

static int cmp_double(const void *a, const void *b) {
    const double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static void summarise(const char *label, struct sink *s, int sent, double seconds, double *p50, double *max) {
    const int n = atomic_load(&s->handled) < MAX_EVENTS ? atomic_load(&s->handled) : MAX_EVENTS;
    qsort(s->delays_ms, (size_t)n, sizeof(double), cmp_double);
    *p50 = n ? s->delays_ms[n / 2] : 0;
    *max = n ? s->delays_ms[n - 1] : 0;
    printf("test_runloop_thread: %-6s %d of %d events in %.1f s (%.0f/s); waited p50 %.1f ms, max %.1f ms\n",
           label, n, sent, seconds, n / seconds, *p50, *max);
}

/* ---- tap state --------------------------------------------------------- */

struct add_ctx {
    CFMachPortRef      port;
    CFRunLoopSourceRef source;
    pthread_t          ran_on;
};

static void add_source(void *ctx) {
    struct add_ctx *c = (struct add_ctx *)ctx;
    c->ran_on = pthread_self();
    c->source = CFMachPortCreateRunLoopSource(NULL, c->port, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), c->source, kCFRunLoopDefaultMode);
}

static void remove_source(void *ctx) {
    struct add_ctx *c = (struct add_ctx *)ctx;
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), c->source, kCFRunLoopDefaultMode);
    CFRelease(c->source);
    c->source = NULL;
    CFMachPortInvalidate(c->port);
}

/* 1.1.0: the source on the main run loop, one pass every 17 ms. */
static void test_before(double *p50, double *max) {
    static struct sink s;
    memset(&s, 0, sizeof(s));
    CFMachPortRef port = make_port(&s);
    CHECK(port != NULL);
    if (!port) return;
    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(NULL, port, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);

    struct producer p = { CFMachPortGetPort(port), 400, 2500, 0 };
    pthread_t producer;
    pthread_create(&producer, NULL, produce, &p);
    const uint64_t start = now_ns();
    while (now_ns() - start < 1000000000ull) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0, true);   /* as main.c's loop did */
        usleep(17000);                                           /* decode and draw a 5K frame */
    }
    pthread_join(producer, NULL);
    const double seconds = (double)(now_ns() - start) / 1e9;
    double handled_p50, handled_max;
    summarise("before", &s, p.sent, seconds, &handled_p50, &handled_max);
    *p50 = handled_p50;
    *max = handled_max;
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
    CFRelease(source);
    CFMachPortInvalidate(port);
    CFRelease(port);
}

/* 1.1.1: the source on its own thread; the main thread is stuck throughout. */
static void test_after(double *p50, double *max) {
    static struct sink s;
    memset(&s, 0, sizeof(s));
    struct tb_rlthread *t = tb_rlthread_start("test input tap");
    CHECK(t != NULL);
    if (!t) return;
    CHECK(!tb_rlthread_is_current(t));
    struct add_ctx c = { make_port(&s), NULL, 0 };
    CHECK(c.port != NULL);
    if (!c.port) { tb_rlthread_stop(t); return; }
    CHECK(tb_rlthread_call(t, add_source, &c) == 0);
    CHECK(!pthread_equal(c.ran_on, pthread_self()));   /* it ran on the thread */

    struct producer p = { CFMachPortGetPort(c.port), 400, 2500, 0 };
    pthread_t producer;
    const uint64_t start = now_ns();
    pthread_create(&producer, NULL, produce, &p);
    usleep(1300 * 1000);   /* the main thread in a decoder stall */
    pthread_join(producer, NULL);
    const double seconds = (double)(now_ns() - start) / 1e9;
    summarise("after", &s, p.sent, seconds, p50, max);

    CHECK(p.sent == 400);
    CHECK(atomic_load(&s.handled) == p.sent);          /* every event, during the stall */
    CHECK(pthread_equal(s.handled_on, c.ran_on));      /* on the tap's thread */
    CHECK(*p50 < 2.0);

    /* Once removal returns, the callback never runs again. */
    CHECK(tb_rlthread_call(t, remove_source, &c) == 0);
    const int handled = atomic_load(&s.handled);
    usleep(50 * 1000);
    CHECK(atomic_load(&s.handled) == handled);
    CFRelease(c.port);
    tb_rlthread_stop(t);
}

static void count_call(void *ctx) { (*(int *)ctx)++; }

static void test_lifecycle(void) {
    CHECK(tb_rlthread_call(NULL, count_call, NULL) == -1);
    tb_rlthread_stop(NULL);
    struct tb_rlthread *t = tb_rlthread_start("test calls");
    CHECK(t != NULL);
    if (!t) return;
    int n = 0;
    for (int i = 0; i < 1000; i++) tb_rlthread_call(t, count_call, &n);
    CHECK(n == 1000);   /* each call ran, and returned only after running */
    tb_rlthread_stop(t);
}

int main(void) {
    test_lifecycle();
    double before_p50 = 0, before_max = 0, after_p50 = 0, after_max = 0;
    test_before(&before_p50, &before_max);
    test_after(&after_p50, &after_max);
    /* On the main loop an event waits for the next pass; on its thread it does not. */
    CHECK(before_p50 > after_p50);
    CHECK(before_max >= 10.0);
    if (failures) {
        fprintf(stderr, "test_runloop_thread: %d of %d checks failed\n", failures, checks);
        return 1;
    }
    printf("test_runloop_thread: %d checks passed\n", checks);
    return 0;
}
