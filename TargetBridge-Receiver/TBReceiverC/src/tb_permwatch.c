/* tb_permwatch.c — permissions re-checked off the main loop. See tb_permwatch.h. */

#include "tb_permwatch.h"

#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <time.h>

struct tb_permwatch {
    pthread_t             thread;
    pthread_mutex_t       lock;
    pthread_cond_t        cond;
    tb_permwatch_check_fn check;
    uint64_t              interval_ms, min_gap_ms;
    int                   kicked, stop;
    uint64_t              seq;
    int                   input_monitoring, accessibility;
};

static uint64_t pw_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

uint64_t tb_permwatch_due_in(uint64_t now_ms, uint64_t last_ms, int kicked,
                             uint64_t interval_ms, uint64_t min_gap_ms) {
    if (last_ms == 0 || now_ms < last_ms) return 0;
    const uint64_t since = now_ms - last_ms;
    const uint64_t wait = kicked ? min_gap_ms : interval_ms;
    return since >= wait ? 0 : wait - since;
}

static void *pw_main(void *arg) {
    struct tb_permwatch *w = (struct tb_permwatch *)arg;
    pthread_setname_np("PWE permission watch");
    uint64_t last_ms = 0;
    pthread_mutex_lock(&w->lock);
    while (!w->stop) {
        const uint64_t due = tb_permwatch_due_in(pw_now_ms(), last_ms, w->kicked, w->interval_ms, w->min_gap_ms);
        if (due > 0) {
            /* CLOCK_REALTIME is the condition variable's clock; only the length matters. */
            struct timespec until;
            clock_gettime(CLOCK_REALTIME, &until);
            until.tv_sec += (time_t)(due / 1000u);
            until.tv_nsec += (long)(due % 1000u) * 1000000L;
            if (until.tv_nsec >= 1000000000L) { until.tv_sec++; until.tv_nsec -= 1000000000L; }
            pthread_cond_timedwait(&w->cond, &w->lock, &until);
            continue;
        }
        w->kicked = 0;
        pthread_mutex_unlock(&w->lock);
        int input_monitoring = 0, accessibility = 0;
        w->check(&input_monitoring, &accessibility);   /* the slow part, unlocked */
        last_ms = pw_now_ms();
        pthread_mutex_lock(&w->lock);
        w->input_monitoring = input_monitoring;
        w->accessibility = accessibility;
        w->seq++;
    }
    pthread_mutex_unlock(&w->lock);
    return NULL;
}

struct tb_permwatch *tb_permwatch_start(tb_permwatch_check_fn check, uint64_t interval_ms, uint64_t min_gap_ms) {
    if (!check) return NULL;
    struct tb_permwatch *w = (struct tb_permwatch *)calloc(1, sizeof(*w));
    if (!w) return NULL;
    w->check = check;
    w->interval_ms = interval_ms;
    w->min_gap_ms = min_gap_ms;
    pthread_mutex_init(&w->lock, NULL);
    pthread_cond_init(&w->cond, NULL);
    if (pthread_create(&w->thread, NULL, pw_main, w) != 0) {
        pthread_cond_destroy(&w->cond);
        pthread_mutex_destroy(&w->lock);
        free(w);
        return NULL;
    }
    return w;
}

void tb_permwatch_kick(struct tb_permwatch *w) {
    if (!w) return;
    pthread_mutex_lock(&w->lock);
    w->kicked = 1;
    pthread_cond_signal(&w->cond);
    pthread_mutex_unlock(&w->lock);
}

uint64_t tb_permwatch_read(struct tb_permwatch *w, int *input_monitoring, int *accessibility) {
    if (!w) return 0;
    pthread_mutex_lock(&w->lock);
    const uint64_t seq = w->seq;
    if (input_monitoring) *input_monitoring = w->input_monitoring;
    if (accessibility) *accessibility = w->accessibility;
    pthread_mutex_unlock(&w->lock);
    return seq;
}

void tb_permwatch_stop(struct tb_permwatch *w) {
    if (!w) return;
    pthread_mutex_lock(&w->lock);
    w->stop = 1;
    pthread_cond_signal(&w->cond);
    pthread_mutex_unlock(&w->lock);
    pthread_join(w->thread, NULL);
    pthread_cond_destroy(&w->cond);
    pthread_mutex_destroy(&w->lock);
    free(w);
}
