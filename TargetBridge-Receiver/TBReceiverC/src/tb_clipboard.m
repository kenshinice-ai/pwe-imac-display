/* tb_clipboard.m — the iMac's clipboard on its own thread. See tb_clipboard.h. */

#include "tb_clipboard.h"

#import <AppKit/AppKit.h>

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

enum tb_clipboard_kind { TB_CLIPBOARD_GENERAL = 0, TB_CLIPBOARD_PRIVATE, TB_CLIPBOARD_NAMED };

struct tb_clipboard {
    pthread_mutex_t lock;          /* everything below; never held across a pasteboard call */
    pthread_cond_t  wake;
    int      quit;
    int      polling;
    unsigned session;              /* bumped by new_session */
    unsigned polling_epoch;        /* bumped by set_polling(0) */
    long     last_seen;            /* change count last looked at; -1: read on the next poll */
    char     last_sent[TB_CLIPBOARD_MAX_TEXT];   /* the text the Mac has, as far as we know */
    int      slot_full;
    char     slot[TB_CLIPBOARD_MAX_TEXT];        /* the iMac's new text, for the main loop */
    int      write_pending;
    char     write_text[TB_CLIPBOARD_MAX_TEXT];  /* the Mac's text, for the worker */
    /* PWE (1.1.1, R1): the session the queued write belongs to (set when it is
     * queued), and the change count the worker knew then (-1: unknown). */
    unsigned write_session;
    long     write_base_seen;
    /* A write that finished after its session ended: the change count it
     * made. That text is the old session's Mac's, never sent to a new one. */
    long     orphan_count;

    pthread_t  thread;
    atomic_int worker_done;

    /* Set before the worker starts; read only by it. */
    enum tb_clipboard_kind kind;
    char     name[256];
    unsigned read_delay_ms;        /* test builds: a read that takes this long */
};

static uint64_t cb_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

/* At most size - 1 bytes, never splitting a UTF-8 sequence. */
static void cb_copy_text(char *dest, size_t size, const char *src) {
    if (!dest || size == 0) return;
    if (!src) src = "";
    size_t n = strlen(src);
    if (n >= size) {
        n = size - 1;
        while (n > 0 && ((unsigned char)src[n] & 0xC0) == 0x80) n--;
    }
    memcpy(dest, src, n);
    dest[n] = '\0';
}

static NSPasteboard *cb_open(struct tb_clipboard *c) {
    switch (c->kind) {
    case TB_CLIPBOARD_PRIVATE: return [NSPasteboard pasteboardWithUniqueName];
    case TB_CLIPBOARD_NAMED:   return [NSPasteboard pasteboardWithName:@(c->name)];
    case TB_CLIPBOARD_GENERAL:
    default:                   return [NSPasteboard generalPasteboard];
    }
}

static void cb_wait(struct tb_clipboard *c, unsigned ms) {
    struct timespec rel = { (time_t)(ms / 1000u), (long)(ms % 1000u) * 1000000L };
    pthread_cond_timedwait_relative_np(&c->wake, &c->lock, &rel);
}

static void *cb_worker(void *arg) {
    struct tb_clipboard *c = (struct tb_clipboard *)arg;
    pthread_setname_np("PWE clipboard");
    NSPasteboard *pb = nil;
    @autoreleasepool { pb = cb_open(c); }
    uint64_t next_poll = 0;

    pthread_mutex_lock(&c->lock);
    while (!c->quit) {
        if (c->write_pending) {
            char text[TB_CLIPBOARD_MAX_TEXT];
            memcpy(text, c->write_text, sizeof(text));
            c->write_pending = 0;
            /* PWE (1.1.1, R1): the session it was queued in, not the one now. */
            const unsigned session = c->write_session;
            const long base_seen = c->write_base_seen;
            if (session != c->session) continue;   /* its session ended: dropped */
            pthread_mutex_unlock(&c->lock);

            long count = -1;
            @autoreleasepool {
                /* PWE (1.1.1, R1): the iMac's clipboard changed after the
                 * worker last looked when this was queued: that copy is newer
                 * than what the worker knew, so it is kept and goes to the Mac
                 * on the next poll. A change count is cheap: no data fetched. */
                if (base_seen >= 0 && (long)[pb changeCount] != base_seen) {
                    text[0] = '\0';
                }
            }
            @autoreleasepool {
                /* Text cut at 4095 bytes may end inside a character: drop
                 * that tail. Text that still is not UTF-8 is not written. */
                const size_t n = strlen(text);
                NSString *s = nil;
                for (size_t cut = 0; n > 0 && !s && cut < 4 && cut <= n; cut++) {
                    s = [[NSString alloc] initWithBytes:text length:n - cut encoding:NSUTF8StringEncoding];
                }
                if (s) {
                    /* The count of our own change. If another app changes the
                     * clipboard right after, the count moves on and that
                     * change is read and sent as usual. */
                    count = (long)[pb clearContents];
                    [pb setString:s forType:NSPasteboardTypeString];
                    cb_copy_text(text, sizeof(text), s.UTF8String);
                }
            }

            pthread_mutex_lock(&c->lock);
            if (count < 0) continue;   /* nothing written */
            /* Our own change: never sent back. The iMac's clipboard is now the
             * Mac's text, so older iMac text not yet sent is stale. Polling
             * turned off meanwhile does not matter; a new session does (its
             * Mac does not have this text). PWE (1.1.1, R1): the session ended
             * while the write was inside the pasteboard call: it stays written,
             * but it is no copy of the iMac's for the next session's Mac. */
            if (session == c->session) {
                c->last_seen = count;
                memcpy(c->last_sent, text, sizeof(c->last_sent));
                c->slot_full = 0;
            } else {
                c->orphan_count = count;
            }
            continue;
        }

        const uint64_t now = cb_now_ms();
        if (c->polling && now >= next_poll) {
            const unsigned session = c->session, epoch = c->polling_epoch;
            const long seen = c->last_seen;
            pthread_mutex_unlock(&c->lock);

            long count = -1;
            int have_text = 0;
            char text[TB_CLIPBOARD_MAX_TEXT] = "";
            uint64_t read_ms = 0;
            @autoreleasepool {
                count = (long)[pb changeCount];
                if (count != seen) {
                    /* The slow part: the owner of the clipboard supplies the
                     * data now (Screen Sharing: up to 45 s seen). */
                    const uint64_t t0 = cb_now_ms();
#if TB_RECEIVER_TEST_HOOKS
                    if (c->read_delay_ms) usleep((useconds_t)c->read_delay_ms * 1000u);
#endif
                    NSString *s = [pb stringForType:NSPasteboardTypeString];
                    cb_copy_text(text, sizeof(text), s ? s.UTF8String : "");   /* no text: "", as pbpaste */
                    read_ms = cb_now_ms() - t0;
                    have_text = 1;
                }
            }
            if (read_ms >= TB_CLIPBOARD_SLOW_READ_MS) {
                fprintf(stderr, "[clipboard] the clipboard took %.1f s to give its text "
                                "(read on the clipboard thread; the main loop did not wait)\n",
                        (double)read_ms / 1000.0);
            }

            pthread_mutex_lock(&c->lock);
            next_poll = cb_now_ms() + TB_CLIPBOARD_POLL_MS;
            /* A session that ended, or polling turned off, while we read:
             * the result belongs to nobody. last_seen stays as reset. */
            if (have_text && session == c->session && epoch == c->polling_epoch) {
                c->last_seen = count;
                if (count == c->orphan_count) {
                    c->slot_full = 0;   /* PWE (1.1.1, R1): an ended session's Mac text */
                } else if (strcmp(text, c->last_sent) != 0) {
                    memcpy(c->slot, text, sizeof(c->slot));
                    c->slot_full = 1;
                } else {
                    c->slot_full = 0;   /* back to what the Mac has */
                }
            }
            continue;
        }

        if (c->polling) {
            const uint64_t t = cb_now_ms();
            cb_wait(c, next_poll > t ? (unsigned)(next_poll - t) : 1u);
        } else {
            pthread_cond_wait(&c->wake, &c->lock);
        }
    }
    pthread_mutex_unlock(&c->lock);

    if (c->kind == TB_CLIPBOARD_PRIVATE) {
        @autoreleasepool { [pb releaseGlobally]; }
    }
    pb = nil;
    atomic_store(&c->worker_done, 1);
    return NULL;
}

struct tb_clipboard *tb_clipboard_create(const char *name) {
    struct tb_clipboard *c = (struct tb_clipboard *)calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->last_seen = -1;
    c->write_base_seen = -1;
    c->orphan_count = -1;
    if (!name) {
        c->kind = TB_CLIPBOARD_GENERAL;
    } else if (!*name) {
        c->kind = TB_CLIPBOARD_PRIVATE;
    } else {
        c->kind = TB_CLIPBOARD_NAMED;
        snprintf(c->name, sizeof(c->name), "%s", name);
    }
#if TB_RECEIVER_TEST_HOOKS
    const char *delay = getenv("TB_RECEIVER_TEST_CLIPBOARD_READ_DELAY_MS");
    if (delay && *delay) c->read_delay_ms = (unsigned)strtoul(delay, NULL, 10);
#endif
    pthread_mutex_init(&c->lock, NULL);
    pthread_cond_init(&c->wake, NULL);
    if (pthread_create(&c->thread, NULL, cb_worker, c) != 0) {
        pthread_cond_destroy(&c->wake);
        pthread_mutex_destroy(&c->lock);
        free(c);
        return NULL;
    }
    return c;
}

void tb_clipboard_set_polling(struct tb_clipboard *c, int on) {
    if (!c) return;
    pthread_mutex_lock(&c->lock);
    on = on != 0;
    if (c->polling != on) {
        c->polling = on;
        if (!on) {
            /* Text not taken is dropped; it is read again (and compared with
             * what the Mac has) when polling resumes. */
            c->polling_epoch++;
            c->slot_full = 0;
            c->last_seen = -1;
        }
        pthread_cond_signal(&c->wake);
    }
    pthread_mutex_unlock(&c->lock);
}

void tb_clipboard_new_session(struct tb_clipboard *c) {
    if (!c) return;
    pthread_mutex_lock(&c->lock);
    c->session++;
    c->last_seen = -1;
    c->last_sent[0] = '\0';
    c->slot_full = 0;
    /* PWE (1.1.1, R1): the Mac's text not yet written belongs to the session
     * that ended: dropped, so it can neither overwrite what is copied on the
     * iMac later nor pass for the next session's Mac's copy. */
    c->write_pending = 0;
    pthread_mutex_unlock(&c->lock);
}

void tb_clipboard_write(struct tb_clipboard *c, const char *text) {
    if (!c) return;
    pthread_mutex_lock(&c->lock);
    cb_copy_text(c->write_text, sizeof(c->write_text), text);
    c->write_pending = 1;
    c->write_session = c->session;          /* PWE (1.1.1, R1) */
    c->write_base_seen = c->last_seen;
    pthread_cond_signal(&c->wake);
    pthread_mutex_unlock(&c->lock);
}

int tb_clipboard_take(struct tb_clipboard *c, char *dest, size_t size) {
    if (!c || !dest || size == 0) return 0;
    int took = 0;
    pthread_mutex_lock(&c->lock);
    if (c->slot_full && c->polling) {
        cb_copy_text(dest, size, c->slot);
        memcpy(c->last_sent, c->slot, sizeof(c->last_sent));
        c->slot_full = 0;
        took = 1;
    }
    pthread_mutex_unlock(&c->lock);
    return took;
}

int tb_clipboard_destroy(struct tb_clipboard *c, unsigned wait_ms) {
    if (!c) return 1;
    pthread_mutex_lock(&c->lock);
    c->quit = 1;
    pthread_cond_signal(&c->wake);
    pthread_mutex_unlock(&c->lock);
    for (unsigned waited = 0; waited < wait_ms && !atomic_load(&c->worker_done); waited += 10) {
        struct timespec ts = { 0, 10 * 1000000L };
        nanosleep(&ts, NULL);
    }
    if (!atomic_load(&c->worker_done)) {
        fprintf(stderr, "[clipboard] the clipboard thread is still waiting for the clipboard "
                        "after %u ms; leaving it\n", wait_ms);
        pthread_detach(c->thread);
        return 0;   /* the worker still uses `c`: not freed */
    }
    pthread_join(c->thread, NULL);
    pthread_cond_destroy(&c->wake);
    pthread_mutex_destroy(&c->lock);
    free(c);
    return 1;
}
