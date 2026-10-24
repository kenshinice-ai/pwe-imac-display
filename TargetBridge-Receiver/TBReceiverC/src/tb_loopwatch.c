/* tb_loopwatch.c — the main loop's watchdog. See tb_loopwatch.h. */

#include "tb_loopwatch.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/resource.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <dlfcn.h>
#include <mach/mach.h>
#include <pthread.h>
#endif

_Atomic(const char *) tb_loopwatch_phase_now = "starting";

static _Atomic uint64_t g_seq;
static _Atomic uint64_t g_started_ms;
static atomic_int g_running;

#if defined(__APPLE__)
static pthread_t        g_thread;
static mach_port_t      g_main_thread = MACH_PORT_NULL;
static uintptr_t        g_stack_lo, g_stack_hi;
#endif

/* Time the Mac is awake: a loop that slept with the system did not stall. */
static uint64_t lw_now_ms(void) {
#if defined(__APPLE__)
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1000000u;
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
#endif
}

enum tb_loopwatch_event tb_loopwatch_decide(struct tb_loopwatch_track *t, uint64_t seq,
                                            uint64_t started_ms, uint64_t now_ms,
                                            uint64_t stuck_ms, uint64_t repeat_ms,
                                            uint64_t *for_ms) {
    if (!t || !for_ms) return TB_LOOPWATCH_NONE;
    *for_ms = 0;
    if (t->stuck) {
        if (seq != t->seq) {
            /* The stalled iteration ended when the next one started. */
            *for_ms = started_ms >= t->started_ms ? started_ms - t->started_ms
                                                  : now_ms - t->started_ms;
            t->stuck = 0;
            return TB_LOOPWATCH_RECOVERED;
        }
        *for_ms = now_ms >= t->started_ms ? now_ms - t->started_ms : 0;
        if (now_ms >= t->next_report_ms) {
            t->next_report_ms = now_ms + repeat_ms;
            return TB_LOOPWATCH_STILL_STUCK;
        }
        return TB_LOOPWATCH_NONE;
    }
    if (now_ms < started_ms || now_ms - started_ms < stuck_ms) return TB_LOOPWATCH_NONE;
    t->stuck = 1;
    t->seq = seq;
    t->started_ms = started_ms;
    t->next_report_ms = now_ms + repeat_ms;
    *for_ms = now_ms - started_ms;
    return TB_LOOPWATCH_STUCK;
}

void tb_slowcall_begin(struct tb_slowcall *s) {
    if (!s) return;
#if defined(__APPLE__)
    s->wall_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    /* thread_info, not CLOCK_THREAD_CPUTIME_ID: under Rosetta that clock
     * reports Apple-silicon ticks as nanoseconds (41x too little, measured
     * 2026-10-24). */
    thread_basic_info_data_t info;
    mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
    s->cpu_ns = thread_info(pthread_mach_thread_np(pthread_self()), THREAD_BASIC_INFO,
                            (thread_info_t)&info, &count) == KERN_SUCCESS
        ? ((uint64_t)info.user_time.seconds + (uint64_t)info.system_time.seconds) * 1000000000u +
          ((uint64_t)info.user_time.microseconds + (uint64_t)info.system_time.microseconds) * 1000u
        : 0;
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    s->wall_ns = (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
    s->cpu_ns = (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
#endif
    struct rusage ru;
    s->pageins = getrusage(RUSAGE_SELF, &ru) == 0 ? ru.ru_majflt : 0;
}

uint64_t tb_slowcall_end(const struct tb_slowcall *s, uint64_t *cpu_ms, long *pageins) {
    struct tb_slowcall now;
    tb_slowcall_begin(&now);
    if (cpu_ms) *cpu_ms = now.cpu_ns > s->cpu_ns ? (now.cpu_ns - s->cpu_ns) / 1000000u : 0;
    if (pageins) *pageins = now.pageins > s->pageins ? now.pageins - s->pageins : 0;
    return now.wall_ns > s->wall_ns ? (now.wall_ns - s->wall_ns) / 1000000u : 0;
}

const char *tb_slowcall_verdict(uint64_t wall_ms, uint64_t cpu_ms, long pageins) {
    if (wall_ms == 0 || cpu_ms * 10 >= wall_ms * 6) return "working: the CPU was busy for most of it";
    if (pageins > 0) return "waiting for memory: pages were read back from disk";
    if (cpu_ms * 10 < wall_ms * 2) return "not running: waiting, or the whole Mac paused";
    return "partly working, partly waiting";
}

void tb_loopwatch_iteration(void) {
    /* The start time first, then the number: a reader that sees the new number
     * sees this start time or a later one, never a stale one (no false stall). */
    atomic_store_explicit(&g_started_ms, lw_now_ms(), memory_order_relaxed);
    atomic_fetch_add_explicit(&g_seq, 1, memory_order_release);
}

/* stderr without stdio. */
static void lw_write(const char *line) {
    size_t len = strlen(line);
    while (len > 0) {
        ssize_t w = write(STDERR_FILENO, line, len);
        if (w <= 0) return;
        line += w;
        len -= (size_t)w;
    }
}

#if defined(__APPLE__)

#define LW_MAX_FRAMES 48

static uintptr_t lw_strip(uintptr_t pc) {
#if defined(__arm64__) || defined(__aarch64__)
    return pc & 0x00007FFFFFFFFFFFull;   /* drop pointer-authentication bits */
#else
    return pc;
#endif
}

static int lw_on_stack(uintptr_t p, size_t bytes) {
    return p >= g_stack_lo && p + bytes <= g_stack_hi && (p & (sizeof(uintptr_t) - 1)) == 0;
}

/* The main thread's return addresses, innermost first. Between suspend and
 * resume nothing here takes a lock or allocates. */
static int lw_main_stack(uintptr_t *pcs, int max) {
    if (g_main_thread == MACH_PORT_NULL || !g_stack_hi) return 0;
    if (thread_suspend(g_main_thread) != KERN_SUCCESS) return 0;
    int n = 0;
    uintptr_t fp = 0;
#if defined(__x86_64__)
    x86_thread_state64_t st;
    mach_msg_type_number_t count = x86_THREAD_STATE64_COUNT;
    if (thread_get_state(g_main_thread, x86_THREAD_STATE64, (thread_state_t)&st, &count) == KERN_SUCCESS) {
        pcs[n++] = (uintptr_t)st.__rip;
        /* A leaf without a frame (a system call stub): its caller is at the top of the stack. */
        if (lw_on_stack((uintptr_t)st.__rsp, sizeof(uintptr_t)) && n < max) pcs[n++] = *(uintptr_t *)st.__rsp;
        fp = (uintptr_t)st.__rbp;
    }
#elif defined(__arm64__) || defined(__aarch64__)
    arm_thread_state64_t st;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(g_main_thread, ARM_THREAD_STATE64, (thread_state_t)&st, &count) == KERN_SUCCESS) {
        pcs[n++] = lw_strip((uintptr_t)arm_thread_state64_get_pc(st));
        if (n < max) pcs[n++] = lw_strip((uintptr_t)arm_thread_state64_get_lr(st));
        fp = (uintptr_t)arm_thread_state64_get_fp(st);
    }
#endif
    while (n < max && lw_on_stack(fp, 2 * sizeof(uintptr_t))) {
        const uintptr_t *frame = (const uintptr_t *)fp;
        const uintptr_t ret = lw_strip(frame[1]);
        if (!ret) break;
        pcs[n++] = ret;
        if (frame[0] <= fp) break;   /* the chain must climb the stack */
        fp = frame[0];
    }
    thread_resume(g_main_thread);
    return n;
}

static void lw_log_stack(void) {
    uintptr_t pcs[LW_MAX_FRAMES];
    const int n = lw_main_stack(pcs, LW_MAX_FRAMES);
    char line[512];
    for (int i = 0; i < n; i++) {
        Dl_info info;
        memset(&info, 0, sizeof(info));
        /* A return address points after the call: look up the byte before it. */
        const uintptr_t look = i == 0 ? pcs[i] : pcs[i] - 1;
        if (dladdr((const void *)look, &info) && info.dli_fname) {
            const char *image = strrchr(info.dli_fname, '/');
            image = image ? image + 1 : info.dli_fname;
            /* The offset in the image always (atos -l finds it in a stripped
             * build); the nearest symbol when there is one. */
            const unsigned long offset = (unsigned long)(pcs[i] - (uintptr_t)info.dli_fbase);
            if (info.dli_sname && info.dli_saddr) {
                snprintf(line, sizeof(line), "[watchdog]   #%d %s +0x%lx %s+%lu\n", i, image, offset,
                         info.dli_sname, (unsigned long)(pcs[i] - (uintptr_t)info.dli_saddr));
            } else {
                snprintf(line, sizeof(line), "[watchdog]   #%d %s +0x%lx\n", i, image, offset);
            }
        } else {
            snprintf(line, sizeof(line), "[watchdog]   #%d 0x%lx\n", i, (unsigned long)pcs[i]);
        }
        lw_write(line);
    }
    if (n == 0) lw_write("[watchdog]   (the main thread's stack could not be read)\n");
}

static void *lw_thread(void *unused) {
    (void)unused;
    pthread_setname_np("PWE main-loop watchdog");
    struct tb_loopwatch_track track;
    memset(&track, 0, sizeof(track));
    const char *stuck_phase = "";
    while (atomic_load(&g_running)) {
        usleep(200 * 1000);
        const uint64_t seq = atomic_load_explicit(&g_seq, memory_order_acquire);
        const uint64_t started = atomic_load_explicit(&g_started_ms, memory_order_relaxed);
        if (seq == 0) continue;   /* the loop has not started yet */
        uint64_t for_ms = 0;
        const enum tb_loopwatch_event ev =
            tb_loopwatch_decide(&track, seq, started, lw_now_ms(), TB_LOOPWATCH_STUCK_MS,
                                TB_LOOPWATCH_REPEAT_MS, &for_ms);
        if (ev == TB_LOOPWATCH_NONE) continue;
        const char *phase = atomic_load_explicit(&tb_loopwatch_phase_now, memory_order_relaxed);
        char line[512];
        if (ev == TB_LOOPWATCH_STUCK) {
            stuck_phase = phase;
            snprintf(line, sizeof(line), "[watchdog] main loop stuck %.1f s in %s\n", for_ms / 1000.0, phase);
            lw_write(line);
            lw_log_stack();
        } else if (ev == TB_LOOPWATCH_STILL_STUCK) {
            snprintf(line, sizeof(line), "[watchdog] main loop still stuck after %.1f s in %s\n",
                     for_ms / 1000.0, phase);
            lw_write(line);
            /* A different phase than first reported: show where it is now. */
            if (phase != stuck_phase) {
                stuck_phase = phase;
                lw_log_stack();
            }
        } else {
            snprintf(line, sizeof(line), "[watchdog] main loop ran again after %.1f s (stuck in %s)\n",
                     for_ms / 1000.0, stuck_phase);
            lw_write(line);
        }
    }
    return NULL;
}

/* Bind the calls made while the main thread is suspended, now, while nothing
 * is stuck. A build for macOS 11 binds imported functions lazily, on their
 * first call, under dyld's lock; if the suspended main thread held that lock
 * (inside dlopen, say), a first call from the watchdog would wait for ever and
 * the main thread would never be resumed. On a null port each call only fails. */
static void lw_bind_suspend_calls(void) {
#if defined(__x86_64__)
    x86_thread_state64_t st;
    mach_msg_type_number_t count = x86_THREAD_STATE64_COUNT;
    (void)thread_get_state(MACH_PORT_NULL, x86_THREAD_STATE64, (thread_state_t)&st, &count);
#elif defined(__arm64__) || defined(__aarch64__)
    arm_thread_state64_t st;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    (void)thread_get_state(MACH_PORT_NULL, ARM_THREAD_STATE64, (thread_state_t)&st, &count);
#endif
    (void)thread_suspend(MACH_PORT_NULL);
    (void)thread_resume(MACH_PORT_NULL);
}

int tb_loopwatch_start(void) {
    if (atomic_load(&g_running)) return 0;
    lw_bind_suspend_calls();
    g_main_thread = mach_thread_self();
    pthread_t self = pthread_self();
    g_stack_hi = (uintptr_t)pthread_get_stackaddr_np(self);
    g_stack_lo = g_stack_hi - (uintptr_t)pthread_get_stacksize_np(self);
    atomic_store(&g_running, 1);
    if (pthread_create(&g_thread, NULL, lw_thread, NULL) != 0) {
        atomic_store(&g_running, 0);
        return -1;
    }
    return 0;
}

void tb_loopwatch_stop(void) {
    if (!atomic_exchange(&g_running, 0)) return;
    pthread_join(g_thread, NULL);
}

#else   /* not Apple: the phases still compile; no thread */

int tb_loopwatch_start(void) { (void)lw_write; return -1; }
void tb_loopwatch_stop(void) {}

#endif
