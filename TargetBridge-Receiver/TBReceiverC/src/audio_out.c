/* audio_out.c — the receiver's sound output on its own thread. See audio_out.h. */

#include "audio_out.h"

#include "audio_ring.h"

#include <SDL.h>

#if defined(__APPLE__)
#include <CoreAudio/CoreAudio.h>
#endif

#include <errno.h>
#include <pthread.h>
#include <unistd.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* kAudioObjectPropertyElementMain is the macOS 12+ SDK spelling. */
#if defined(__APPLE__) && !defined(kAudioObjectPropertyElementMain)
#define kAudioObjectPropertyElementMain kAudioObjectPropertyElementMaster
#endif

#define TB_AUDIO_OUT_BUF_CAP 192000   /* 1 s of 48 kHz stereo s16 */
/* Keep at most 150 ms queued (150 * 192 bytes): a cushion against network and
 * scheduling jitter that still keeps playout tight. */
#define TB_AUDIO_OUT_BACKLOG 28800

struct tb_audio_out {
    pthread_mutex_t ring_lock;   /* the ring only; held for a memcpy */
    struct tb_audio_ring ring;
    uint8_t buf[TB_AUDIO_OUT_BUF_CAP];

    pthread_mutex_t lock;        /* everything below */
    pthread_cond_t  wake;
    int      want;
    uint64_t unwanted_since_ms;
    int      volume_pending;
    double   volume;
    int      quit;
    pthread_t thread;
    atomic_int worker_done;
    atomic_int device_open;   /* for tests and logs: the device is open */

    uint64_t retry_after_ms;     /* no open attempt before this */

    /* Worker only. */
    SDL_AudioDeviceID device;
};

static uint64_t ao_now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

enum tb_audio_out_action tb_audio_out_decide(int want, int is_open, uint64_t unwanted_since_ms,
                                             uint64_t retry_after_ms, uint64_t now_ms) {
    if (want) return !is_open && now_ms >= retry_after_ms ? TB_AUDIO_OUT_OPEN : TB_AUDIO_OUT_NOTHING;
    if (is_open && now_ms >= unwanted_since_ms + TB_AUDIO_OUT_CLOSE_AFTER_MS) return TB_AUDIO_OUT_CLOSE;
    return TB_AUDIO_OUT_NOTHING;
}

/* SDL's audio thread. */
static void ao_callback(void *userdata, Uint8 *stream, int len) {
    struct tb_audio_out *o = (struct tb_audio_out *)userdata;
    pthread_mutex_lock(&o->ring_lock);
    const int copied = tb_audio_ring_pop(&o->ring, stream, len);
    pthread_mutex_unlock(&o->ring_lock);
    if (copied < len) memset(stream + copied, 0, (size_t)(len - copied));
}

/* Drive the receiver's master output volume knob (with the system volume HUD).
 * Sets the default output device's scalar volume, preferring the master
 * element and falling back to per-channel when a device has no master. */
static void ao_set_system_volume(double level) {
#if defined(__APPLE__)
    if (level < 0.0) level = 0.0;
    if (level > 1.0) level = 1.0;
    Float32 vol = (Float32)level;

    AudioObjectPropertyAddress dev_addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &dev_addr, 0, NULL, &size, &device) != noErr ||
        device == kAudioObjectUnknown) {
        return;
    }

    AudioObjectPropertyAddress vol_addr = {
        kAudioDevicePropertyVolumeScalar,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain   /* element 0 = master */
    };
    Boolean settable = false;
    if (AudioObjectHasProperty(device, &vol_addr) &&
        AudioObjectIsPropertySettable(device, &vol_addr, &settable) == noErr && settable) {
        AudioObjectSetPropertyData(device, &vol_addr, 0, NULL, sizeof(vol), &vol);
        return;
    }
    /* No master element: set the left and right channels. */
    for (UInt32 ch = 1; ch <= 2; ch++) {
        vol_addr.mElement = ch;
        settable = false;
        if (AudioObjectHasProperty(device, &vol_addr) &&
            AudioObjectIsPropertySettable(device, &vol_addr, &settable) == noErr && settable) {
            AudioObjectSetPropertyData(device, &vol_addr, 0, NULL, sizeof(vol), &vol);
        }
    }
#else
    (void)level;
#endif
}

/* 1 when the device opened. */
static int ao_open(struct tb_audio_out *o) {
    SDL_AudioSpec spec;
    SDL_zero(spec);
    spec.freq = 48000;
    spec.format = AUDIO_S16LSB;
    spec.channels = 2;
    spec.samples = 1024;
    spec.callback = ao_callback;
    spec.userdata = o;

    SDL_AudioSpec obtained;
    SDL_zero(obtained);
    const uint64_t t0 = ao_now_ms();
    o->device = SDL_OpenAudioDevice(NULL, 0, &spec, &obtained, 0);
    if (o->device == 0) {
        fprintf(stderr, "[audio] warning: SDL_OpenAudioDevice failed: %s; retrying in 5s\n", SDL_GetError());
        return 0;
    }
    /* SDL opens devices paused; the session's first packet is already queued. */
    SDL_PauseAudioDevice(o->device, 0);
    atomic_store(&o->device_open, 1);
    fprintf(stderr,
            "[audio] output device opened for the session in %llu ms: 48000Hz stereo 16-bit PCM "
            "(obtained %d samples)\n",
            (unsigned long long)(ao_now_ms() - t0), obtained.samples);
    return 1;
}

static void ao_close(struct tb_audio_out *o) {
    const uint64_t t0 = ao_now_ms();
#if TB_RECEIVER_TEST_HOOKS
    /* Tests only: a close that takes this long, as a stuck CoreAudio would. */
    const char *delay = getenv("TB_RECEIVER_TEST_AUDIO_CLOSE_DELAY_MS");
    if (delay && *delay) usleep((useconds_t)(strtoul(delay, NULL, 10) * 1000u));
#endif
    atomic_store(&o->device_open, 0);
    SDL_CloseAudioDevice(o->device);
    o->device = 0;
    fprintf(stderr, "[audio] output device closed while idle (%llu ms)\n",
            (unsigned long long)(ao_now_ms() - t0));
}

static void *ao_worker(void *arg) {
    struct tb_audio_out *o = (struct tb_audio_out *)arg;
#if defined(__APPLE__)
    pthread_setname_np("PWE audio output");
#endif
    pthread_mutex_lock(&o->lock);
    for (;;) {
        if (o->quit) break;
        int volume_pending = o->volume_pending;
        double volume = o->volume;
        o->volume_pending = 0;
        const uint64_t now = ao_now_ms();
        const enum tb_audio_out_action action =
            tb_audio_out_decide(o->want, o->device != 0, o->unwanted_since_ms, o->retry_after_ms, now);

        if (volume_pending || action != TB_AUDIO_OUT_NOTHING) {
            /* CoreAudio may take its time: never with the lock held. */
            pthread_mutex_unlock(&o->lock);
            int opened = 1;
            if (action == TB_AUDIO_OUT_OPEN) opened = ao_open(o);
            else if (action == TB_AUDIO_OUT_CLOSE) ao_close(o);
            if (volume_pending) ao_set_system_volume(volume);
            pthread_mutex_lock(&o->lock);
            /* A failed open retries later, not for every packet. */
            if (action == TB_AUDIO_OUT_OPEN) o->retry_after_ms = opened ? 0 : ao_now_ms() + TB_AUDIO_OUT_RETRY_MS;
            continue;
        }

        /* Sleep until asked, or until a close or a retry falls due. */
        uint64_t due = 0;
        if (o->want && !o->device) due = o->retry_after_ms;
        else if (!o->want && o->device) due = o->unwanted_since_ms + TB_AUDIO_OUT_CLOSE_AFTER_MS;
        if (due > now) {
            const uint64_t wait_ms = due - now + 1;
#if defined(__APPLE__)
            /* Relative: a change of the wall clock cannot stretch the wait. */
            struct timespec rel = { (time_t)(wait_ms / 1000u), (long)(wait_ms % 1000u) * 1000000L };
            pthread_cond_timedwait_relative_np(&o->wake, &o->lock, &rel);
#else
            struct timespec until;
            clock_gettime(CLOCK_REALTIME, &until);
            until.tv_sec += (time_t)(wait_ms / 1000u);
            until.tv_nsec += (long)(wait_ms % 1000u) * 1000000L;
            if (until.tv_nsec >= 1000000000L) { until.tv_sec++; until.tv_nsec -= 1000000000L; }
            pthread_cond_timedwait(&o->wake, &o->lock, &until);
#endif
        } else {
            pthread_cond_wait(&o->wake, &o->lock);
        }
    }
    pthread_mutex_unlock(&o->lock);
    if (o->device) ao_close(o);
    atomic_store(&o->worker_done, 1);
    return NULL;
}

struct tb_audio_out *tb_audio_out_create(void) {
    struct tb_audio_out *o = (struct tb_audio_out *)calloc(1, sizeof(*o));
    if (!o) return NULL;
    tb_audio_ring_init(&o->ring, o->buf, TB_AUDIO_OUT_BUF_CAP);
    pthread_mutex_init(&o->ring_lock, NULL);
    pthread_mutex_init(&o->lock, NULL);
    pthread_cond_init(&o->wake, NULL);
    if (pthread_create(&o->thread, NULL, ao_worker, o) != 0) {
        pthread_cond_destroy(&o->wake);
        pthread_mutex_destroy(&o->lock);
        pthread_mutex_destroy(&o->ring_lock);
        free(o);
        return NULL;
    }
    return o;
}

void tb_audio_out_push(struct tb_audio_out *o, const uint8_t *pcm, size_t len) {
    if (!o || !pcm || len == 0) return;
    pthread_mutex_lock(&o->ring_lock);
    tb_audio_ring_push(&o->ring, pcm, len, TB_AUDIO_OUT_BACKLOG);
    pthread_mutex_unlock(&o->ring_lock);
    pthread_mutex_lock(&o->lock);
    if (!o->want) {
        o->want = 1;
        pthread_cond_signal(&o->wake);
    }
    pthread_mutex_unlock(&o->lock);
}

void tb_audio_out_idle(struct tb_audio_out *o) {
    if (!o) return;
    pthread_mutex_lock(&o->ring_lock);
    tb_audio_ring_reset(&o->ring);
    pthread_mutex_unlock(&o->ring_lock);
    pthread_mutex_lock(&o->lock);
    if (o->want) {
        o->want = 0;
        o->unwanted_since_ms = ao_now_ms();
        o->retry_after_ms = 0;   /* the next session may try at once */
        pthread_cond_signal(&o->wake);
    }
    pthread_mutex_unlock(&o->lock);
}

void tb_audio_out_set_volume(struct tb_audio_out *o, double level) {
    if (!o) return;
    pthread_mutex_lock(&o->lock);
    o->volume = level;
    o->volume_pending = 1;
    pthread_cond_signal(&o->wake);
    pthread_mutex_unlock(&o->lock);
}

int tb_audio_out_device_open(struct tb_audio_out *o) {
    return o ? atomic_load(&o->device_open) : 0;
}

int tb_audio_out_destroy(struct tb_audio_out *o, unsigned wait_ms) {
    if (!o) return 1;
    pthread_mutex_lock(&o->lock);
    o->quit = 1;
    pthread_cond_signal(&o->wake);
    pthread_mutex_unlock(&o->lock);
    for (unsigned waited = 0; waited < wait_ms && !atomic_load(&o->worker_done); waited += 10) {
        struct timespec ts = { 0, 10 * 1000000L };
        nanosleep(&ts, NULL);
    }
    if (!atomic_load(&o->worker_done)) {
        fprintf(stderr, "[audio] the output device did not close within %u ms; leaving it\n", wait_ms);
        pthread_detach(o->thread);
        return 0;   /* the worker still uses `o`: not freed */
    }
    pthread_join(o->thread, NULL);
    pthread_cond_destroy(&o->wake);
    pthread_mutex_destroy(&o->lock);
    pthread_mutex_destroy(&o->ring_lock);
    free(o);
    return 1;
}
