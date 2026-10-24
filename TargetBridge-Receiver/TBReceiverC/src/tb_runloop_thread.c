/* tb_runloop_thread.c — a thread with its own CFRunLoop. See tb_runloop_thread.h. */

#include "tb_runloop_thread.h"

#include <CoreFoundation/CoreFoundation.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct tb_rlthread {
    pthread_t          thread;
    char               name[64];
    pthread_mutex_t    call_lock;   /* one caller at a time */
    pthread_mutex_t    lock;        /* everything below */
    pthread_cond_t     cond;
    CFRunLoopRef       run_loop;    /* retained; set once the thread runs */
    CFRunLoopSourceRef command;     /* signalled to run `fn` on the thread */
    int                ready;
    int                stop_requested;
    int                stopped;     /* no more calls */
    void             (*fn)(void *);
    void              *ctx;
    int                done;
};

/* The command source fired: run the waiting call, on this thread. */
static void rlt_perform(void *info) {
    struct tb_rlthread *t = (struct tb_rlthread *)info;
    pthread_mutex_lock(&t->lock);
    void (*fn)(void *) = t->fn;
    void *ctx = t->ctx;
    pthread_mutex_unlock(&t->lock);
    if (!fn) return;   /* a signal with no call waiting */
    fn(ctx);
    pthread_mutex_lock(&t->lock);
    t->fn = NULL;
    t->ctx = NULL;
    t->done = 1;
    const int stop = t->stop_requested;
    pthread_cond_broadcast(&t->cond);
    pthread_mutex_unlock(&t->lock);
    if (stop) CFRunLoopStop(CFRunLoopGetCurrent());
}

static void *rlt_main(void *arg) {
    struct tb_rlthread *t = (struct tb_rlthread *)arg;
    pthread_setname_np(t->name);
    CFRunLoopSourceContext context;
    memset(&context, 0, sizeof(context));
    context.info = t;
    context.perform = rlt_perform;
    CFRunLoopSourceRef command = CFRunLoopSourceCreate(NULL, 0, &context);
    CFRunLoopRef run_loop = CFRunLoopGetCurrent();
    if (command) CFRunLoopAddSource(run_loop, command, kCFRunLoopDefaultMode);

    pthread_mutex_lock(&t->lock);
    t->command = command;
    t->run_loop = command ? (CFRunLoopRef)CFRetain(run_loop) : NULL;
    t->ready = 1;
    if (!command) t->stopped = 1;
    pthread_cond_broadcast(&t->cond);
    pthread_mutex_unlock(&t->lock);
    if (!command) return NULL;

    for (;;) {
        /* Returns when stopped; the command source keeps it from running dry. */
        CFRunLoopRun();
        pthread_mutex_lock(&t->lock);
        const int stop = t->stop_requested;
        pthread_mutex_unlock(&t->lock);
        if (stop) break;
    }
    CFRunLoopRemoveSource(run_loop, command, kCFRunLoopDefaultMode);
    return NULL;
}

struct tb_rlthread *tb_rlthread_start(const char *name) {
    struct tb_rlthread *t = (struct tb_rlthread *)calloc(1, sizeof(*t));
    if (!t) return NULL;
    snprintf(t->name, sizeof(t->name), "%s", name ? name : "run loop");
    pthread_mutex_init(&t->call_lock, NULL);
    pthread_mutex_init(&t->lock, NULL);
    pthread_cond_init(&t->cond, NULL);
    if (pthread_create(&t->thread, NULL, rlt_main, t) != 0) {
        pthread_cond_destroy(&t->cond);
        pthread_mutex_destroy(&t->lock);
        pthread_mutex_destroy(&t->call_lock);
        free(t);
        return NULL;
    }
    pthread_mutex_lock(&t->lock);
    while (!t->ready) pthread_cond_wait(&t->cond, &t->lock);
    const int failed = t->stopped;
    pthread_mutex_unlock(&t->lock);
    if (failed) {
        pthread_join(t->thread, NULL);
        pthread_cond_destroy(&t->cond);
        pthread_mutex_destroy(&t->lock);
        pthread_mutex_destroy(&t->call_lock);
        free(t);
        return NULL;
    }
    return t;
}

int tb_rlthread_is_current(const struct tb_rlthread *t) {
    return t && pthread_equal(pthread_self(), t->thread);
}

int tb_rlthread_call(struct tb_rlthread *t, void (*fn)(void *ctx), void *ctx) {
    if (!t || !fn) return -1;
    if (tb_rlthread_is_current(t)) {   /* from one of its own callbacks */
        fn(ctx);
        return 0;
    }
    pthread_mutex_lock(&t->call_lock);
    pthread_mutex_lock(&t->lock);
    if (t->stopped) {
        pthread_mutex_unlock(&t->lock);
        pthread_mutex_unlock(&t->call_lock);
        return -1;
    }
    t->fn = fn;
    t->ctx = ctx;
    t->done = 0;
    pthread_mutex_unlock(&t->lock);
    CFRunLoopSourceSignal(t->command);
    CFRunLoopWakeUp(t->run_loop);
    pthread_mutex_lock(&t->lock);
    while (!t->done) pthread_cond_wait(&t->cond, &t->lock);
    pthread_mutex_unlock(&t->lock);
    pthread_mutex_unlock(&t->call_lock);
    return 0;
}

static void rlt_request_stop(void *ctx) {
    struct tb_rlthread *t = (struct tb_rlthread *)ctx;
    pthread_mutex_lock(&t->lock);
    t->stop_requested = 1;
    t->stopped = 1;   /* later calls are refused */
    pthread_mutex_unlock(&t->lock);
}

void tb_rlthread_stop(struct tb_rlthread *t) {
    if (!t) return;
    if (tb_rlthread_call(t, rlt_request_stop, t) == 0) pthread_join(t->thread, NULL);
    if (t->command) CFRelease(t->command);
    if (t->run_loop) CFRelease(t->run_loop);
    pthread_cond_destroy(&t->cond);
    pthread_mutex_destroy(&t->lock);
    pthread_mutex_destroy(&t->call_lock);
    free(t);
}
