/* main.c — TBReceiver pure-C entry point.
 *
 * Single-threaded event loop:
 *   - SDL_PollEvent (non-blocking)  → quit detection
 *   - non-blocking socket read     → packet parser → decoder → renderer
 *   - 1ms sleep between packets, 10ms with no sender → CPU yield
 *
 * No ObjC. No Cocoa NSApplication. No autoreleasepool.
 * Crashes from objc_release/__CFAutoreleasePoolPop cannot happen here:
 * no Objective-C runtime objects are managed by us. SDL2 may use Cocoa
 * windowing internally on macOS, but with this minimal setup the OCLP-
 * triggered bug pattern (corrupt object in main-thread ARP) is dramatically
 * less likely than with SwiftUI / AppKit programmatic UIs.
 */

#include "net.h"
#include "audio_out.h"
#include "decoder.h"
#include "display.h"
#include "idle_watchdog.h"
#include "receiver_profile.h"
#include "proto.h"
#include "tb_gesture_bridge.h"
#include "tb_display_tweaks.h"
#include "tb_i18n.h"
#include "tb_login_item.h"
#include "tb_log.h"
#include "tb_loopwatch.h"
#include "tb_trace.h"
#include "tb_catchup.h"
#include "tb_ratelimit.h"
#include "tb_input_rate.h"
#include "tb_runloop_thread.h"
#include "tb_permwatch.h"
#include "tb_clipboard.h"
#include "tb_sysinfo.h"
#include "tb_running_app.h"
/* PWE: pairing and encrypted sessions */
#include "pwe_secure.h"
#include "pwe_keystore.h"
#include "tb_pairing_menu.h"
#include <SystemConfiguration/SystemConfiguration.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <poll.h>
#ifndef TB_RECEIVER_TEST_HOOKS
#define TB_RECEIVER_TEST_HOOKS 0   /* 1 only in test builds: make TEST_HOOKS=1 */
#endif

#ifndef TB_RECEIVER_OFFER_LOGIN_ITEM
#define TB_RECEIVER_OFFER_LOGIN_ITEM 0
#endif

#ifndef TB_RECEIVER_DIRECT_LINK_ONLY
#define TB_RECEIVER_DIRECT_LINK_ONLY 0
#endif

#include <SDL.h>
#include <ApplicationServices/ApplicationServices.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <dns_sd.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreVideo/CoreVideo.h>
#include <sys/ioctl.h>
#include <pthread.h>
#include <stdatomic.h>

#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <stdarg.h>
#include <time.h>
#include <unistd.h>

/* Reap a connected sender that has gone completely silent. The sender
 * heartbeats every 2s and streams frames continuously, so 10s of silence
 * (5 missed heartbeats) means it died without a FIN. */
#define TB_SENDER_IDLE_TIMEOUT_MS 10000

struct app {
    struct tb_display *disp;
    struct tb_decoder *dec;

    int      server_fd;
    int      server6_fd;   /* PWE: IPv6 listener (T34); -1 without IPv6 */
    int      client_fd;
    /* PWE (T47): a cable connection that came while a session was in place,
     * waiting to take over (tb_pwe_screen_new_connections); -1 when none. */
    int      held_fd;
    int      held_ipv6;
    char     held_ifname[IFNAMSIZ];

    uint64_t frames;   /* pictures shown */
    /* PWE (1.1.1): behind the sender after a stall (tb_catchup.h). While
     * `catchup_holding`, decoded pictures wait in `catchup_frame`, newest
     * first, and the read pass shows the newest when it ends. */
    struct tb_catchup catchup;
    int               catchup_holding;
    CVPixelBufferRef  catchup_frame;
    uint32_t          catchup_trace_id;
    unsigned long     catchup_skipped;   /* decoded, never shown; since the last report */
    unsigned long     catchup_passes;    /* read passes that skipped any */
    uint64_t last_fps_tick_ms;
    uint64_t last_fps_count;
    /* PWE (1.1.1): per-second counts gathered into one line every 10 s. */
    uint64_t fps_report_ms;
    unsigned fps_seconds, fps_min, fps_max;
    uint64_t fps_sum;
    uint64_t last_ip_check_ms;
    /* Last display-tweak state reported to the sender, so changes made on this
     * Mac (Control Center, System Settings) propagate back and the sender's
     * toggles stay truthful. -1 = nothing sent yet. */
    int      reported_night_shift;
    int      reported_true_tone;
    uint64_t last_tweak_poll_ms;

    uint64_t last_recv_ms;      /* idle watchdog: last time the sender sent anything */
    int      close_requested;
    int      have_video_frame;
    /* A real streaming session has begun (the sender sent a session packet, not
     * just a transient probe like a UI-language push). Gates the fullscreen
     * "connecting" splash so a bare/short-lived connection doesn't flash it. */
    int      session_active;

    char     ip_text[64];
    char     tb_ip_text[64];
    char     usb_ip_text[64];
    char     net_ip_text[64];
    char     ethernet_ip_text[64];
    char     wifi_ip_text[64];
    char     tb_ip6_text[64];   /* PWE: Thunderbolt Bridge IPv6 link-local, unscoped */
    unsigned int tb_ip6_if;     /* its interface index */
    char     receiver_id[64];
    char     display_host[128]; /* short hostname (or hostname+IP), cached at startup */
    char     status_text[128];
    char     sender_text[128];
    char     panel_text[128];
    char     mode_text[128];
    char     language_pref[8];
    char     language_text[96];
    char     permissions_text[160];
    char     sender_ui_language[8];
    char     input_control_mode[32];
    int      last_input_monitoring_trusted;
    int      last_accessibility_trusted;
    uint64_t last_permissions_poll_ms;
    /* PWE (1.1.1, A8): the permissions, asked on their own thread every 5 s
     * (tb_permwatch.h); NULL = asked here every 5 s. */
    struct tb_permwatch *permwatch;
    uint64_t permissions_seq;           /* the watcher's answer last taken */
    uint64_t last_permissions_check_ms; /* without a watcher */
    uint64_t last_tap_check_ms;         /* is the event tap still on */
    atomic_int tap_switched_off;        /* the tap's thread saw macOS switch it off for good */
    int      input_permissions_requested;   /* PWE (1.1.1): asked macOS once this launch */

    DNSServiceRef bonjour_ref;
    char     bonjour_name[128];
    CFMachPortRef input_tap;
    CFRunLoopSourceRef input_tap_source;
    int      input_tap_consumes_events;
    /* PWE (1.1.1, A15): the global event tap runs on its own thread, so the
     * iMac's input reaches the Mac as it comes, not in bursts at the frame
     * rate. NULL (thread unavailable, or TB_RECEIVER_TAP_ON_MAIN=1): on the
     * main run loop, as in 1.1.0. */
    struct tb_rlthread *tap_thread;
    int      tap_thread_tried;
    /* Recursive. Held for every send to the Mac (the tap thread sends too)
     * and while the tap's callback reads and writes the input state below
     * (modifier keys, switch timers, counts). */
    pthread_mutex_t tx_lock;
    /* receiverMaster with a session: input goes to the Mac. Written under
     * tx_lock on the main thread; the tap reads it. */
    atomic_int forwarding;
    /* Whether this window is on the Space being viewed (AppKit, so asked on
     * the main thread every 100 ms); the tap forwards nothing when it is not. */
    atomic_int window_on_active_space;
    uint64_t   last_space_check_ms;
    struct tb_input_rate tap_rate;   /* the tap's thread only */
    struct tb_ratelimit  edge_switch_log;   /* under tx_lock */

    /* PWE (T40): sound output and volume, on their own thread (audio_out.h). */
    struct tb_audio_out *audio;

    uint64_t input_events_sent;
    uint64_t input_events_received;
    uint64_t last_target_switch_ms;
    uint64_t last_space_switch_ms;
    uint64_t last_space_gesture_ms;
    int      space_gesture_accum_x;
    int      sent_command_down;
    int      sent_shift_down;
    int      sent_option_down;
    int      sent_control_down;
    int      sent_caps_down;
    /* PWE (T40): the iMac's clipboard, on its own thread (tb_clipboard.h). */
    struct tb_clipboard *clipboard;
    int      clipboard_polling;

    /* ---- PWE: pairing and encrypted sessions (tb_conn.c) ---- */
    CFStringRef             app_id;           /* preferences domain */
    struct tb_conn          conn;             /* the client connection, when client_fd >= 0 */
    struct pwe_keystore     keystore;
    struct pwe_sec_identity identity;
    struct pwe_sec_store    store;
    struct pwe_sec_gate     gate;             /* the pairing code, shared by all connections */
    int                     have_keys;
    int                     allow_plaintext;  /* compatibility mode: unencrypted senders (D1) */
    int                     session_plaintext;
    int                     pwe_status_overridden;
    enum tb_display_notice  pwe_message_kind;
    char                    pwe_message_key[64];    /* the words are looked up when shown, */
    char                    pwe_message_name[128];  /* in the language of the moment */
    uint64_t                pwe_message_until_ms;
    DNSServiceRef           bonjour_ref2;     /* second cable interface (USB), if any */
    unsigned int            bonjour_if1, bonjour_if2;  /* where the two are registered */
    uint16_t                bonjour_port;
    char                    bonjour_addrs[384];  /* the address keys registered */
    int                     bonjour_pending;     /* addresses updated in place mid-session */
    int                     accept_turn;         /* which listener goes first this pass */
    unsigned long           pwe_test_counts[256];  /* test builds: packets per type this session */
    uint64_t                pwe_test_frames_at_connect;
};

static int tb_should_log_input_event(uint64_t count) {
    return count <= 20 || (count % 100) == 0;
}

/* PWE: stderr, like every other log line; tb_log.c copies it into the
 * rotated receiver.log. (Upstream also appended each line to an
 * input-debug.log that grew without limit.) Never pass a key code. */
static void tb_receiver_input_log(const char *fmt, ...) {
    char message[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(message, sizeof(message), fmt, args);
    va_end(args);
    fprintf(stderr, "%s\n", message);
}

static volatile sig_atomic_t g_term = 0;
static void on_sigint(int s) { (void)s; g_term = 1; }

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ULL + ts.tv_nsec / 1000000ULL;
}

static void tb_copy_i18n(char *dest, size_t size, const char *key);
static void tb_format_i18n(char *dest,
                           size_t size,
                           const char *key,
                           const struct tb_i18n_pair *pairs,
                           size_t pair_count);
static void tb_set_receiver_mode_requested(char *dest,
                                           size_t size,
                                           int width,
                                           int height,
                                           const char *source,
                                           const char *preset,
                                           const char *codec);
static void tb_refresh_idle_localized_strings(struct app *a);
static void tb_receiver_load_language_preference(char *dest, size_t size);
static void tb_receiver_save_language_preference(const char *language_pref);
static void tb_receiver_apply_language_preference(struct app *a);
static void tb_receiver_cycle_language_preference(struct app *a);
static void tb_receiver_refresh_language_text(struct app *a);
static void tb_receiver_refresh_permissions_text(struct app *a);
static void tb_receiver_poll_permissions(struct app *a);
static int tb_receiver_input_monitoring_trusted(void);
static int tb_receiver_accessibility_trusted(void);
static void send_receiver_info(struct app *a);
static void tb_receiver_apply_input_event(struct app *a, const uint8_t *payload, size_t len);
static void tb_receiver_apply_input_control_mode(struct app *a, const uint8_t *payload, size_t len);
static void tb_receiver_refresh_input_capture(struct app *a);
static void tb_receiver_send_clipboard_text(struct app *a, const char *text);
static void write_be32(uint8_t *dst, uint32_t value);
static void tb_receiver_send_display_tweaks_if_changed(struct app *a);

static int tb_receiver_is_valid_language_pref(const char *language_pref) {
    return language_pref &&
           (strcmp(language_pref, "auto") == 0 ||
            strcmp(language_pref, "it") == 0 ||
            strcmp(language_pref, "en") == 0 ||
            strcmp(language_pref, "de") == 0 ||
            strcmp(language_pref, "fr") == 0 ||
            strcmp(language_pref, "zh") == 0);
}

static void tb_receiver_settings_path(char *dest, size_t size) {
    const char *home = getenv("HOME");
    if (!dest || size == 0) return;
    dest[0] = '\0';
    if (!home || !*home) return;
    snprintf(dest, size, "%s/Library/Application Support/TargetBridge Receiver/settings.json", home);
}

static void tb_receiver_ensure_settings_dir(void) {
    const char *home = getenv("HOME");
    if (!home || !*home) return;

    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/Library", home);
    mkdir(path, 0755);
    snprintf(path, sizeof(path), "%s/Library/Application Support", home);
    mkdir(path, 0755);
    snprintf(path, sizeof(path), "%s/Library/Application Support/TargetBridge Receiver", home);
    mkdir(path, 0755);
}

static void tb_receiver_load_language_preference(char *dest, size_t size) {
    if (!dest || size == 0) return;
    snprintf(dest, size, "%s", "auto");

    char path[PATH_MAX];
    tb_receiver_settings_path(path, sizeof(path));
    if (!path[0]) return;

    FILE *fp = fopen(path, "rb");
    if (!fp) return;

    char buf[256];
    size_t n = fread(buf, 1, sizeof(buf) - 1, fp);
    fclose(fp);
    buf[n] = '\0';

    const char *pos = strstr(buf, "\"language\"");
    if (!pos) return;
    pos = strchr(pos, ':');
    if (!pos) return;
    pos = strchr(pos, '"');
    if (!pos) return;
    pos++;

    char code[8];
    size_t i = 0;
    while (*pos && *pos != '"' && i + 1 < sizeof(code)) code[i++] = *pos++;
    code[i] = '\0';

    if (tb_receiver_is_valid_language_pref(code)) {
        snprintf(dest, size, "%s", code);
    }
}

static void tb_receiver_save_language_preference(const char *language_pref) {
    if (!tb_receiver_is_valid_language_pref(language_pref)) return;
    tb_receiver_ensure_settings_dir();

    char path[PATH_MAX];
    tb_receiver_settings_path(path, sizeof(path));
    if (!path[0]) return;

    FILE *fp = fopen(path, "wb");
    if (!fp) return;
    fprintf(fp, "{\n  \"language\": \"%s\"\n}\n", language_pref);
    fclose(fp);
}

static const char *tb_receiver_language_display_name(const char *language_code) {
    if (!language_code || !*language_code) language_code = "en";
    if (strcmp(language_code, "it") == 0) return tb_i18n_get("common.language.italian");
    if (strcmp(language_code, "de") == 0) return tb_i18n_get("common.language.german");
    if (strcmp(language_code, "fr") == 0) return tb_i18n_get("common.language.french");
    if (strcmp(language_code, "zh") == 0) return tb_i18n_get("common.language.chinese");
    return tb_i18n_get("common.language.english");
}

static void tb_receiver_refresh_language_text(struct app *a) {
    if (!a) return;
    if (strcmp(a->language_pref, "auto") == 0) {
        snprintf(a->language_text,
                 sizeof(a->language_text),
                 "%s · %s",
                 tb_i18n_get("receiver.language.auto"),
                 tb_receiver_language_display_name(tb_i18n_current_language()));
    } else {
        snprintf(a->language_text,
                 sizeof(a->language_text),
                 "%s",
                 tb_receiver_language_display_name(a->language_pref));
    }
}

static void tb_receiver_refresh_permissions_text(struct app *a) {
    if (!a) return;

    const int input_monitoring = (a->last_input_monitoring_trusted >= 0)
        ? a->last_input_monitoring_trusted
        : tb_receiver_input_monitoring_trusted();
    const int accessibility = (a->last_accessibility_trusted >= 0)
        ? a->last_accessibility_trusted
        : tb_receiver_accessibility_trusted();
    /* In the language files, so every language has its words (French was
     * English here, and the receiver's own screens follow the files). */
    struct tb_i18n_pair pairs[] = {
        { "input", tb_i18n_get(input_monitoring ? "receiver.permissions.granted" : "receiver.permissions.missing") },
        { "accessibility", tb_i18n_get(accessibility ? "receiver.permissions.granted" : "receiver.permissions.missing") },
    };
    tb_format_i18n(a->permissions_text, sizeof(a->permissions_text), "receiver.permissions.summary", pairs, 2);
}

static void tb_receiver_refresh_login_item(struct app *a) {
    if (!TB_RECEIVER_OFFER_LOGIN_ITEM || !a || !a->disp) return;
    const int enabled = tb_login_item_is_enabled();
    tb_disp_set_login_item_state(a->disp,
                                 enabled ? TB_DISP_LOGIN_ITEM_ON
                                 : (tb_login_item_available() ? TB_DISP_LOGIN_ITEM_OFF
                                                              : TB_DISP_LOGIN_ITEM_UNAVAILABLE));
}

/* PWE (1.1.1, A8): a listen-only event tap for key presses, made and thrown
 * away at once, never attached to a run loop: whether the window server lets
 * this process see the keyboard right now. About 2 ms (2021 MacBook Pro). */
static CGEventRef tb_receiver_probe_tap_callback(CGEventTapProxy proxy, CGEventType type, CGEventRef event,
                                                 void *user_info) {
    (void)proxy; (void)type; (void)user_info;
    return event;
}

static int tb_receiver_listen_probe(void) {
    CFMachPortRef tap = CGEventTapCreate(kCGSessionEventTap, kCGTailAppendEventTap, kCGEventTapOptionListenOnly,
                                         CGEventMaskBit(kCGEventKeyDown), tb_receiver_probe_tap_callback, NULL);
    if (!tap) return 0;
    CFMachPortInvalidate(tap);
    CFRelease(tap);
    return 1;
}

/* PWE (1.1.1, A8): what the watcher thread asks (any thread). In 1.1.0 a
 * removed permission still read as allowed until the receiver was reopened
 * (RC8, 2026-10-22), so Input Monitoring that macOS reports as allowed is
 * also tried: when the window server refuses a listening tap twice in a row
 * (10 s), it counts as removed. A refused tap means input capture cannot work
 * anyway, so this never takes away anything that worked. */
static void tb_receiver_check_permissions(int *input_monitoring, int *accessibility) {
    static int refused;   /* the watcher's thread (or the main thread without one) */
    int listen = tb_receiver_input_monitoring_trusted();
    if (listen) {
        if (tb_receiver_listen_probe()) {
            refused = 0;
        } else if (++refused >= 2) {
            if (refused == 2) {
                fprintf(stderr, "[input] macOS reports Input Monitoring as allowed, but the window server "
                                "refuses an event tap: counted as not allowed\n");
            }
            listen = 0;
        }
    } else {
        refused = 0;
    }
    *input_monitoring = listen;
    *accessibility = tb_receiver_accessibility_trusted();
}

static void tb_receiver_apply_permissions(struct app *a, int input_monitoring, int accessibility);

/* PWE (1.1.1, A8): take the latest answer, if there is a new one. Cheap:
 * called from the main loop every 250 ms. */
static void tb_receiver_poll_permissions(struct app *a) {
    if (!a) return;
    int input_monitoring = 0, accessibility = 0;
    if (a->permwatch) {
        const uint64_t seq = tb_permwatch_read(a->permwatch, &input_monitoring, &accessibility);
        if (seq == 0 || seq == a->permissions_seq) return;
        a->permissions_seq = seq;
    } else {
        const uint64_t now = now_ms();
        if (a->last_permissions_check_ms && now - a->last_permissions_check_ms < TB_PERMWATCH_INTERVAL_MS) return;
        a->last_permissions_check_ms = now;
        tb_receiver_check_permissions(&input_monitoring, &accessibility);
    }
    tb_receiver_apply_permissions(a, input_monitoring, accessibility);
}

static void tb_receiver_apply_permissions(struct app *a, int input_monitoring, int accessibility) {
    const int changed =
        input_monitoring != a->last_input_monitoring_trusted ||
        accessibility != a->last_accessibility_trusted;

    a->last_input_monitoring_trusted = input_monitoring;
    a->last_accessibility_trusted = accessibility;

    if (!changed) return;

    tb_receiver_refresh_permissions_text(a);
    tb_receiver_refresh_input_capture(a);
    if (a->client_fd >= 0) {
        send_receiver_info(a);
    }
    tb_receiver_input_log("[input] permission state changed inputMonitoring=%s accessibility=%s",
                          input_monitoring ? "true" : "false",
                          accessibility ? "true" : "false");
}

static void tb_receiver_apply_language_preference(struct app *a) {
    if (!a) return;

    if (strcmp(a->language_pref, "auto") == 0) {
        if (a->sender_ui_language[0] != '\0') {
            tb_i18n_set_runtime_language(a->sender_ui_language);
        } else {
            tb_i18n_set_runtime_language("auto");
        }
    } else {
        tb_i18n_set_runtime_language(a->language_pref);
    }

    tb_refresh_idle_localized_strings(a);
    tb_receiver_refresh_language_text(a);
    tb_receiver_refresh_permissions_text(a);
}

static int tb_receiver_input_monitoring_trusted(void) {
    return CGPreflightListenEventAccess() ? 1 : 0;
}

static int tb_receiver_accessibility_trusted(void) {
    return AXIsProcessTrusted() ? 1 : 0;
}

static void tb_receiver_cycle_language_preference(struct app *a) {
    if (!a) return;

    if (strcmp(a->language_pref, "auto") == 0) {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "it");
    } else if (strcmp(a->language_pref, "it") == 0) {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "en");
    } else if (strcmp(a->language_pref, "en") == 0) {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "de");
    } else if (strcmp(a->language_pref, "de") == 0) {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "fr");
    } else if (strcmp(a->language_pref, "fr") == 0) {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "zh");
    } else {
        snprintf(a->language_pref, sizeof(a->language_pref), "%s", "auto");
    }

    tb_receiver_save_language_preference(a->language_pref);
    tb_receiver_apply_language_preference(a);
}

static void tb_refresh_idle_localized_strings(struct app *a) {
    if (!a) return;
    tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.waiting_for_sender");
    tb_copy_i18n(a->sender_text, sizeof(a->sender_text), "receiver.status.waiting");
    tb_copy_i18n(a->mode_text, sizeof(a->mode_text), "receiver.mode.default");
    tb_receiver_refresh_permissions_text(a);
    if (a->ip_text[0] == '\0') {
        tb_copy_i18n(a->ip_text, sizeof(a->ip_text), "receiver.network.not_detected");
    }
}

static void tb_copy_i18n(char *dest, size_t size, const char *key) {
    if (!dest || size == 0) return;
    snprintf(dest, size, "%s", tb_i18n_get(key));
}

static void tb_json_escape_string(const char *src, char *dest, size_t size) {
    if (!dest || size == 0) return;
    if (!src) {
        dest[0] = '\0';
        return;
    }

    size_t j = 0;
    for (size_t i = 0; src[i] != '\0' && j + 1 < size; i++) {
        char c = src[i];
        const char *escape = NULL;
        switch (c) {
        case '\\': escape = "\\\\"; break;
        case '"': escape = "\\\""; break;
        case '\n': escape = "\\n"; break;
        case '\r': escape = "\\r"; break;
        case '\t': escape = "\\t"; break;
        default: break;
        }

        if (escape) {
            for (size_t k = 0; escape[k] != '\0' && j + 1 < size; k++) {
                dest[j++] = escape[k];
            }
        } else {
            dest[j++] = c;
        }
    }
    dest[j] = '\0';
}

/* PWE (1.1.1): every send to the Mac goes through these two. The event tap's
 * thread sends input while the main thread sends everything else; tx_lock
 * keeps their records whole and in order. Receiving (tb_conn_feed, main
 * thread) uses the session's receive state only, so it needs no lock. */
static int tb_receiver_send(struct app *a, uint8_t type, const uint8_t *payload, size_t len) {
    pthread_mutex_lock(&a->tx_lock);
    const int r = tb_conn_send(&a->conn, type, payload, len);
    pthread_mutex_unlock(&a->tx_lock);
    return r;
}

static int tb_receiver_send_packet(struct app *a, const uint8_t *pkt, size_t len) {
    pthread_mutex_lock(&a->tx_lock);
    const int r = tb_conn_send_packet(&a->conn, pkt, len);
    pthread_mutex_unlock(&a->tx_lock);
    return r;
}

/* PWE (1.1.1): whether input goes to the Mac, from the control mode and the
 * session. Main thread; call after either changes. */
static void tb_receiver_update_forwarding(struct app *a) {
    const int on = strcmp(a->input_control_mode, "receiverMaster") == 0 && a->client_fd >= 0;
    pthread_mutex_lock(&a->tx_lock);
    atomic_store(&a->forwarding, on);
    pthread_mutex_unlock(&a->tx_lock);
}

/* PWE (T40): the clipboard is read and written on its own thread
 * (tb_clipboard.m); upstream ran pbpaste and pbcopy on this loop. This sends
 * text the worker found. */
static void tb_receiver_send_clipboard_text(struct app *a, const char *text) {
    if (!a || strcmp(a->input_control_mode, "receiverMaster") != 0 || a->client_fd < 0) return;

    char escaped[8192];
    tb_json_escape_string(text, escaped, sizeof(escaped));

    char json[8300];
    int len = snprintf(json, sizeof(json), "{\"text\":\"%s\"}", escaped);
    if (len <= 0 || (size_t)len >= sizeof(json)) return;

    (void)tb_receiver_send(a, TB_PKT_CLIPBOARD, (const uint8_t *)json, (size_t)len);
}

static void tb_format_i18n(char *dest,
                           size_t size,
                           const char *key,
                           const struct tb_i18n_pair *pairs,
                           size_t pair_count) {
    tb_i18n_format(dest, size, key, pairs, pair_count);
}

static void tb_set_receiver_mode_requested(char *dest,
                                           size_t size,
                                           int width,
                                           int height,
                                           const char *source,
                                           const char *preset,
                                           const char *codec) {
    char width_text[16];
    char height_text[16];
    snprintf(width_text, sizeof(width_text), "%d", width);
    snprintf(height_text, sizeof(height_text), "%d", height);

    struct tb_i18n_pair pairs[] = {
        { "width", width_text },
        { "height", height_text },
        { "source", source ? source : "" },
        { "preset", preset ? preset : "" },
        { "codec", codec ? codec : "" }
    };

    if (width > 0 && height > 0 && source && *source && preset && *preset && codec && *codec) {
        tb_format_i18n(dest, size, "receiver.mode.requested_source_preset_codec", pairs, 5);
    } else if (width > 0 && height > 0 && preset && *preset && codec && *codec) {
        tb_format_i18n(dest, size, "receiver.mode.requested_preset_codec", pairs, 5);
    } else if (width > 0 && height > 0 && preset && *preset) {
        tb_format_i18n(dest, size, "receiver.mode.requested_preset", pairs, 5);
    } else if (width > 0 && height > 0 && codec && *codec) {
        tb_format_i18n(dest, size, "receiver.mode.requested_codec", pairs, 5);
    } else if (width > 0 && height > 0) {
        tb_format_i18n(dest, size, "receiver.mode.requested", pairs, 5);
    }
}

static void bonjour_deinit(struct app *a) {
    if (a->bonjour_ref) {
        DNSServiceRefDeallocate(a->bonjour_ref);
        a->bonjour_ref = NULL;
    }
    if (a->bonjour_ref2) {
        DNSServiceRefDeallocate(a->bonjour_ref2);
        a->bonjour_ref2 = NULL;
    }
    a->bonjour_addrs[0] = '\0';   /* PWE: nothing registered, nothing pending */
    a->bonjour_pending = 0;
}

/* ---- PWE: preferences and the cable interfaces ------------------------- */

static int tb_pwe_pref_bool(CFStringRef app_id, CFStringRef key, int fallback) {
    if (!app_id) return fallback;
    Boolean valid = false;
    Boolean value = CFPreferencesGetAppBooleanValue(key, app_id, &valid);
    return valid ? (value ? 1 : 0) : fallback;
}

static void tb_pwe_set_pref_bool(CFStringRef app_id, CFStringRef key, int value) {
    if (!app_id) return;
    CFPreferencesSetAppValue(key, value ? kCFBooleanTrue : kCFBooleanFalse, app_id);
    (void)CFPreferencesAppSynchronize(app_id);
}

/* Senders off the cable (Wi-Fi, LAN) may connect at all: always in a build
 * without DIRECT_LINK_ONLY, otherwise only after the user opts in with
 *   defaults write <receiver bundle id> AllowLocalNetwork -bool true
 * Read on every accept, so the setting needs no restart. Even then such a
 * sender must resume an encrypted session of a paired Mac (tb_net_accept_policy). */
static int tb_pwe_network_allowed(const struct app *a) {
    return !TB_RECEIVER_DIRECT_LINK_ONLY ||
           tb_pwe_pref_bool(a->app_id, CFSTR("AllowLocalNetwork"), 0);
}

/* At most one line every 10 s, so a peer that keeps redialling cannot flood
 * (and rotate away) the log file. */
static void tb_pwe_log_refused(const char *ifname, int ipv6) {
    static uint64_t last_ms;
    static unsigned long quiet;
    const uint64_t t = now_ms();
    if (last_ms && t - last_ms < 10000) { quiet++; return; }
    fprintf(stderr, "[net] refused a sender on %s: not a direct link (%s)",
            ifname && *ifname ? ifname : "an unknown interface",
            ipv6 ? "IPv6 is for the cable only" : "AllowLocalNetwork is off");
    if (quiet) fprintf(stderr, "; %lu more since the last report", quiet);
    fputc('\n', stderr);
    last_ms = t;
    quiet = 0;
}

/* Interface index of the interface that holds this IPv4 address; 0 if none. */
static unsigned int tb_pwe_ifindex_for_ip(const char *ip) {
    if (!ip || !*ip) return 0;
    struct in_addr want;
    if (inet_pton(AF_INET, ip, &want) != 1) return 0;
    struct ifaddrs *ifap = NULL;
    if (getifaddrs(&ifap) != 0) return 0;
    unsigned int index = 0;
    for (struct ifaddrs *p = ifap; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET) continue;
        if (((const struct sockaddr_in *)p->ifa_addr)->sin_addr.s_addr == want.s_addr) {
            index = if_nametoindex(p->ifa_name);
            break;
        }
    }
    freeifaddrs(ifap);
    return index;
}

static int tb_receiver_load_or_create_id(char *dest, size_t size, CFStringRef app_id) {
    if (!dest || size == 0) return -1;
    dest[0] = '\0';
    if (size < 37 || !app_id) return -1;

    CFStringRef key = CFSTR("receiverID");
    CFPropertyListRef stored = CFPreferencesCopyAppValue(key, app_id);
    CFUUIDRef uuid = NULL;
    if (stored && CFGetTypeID(stored) == CFStringGetTypeID() &&
        CFStringGetLength((CFStringRef)stored) == 36) {
        uuid = CFUUIDCreateFromString(kCFAllocatorDefault, (CFStringRef)stored);
    }
    if (stored) CFRelease(stored);

    const Boolean needs_persistence = uuid == NULL;
    if (!uuid) uuid = CFUUIDCreate(kCFAllocatorDefault);
    if (!uuid) return -1;
    CFStringRef value = CFUUIDCreateString(kCFAllocatorDefault, uuid);
    CFRelease(uuid);
    if (!value) return -1;

    const Boolean copied = CFStringGetCString(value, dest, (CFIndex)size, kCFStringEncodingUTF8);
    Boolean persisted = true;
    if (copied && dest[0] != '\0' && needs_persistence) {
        CFPreferencesSetAppValue(key, value, app_id);
        persisted = CFPreferencesAppSynchronize(app_id);
    }
    CFRelease(value);
    if (!copied || !persisted) {
        dest[0] = '\0';
        return -1;
    }
    return dest[0] != '\0' ? 0 : -1;
}

static void on_bonjour_register(DNSServiceRef sdRef,
                                DNSServiceFlags flags,
                                DNSServiceErrorType errorCode,
                                const char *name,
                                const char *regtype,
                                const char *domain,
                                void *context) {
    (void)sdRef;
    (void)flags;
    (void)context;
    if (errorCode == kDNSServiceErr_NoError) {
        fprintf(stderr, "[bonjour] published %s.%s%s\n", name ? name : "TargetBridge Receiver", regtype ? regtype : "", domain ? domain : "");
    } else {
        fprintf(stderr, "[bonjour] register failed: %d\n", (int)errorCode);
    }
}

static void bonjour_update(struct app *a, uint16_t port) {
    /* Tests on a Mac whose own sender is running (loopback_smoke.sh): stay
     * out of discovery; TB_RECEIVER_TEST_PORT also moves the listener. */
#if TB_RECEIVER_TEST_HOOKS
    if (getenv("TB_RECEIVER_NO_BONJOUR")) { bonjour_deinit(a); return; }
#endif

    const int have_ipv4 = a->ip_text[0] != '\0' &&
        strcmp(a->ip_text, tb_i18n_get("receiver.network.not_detected")) != 0;
    /* PWE (T34): the bridge's IPv6 address, only while the IPv6 listener is up. */
    const char *tb_ip6 = a->server6_fd >= 0 ? a->tb_ip6_text : "";
    const unsigned int tb_ip6_if = a->server6_fd >= 0 ? a->tb_ip6_if : 0;
    /* The bridge's IPv6 address alone is enough to be found. */
    if (!have_ipv4 && tb_ip6[0] == '\0') { bonjour_deinit(a); return; }

    /* PWE: announce this receiver on the cable only (Thunderbolt Bridge, USB),
     * with only the cable addresses, unless the network is allowed
     * (preference AllowLocalNetwork). */
    const int network = tb_pwe_pref_bool(a->app_id, CFSTR("AllowLocalNetwork"), 0);
    unsigned int tb_if = network ? 0 : tb_pwe_ifindex_for_ip(a->tb_ip_text);
    if (!network && !tb_if) tb_if = tb_ip6_if;
    const unsigned int usb_if = network ? 0 : tb_pwe_ifindex_for_ip(a->usb_ip_text);
    const char *announced_ip = network ? (have_ipv4 ? a->ip_text : "")
                                       : (a->tb_ip_text[0] ? a->tb_ip_text : a->usb_ip_text);
    if (!network && !tb_if && !usb_if) { bonjour_deinit(a); return; }

    TXTRecordRef txt;
    TXTRecordCreate(&txt, 0, NULL);
    TXTRecordSetValue(&txt, "name", (uint8_t)strlen(a->bonjour_name), a->bonjour_name);
    if (a->receiver_id[0] != '\0') {
        TXTRecordSetValue(&txt, "receiverID", (uint8_t)strlen(a->receiver_id), a->receiver_id);
    }
    /* No `ip` while only IPv6 is up: a sender that knows no `tbIP6` keeps
     * waiting for an IPv4 address, as before. */
    if (announced_ip[0] != '\0') {
        TXTRecordSetValue(&txt, "ip", (uint8_t)strlen(announced_ip), announced_ip);
    }
    if (a->tb_ip_text[0] != '\0') {
        TXTRecordSetValue(&txt, "tbIP", (uint8_t)strlen(a->tb_ip_text), a->tb_ip_text);
    }
    if (tb_ip6[0] != '\0') {
        TXTRecordSetValue(&txt, "tbIP6", (uint8_t)strlen(tb_ip6), tb_ip6);
    }
    if (a->usb_ip_text[0] != '\0') {
        TXTRecordSetValue(&txt, "usbIP", (uint8_t)strlen(a->usb_ip_text), a->usb_ip_text);
    }
    if (network && a->net_ip_text[0] != '\0') {
        TXTRecordSetValue(&txt, "netIP", (uint8_t)strlen(a->net_ip_text), a->net_ip_text);
    }
    if (network && a->ethernet_ip_text[0] != '\0') {
        TXTRecordSetValue(&txt, "ethernetIP", (uint8_t)strlen(a->ethernet_ip_text), a->ethernet_ip_text);
    }
    if (network && a->wifi_ip_text[0] != '\0') {
        TXTRecordSetValue(&txt, "wifiIP", (uint8_t)strlen(a->wifi_ip_text), a->wifi_ip_text);
    }
    TXTRecordSetValue(&txt, "pweSec", 1, "2");   /* PWE: pairing and encryption, protocol 2 */
    TXTRecordSetValue(&txt, "panel", (uint8_t)strlen(a->panel_text), a->panel_text);
    TXTRecordSetValue(&txt, "version", (uint8_t)strlen(TB_RECEIVER_VERSION), TB_RECEIVER_VERSION);
    TXTRecordSetValue(&txt, "supportsHEVCDecode", 1, tb_dec_supports_hevc_hwdecode() ? "1" : "0");
    TXTRecordSetValue(&txt, "supportsRawNV12", 1, "1");
    {
        /* PWE (1.1.1): which Mac and macOS the sender is talking to, for its
         * diagnostics. Nothing personal: no host or user name. */
        char model[64], os[32];
        if (tb_sysinfo_model(model, sizeof(model))[0]) {
            TXTRecordSetValue(&txt, "model", (uint8_t)strlen(model), model);
        }
        if (tb_sysinfo_os_version(os, sizeof(os))[0]) {
            TXTRecordSetValue(&txt, "os", (uint8_t)strlen(os), os);
        }
    }

    struct tb_display_info info;
    if (tb_disp_get_info(a->disp, &info) == 0) {
        char panel_w[16];
        char panel_h[16];
        snprintf(panel_w, sizeof(panel_w), "%u", info.active_w);
        snprintf(panel_h, sizeof(panel_h), "%u", info.active_h);
        TXTRecordSetValue(&txt, "panelWidth", (uint8_t)strlen(panel_w), panel_w);
        TXTRecordSetValue(&txt, "panelHeight", (uint8_t)strlen(panel_h), panel_h);
    }

    const unsigned int if1 = network ? 0 : (tb_if ? tb_if : usb_if);
    const unsigned int if2 = (tb_if && usb_if) ? usb_if : 0;

    /* PWE: the addresses this record announces. A change re-registers, as
     * upstream always did: senders that do not follow TXT updates see the
     * receiver leave and come back with its new addresses. During a session
     * (the bridge's IPv4 address arriving mid-session, T34) the record is
     * updated in place instead, so the sender does not see its receiver
     * vanish, and re-registered once the session ends (bonjour_pending). */
    char addrs[sizeof(a->bonjour_addrs)];
    snprintf(addrs, sizeof(addrs), "ip=%s tbIP=%s tbIP6=%s usbIP=%s netIP=%s ethernetIP=%s wifiIP=%s",
             announced_ip, a->tb_ip_text, tb_ip6, a->usb_ip_text,
             network ? a->net_ip_text : "", network ? a->ethernet_ip_text : "",
             network ? a->wifi_ip_text : "");
    const int same_addrs = strcmp(addrs, a->bonjour_addrs) == 0;
    if (a->bonjour_ref && a->bonjour_if1 == if1 && a->bonjour_if2 == if2 &&
        a->bonjour_port == port && (!if2 || a->bonjour_ref2) &&
        (same_addrs || a->client_fd >= 0)) {
        DNSServiceErrorType uerr = DNSServiceUpdateRecord(a->bonjour_ref, NULL, 0,
                                                          TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt), 0);
        if (uerr == kDNSServiceErr_NoError && a->bonjour_ref2) {
            uerr = DNSServiceUpdateRecord(a->bonjour_ref2, NULL, 0,
                                          TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt), 0);
        }
        if (uerr == kDNSServiceErr_NoError) {
            TXTRecordDeallocate(&txt);
            if (!same_addrs) {
                a->bonjour_pending = 1;
                fprintf(stderr, "[bonjour] TXT updated in place during the session: %s\n", addrs);
            }
            return;
        }
        fprintf(stderr, "[bonjour] TXT update failed (%d); registering again\n", (int)uerr);
    }
    bonjour_deinit(a);
    a->bonjour_if1 = if1;
    a->bonjour_if2 = if2;
    a->bonjour_port = port;
    a->bonjour_pending = 0;
    snprintf(a->bonjour_addrs, sizeof(a->bonjour_addrs), "%s", addrs);
    {
        char ifn[IFNAMSIZ] = "";
        if (if1) if_indextoname(if1, ifn);
        fprintf(stderr, "[bonjour] registering on %s: %s (TXT %u bytes)\n", if1 ? (ifn[0] ? ifn : "?") : "every interface",
                addrs, (unsigned)TXTRecordGetLength(&txt));
    }

    DNSServiceErrorType err = DNSServiceRegister(
        &a->bonjour_ref,
        0,
        if1,
        a->bonjour_name,
        "_targetbridge._tcp",
        "local.",
        NULL,
        htons(port),
        TXTRecordGetLength(&txt),
        TXTRecordGetBytesPtr(&txt),
        on_bonjour_register,
        a
    );
    if (err == kDNSServiceErr_NoError && if2) {
        /* Both cables: announce on the USB link too. */
        err = DNSServiceRegister(&a->bonjour_ref2, 0, usb_if, a->bonjour_name, "_targetbridge._tcp",
                                 "local.", NULL, htons(port), TXTRecordGetLength(&txt),
                                 TXTRecordGetBytesPtr(&txt), on_bonjour_register, a);
    }
    TXTRecordDeallocate(&txt);

    if (err != kDNSServiceErr_NoError) {
        fprintf(stderr, "[bonjour] unable to publish receiver service: %d\n", (int)err);
        bonjour_deinit(a);
    }
}

static void extract_json_string_field(const uint8_t *payload,
                                      size_t len,
                                      const char *key,
                                      char *out,
                                      size_t out_size) {
    if (!payload || !key || !out || out_size == 0) return;
    out[0] = '\0';

    const char *text = (const char *)payload;
    const char *pos = strstr(text, key);
    if (!pos) return;

    pos = strchr(pos, ':');
    if (!pos) return;
    pos = strchr(pos, '"');
    if (!pos) return;
    pos++;

    size_t i = 0;
    while ((size_t)(pos - text) < len && *pos && *pos != '"' && i + 1 < out_size) {
        if (*pos == '\\' && (size_t)(pos - text + 1) < len && pos[1] != '\0') pos++;
        out[i++] = *pos++;
    }
    out[i] = '\0';
}

static int extract_json_int_field(const uint8_t *payload,
                                  size_t len,
                                  const char *key,
                                  int *out_value) {
    if (!payload || !key || !out_value) return 0;

    const char *text = (const char *)payload;
    const char *pos = strstr(text, key);
    if (!pos) return 0;

    pos = strchr(pos, ':');
    if (!pos) return 0;
    pos++;
    while ((size_t)(pos - text) < len && (*pos == ' ' || *pos == '\t')) pos++;
    if ((size_t)(pos - text) >= len) return 0;

    char *end = NULL;
    long value = strtol(pos, &end, 10);
    if (end == pos) return 0;
    *out_value = (int)value;
    return 1;
}

static int extract_json_bool_field(const uint8_t *payload,
                                   size_t len,
                                   const char *key,
                                   int *out_value) {
    if (!payload || !key || !out_value) return 0;

    const char *text = (const char *)payload;
    const char *pos = strstr(text, key);
    if (!pos) return 0;

    pos = strchr(pos, ':');
    if (!pos) return 0;
    pos++;
    while ((size_t)(pos - text) < len && (*pos == ' ' || *pos == '\t')) pos++;
    if ((size_t)(pos - text) >= len) return 0;

    if (strncmp(pos, "true", 4) == 0) {
        *out_value = 1;
        return 1;
    }
    if (strncmp(pos, "false", 5) == 0) {
        *out_value = 0;
        return 1;
    }
    return extract_json_int_field(payload, len, key, out_value);
}

static int extract_json_double_field(const uint8_t *payload,
                                     size_t len,
                                     const char *key,
                                     double *out_value) {
    if (!payload || !key || !out_value) return 0;

    const char *text = (const char *)payload;
    const char *pos = strstr(text, key);
    if (!pos) return 0;

    pos = strchr(pos, ':');
    if (!pos) return 0;
    pos++;
    while ((size_t)(pos - text) < len && (*pos == ' ' || *pos == '\t')) pos++;
    if ((size_t)(pos - text) >= len) return 0;

    char *end = NULL;
    double value = strtod(pos, &end);
    if (end == pos) return 0;
    *out_value = value;
    return 1;
}

static CGPoint tb_receiver_current_mouse_location(void) {
    CGPoint point = CGPointZero;
    CGEventRef event = CGEventCreate(NULL);
    if (event) {
        point = CGEventGetLocation(event);
        CFRelease(event);
    }
    return point;
}

static void tb_receiver_post_mouse_move(int dx, int dy, CGEventType type, CGMouseButton button) {
    CGPoint current = tb_receiver_current_mouse_location();
    CGPoint target = CGPointMake(current.x + dx, current.y + dy);
    CGEventRef event = CGEventCreateMouseEvent(NULL, type, target, button);
    if (!event) return;
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void tb_receiver_post_mouse_button(CGEventType type, CGMouseButton button) {
    CGPoint current = tb_receiver_current_mouse_location();
    CGEventRef event = CGEventCreateMouseEvent(NULL, type, current, button);
    if (!event) return;
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void tb_receiver_post_scroll(int scroll_x, int scroll_y) {
    CGEventRef event = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitLine, 2, scroll_y, scroll_x);
    if (!event) return;
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void tb_receiver_post_key(uint16_t key_code, int is_down) {
    CGEventRef event = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)key_code, is_down ? true : false);
    if (!event) return;
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static void tb_receiver_apply_input_event(struct app *a, const uint8_t *payload, size_t len) {
    char kind[32];
    kind[0] = '\0';
    extract_json_string_field(payload, len, "\"kind\"", kind, sizeof(kind));
    if (kind[0] == '\0') return;
    /* PWE: sampled like the events sent, not one log line per mouse move. */
    a->input_events_received += 1;
    if (tb_should_log_input_event(a->input_events_received)) {
        tb_receiver_input_log("[input][sender->receiver] received #%llu kind=%s len=%zu",
                              (unsigned long long)a->input_events_received, kind, len);
    }

    if (strcmp(kind, "move") == 0) {
        int dx = 0;
        int dy = 0;
        (void)extract_json_int_field(payload, len, "\"dx\"", &dx);
        (void)extract_json_int_field(payload, len, "\"dy\"", &dy);
        tb_receiver_post_mouse_move(dx, dy, kCGEventMouseMoved, kCGMouseButtonLeft);
        return;
    }

    if (strcmp(kind, "leftDrag") == 0) {
        int dx = 0;
        int dy = 0;
        (void)extract_json_int_field(payload, len, "\"dx\"", &dx);
        (void)extract_json_int_field(payload, len, "\"dy\"", &dy);
        tb_receiver_post_mouse_move(dx, dy, kCGEventLeftMouseDragged, kCGMouseButtonLeft);
        return;
    }

    if (strcmp(kind, "rightDrag") == 0) {
        int dx = 0;
        int dy = 0;
        (void)extract_json_int_field(payload, len, "\"dx\"", &dx);
        (void)extract_json_int_field(payload, len, "\"dy\"", &dy);
        tb_receiver_post_mouse_move(dx, dy, kCGEventRightMouseDragged, kCGMouseButtonRight);
        return;
    }

    if (strcmp(kind, "otherDrag") == 0) {
        int dx = 0;
        int dy = 0;
        (void)extract_json_int_field(payload, len, "\"dx\"", &dx);
        (void)extract_json_int_field(payload, len, "\"dy\"", &dy);
        tb_receiver_post_mouse_move(dx, dy, kCGEventOtherMouseDragged, kCGMouseButtonCenter);
        return;
    }

    if (strcmp(kind, "leftDown") == 0) {
        tb_receiver_post_mouse_button(kCGEventLeftMouseDown, kCGMouseButtonLeft);
        return;
    }
    if (strcmp(kind, "leftUp") == 0) {
        tb_receiver_post_mouse_button(kCGEventLeftMouseUp, kCGMouseButtonLeft);
        return;
    }
    if (strcmp(kind, "rightDown") == 0) {
        tb_receiver_post_mouse_button(kCGEventRightMouseDown, kCGMouseButtonRight);
        return;
    }
    if (strcmp(kind, "rightUp") == 0) {
        tb_receiver_post_mouse_button(kCGEventRightMouseUp, kCGMouseButtonRight);
        return;
    }
    if (strcmp(kind, "otherDown") == 0) {
        tb_receiver_post_mouse_button(kCGEventOtherMouseDown, kCGMouseButtonCenter);
        return;
    }
    if (strcmp(kind, "otherUp") == 0) {
        tb_receiver_post_mouse_button(kCGEventOtherMouseUp, kCGMouseButtonCenter);
        return;
    }
    if (strcmp(kind, "scroll") == 0) {
        int scroll_x = 0;
        int scroll_y = 0;
        (void)extract_json_int_field(payload, len, "\"scrollX\"", &scroll_x);
        (void)extract_json_int_field(payload, len, "\"scrollY\"", &scroll_y);
        tb_receiver_post_scroll(scroll_x, scroll_y);
        return;
    }
    if (strcmp(kind, "keyDown") == 0 || strcmp(kind, "keyUp") == 0) {
        int key_code = 0;
        if (extract_json_int_field(payload, len, "\"keyCode\"", &key_code)) {
            tb_receiver_post_key((uint16_t)key_code, strcmp(kind, "keyDown") == 0);
        }
    }
}

static void tb_receiver_apply_input_control_mode(struct app *a, const uint8_t *payload, size_t len) {
    char mode[32];
    mode[0] = '\0';
    extract_json_string_field(payload, len, "\"mode\"", mode, sizeof(mode));
    if (mode[0] == '\0') {
        snprintf(a->input_control_mode, sizeof(a->input_control_mode), "off");
    } else {
        snprintf(a->input_control_mode, sizeof(a->input_control_mode), "%s", mode);
    }
    tb_receiver_input_log("[input] control mode updated to %s", a->input_control_mode);
    tb_receiver_update_forwarding(a);
    if (strcmp(a->input_control_mode, "receiverMaster") != 0) {
        pthread_mutex_lock(&a->tx_lock);   /* PWE (1.1.1): the tap's state */
        a->sent_command_down = 0;
        a->sent_shift_down = 0;
        a->sent_option_down = 0;
        a->sent_control_down = 0;
        a->sent_caps_down = 0;
        pthread_mutex_unlock(&a->tx_lock);
    }
    tb_receiver_refresh_input_capture(a);
}

/* ---- Callbacks: decoder → display ------------------------------------ */

/* PWE (1.1.1): a session's first picture wakes the iMac's screen, as a key
 * press would. A Mac that connects to an iMac whose display has gone to sleep
 * otherwise streams to a dark panel until someone touches the iMac. Declared
 * on the first frame, not on accept: only a session that got through the
 * handshake and is sending pictures counts. A password-locked iMac wakes to
 * its lock screen and stays locked. */
static void tb_receiver_wake_screen_for_session(void) {
    static IOPMAssertionID activity = kIOPMNullAssertionID;
    const IOReturn r = IOPMAssertionDeclareUserActivity(CFSTR("PWE Screen Encore session"),
                                                        kIOPMUserActiveLocal, &activity);
    if (r == kIOReturnSuccess) fprintf(stderr, "[power] first picture: screen woken\n");
    else fprintf(stderr, "[power] first picture: could not wake the screen (0x%x)\n", (unsigned)r);
}

/* A decoded picture goes to the screen now. */
static void tb_receiver_present(struct app *a, const struct tb_frame *frame) {
    if (!a->have_video_frame) tb_receiver_wake_screen_for_session();
    a->have_video_frame = 1;
    tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.stream_active");
    {
        char width_text[16];
        char height_text[16];
        struct tb_i18n_pair pairs[] = {
            { "width", width_text },
            { "height", height_text }
        };
        snprintf(width_text, sizeof(width_text), "%d", frame->width);
        snprintf(height_text, sizeof(height_text), "%d", frame->height);
        tb_format_i18n(a->mode_text, sizeof(a->mode_text), "receiver.mode.receiving", pairs, 2);
    }
    tb_disp_show_frame(a->disp, frame);
    a->frames++;
}

/* PWE (1.1.1): the waiting picture is not shown: a newer one replaces it. */
static void tb_receiver_skip_waiting_frame(struct app *a) {
    if (!a->catchup_frame) return;
    tb_trace_frame_replaced(a->catchup_trace_id);
    CVPixelBufferRelease(a->catchup_frame);
    a->catchup_frame = NULL;
    a->catchup_trace_id = 0;
    a->catchup_skipped++;
}

/* PWE (1.1.1): the read pass ended: show the newest waiting picture. */
static void tb_receiver_show_waiting_frame(struct app *a) {
    CVPixelBufferRef pb = a->catchup_frame;
    if (!pb) return;
    a->catchup_frame = NULL;
    const struct tb_frame f = {
        .width = (int)CVPixelBufferGetWidth(pb),
        .height = (int)CVPixelBufferGetHeight(pb),
        .pixel_buffer = pb,
        .trace_id = a->catchup_trace_id,
    };
    a->catchup_trace_id = 0;
    tb_receiver_present(a, &f);
    CVPixelBufferRelease(pb);
}

static void on_frame(const struct tb_frame *frame, void *ud) {
    struct app *a = (struct app *)ud;
    tb_trace_mark_now(frame->trace_id, TB_TRACE_DECODED);
    /* PWE (1.1.1): behind the sender, the picture waits; a newer one decoded
     * in the same pass replaces it. VideoToolbox pictures only: they can be
     * kept past this call by a retain. CPU pictures (software decode) are
     * valid only now and are shown as before. */
    if (a->catchup_holding && frame->pixel_buffer) {
        tb_receiver_skip_waiting_frame(a);
        a->catchup_frame = CVPixelBufferRetain((CVPixelBufferRef)frame->pixel_buffer);
        a->catchup_trace_id = frame->trace_id;
        return;
    }
    tb_receiver_skip_waiting_frame(a);
    tb_receiver_present(a, frame);
}

/* Raw passthrough: render received NV12 planes directly, bypassing the decoder.
 * Payload: [1: format=1(NV12)][BE32 w][BE32 h][BE32 yStride][BE32 uvStride]
 *          [Y plane: yStride*h][CbCr plane: uvStride*(h/2)] */
static void handle_raw_frame(struct app *a, const uint8_t *p, size_t len) {
    if (len < 17) return;
    if (p[0] != 1) return; /* only NV12 is supported */
    uint32_t w  = ((uint32_t)p[1]  << 24) | ((uint32_t)p[2]  << 16) | ((uint32_t)p[3]  << 8) | (uint32_t)p[4];
    uint32_t h  = ((uint32_t)p[5]  << 24) | ((uint32_t)p[6]  << 16) | ((uint32_t)p[7]  << 8) | (uint32_t)p[8];
    uint32_t ys = ((uint32_t)p[9]  << 24) | ((uint32_t)p[10] << 16) | ((uint32_t)p[11] << 8) | (uint32_t)p[12];
    uint32_t us = ((uint32_t)p[13] << 24) | ((uint32_t)p[14] << 16) | ((uint32_t)p[15] << 8) | (uint32_t)p[16];
    /* Keep malformed peer data from turning into oversized stride arithmetic or
     * an out-of-bounds render. TargetBridge RAW is intentionally limited to
     * practical 4:2:0 display sizes and the protocol packet cap. */
    if (w == 0 || h == 0 || (w & 1) || (h & 1) ||
        w > 8192 || h > 8192 || ys < w || us < w ||
        ys > 16384 || us > 16384) return;
    size_t y_size  = (size_t)ys * h;
    size_t uv_size = (size_t)us * (h / 2);
    size_t payload_size = len - 17;
    if (y_size > payload_size || uv_size > payload_size - y_size) return;
    const uint8_t *y  = p + 17;
    const uint8_t *uv = y + y_size;
    const uint32_t trace_id = tb_trace_frame_arrived();
    tb_trace_mark_now(trace_id, TB_TRACE_DECODED);   /* nothing to decode */

    if (!a->have_video_frame) tb_receiver_wake_screen_for_session();
    a->have_video_frame = 1;
    tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.stream_active");
    {
        char width_text[16];
        char height_text[16];
        struct tb_i18n_pair pairs[] = {
            { "width", width_text },
            { "height", height_text }
        };
        snprintf(width_text, sizeof(width_text), "%u", w);
        snprintf(height_text, sizeof(height_text), "%u", h);
        tb_format_i18n(a->mode_text, sizeof(a->mode_text), "receiver.mode.receiving", pairs, 2);
    }
    struct tb_frame frame = {
        .y = y, .y_stride = (int)ys,
        .uv = uv, .uv_stride = (int)us,
        .width = (int)w, .height = (int)h,
        .trace_id = trace_id,
    };
    tb_disp_show_frame(a->disp, &frame);
    a->frames++;
}

/* ---- Callbacks: parser → decoder ------------------------------------- */

static void on_packet(uint8_t type, const uint8_t *payload, size_t len, void *ud) {
    struct app *a = (struct app *)ud;
#if TB_RECEIVER_TEST_HOOKS
    a->pwe_test_counts[type]++;
#endif
    /* Each packet names itself; the caller's phase comes back afterwards. */
    const char *outer_phase = TB_LOOP_ENTER("packet: other");
    switch (type) {
    case TB_PKT_UI_LANGUAGE:
        TB_LOOP_PHASE("packet: UI language");
        {
            char ui_language[16];
            ui_language[0] = '\0';
            extract_json_string_field(payload, len, "\"uiLanguage\"", ui_language, sizeof(ui_language));
            if (ui_language[0] != '\0') {
                snprintf(a->sender_ui_language, sizeof(a->sender_ui_language), "%s", ui_language);
                if (strcmp(a->language_pref, "auto") == 0) {
                    tb_i18n_set_runtime_language(ui_language);
                }
                if (a->client_fd < 0 || !a->have_video_frame) {
                    tb_refresh_idle_localized_strings(a);
                }
            }
        }
        break;
    case TB_PKT_HELLO_RECEIVER:
        TB_LOOP_PHASE("packet: hello (renderer choice)");
        extract_json_string_field(payload, len, "\"senderName\"", a->sender_text, sizeof(a->sender_text));
        {
            char ui_language[16];
            ui_language[0] = '\0';
            extract_json_string_field(payload, len, "\"uiLanguage\"", ui_language, sizeof(ui_language));
            if (ui_language[0] != '\0') {
                snprintf(a->sender_ui_language, sizeof(a->sender_ui_language), "%s", ui_language);
                if (strcmp(a->language_pref, "auto") == 0) {
                    tb_i18n_set_runtime_language(ui_language);
                }
            }
        }
        if (a->sender_text[0] == '\0') {
            tb_copy_i18n(a->sender_text, sizeof(a->sender_text), "receiver.status.sender_connected");
        }
        {
            char preset[64];
            char source[64];
            char codec[64];
            int capture_w = 0;
            int capture_h = 0;
            preset[0] = '\0';
            source[0] = '\0';
            codec[0] = '\0';
            extract_json_string_field(payload, len, "\"capturePreset\"", preset, sizeof(preset));
            extract_json_string_field(payload, len, "\"captureSource\"", source, sizeof(source));
            extract_json_string_field(payload, len, "\"codec\"", codec, sizeof(codec));
            (void)extract_json_int_field(payload, len, "\"captureWidth\"", &capture_w);
            (void)extract_json_int_field(payload, len, "\"captureHeight\"", &capture_h);

            tb_set_receiver_mode_requested(a->mode_text, sizeof(a->mode_text), capture_w, capture_h, source, preset, codec);
        }
        {
            /* PWE: Settings › Advanced on the Mac, "metal" or "opengl"; absent
             * from upstream senders. Applied before the first frame. */
            char renderer[16];
            renderer[0] = '\0';
            extract_json_string_field(payload, len, "\"receiverRenderer\"", renderer, sizeof(renderer));
            tb_disp_use_renderer(a->disp, renderer[0] ? renderer : NULL);
        }
        a->session_active = 1;
        fprintf(stderr, "[main] hello from sender\n");
        tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.sender_connected_profile_sent");
        break;
    case TB_PKT_CREATE_SESSION_ACK:
        a->session_active = 1;
        fprintf(stderr, "[main] sender session ack: %.*s\n", (int)len, (const char *)payload);
        tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.session_accepted_waiting_frames");
        break;
    case TB_PKT_PARAM_SETS:
        TB_LOOP_PHASE("packet: parameter sets (decoder open)");
        a->session_active = 1;
        /* tb_dec_set_param_sets is now a no-op if the sets are unchanged,
         * so we don't spam a log line per keyframe. */
        tb_dec_set_param_sets(a->dec, payload, len);
        break;
    case TB_PKT_FRAME:
        TB_LOOP_PHASE("packet: video frame (decode, draw)");
        a->session_active = 1;
        tb_catchup_note_frame(&a->catchup, len);   /* PWE (1.1.1) */
        tb_dec_feed_frame(a->dec, payload, len, tb_trace_frame_arrived());
        break;
    case TB_PKT_RAW_FRAME:
        TB_LOOP_PHASE("packet: raw frame (draw)");
        a->session_active = 1;
        handle_raw_frame(a, payload, len);
        break;
    case TB_PKT_CURSOR:
        TB_LOOP_PHASE("packet: pointer position");
        {
            int x = 0;
            int y = 0;
            int w = 0;
            int h = 0;
            int visible = 0;
            int type = 0;
            int large = 0;
            (void)extract_json_int_field(payload, len, "\"x\"", &x);
            (void)extract_json_int_field(payload, len, "\"y\"", &y);
            (void)extract_json_int_field(payload, len, "\"width\"", &w);
            (void)extract_json_int_field(payload, len, "\"height\"", &h);
            (void)extract_json_bool_field(payload, len, "\"visible\"", &visible);
            (void)extract_json_int_field(payload, len, "\"type\"", &type);
            (void)extract_json_bool_field(payload, len, "\"large\"", &large);
            tb_disp_set_cursor(a->disp, x, y, w, h, visible, type, large);
        }
        break;
    case TB_PKT_CURSOR_IMAGE:
        TB_LOOP_PHASE("packet: pointer picture");
        {
            struct tb_cursor_image image;
            if (tb_cursor_image_parse(payload, len, &image) == 0) {
                tb_disp_set_cursor_image(a->disp, &image);
            } else {
                fprintf(stderr, "[main] malformed cursor image (%zu bytes)\n", len);
            }
        }
        break;
    case TB_PKT_BRIGHTNESS:
        TB_LOOP_PHASE("packet: brightness (DisplayServices)");
        {
            double level = 1.0;
            (void)extract_json_double_field(payload, len, "\"level\"", &level);
            tb_disp_set_brightness(a->disp, level);
        }
        break;
    case TB_PKT_DISPLAY_TWEAKS:
        TB_LOOP_PHASE("packet: Night Shift / True Tone (CoreBrightness)");
        {
            /* Absent fields are left alone rather than defaulted, so the sender
             * can change one without disturbing the other. */
            int night = 0, tone = 0;
            if (extract_json_bool_field(payload, len, "\"nightShift\"", &night)) {
                tb_night_shift_set(night);
            }
            if (extract_json_bool_field(payload, len, "\"trueTone\"", &tone)) {
                tb_true_tone_set(tone);
            }
        }
        break;
    case TB_PKT_CLIPBOARD:
        TB_LOOP_PHASE("packet: clipboard (handed to the clipboard thread)");
        {
            char text[TB_CLIPBOARD_MAX_TEXT];
            extract_json_string_field(payload, len, "\"text\"", text, sizeof(text));
            tb_clipboard_write(a->clipboard, text);   /* PWE (T40): written on the clipboard thread */
        }
        break;
    case TB_PKT_VOLUME:
        TB_LOOP_PHASE("packet: volume");
        {
            double level = 1.0;
            (void)extract_json_double_field(payload, len, "\"level\"", &level);
            tb_audio_out_set_volume(a->audio, level);   /* PWE (T40): CoreAudio on the audio thread */
        }
        break;
    case TB_PKT_AUDIO_FRAME:
        /* PWE (T40): queued for the audio thread, which opens the device. The
         * loop never takes SDL's device lock or calls CoreAudio. */
        TB_LOOP_PHASE("packet: audio");
        tb_audio_out_push(a->audio, payload, len);
        break;
    case TB_PKT_INPUT_EVENT:
        TB_LOOP_PHASE("packet: input event");
        tb_receiver_apply_input_event(a, payload, len);
        break;
    case TB_PKT_INPUT_CONTROL:
        TB_LOOP_PHASE("packet: input control mode (event tap)");
        tb_receiver_apply_input_control_mode(a, payload, len);
        break;
    case TB_PKT_HEARTBEAT:
        break;
    case TB_PKT_TEST_DATA:
        /* Performance test data; discard */
#if TB_RECEIVER_TEST_HOOKS
        /* Tests only: "stall <ms>" holds up the main loop, for the watchdog. */
        if (len > 6 && len < 32 && memcmp(payload, "stall ", 6) == 0) {
            char ms_text[32];
            memcpy(ms_text, payload + 6, len - 6);
            ms_text[len - 6] = '\0';
            TB_LOOP_PHASE("packet: test stall");
            usleep((useconds_t)(strtoul(ms_text, NULL, 10) * 1000u));
        }
#endif
        break;
    case TB_PKT_TEARDOWN:
        fprintf(stderr, "[main] teardown requested by sender\n");
        tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.session_closed_by_sender");
        a->close_requested = 1;
        break;
    default:
        fprintf(stderr, "[main] unknown pkt type=0x%02x\n", type);
        break;
    }
    TB_LOOP_LEAVE(outer_phase);
}

/* ---- Networking helpers ---------------------------------------------- */

/* PWE (1.1.1): one read pass. Behind the sender (tb_catchup.h), the pictures
 * decoded from a chunk wait and only the newest is shown when the pass ends;
 * a pass that has decoded for TB_CATCHUP_PASS_BUDGET_MS ends early, so a long
 * backlog still lets the loop show a picture and answer the window and the
 * keyboard every 50 ms. Every frame is decoded either way. */
static int drain_socket_pass(struct app *a) {
    uint8_t buf[1024 * 1024];
    int saw_data = 0;
    const uint64_t started_ms = now_ms();
    for (;;) {
        TB_LOOP_PHASE("socket read");
        ssize_t n = read(a->client_fd, buf, sizeof(buf));
        if (n > 0) {
            saw_data = 1;
            int waiting = 0;   /* bytes the kernel still holds after this chunk */
            if (ioctl(a->client_fd, FIONREAD, &waiting) < 0 || waiting < 0) waiting = 0;
            a->catchup_holding = tb_catchup_behind(&a->catchup, (uint64_t)n + (uint64_t)waiting);
            TB_LOOP_PHASE("connection: secure layer (handshake, keychain, decrypt)");
            const int fed = tb_conn_feed(&a->conn, buf, (size_t)n, now_ms());
            a->catchup_holding = 0;
            if (fed < 0) return -1;
            if (waiting > 0 && now_ms() - started_ms >= TB_CATCHUP_PASS_BUDGET_MS) return saw_data;
        } else if (n == 0) {
            return -1;  /* peer closed */
        } else {
            if (errno == EAGAIN || errno == EWOULDBLOCK) return saw_data;
            perror("[main] read");
            return -1;
        }
    }
}

static int drain_socket(struct app *a) {
    const unsigned long skipped_before = a->catchup_skipped;
    const int r = drain_socket_pass(a);
    if (r < 0) {
        tb_receiver_skip_waiting_frame(a);   /* the session is ending */
    } else {
        TB_LOOP_PHASE("display: the newest picture of a backlog");
        tb_receiver_show_waiting_frame(a);
    }
    if (a->catchup_skipped != skipped_before) a->catchup_passes++;
    return r;
}

static void write_be32(uint8_t *dst, uint32_t value) {
    dst[0] = (uint8_t)((value >> 24) & 0xff);
    dst[1] = (uint8_t)((value >> 16) & 0xff);
    dst[2] = (uint8_t)((value >> 8) & 0xff);
    dst[3] = (uint8_t)(value & 0xff);
}

static void tb_receiver_send_input_event(struct app *a,
                                         const char *kind,
                                         int has_dx, int dx,
                                         int has_dy, int dy,
                                         int has_scroll_x, int scroll_x,
                                         int has_scroll_y, int scroll_y,
                                         int has_key_code, uint16_t key_code) {
    /* PWE (1.1.1): called from the tap's thread too; `forwarding` stands for
     * "receiverMaster with a session" there. */
    if (!a || !atomic_load(&a->forwarding)) return;

    char json[256];
    int len = snprintf(json, sizeof(json), "{\"kind\":\"%s\"", kind ? kind : "");
    if (len <= 0 || (size_t)len >= sizeof(json)) return;

    if (has_dx) len += snprintf(json + len, sizeof(json) - (size_t)len, ",\"dx\":%d", dx);
    if (has_dy) len += snprintf(json + len, sizeof(json) - (size_t)len, ",\"dy\":%d", dy);
    if (has_scroll_x) len += snprintf(json + len, sizeof(json) - (size_t)len, ",\"scrollX\":%d", scroll_x);
    if (has_scroll_y) len += snprintf(json + len, sizeof(json) - (size_t)len, ",\"scrollY\":%d", scroll_y);
    if (has_key_code) len += snprintf(json + len, sizeof(json) - (size_t)len, ",\"keyCode\":%u", (unsigned int)key_code);
    len += snprintf(json + len, sizeof(json) - (size_t)len, "}");
    if (len <= 0 || (size_t)len >= sizeof(json)) return;

    uint8_t pkt[4 + 1 + sizeof(json)];
    write_be32(pkt, (uint32_t)(1 + len));
    pkt[4] = TB_PKT_INPUT_EVENT;
    memcpy(pkt + 5, json, (size_t)len);
    pthread_mutex_lock(&a->tx_lock);
    if (!atomic_load(&a->forwarding)) {   /* the session ended meanwhile */
        pthread_mutex_unlock(&a->tx_lock);
        return;
    }
    a->input_events_sent += 1;
    if (tb_should_log_input_event(a->input_events_sent)) {
        /* PWE: whether a key was sent, never which: the log is a file now,
         * and the keys typed may be a password. */
        tb_receiver_input_log("[input][receiver->sender] send #%llu kind=%s dx=%d dy=%d sx=%d sy=%d key=%s mode=receiverMaster",
                              (unsigned long long)a->input_events_sent,
                              kind ? kind : "?",
                              has_dx ? dx : 0,
                              has_dy ? dy : 0,
                              has_scroll_x ? scroll_x : 0,
                              has_scroll_y ? scroll_y : 0,
                              has_key_code ? "yes" : "no");
    }
    (void)tb_conn_send_packet(&a->conn, pkt, 5 + (size_t)len);
    pthread_mutex_unlock(&a->tx_lock);
}

static void tb_receiver_send_input_button_event(struct app *a,
                                                const char *kind,
                                                int click_count) {
    if (!a || !atomic_load(&a->forwarding)) return;   /* PWE (1.1.1): as above */

    if (click_count < 1) click_count = 1;
    if (click_count > 3) click_count = 3;

    char json[128];
    int len = snprintf(json, sizeof(json),
                       "{\"kind\":\"%s\",\"clickCount\":%d}",
                       kind ? kind : "",
                       click_count);
    if (len <= 0 || (size_t)len >= sizeof(json)) return;

    uint8_t pkt[4 + 1 + sizeof(json)];
    write_be32(pkt, (uint32_t)(1 + len));
    pkt[4] = TB_PKT_INPUT_EVENT;
    memcpy(pkt + 5, json, (size_t)len);
    pthread_mutex_lock(&a->tx_lock);
    if (!atomic_load(&a->forwarding)) {
        pthread_mutex_unlock(&a->tx_lock);
        return;
    }
    a->input_events_sent += 1;
    if (tb_should_log_input_event(a->input_events_sent)) {
        tb_receiver_input_log("[input][receiver->sender] send #%llu kind=%s dx=%d dy=%d sx=%d sy=%d key=%s mode=receiverMaster",
                              (unsigned long long)a->input_events_sent,
                              kind ? kind : "?",
                              0,
                              0,
                              0,
                              0,
                              "no");
    }
    (void)tb_conn_send_packet(&a->conn, pkt, 5 + (size_t)len);
    pthread_mutex_unlock(&a->tx_lock);
}

static void tb_receiver_send_target_switch(struct app *a, int direction) {
    tb_receiver_send_input_event(a,
                                 direction < 0 ? "switchPrevTarget" : "switchNextTarget",
                                 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
}

static void tb_receiver_sync_modifier_state(struct app *a,
                                            int command_down,
                                            int shift_down,
                                            int option_down,
                                            int control_down,
                                            int caps_down) {
    if (!a) return;

    struct {
        int *state;
        int desired;
        uint16_t key_code;
    } modifiers[] = {
        { &a->sent_command_down, command_down, 55 },
        { &a->sent_shift_down,   shift_down,   56 },
        { &a->sent_option_down,  option_down,  58 },
        { &a->sent_control_down, control_down, 59 },
        { &a->sent_caps_down,    caps_down,    57 }
    };

    for (size_t i = 0; i < sizeof(modifiers) / sizeof(modifiers[0]); i++) {
        if (*modifiers[i].state == modifiers[i].desired) continue;
        tb_receiver_send_input_event(a,
                                     modifiers[i].desired ? "keyDown" : "keyUp",
                                     0, 0, 0, 0, 0, 0, 0, 0, 1, modifiers[i].key_code);
        *modifiers[i].state = modifiers[i].desired;
    }
}

static void tb_receiver_send_space_switch(struct app *a, int direction) {
    tb_receiver_send_input_event(a,
                                 direction < 0 ? "switchPrevSpace" : "switchNextSpace",
                                 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
}

static void tb_receiver_space_switch_callback(int direction, void *context) {
    struct app *a = (struct app *)context;
    if (!a || strcmp(a->input_control_mode, "receiverMaster") != 0 || a->client_fd < 0) return;
    tb_receiver_send_space_switch(a, direction);
}

static void tb_receiver_send_deactivate_control(struct app *a) {
    tb_receiver_send_input_event(a,
                                 "deactivateInputControl",
                                 0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
}

/* PWE (1.1.1): how old an event is, in ms; negative when unknown. An event's
 * timestamp is nanoseconds of uptime (CLOCK_UPTIME_RAW), on Apple silicon as
 * on Intel (measured 2026-10-24: mach_absolute_time counts 24 MHz ticks on
 * Apple silicon, so it is not the clock to compare with). */
static double tb_receiver_event_age_ms(CGEventRef event) {
    const uint64_t stamp = CGEventGetTimestamp(event);
    const uint64_t now = tb_trace_now_ns();   /* CLOCK_UPTIME_RAW */
    if (!stamp || now < stamp) return -1.0;
    const double ms = (double)(now - stamp) / 1e6;
    return ms < 10000.0 ? ms : -1.0;
}

/* PWE (1.1.1): the input state below is the tap's and is guarded by tx_lock
 * (recursive: the sends inside take it again). */
static int tb_receiver_input_tap_forward(struct app *a, CGEventType type, CGEventRef event);

static CGEventRef tb_receiver_input_tap_callback(CGEventTapProxy proxy,
                                                 CGEventType type,
                                                 CGEventRef event,
                                                 void *user_info) {
    (void)proxy;
    struct app *a = (struct app *)user_info;
    if (!a) return event;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (a->input_tap) CGEventTapEnable(a->input_tap, true);
        /* PWE (1.1.1): say so (once per 10 s); a tap that stays off (a removed
         * permission) is rebuilt from the main loop. */
        static struct tb_ratelimit disabled_log;   /* the tap's thread only */
        unsigned long quiet = 0;
        const int still_off = a->input_tap && !CGEventTapIsEnabled(a->input_tap);
        if (tb_ratelimit_allow(&disabled_log, now_ms(), 10000, &quiet)) {
            tb_receiver_input_log("[input] macOS switched the event tap off (%s); %s%s",
                                  type == kCGEventTapDisabledByTimeout ? "timeout" : "user input",
                                  still_off ? "it stays off" : "switched back on",
                                  quiet ? "; it happened before since the last report" : "");
        }
        if (still_off) atomic_store(&a->tap_switched_off, 1);
        return event;
    }

    /* PWE (1.1.1): this runs on the tap's thread; the control mode string
     * belongs to the main thread, `forwarding` stands for it. */
    if (!atomic_load(&a->forwarding)) return event;

    /* Only drive the sender while the user is actually on the shared display
     * window's Space. The global tap also sees events from other receiver
     * Spaces; forwarding those would make the sender's cursor jump while the
     * user is doing local work on the receiver. When the window is on a
     * different Space, pass the event through untouched and forward nothing.
     * PWE (1.1.1): AppKit answers that on the main thread only; this reads
     * its answer from at most 100 ms ago. */
    if (!atomic_load(&a->window_on_active_space)) return event;

    pthread_mutex_lock(&a->tx_lock);
    const int should_consume = tb_receiver_input_tap_forward(a, type, event);
    pthread_mutex_unlock(&a->tx_lock);

    /* PWE (1.1.1): how fast input reaches the Mac, one line per 10 s. */
    uint64_t rate_window_ns = 10000000000ull;
#if TB_RECEIVER_TEST_HOOKS
    {
        /* Tests only: a shorter report window. */
        static long test_window_ms = -1;   /* the tap's thread only */
        if (test_window_ms < 0) {
            const char *v = getenv("TB_RECEIVER_TEST_INPUT_RATE_MS");
            test_window_ms = v ? strtol(v, NULL, 10) : 0;
        }
        if (test_window_ms > 0) rate_window_ns = (uint64_t)test_window_ms * 1000000ull;
    }
#endif
    tb_input_rate_note(&a->tap_rate, tb_trace_now_ns(), tb_receiver_event_age_ms(event));
    char rate_line[256];
    if (tb_input_rate_report(&a->tap_rate, tb_trace_now_ns(), rate_window_ns, rate_line, sizeof(rate_line))) {
        tb_receiver_input_log("[input] %s%s", rate_line, a->tap_thread ? "" : " (tap on the main run loop)");
    }
    return should_consume ? NULL : event;
}

/* PWE (1.1.1, A16): the iMac's own (hidden) pointer reached a side of its
 * screen, so the move became a request to switch to another receiver, which a
 * Mac with one receiver ignores. The iMac's pointer and the Mac's pointer move
 * independently; when the pointer seems to vanish or stop, these lines say
 * whether this was it. Once per 10 s. Under tx_lock. */
static void tb_receiver_log_edge_switch(struct app *a, int direction, CGPoint location) {
    unsigned long quiet = 0;
    if (!tb_ratelimit_allow(&a->edge_switch_log, now_ms(), 10000, &quiet)) return;
    tb_receiver_input_log("[input] the iMac's pointer is at the %s edge of its screen (%.0f, %.0f): "
                          "asked the Mac to switch to the %s receiver instead of moving%s",
                          direction < 0 ? "left" : "right", location.x, location.y,
                          direction < 0 ? "previous" : "next",
                          quiet ? "; more since the last report" : "");
}

/* Forward one event; 1 when it should not reach the iMac's own apps. */
static int tb_receiver_input_tap_forward(struct app *a, CGEventType type, CGEventRef event) {
    int should_consume = 0;

    switch (type) {
    case kCGEventMouseMoved:
    case kCGEventLeftMouseDragged:
    case kCGEventRightMouseDragged:
    case kCGEventOtherMouseDragged: {
        int dx = (int)CGEventGetIntegerValueField(event, kCGMouseEventDeltaX);
        int dy = (int)CGEventGetIntegerValueField(event, kCGMouseEventDeltaY);
        CGPoint location = CGEventGetLocation(event);
        CGRect bounds = CGDisplayBounds(CGMainDisplayID());
        uint64_t now = now_ms();
        if (now - a->last_target_switch_ms > 450) {
            if (location.x <= CGRectGetMinX(bounds) + 2.0 && dx < 0) {
                a->last_target_switch_ms = now;
                tb_receiver_log_edge_switch(a, -1, location);
                tb_receiver_send_target_switch(a, -1);
                should_consume = a->input_tap_consumes_events;
                break;
            }
            if (location.x >= CGRectGetMaxX(bounds) - 2.0 && dx > 0) {
                a->last_target_switch_ms = now;
                tb_receiver_log_edge_switch(a, 1, location);
                tb_receiver_send_target_switch(a, 1);
                should_consume = a->input_tap_consumes_events;
                break;
            }
        }
        const char *kind = "move";
        if (type == kCGEventLeftMouseDragged) kind = "leftDrag";
        else if (type == kCGEventRightMouseDragged) kind = "rightDrag";
        else if (type == kCGEventOtherMouseDragged) kind = "otherDrag";
        tb_receiver_send_input_event(a, kind, 1, dx, 1, dy, 0, 0, 0, 0, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    }
    case kCGEventLeftMouseDown:
        tb_receiver_send_input_button_event(
            a,
            "leftDown",
            (int)CGEventGetIntegerValueField(event, kCGMouseEventClickState));
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventLeftMouseUp:
        tb_receiver_send_input_button_event(
            a,
            "leftUp",
            (int)CGEventGetIntegerValueField(event, kCGMouseEventClickState));
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventRightMouseDown:
        tb_receiver_send_input_button_event(
            a,
            "rightDown",
            (int)CGEventGetIntegerValueField(event, kCGMouseEventClickState));
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventRightMouseUp:
        tb_receiver_send_input_button_event(
            a,
            "rightUp",
            (int)CGEventGetIntegerValueField(event, kCGMouseEventClickState));
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventOtherMouseDown:
        tb_receiver_send_input_button_event(
            a,
            "otherDown",
            (int)CGEventGetIntegerValueField(event, kCGMouseEventClickState));
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventOtherMouseUp:
        tb_receiver_send_input_button_event(
            a,
            "otherUp",
            (int)CGEventGetIntegerValueField(event, kCGMouseEventClickState));
        should_consume = a->input_tap_consumes_events;
        break;
    case kCGEventScrollWheel: {
        int sx = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2);
        int sy = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1);
        int point_sx = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2);
        int point_sy = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1);
        int is_continuous = (int)CGEventGetIntegerValueField(event, kCGScrollWheelEventIsContinuous);
        CGEventFlags flags = CGEventGetFlags(event);
        const CGEventFlags effective_flags = flags & ~kCGEventFlagMaskSecondaryFn;
        uint64_t now = now_ms();
        if ((effective_flags & kCGEventFlagMaskAlternate) &&
            (llabs((long long)point_sx) > llabs((long long)point_sy) * 2 || llabs((long long)sx) > llabs((long long)sy) * 2) &&
            now - a->last_space_switch_ms > 300) {
            int direction = 0;
            if (point_sx != 0) direction = point_sx > 0 ? 1 : -1;
            else if (sx != 0) direction = sx > 0 ? 1 : -1;
            if (direction != 0) {
                a->last_space_switch_ms = now;
                a->space_gesture_accum_x = 0;
                tb_receiver_send_space_switch(a, direction);
                should_consume = a->input_tap_consumes_events;
                break;
            }
        }
        if (is_continuous &&
            (point_sx != 0 || point_sy != 0) &&
            llabs((long long)point_sx) > llabs((long long)point_sy) * 2) {
            if (now - a->last_space_gesture_ms > 250) {
                a->space_gesture_accum_x = 0;
            }
            a->last_space_gesture_ms = now;
            a->space_gesture_accum_x += point_sx;
            if (llabs((long long)a->space_gesture_accum_x) >= 45 &&
                now - a->last_space_switch_ms > 450) {
                a->last_space_switch_ms = now;
                tb_receiver_send_space_switch(a, a->space_gesture_accum_x > 0 ? 1 : -1);
                a->space_gesture_accum_x = 0;
            }
            should_consume = a->input_tap_consumes_events;
            break;
        }
        if (now - a->last_space_gesture_ms > 250) {
            a->space_gesture_accum_x = 0;
        }
        tb_receiver_send_input_event(a, "scroll", 0, 0, 0, 0, 1, sx, 1, sy, 0, 0);
        should_consume = a->input_tap_consumes_events;
        break;
    }
    case kCGEventKeyDown: {
        uint16_t key_code = (uint16_t)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        CGEventFlags flags = CGEventGetFlags(event);
        const CGEventFlags effective_flags = flags & ~kCGEventFlagMaskSecondaryFn;
        tb_receiver_sync_modifier_state(a,
                                        (effective_flags & kCGEventFlagMaskCommand) != 0,
                                        (effective_flags & kCGEventFlagMaskShift) != 0,
                                        (effective_flags & kCGEventFlagMaskAlternate) != 0,
                                        (effective_flags & kCGEventFlagMaskControl) != 0,
                                        (effective_flags & kCGEventFlagMaskAlphaShift) != 0);
        if ((flags & kCGEventFlagMaskControl) &&
            (flags & kCGEventFlagMaskAlternate) &&
            (flags & kCGEventFlagMaskCommand) &&
            key_code == 40) {
            tb_receiver_send_deactivate_control(a);
            should_consume = a->input_tap_consumes_events;
            break;
        }
        if ((effective_flags & kCGEventFlagMaskControl) && (effective_flags & kCGEventFlagMaskCommand)) {
            if (key_code == 123) {
                tb_receiver_send_target_switch(a, -1);
                should_consume = a->input_tap_consumes_events;
                break;
            }
            if (key_code == 124) {
                tb_receiver_send_target_switch(a, 1);
                should_consume = a->input_tap_consumes_events;
                break;
            }
        }
        tb_receiver_send_input_event(a, "keyDown", 0, 0, 0, 0, 0, 0, 0, 0, 1, key_code);
        should_consume = a->input_tap_consumes_events;
        break;
    }
    case kCGEventKeyUp:
    {
        uint16_t key_code = (uint16_t)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        CGEventFlags flags = CGEventGetFlags(event);
        const CGEventFlags effective_flags = flags & ~kCGEventFlagMaskSecondaryFn;
        tb_receiver_sync_modifier_state(a,
                                        (effective_flags & kCGEventFlagMaskCommand) != 0,
                                        (effective_flags & kCGEventFlagMaskShift) != 0,
                                        (effective_flags & kCGEventFlagMaskAlternate) != 0,
                                        (effective_flags & kCGEventFlagMaskControl) != 0,
                                        (effective_flags & kCGEventFlagMaskAlphaShift) != 0);
        if ((flags & kCGEventFlagMaskControl) &&
            (flags & kCGEventFlagMaskAlternate) &&
            (flags & kCGEventFlagMaskCommand) &&
            key_code == 40) {
            should_consume = a->input_tap_consumes_events;
            break;
        }
        if ((effective_flags & kCGEventFlagMaskControl) && (effective_flags & kCGEventFlagMaskCommand) &&
            (key_code == 123 || key_code == 124)) {
            should_consume = a->input_tap_consumes_events;
            break;
        }
        tb_receiver_send_input_event(a, "keyUp", 0, 0, 0, 0, 0, 0, 0, 0, 1, key_code);
        should_consume = a->input_tap_consumes_events;
        break;
    }
    case kCGEventFlagsChanged: {
        CGEventFlags flags = CGEventGetFlags(event);
        const CGEventFlags effective_flags = flags & ~kCGEventFlagMaskSecondaryFn;
        should_consume = a->input_tap_consumes_events;
        tb_receiver_sync_modifier_state(a,
                                        (effective_flags & kCGEventFlagMaskCommand) != 0,
                                        (effective_flags & kCGEventFlagMaskShift) != 0,
                                        (effective_flags & kCGEventFlagMaskAlternate) != 0,
                                        (effective_flags & kCGEventFlagMaskControl) != 0,
                                        (effective_flags & kCGEventFlagMaskAlphaShift) != 0);
        break;
    }
    default:
        break;
    }

    return should_consume;
}

/* PWE (1.1.1): the run-loop mode the tap's source lives in: the default mode
 * on its own thread (which runs nothing else), all common modes on the main
 * run loop, as in 1.1.0. */
static CFStringRef tb_receiver_tap_mode(void) {
    return CFRunLoopGetCurrent() == CFRunLoopGetMain() ? kCFRunLoopCommonModes : kCFRunLoopDefaultMode;
}

/* PWE (1.1.1): run `fn` where the tap lives (its thread, else here), and wait.
 * Never with tx_lock held: the tap's callback takes it. */
static void tb_receiver_tap_call(struct app *a, void (*fn)(void *), void *ctx) {
    if (!a->tap_thread && !a->tap_thread_tried) {
        a->tap_thread_tried = 1;
        char on_main[8];
        if (tb_disp_setting("TB_RECEIVER_TAP_ON_MAIN", "TBReceiverTapOnMain", on_main, sizeof(on_main)) &&
            strcmp(on_main, "1") == 0) {
            tb_receiver_input_log("[input] event tap on the main run loop (TB_RECEIVER_TAP_ON_MAIN)");
        } else {
            a->tap_thread = tb_rlthread_start("PWE input tap");
            if (!a->tap_thread) tb_receiver_input_log("[input] no thread for the event tap; it runs on the main run loop");
        }
    }
    if (!a->tap_thread || tb_rlthread_call(a->tap_thread, fn, ctx) != 0) fn(ctx);
}

static void tb_receiver_stop_input_tap_here(void *ctx) {
    struct app *a = (struct app *)ctx;
    if (a->input_tap_source) {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), a->input_tap_source, tb_receiver_tap_mode());
        CFRelease(a->input_tap_source);
        a->input_tap_source = NULL;
    }
    if (a->input_tap) {
        CFMachPortInvalidate(a->input_tap);
        CFRelease(a->input_tap);
        a->input_tap = NULL;
    }
    a->input_tap_consumes_events = 0;
}

static void tb_receiver_stop_input_tap(struct app *a) {
    if (!a || (!a->input_tap && !a->input_tap_source)) return;
    tb_receiver_tap_call(a, tb_receiver_stop_input_tap_here, a);
}

struct tb_receiver_tap_start {
    struct app       *a;
    CGEventTapOptions options;
    CGEventMask       mask;
    int               can_consume;
};

/* On the tap's thread (or the main thread without one): create the tap and
 * attach it to this thread's run loop. */
static void tb_receiver_start_input_tap_here(void *ctx) {
    struct tb_receiver_tap_start *start = (struct tb_receiver_tap_start *)ctx;
    struct app *a = start->a;
    a->input_tap = CGEventTapCreate(
        kCGHIDEventTap,
        kCGHeadInsertEventTap,
        start->options,
        start->mask,
        tb_receiver_input_tap_callback,
        a
    );
    if (!a->input_tap) return;
    a->input_tap_source = CFMachPortCreateRunLoopSource(NULL, a->input_tap, 0);
    if (!a->input_tap_source) {
        tb_receiver_stop_input_tap_here(a);
        return;
    }
    tb_input_rate_reset(&a->tap_rate);
    a->input_tap_consumes_events = start->can_consume;
    CFRunLoopAddSource(CFRunLoopGetCurrent(), a->input_tap_source, tb_receiver_tap_mode());
    CGEventTapEnable(a->input_tap, true);
}

/* listen_only: never keep events from the iMac's own apps (tests). */
static void tb_receiver_start_input_tap(struct app *a, int listen_only) {
    if (!a || a->input_tap) return;

    if (!tb_receiver_input_monitoring_trusted()) {
        return;
    }

    const int can_consume = !listen_only && tb_receiver_accessibility_trusted() ? 1 : 0;
    CGEventTapOptions tap_options = can_consume ? kCGEventTapOptionDefault : kCGEventTapOptionListenOnly;

    CGEventMask mask =
        CGEventMaskBit(kCGEventMouseMoved) |
        CGEventMaskBit(kCGEventLeftMouseDragged) |
        CGEventMaskBit(kCGEventRightMouseDragged) |
        CGEventMaskBit(kCGEventOtherMouseDragged) |
        CGEventMaskBit(kCGEventLeftMouseDown) |
        CGEventMaskBit(kCGEventLeftMouseUp) |
        CGEventMaskBit(kCGEventRightMouseDown) |
        CGEventMaskBit(kCGEventRightMouseUp) |
        CGEventMaskBit(kCGEventOtherMouseDown) |
        CGEventMaskBit(kCGEventOtherMouseUp) |
        CGEventMaskBit(kCGEventScrollWheel) |
        CGEventMaskBit(kCGEventKeyDown) |
        CGEventMaskBit(kCGEventKeyUp) |
        CGEventMaskBit(kCGEventFlagsChanged);

    /* PWE (1.1.1): the window's Space before the first event, not 100 ms later. */
    atomic_store(&a->window_on_active_space, tb_disp_window_on_active_space(a->disp));
    a->last_space_check_ms = now_ms();
    struct tb_receiver_tap_start start = { a, tap_options, mask, can_consume };
    tb_receiver_tap_call(a, tb_receiver_start_input_tap_here, &start);
    if (!a->input_tap) {
        tb_receiver_input_log("[input] global event tap unavailable; will fall back to SDL window input");
        return;
    }
    tb_receiver_input_log("[input] global event tap enabled for receiverMaster mode (consume=%s, %s)",
                          can_consume ? "true" : "false",
                          a->tap_thread ? "own thread" : "main run loop");
}

/* PWE (1.1.1): the first time a Mac hands control to this iMac
 * (receiverMaster) in a launch, ask macOS for what the global event tap needs:
 * Input Monitoring to see keys and the pointer, Accessibility to keep them from
 * the iMac's own apps. macOS shows its own prompt for whichever is missing and
 * lists the receiver in Privacy & Security; the permission watcher (every 5 s,
 * and when the window comes back to the front) picks up a grant and restarts
 * the tap. Once per launch, and only from a session: an idle
 * receiver never prompts. Without this, the receiver appeared in neither list
 * and the person had to add it by hand. */
static void tb_receiver_request_input_permissions_once(struct app *a) {
    if (a->input_permissions_requested) return;
    a->input_permissions_requested = 1;
    const int input_monitoring = tb_receiver_input_monitoring_trusted();
    const int accessibility = tb_receiver_accessibility_trusted();
    if (input_monitoring && accessibility) return;
    tb_receiver_input_log("[input] receiverMaster: asking macOS for %s%s%s",
                          input_monitoring ? "" : "Input Monitoring",
                          !input_monitoring && !accessibility ? " and " : "",
                          accessibility ? "" : "Accessibility");
    if (!input_monitoring) (void)CGRequestListenEventAccess();
    if (!accessibility) {
        const void *keys[] = { kAXTrustedCheckOptionPrompt };
        const void *values[] = { kCFBooleanTrue };
        CFDictionaryRef options = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                                                     &kCFTypeDictionaryValueCallBacks);
        if (options) {
            (void)AXIsProcessTrustedWithOptions(options);
            CFRelease(options);
        }
    }
}

static void tb_receiver_refresh_input_capture(struct app *a) {
    if (!a) return;
    int capture = strcmp(a->input_control_mode, "receiverMaster") == 0 && a->client_fd >= 0;
#if TB_RECEIVER_TEST_HOOKS
    /* Tests only: receiverMaster without taking this Mac's keyboard and mouse. */
    if (capture && getenv("TB_RECEIVER_TEST_NO_INPUT_CAPTURE")) {
        fprintf(stderr, "[test] receiverMaster: input capture left off\n");
        capture = 0;
    }
#endif
#if TB_RECEIVER_TEST_HOOKS
    /* Tests only: the global tap in listen-only mode and nothing else of input
     * capture (the pointer stays, keys reach this Mac's apps), so the smoke can
     * watch the tap forward input without taking the Mac it runs on. */
    if (capture && getenv("TB_RECEIVER_TEST_TAP_LISTEN_ONLY")) {
        tb_receiver_start_input_tap(a, 1);
        tb_receiver_input_log("[test] receiverMaster: listen-only tap %s", a->input_tap ? "on" : "unavailable");
        return;
    }
#endif
    if (capture) {
        tb_receiver_request_input_permissions_once(a);
        const int wants_global_tap = tb_receiver_input_monitoring_trusted() ? 1 : 0;
        const int wants_consume = tb_receiver_accessibility_trusted() ? 1 : 0;
        if (a->input_tap && (!wants_global_tap || a->input_tap_consumes_events != wants_consume)) {
            tb_receiver_stop_input_tap(a);
        }
        tb_receiver_start_input_tap(a, 0);
        tb_disp_set_input_intercept_active(a->disp, 1);
        tb_disp_set_input_capture_active(a->disp, a->input_tap == NULL ? 1 : 0);
        tb_gesture_bridge_set_active(1);
        tb_receiver_input_log("[input] receiverMaster capture path = %s",
                              a->input_tap ? "global-tap" : "sdl-fallback");
    } else {
        tb_receiver_stop_input_tap(a);
        tb_disp_set_input_intercept_active(a->disp, 0);
        tb_disp_set_input_capture_active(a->disp, 0);
        tb_gesture_bridge_set_active(0);
        tb_receiver_input_log("[input] input capture disabled");
    }
}


/* Report Night Shift / True Tone back to the sender when they change, so its
 * menu reflects the panel's real state rather than only what it last asked for. */
static void tb_receiver_send_display_tweaks_if_changed(struct app *a) {
    if (a->client_fd < 0) return;

    const int night = tb_night_shift_supported() ? tb_night_shift_enabled() : 0;
    const int tone  = tb_true_tone_supported() ? tb_true_tone_enabled() : 0;
    if (night == a->reported_night_shift && tone == a->reported_true_tone) return;

    a->reported_night_shift = night;
    a->reported_true_tone = tone;

    char json[192];
    int len = snprintf(json, sizeof(json),
                       "{\"nightShift\":%s,\"trueTone\":%s}",
                       night ? "true" : "false",
                       tone ? "true" : "false");
    if (len <= 0 || (size_t)len >= sizeof(json)) return;

    uint8_t pkt[4 + 1 + sizeof(json)];
    write_be32(pkt, (uint32_t)(1 + len));
    pkt[4] = TB_PKT_DISPLAY_TWEAKS;
    memcpy(pkt + 5, json, (size_t)len);
    (void)tb_receiver_send_packet(a, pkt, 5 + (size_t)len);
}

/* Draw the sender's pointer here, from 0x39 pictures and 0x32 positions, so
 * the video can leave it out. TB_RECEIVER_CURSOR_IMAGE=0 (or the defaults key
 * TBReceiverCursorImage = NO) keeps it in the video. */
static int tb_receiver_draws_pointer(void) {
    char v[8];
    return !(tb_disp_setting("TB_RECEIVER_CURSOR_IMAGE", "TBReceiverCursorImage", v, sizeof(v)) &&
             strcmp(v, "0") == 0);
}

static void send_receiver_info(struct app *a) {
    struct tb_display_info info;
    if (tb_disp_get_info(a->disp, &info) < 0) return;

    struct tb_receiver_profile profile;
    if (tb_receiver_profile_from_dimensions(info.logical_w, info.logical_h,
                                            info.active_w, info.active_h,
                                            &profile) < 0) {
        return;
    }

    char escaped_name[256];
    size_t out = 0;
    for (size_t i = 0; info.name[i] != '\0' && out + 2 < sizeof(escaped_name); i++) {
        unsigned char c = (unsigned char)info.name[i];
        if (c == '"' || c == '\\') {
            escaped_name[out++] = '\\';
            escaped_name[out++] = (char)c;
        } else if (c >= 0x20) {
            escaped_name[out++] = (char)c;
        }
    }
    escaped_name[out] = '\0';

    char json[1024];
    int json_len = snprintf(
        json,
        sizeof(json),
        "{\"receiverName\":\"%s\",\"panelWidth\":%u,\"panelHeight\":%u,"
        "\"modeWidth\":%u,\"modeHeight\":%u,\"refreshRate\":60,"
        "\"hiDPI\":%s,\"captureWidth\":%u,\"captureHeight\":%u,"
        "\"supportsHEVCDecode\":%s,\"supportsRawNV12\":true,\"inputMonitoringTrusted\":%s,\"accessibilityTrusted\":%s,"
        "\"supportsNightShift\":%s,\"supportsTrueTone\":%s,\"cursorImage\":%s,\"receiverVersion\":\"%s\"}",
        escaped_name,
        profile.panel_w,
        profile.panel_h,
        profile.mode_w,
        profile.mode_h,
        profile.hi_dpi ? "true" : "false",
        profile.capture_w,
        profile.capture_h,
        tb_dec_supports_hevc_hwdecode() ? "true" : "false",
        /* PWE (1.1.1): the last answer when there is one (each ask is ~8 ms). */
        (a->last_input_monitoring_trusted >= 0 ? a->last_input_monitoring_trusted
                                               : tb_receiver_input_monitoring_trusted()) ? "true" : "false",
        (a->last_accessibility_trusted >= 0 ? a->last_accessibility_trusted
                                            : tb_receiver_accessibility_trusted()) ? "true" : "false",
        tb_night_shift_supported() ? "true" : "false",
        tb_true_tone_supported() ? "true" : "false",
        tb_receiver_draws_pointer() ? "true" : "false",
        TB_RECEIVER_VERSION);   /* PWE (1.1.1) */
    if (json_len <= 0 || (size_t)json_len >= sizeof(json)) return;

    const size_t packet_len = 4 + 1 + (size_t)json_len;
    uint8_t *pkt = (uint8_t *)calloc(1, packet_len);
    if (!pkt) return;

    write_be32(pkt, (uint32_t)(1 + json_len));
    pkt[4] = TB_PKT_DISPLAY_PROFILE;
    memcpy(pkt + 5, json, (size_t)json_len);

    if (tb_receiver_send_packet(a, pkt, packet_len) == 0) {
        fprintf(stderr,
                "[main] sent display profile: panel=%ux%u mode=%ux%u hidpi=%d name=%s\n",
                profile.panel_w, profile.panel_h, profile.mode_w, profile.mode_h,
                profile.hi_dpi, info.name);
    }
    free(pkt);
}

static void tb_pwe_refresh_notice(struct app *a, uint64_t now);

static void close_client(struct app *a) {
#if TB_RECEIVER_TEST_HOOKS
    if (a->client_fd >= 0) {
        const unsigned long *n = a->pwe_test_counts;
        fprintf(stderr, "[test] session: secure=%d hello=%lu paramSets=%lu frames=%lu decoded=%llu "
                        "cursor=%lu cursorImage=%lu brightness=%lu volume=%lu language=%lu teardown=%lu "
                        "input=%lu clipboard=%lu\n",
                tb_conn_is_secure(&a->conn), n[TB_PKT_HELLO_RECEIVER], n[TB_PKT_PARAM_SETS], n[TB_PKT_FRAME],
                (unsigned long long)(a->frames - a->pwe_test_frames_at_connect), n[TB_PKT_CURSOR],
                n[TB_PKT_CURSOR_IMAGE], n[TB_PKT_BRIGHTNESS], n[TB_PKT_VOLUME], n[TB_PKT_UI_LANGUAGE],
                n[TB_PKT_TEARDOWN], n[TB_PKT_INPUT_EVENT], n[TB_PKT_CLIPBOARD]);
    }
    memset(a->pwe_test_counts, 0, sizeof(a->pwe_test_counts));
#endif
    /* PWE (1.1.1): the tap's thread stops sending before the connection goes. */
    pthread_mutex_lock(&a->tx_lock);
    atomic_store(&a->forwarding, 0);
    pthread_mutex_unlock(&a->tx_lock);
    TB_LOOP_PHASE("session end: close the connection");
    if (a->client_fd >= 0) tb_conn_close(&a->conn, now_ms());   /* PWE: closes the socket, wipes keys */
    a->client_fd = -1;
    a->session_plaintext = 0;
    a->session_active = 0;
    a->close_requested = 0;
    a->have_video_frame = 0;
    snprintf(a->input_control_mode, sizeof(a->input_control_mode), "off");
    TB_LOOP_PHASE("session end: SDL_EnableScreenSaver");
    SDL_EnableScreenSaver();
    TB_LOOP_PHASE("session end: input capture off");
    tb_receiver_refresh_input_capture(a);
    TB_LOOP_PHASE("session end: display back to idle");
    tb_disp_set_connection_state(a->disp, 0);
    tb_disp_set_cursor(a->disp, 0, 0, 1, 1, 0, 0, 0);
    tb_disp_set_cursor_image(a->disp, NULL);
    tb_refresh_idle_localized_strings(a);
    TB_LOOP_PHASE("session end: clipboard idle");
    a->clipboard_polling = 0;
    tb_clipboard_set_polling(a->clipboard, 0);
    tb_clipboard_new_session(a->clipboard);
    TB_LOOP_PHASE("session end: decoder reset");
    tb_dec_reset(a->dec);   /* fresh decoder for next session */
    tb_receiver_skip_waiting_frame(a);   /* PWE (1.1.1): normally none by now */
    tb_catchup_reset(&a->catchup);
    TB_LOOP_PHASE("session end: sound idle");
    tb_audio_out_idle(a->audio);   /* the audio thread closes the device later */
    TB_LOOP_PHASE("session end: idle notice");
    tb_pwe_refresh_notice(a, now_ms());
    fprintf(stderr, "[main] client disconnected\n");
}

/* ---- PWE: pairing and encrypted sessions -------------------------------- */

#define TB_PWE_PAIRED_NOTICE_MS   3000
#define TB_PWE_REFUSED_NOTICE_MS  8000
#define TB_PWE_FORGOT_NOTICE_MS   4000

/* A short message by language key; `name` fills %{name}, or NULL. The words are
 * looked up each time the notice is drawn: the Mac's language can arrive just
 * after pairing, and L changes it while a message is up. */
static void tb_pwe_message(struct app *a, enum tb_display_notice kind, const char *key, const char *name,
                           uint64_t for_ms) {
    a->pwe_message_kind = kind;
    snprintf(a->pwe_message_key, sizeof(a->pwe_message_key), "%s", key);
    snprintf(a->pwe_message_name, sizeof(a->pwe_message_name), "%s", name ? name : "");
    a->pwe_message_until_ms = now_ms() + for_ms;
}

/* What the idle screen says about pairing: the code while one is shown, a
 * short message, the unencrypted warning, or why encryption is unavailable. */
static void tb_pwe_refresh_notice(struct app *a, uint64_t now) {
    char line1[192] = "", line2[192] = "", line3[192] = "";
    char status[192] = "";   /* the details screen's status line, when not line1 */
    enum tb_display_notice kind = TB_DISP_NOTICE_NONE;
    if (a->gate.code[0]) {
        /* The screen shows the digits alone, in two groups of three with an en
         * space between (U+2002); the next line says what they are. The details
         * screen's status line names them ("Pairing code 482 913"). */
        snprintf(line1, sizeof(line1), "%.3s\xE2\x80\x82%.3s", a->gate.code, a->gate.code + 3);
        struct tb_i18n_pair pairs[] = { { "code", line1 } };
        tb_format_i18n(status, sizeof(status), "receiver.pairing.code", pairs, 1);
        tb_copy_i18n(line2, sizeof(line2), "receiver.pairing.enter_on_mac");
        tb_copy_i18n(line3, sizeof(line3), "receiver.pairing.not_you");
        kind = TB_DISP_NOTICE_PAIRING_CODE;
    } else if (a->pwe_message_key[0] && now < a->pwe_message_until_ms) {
        struct tb_i18n_pair pairs[] = { { "name", a->pwe_message_name } };
        tb_format_i18n(line1, sizeof(line1), a->pwe_message_key, pairs, 1);
        kind = a->pwe_message_kind;
    } else if (a->client_fd >= 0 && a->session_plaintext) {
        tb_copy_i18n(line1, sizeof(line1), "receiver.pairing.unencrypted");
        tb_copy_i18n(line2, sizeof(line2), "receiver.pairing.unencrypted_hint");
        kind = TB_DISP_NOTICE_WARNING;
    } else if (!a->have_keys) {
        tb_copy_i18n(line1, sizeof(line1), "receiver.pairing.keychain");
        kind = TB_DISP_NOTICE_ERROR;
    }
    tb_disp_set_notice(a->disp, kind, line1, line2, line3);
    /* The menu follows the receiver's language. */
    static char menu_language[16];
    const char *language = tb_i18n_current_language();
    if (language && strcmp(menu_language, language) != 0) {
        snprintf(menu_language, sizeof(menu_language), "%s", language);
        tb_pairing_menu_update(tb_i18n_get("receiver.menu.allow_unencrypted"), a->allow_plaintext,
                               tb_i18n_get("receiver.menu.forget_all"));
    }
    /* The details screen shows the status line: the notice goes there too. */
    if (!a->session_active) {
        if (kind != TB_DISP_NOTICE_NONE) {
            snprintf(a->status_text, sizeof(a->status_text), "%s", status[0] ? status : line1);
            a->pwe_status_overridden = 1;
        } else if (a->pwe_status_overridden) {
            a->pwe_status_overridden = 0;
            tb_copy_i18n(a->status_text, sizeof(a->status_text), "receiver.status.waiting_for_sender");
        }
    }
}

static void tb_pwe_on_conn_event(struct tb_conn *c, int ev, void *ud) {
    struct app *a = (struct app *)ud;
    /* That a code is on screen, never the code: the log is a file (tb_log.h). */
    if (ev & PWE_SEC_EV_WRONG_CODE) fprintf(stderr, "[sec] the Mac sent a wrong pairing code\n");
    if (ev & PWE_SEC_EV_SHOW_CODE) fprintf(stderr, "[sec] pairing code shown on screen\n");
    if (ev & PWE_SEC_EV_HIDE_CODE) fprintf(stderr, "[sec] pairing code hidden\n");
    if (ev & TB_CONN_EV_READY) {
        a->session_plaintext = (ev & TB_CONN_EV_PLAINTEXT) != 0;
        fprintf(stderr, "[sec] session ready (%s)\n", a->session_plaintext ? "unencrypted" : "encrypted");
        send_receiver_info(a);
    }
    if (ev & PWE_SEC_EV_PAIRED) {
        tb_pwe_message(a, TB_DISP_NOTICE_INFO, "receiver.pairing.paired", pwe_sec_peer_name(c->sec),
                       TB_PWE_PAIRED_NOTICE_MS);
    }
    if (ev & PWE_SEC_EV_LOCKED) {
        tb_pwe_message(a, TB_DISP_NOTICE_WARNING, "receiver.pairing.locked", NULL, PWE_SEC_LOCK_MS);
    }
    /* PWE: the log says when a code is on screen (never the code itself). */
    if ((ev & PWE_SEC_EV_WRONG_CODE) && !(ev & PWE_SEC_EV_LOCKED)) {
        fprintf(stderr, "[sec] wrong pairing code (%d in a row)\n", a->gate.failures);
    }
    if ((ev & PWE_SEC_EV_SHOW_CODE) && a->gate.code[0]) {
        uint64_t t = now_ms();
        int left = a->gate.code_expires_ms > t ? (int)((a->gate.code_expires_ms - t) / 1000) : 0;
        fprintf(stderr, "[sec] showing a pairing code (%d s left)\n", left);
    } else if ((ev & PWE_SEC_EV_HIDE_CODE) && !a->gate.code[0]) {
        fprintf(stderr, "[sec] pairing code hidden\n");
    }
    if (ev & TB_CONN_EV_PLAINTEXT_REFUSED) {
        tb_pwe_message(a, TB_DISP_NOTICE_ERROR, "receiver.pairing.refused_unencrypted", NULL,
                       TB_PWE_REFUSED_NOTICE_MS);
    }
#if TB_RECEIVER_TEST_HOOKS
    /* Tests read the code the screen shows from this file. */
    const char *code_file = getenv("TB_RECEIVER_TEST_CODE_FILE");
    if ((ev & PWE_SEC_EV_SHOW_CODE) && code_file && a->gate.code[0]) {
        FILE *f = fopen(code_file, "w");
        if (f) { fprintf(f, "%s\n", a->gate.code); fclose(f); }
    }
#endif
    tb_pwe_refresh_notice(a, now_ms());
}

/* PWE: accept one waiting connection and decide from its link alone, before
 * any byte reaches the parser. Pairing only over the cable, and loopback is
 * not the cable. -1 when nothing was waiting or the link is refused (closed). */
static int tb_pwe_accept_checked(struct app *a, int listener, int is_ipv6, char *ifname, size_t ifname_size,
                                 struct tb_accept_policy *policy, enum tb_link_kind *link_out) {
    struct tb_accept_policy none = { 0, 0, 0 };
    *policy = none;
    *link_out = TB_LINK_NETWORK;
    if (ifname_size) ifname[0] = '\0';
    int c = tb_net_accept(listener);
    if (c < 0) return -1;
    int direct = tb_net_client_is_direct_link(c, ifname, ifname_size);
    enum tb_link_kind link = tb_net_link_kind(ifname, direct);
#if TB_RECEIVER_TEST_HOOKS
    if (getenv("TB_RECEIVER_TEST_LOOPBACK_IS_CABLE") && link == TB_LINK_LOOPBACK) link = TB_LINK_CABLE;
#endif
    *policy = tb_net_accept_policy_family(link, is_ipv6, tb_pwe_network_allowed(a), a->allow_plaintext);
    *link_out = link;
    if (!policy->accept) {
        tb_pwe_log_refused(ifname, is_ipv6);
        close(c);
        return -1;
    }
    return c;
}

/* PWE: make an accepted connection the session. */
static void tb_pwe_adopt_client(struct app *a, int c, const char *ifname, int is_ipv6,
                                struct tb_accept_policy policy, uint64_t t) {
    a->client_fd = c;
    a->have_video_frame = 0;
    a->session_active = 0;
    a->reported_night_shift = -1;   /* force one report per session */
    a->reported_true_tone = -1;
    a->last_recv_ms = t;
    SDL_DisableScreenSaver();
    struct tb_conn_config conn_cfg = {
        a->have_keys ? &a->identity : NULL, &a->store, &a->gate, policy.pairing, policy.plaintext
    };
    tb_conn_init(&a->conn, c, &conn_cfg, on_packet, tb_pwe_on_conn_event, a);
    a->session_plaintext = 0;
    a->pwe_test_frames_at_connect = a->frames;
    fprintf(stderr, "[main] client connected (%s%s%s)\n", ifname[0] ? ifname : "?",
            is_ipv6 ? ", IPv6" : "",
            policy.pairing ? ", cable" : (policy.plaintext ? "" : ", encrypted only"));
    tb_receiver_refresh_input_capture(a);
    /* The display profile goes out once the connection is secure (or
     * accepted unencrypted): tb_pwe_on_conn_event, TB_CONN_EV_READY. */
}

/* PWE (T47): give up the held connection, if any (a newer one replaces it). */
static void tb_pwe_drop_held(struct app *a) {
    if (a->held_fd < 0) return;
    close(a->held_fd);
    a->held_fd = -1;
}

/* PWE (T47): a held cable connection becomes the session. Its policy is
 * decided now, not when it arrived: "Allow unencrypted connections" may have
 * been turned off while it waited. */
static void tb_pwe_adopt_held(struct app *a) {
    const int c = a->held_fd;
    a->held_fd = -1;
    const struct tb_accept_policy policy =
        tb_net_accept_policy_family(TB_LINK_CABLE, a->held_ipv6, tb_pwe_network_allowed(a), a->allow_plaintext);
    if (!policy.accept) {
        close(c);
        return;
    }
    tb_pwe_adopt_client(a, c, a->held_ifname, a->held_ipv6, policy, now_ms());
}

/* PWE (T47): a cable connection held while a session is in place. Rate-limited:
 * a second Mac on another port redials every few seconds for as long as the
 * session lasts. */
static void tb_pwe_log_held(const char *ifname, int ipv6, int pairing) {
    static uint64_t last_ms;
    static unsigned long quiet;
    const uint64_t t = now_ms();
    if (last_ms && t - last_ms < 10000) { quiet++; return; }
    fprintf(stderr, "[main] cable connection on %s%s held: the session in place is %s",
            ifname && *ifname ? ifname : "?", ipv6 ? " (IPv6)" : "", pairing ? "pairing" : "live");
    if (quiet) fprintf(stderr, "; %lu more since the last report", quiet);
    fputc('\n', stderr);
    last_ms = t;
    quiet = 0;
}

/* PWE (T47): connections closed because a session is in place. Rate-limited
 * like tb_pwe_log_refused: anyone on the network can send them. */
static void tb_pwe_log_busy(const char *ifname, int ipv6) {
    static uint64_t last_ms;
    static unsigned long quiet;
    const uint64_t t = now_ms();
    if (last_ms && t - last_ms < 10000) { quiet++; return; }
    fprintf(stderr, "[main] new connection on %s%s closed: a session is in place, "
                    "and only a cable connection replaces a silent one",
            ifname && *ifname ? ifname : "?", ipv6 ? " (IPv6)" : "");
    if (quiet) fprintf(stderr, "; %lu more since the last report", quiet);
    fputc('\n', stderr);
    last_ms = t;
    quiet = 0;
}

/* PWE (T45, T47): new connections while a session is in place. Every waiting
 * one is accepted and decided from its link at once (net.h,
 * tb_net_offer_during_session): off the cable it is closed; over the cable it
 * replaces a silent session (the cable was pulled and plugged back before the
 * 10 s idle timeout), or waits, held, until the session may be replaced. */
static void tb_pwe_screen_new_connections(struct app *a) {
    const uint64_t now = now_ms();
    const uint64_t silent = now > a->last_recv_ms ? now - a->last_recv_ms : 0;
    const int pairing = a->gate.code[0] && tb_conn_is_pairing(&a->conn);

    if (a->held_fd >= 0) {
        if (tb_net_session_replaceable(silent, pairing)) {
            fprintf(stderr, "[main] the Mac dialled again over the cable (%s%s) after %llu ms of silence "
                            "from this session; closing the stale session\n",
                    a->held_ifname[0] ? a->held_ifname : "?", a->held_ipv6 ? ", IPv6" : "",
                    (unsigned long long)silent);
            close_client(a);
            tb_pwe_adopt_held(a);
            return;
        }
    }

    const int listeners[2] = { a->server_fd, a->server6_fd };
    for (int which = 0; which < 2; which++) {
        if (listeners[which] < 0) continue;
        const int is_ipv6 = which == 1;
        /* A few per pass: a burst is cleared quickly, a flood cannot hold the loop. */
        for (int n = 0; n < 8; n++) {
            /* Only accept() when a connection is waiting: a look costs nothing. */
            struct pollfd pfd = { listeners[which], POLLIN, 0 };
            if (poll(&pfd, 1, 0) <= 0 || !(pfd.revents & POLLIN)) break;
            char ifname[IFNAMSIZ] = "";
            struct tb_accept_policy policy;
            enum tb_link_kind link;
            int c = tb_pwe_accept_checked(a, listeners[which], is_ipv6, ifname, sizeof(ifname), &policy, &link);
            if (c < 0) continue;   /* none after all, or refused by its link and closed */
            switch (tb_net_offer_during_session(silent, pairing, link, policy.accept)) {
            case TB_OFFER_REPLACE:
                fprintf(stderr, "[main] the Mac dialled again over the cable (%s%s) after %llu ms of silence "
                                "from this session; closing the stale session\n",
                        ifname[0] ? ifname : "?", is_ipv6 ? ", IPv6" : "", (unsigned long long)silent);
                tb_pwe_drop_held(a);
                close_client(a);
                tb_pwe_adopt_client(a, c, ifname, is_ipv6, policy, now_ms());
                return;
            case TB_OFFER_HOLD:
                tb_pwe_drop_held(a);
                a->held_fd = c;
                a->held_ipv6 = is_ipv6;
                snprintf(a->held_ifname, sizeof(a->held_ifname), "%s", ifname);
                tb_pwe_log_held(ifname, is_ipv6, pairing);
                break;
            case TB_OFFER_CLOSE:
            default:
                tb_pwe_log_busy(ifname, is_ipv6);
                close(c);
                break;
            }
        }
    }
}

static void tb_pwe_refresh_menu(struct app *a) {
    tb_pairing_menu_update(tb_i18n_get("receiver.menu.allow_unencrypted"), a->allow_plaintext,
                           tb_i18n_get("receiver.menu.forget_all"));
}

static void tb_pwe_toggle_unencrypted(void *ctx) {
    struct app *a = (struct app *)ctx;
    a->allow_plaintext = !a->allow_plaintext;
    tb_pwe_set_pref_bool(a->app_id, CFSTR("AllowUnencryptedConnections"), a->allow_plaintext);
    fprintf(stderr, "[sec] unencrypted connections %s\n", a->allow_plaintext ? "allowed" : "turned off");
    tb_pwe_refresh_menu(a);
    /* Turning it off ends an unencrypted session at once. */
    if (!a->allow_plaintext && a->client_fd >= 0 && a->session_plaintext) close_client(a);
}

static void tb_pwe_forget_all(void *ctx) {
    struct app *a = (struct app *)ctx;
    if (!tb_pairing_menu_confirm(tb_i18n_get("receiver.menu.forget_all_confirm"),
                                 tb_i18n_get("receiver.menu.forget"), tb_i18n_get("receiver.menu.cancel"))) return;
    if (pwe_keystore_forget_all_peers(&a->keystore) == 0) {
        fprintf(stderr, "[sec] forgot all paired Macs\n");
        tb_pwe_message(a, TB_DISP_NOTICE_INFO, "receiver.pairing.forgot_all", NULL, TB_PWE_FORGOT_NOTICE_MS);
        tb_pwe_refresh_notice(a, now_ms());
    }
}

/* This receiver's pairing key and the Macs it paired with, in the login keychain. */
static void tb_pwe_load_keys(struct app *a) {
    char service[192] = "";
    if (!a->app_id || !CFStringGetCString(a->app_id, service, sizeof(service) - 16, kCFStringEncodingUTF8)) {
        snprintf(service, sizeof(service), "%s", "receiver");
    }
    strncat(service, ".pairing", sizeof(service) - strlen(service) - 1);
#if TB_RECEIVER_TEST_HOOKS
    const char *test_service = getenv("TB_RECEIVER_TEST_KEYCHAIN_SERVICE");
    if (test_service && *test_service) snprintf(service, sizeof(service), "%s", test_service);
#endif
    pwe_keystore_init(&a->keystore, service, PWE_SEC_MAX_PEERS);
    pwe_keystore_as_store(&a->keystore, &a->store);

    char name[PWE_SEC_NAME_MAX + 1] = "";
    CFStringRef computer = SCDynamicStoreCopyComputerName(NULL, NULL);
    if (!computer || !CFStringGetCString(computer, name, sizeof(name), kCFStringEncodingUTF8)) {
        if (gethostname(name, sizeof(name)) != 0) snprintf(name, sizeof(name), "%s", "iMac");
    }
    if (computer) CFRelease(computer);

    a->have_keys = pwe_sec_global_init() == 0 && pwe_keystore_load_identity(&a->keystore, name, &a->identity) == 0;
    if (a->have_keys) {
        char hex[2 * PWE_SEC_ID_BYTES + 1];
        pwe_sec_id_hex(a->identity.id, hex);
        fprintf(stderr, "[sec] pairing key ready (%.8s)\n", hex);
    } else {
        fprintf(stderr, "[sec] keychain unavailable (%d): encrypted connections refused\n", a->keystore.last_status);
    }
    a->allow_plaintext = tb_pwe_pref_bool(a->app_id, CFSTR("AllowUnencryptedConnections"), 1);
#if TB_RECEIVER_TEST_HOOKS
    const char *test_plain = getenv("TB_RECEIVER_TEST_ALLOW_UNENCRYPTED");
    if (test_plain) a->allow_plaintext = strcmp(test_plain, "0") != 0;
#endif
}

/* Build the display string for the host/IP line of the status screen.
 * have_ip: non-zero if ip_fallback is a real IP, zero if no IP is available.
 * Called once at startup (and when the IP changes) to cache the result in
 * a.display_host — do NOT call gethostname() in the render loop. */
static void build_display_host(char *buf, size_t bufsz, const char *ip_fallback, int have_ip) {
    if (!buf || bufsz == 0) return;
    char host[96] = {0};
    if (gethostname(host, sizeof(host)) == 0 && host[0] != '\0' && strcmp(host, "localhost") != 0) {
        char short_host[96] = {0};
        size_t i = 0;
        for (; host[i] != '\0' && host[i] != '.' && i + 1 < sizeof(short_host); i++) {
            short_host[i] = host[i];
        }
        short_host[i] = '\0';
        if (short_host[0] != '\0') {
            if (have_ip && ip_fallback && ip_fallback[0] != '\0') {
                snprintf(buf, bufsz, "%s (%s)", short_host, ip_fallback);
            } else {
                snprintf(buf, bufsz, "%s", short_host);
            }
            return;
        }
    }
    snprintf(buf, bufsz, "%s", (have_ip && ip_fallback && ip_fallback[0] != '\0')
             ? ip_fallback : tb_i18n_get("receiver.network.not_detected"));
}

/* ---- Main ------------------------------------------------------------ */

/* PWE (1.1.1): a receiver that cannot start says so. Opened from Finder or at
 * login it has no terminal, and before this it simply vanished. The message
 * gives the reason, the system's own words for it when there are any, and
 * where the log is. SDL_ShowSimpleMessageBox may be called before SDL_Init,
 * so this works even when the display itself could not be opened. */
static void tb_receiver_fatal(const char *reason_key, const char *detail) {
    char title[160], body[1024];
    snprintf(title, sizeof(title), "%s", tb_i18n_get("receiver.fatal.title"));
    size_t n = (size_t)snprintf(body, sizeof(body), "%s", tb_i18n_get(reason_key));
    if (detail && *detail && n < sizeof(body)) {
        n += (size_t)snprintf(body + n, sizeof(body) - n, "\n\n(%s)", detail);
    }
    const char *log_path = tb_log_path();
    if (log_path && n < sizeof(body)) {
        (void)snprintf(body + n, sizeof(body) - n, "\n\n%s\n%s", tb_i18n_get("receiver.fatal.log"), log_path);
    }
    fprintf(stderr, "[main] cannot start (%s)%s%s\n", reason_key, detail && *detail ? ": " : "",
            detail ? detail : "");
    SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, title, body, NULL);
    fprintf(stderr, "[main] bye (could not start)\n");
}

int main(int argc, char **argv) {
    int fullscreen = 1;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--permission-status") == 0) {
            printf(
                "TB_PERMISSION_STATUS:screen_recording=0:accessibility=%d:input_monitoring=%d\n",
                tb_receiver_accessibility_trusted(),
                tb_receiver_input_monitoring_trusted()
            );
            return 0;
        }
        if (strcmp(argv[i], "--windowed") == 0) fullscreen = 0;
    }

    /* PWE (1.1.1): whether the previous run ended without "[main] bye" (a
     * crash, a force quit, a power cut). Read before this run appends to the
     * file; said once this copy has its port, so a second copy, whose log
     * ends with the running receiver's latest line, never says it. */
    char previous_last_line[160] = "";
    int previous_run_unclean = 0;
    /* PWE: the log file, also when opened from Finder or at login (tb_log.h),
     * and the facts a remote tester's log needs (nothing personal). Each file
     * a rotation starts opens with the same facts (1.1.1). */
    {
        char sys[192];
        tb_sysinfo_describe(sys, sizeof(sys));
        char header[320];
        snprintf(header, sizeof(header), "receiver %s (%s), pid %d; %s",
                 TB_RECEIVER_VERSION, TB_RECEIVER_BUILD, (int)getpid(), sys);
        tb_log_set_header(header);
        char log_dir[PATH_MAX];
        if (tb_log_default_dir("TargetBridge Receiver", log_dir, sizeof(log_dir)) &&
            tb_log_read_last_line(log_dir, previous_last_line, sizeof(previous_last_line)) &&
            !tb_log_line_is_clean_exit(previous_last_line)) {
            previous_run_unclean = 1;
        }
        if (log_dir[0] && tb_log_start(log_dir, TB_LOG_MAX_BYTES) == 0) {
            fprintf(stderr, "[log] receiver %s (%s) started, pid %d\n",
                    TB_RECEIVER_VERSION, TB_RECEIVER_BUILD, (int)getpid());
        }
        fprintf(stderr, "[sys] %s\n", sys);
    }

    char startup_language_pref[8];
    tb_receiver_load_language_preference(startup_language_pref, sizeof(startup_language_pref));
    if (strcmp(startup_language_pref, "auto") != 0) {
        tb_i18n_set_runtime_language(startup_language_pref);
    }
    (void)tb_i18n_init();

    signal(SIGINT,  on_sigint);
    signal(SIGTERM, on_sigint);
    signal(SIGHUP,  on_sigint);   /* PWE (1.1.1): a closed Terminal ends it cleanly too */
    signal(SIGPIPE, SIG_IGN);

    char tb_ip[64] = {0};
    char usb_ip[64] = {0};
    char net_ip[64] = {0};
    char ethernet_ip[64] = {0};
    char wifi_ip[64] = {0};
    if (tb_net_get_tb_ip(tb_ip, sizeof(tb_ip)) == 0) {
        printf("TBReceiver: Thunderbolt Bridge IP = %s\n", tb_ip);
    } else {
        printf("TBReceiver: warning, no bridge IP detected (169.254.x.x)\n");
    }
    char tb_ip6[64] = {0};
    unsigned int tb_ip6_if = 0;
    if (tb_net_get_tb_ip6(tb_ip6, sizeof(tb_ip6), &tb_ip6_if) == 0) {
        printf("TBReceiver: Thunderbolt Bridge IPv6 = %s\n", tb_ip6);
    }
    if (tb_net_get_link_local_ip(usb_ip, sizeof(usb_ip)) == 0) {
        printf("TBReceiver: Direct USB-NCM IP = %s\n", usb_ip);
    } else {
        printf("TBReceiver: warning, no direct USB-NCM/link-local IP detected\n");
    }
    if (tb_net_get_lan_ip(net_ip, sizeof(net_ip)) == 0) {
        printf("TBReceiver: Local network IP = %s\n", net_ip);
    } else {
        printf("TBReceiver: warning, no LAN IP detected (RFC1918 IPv4)\n");
    }
    if (tb_net_get_ethernet_ip(ethernet_ip, sizeof(ethernet_ip)) == 0) {
        printf("TBReceiver: Ethernet IP = %s\n", ethernet_ip);
    }
    if (tb_net_get_wifi_ip(wifi_ip, sizeof(wifi_ip)) == 0) {
        printf("TBReceiver: Wi-Fi IP = %s\n", wifi_ip);
    }
    printf("TBReceiver: listening on TCP port %d\n", TB_PORT);

    struct app a;
    memset(&a, 0, sizeof(a));
    a.server_fd = -1;
    a.server6_fd = -1;
    a.client_fd = -1;
    a.held_fd = -1;
    a.app_id = CFSTR("com.targetbridge.receiver");
    fprintf(stderr, "[net] senders accepted over %s\n",
            tb_pwe_network_allowed(&a)
                ? "every interface (off the cable: paired, encrypted sessions only)"
                : "direct links only (Thunderbolt Bridge, USB, loopback)");
    {
        /* PWE: what counts as the Thunderbolt Bridge on this Mac (net.c). */
        char bridges_described[256];
        fprintf(stderr, "[net] cable bridges: %s\n",
                tb_net_describe_cable_bridges(bridges_described, sizeof(bridges_described)) ? bridges_described
                    : "none (no bridge in the network settings)");
    }
    if (tb_receiver_load_or_create_id(a.receiver_id, sizeof(a.receiver_id), a.app_id) == 0) {
        fprintf(stderr, "[identity] receiver ID ready\n");
    } else {
        fprintf(stderr, "[identity] unable to persist receiver ID; using Bonjour name fallback\n");
    }
    {
        char host[96] = {0};
        if (gethostname(host, sizeof(host)) != 0 || host[0] == '\0') {
            snprintf(host, sizeof(host), "%s", "Receiver");
        }
        snprintf(a.bonjour_name, sizeof(a.bonjour_name), "TargetBridge %s", host);
    }
    snprintf(a.tb_ip_text, sizeof(a.tb_ip_text), "%s", tb_ip);
    snprintf(a.usb_ip_text, sizeof(a.usb_ip_text), "%s", usb_ip);
    snprintf(a.net_ip_text, sizeof(a.net_ip_text), "%s", net_ip);
    snprintf(a.ethernet_ip_text, sizeof(a.ethernet_ip_text), "%s", ethernet_ip);
    snprintf(a.wifi_ip_text, sizeof(a.wifi_ip_text), "%s", wifi_ip);
    snprintf(a.tb_ip6_text, sizeof(a.tb_ip6_text), "%s", tb_ip6);
    a.tb_ip6_if = tb_ip6_if;
    snprintf(a.ip_text, sizeof(a.ip_text), "%s",
             tb_ip[0] ? tb_ip
                      : (usb_ip[0] ? usb_ip
                                   : (net_ip[0] ? net_ip : tb_i18n_get("receiver.network.not_detected"))));
    snprintf(a.language_pref, sizeof(a.language_pref), "%s", startup_language_pref);
    snprintf(a.input_control_mode, sizeof(a.input_control_mode), "%s", "off");
    a.last_input_monitoring_trusted = -1;
    a.last_accessibility_trusted = -1;
    {
        /* PWE (1.1.1): see struct app. */
        pthread_mutexattr_t attr;
        pthread_mutexattr_init(&attr);
        pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(&a.tx_lock, &attr);
        pthread_mutexattr_destroy(&attr);
        atomic_init(&a.forwarding, 0);
        atomic_init(&a.window_on_active_space, 1);
        atomic_init(&a.tap_switched_off, 0);
    }
    tb_refresh_idle_localized_strings(&a);
    build_display_host(a.display_host, sizeof(a.display_host), a.ip_text,
                       tb_ip[0] || usb_ip[0] || net_ip[0]);
    tb_receiver_apply_language_preference(&a);
    tb_gesture_bridge_install(tb_receiver_space_switch_callback, &a);
    tb_gesture_bridge_set_active(0);

    /* PWE (1.1.1): the listeners first: a second copy finds the port taken
     * before it opens a window or starts a thread. */
    /* Tests only: another port, so a sender running on the same Mac that
     * remembers this Mac's address cannot take the single client slot. */
    uint16_t listen_port = TB_PORT;
#if TB_RECEIVER_TEST_HOOKS
    {
        const char *p = getenv("TB_RECEIVER_TEST_PORT");
        long v = p ? strtol(p, NULL, 10) : 0;
        if (v > 1024 && v < 65536) listen_port = (uint16_t)v;
    }
#endif
    a.server_fd = tb_net_listen(listen_port);
    if (a.server_fd < 0) {
        if (errno == EADDRINUSE) {
            /* PWE (1.1.1): another receiver holds the port. Say so, bring the
             * running copy to the front and leave quietly: this is the second
             * copy, not a failure. Listening comes before the window and the
             * worker threads, so there is nothing to tear down and no second
             * window flashes. */
            fprintf(stderr, "[net] port %u is in use: another receiver is running; leaving\n",
                    (unsigned)listen_port);
            SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_INFORMATION,
                                     tb_i18n_get("receiver.already_running.title"),
                                     tb_i18n_get("receiver.already_running.body"), NULL);
            char bundle_id[128] = "";
            CFStringGetCString(a.app_id, bundle_id, sizeof(bundle_id), kCFStringEncodingUTF8);
            if (tb_running_app_activate(bundle_id)) {
                fprintf(stderr, "[main] brought the running receiver to the front\n");
            } else {
                fprintf(stderr, "[main] no other receiver found: another program holds the port\n");
            }
            fprintf(stderr, "[main] bye (another receiver is running)\n");
            return 0;
        }
        const int listen_errno = errno;
        fprintf(stderr, "tb_net_listen failed\n");
        char reason[96];
        snprintf(reason, sizeof(reason), "port %u: %s", (unsigned)listen_port, strerror(listen_errno));
        tb_receiver_fatal("receiver.fatal.network", reason);
        return 1;
    }
    /* PWE (T34): IPv6 too, for the Thunderbolt Bridge's link-local address. */
    a.server6_fd = tb_net_listen6(listen_port);
    fprintf(stderr, "[net] listening on port %u over IPv4%s\n", (unsigned)listen_port,
            a.server6_fd >= 0 ? " and IPv6" : " only (no IPv6 listener)");
    if (previous_run_unclean) {
        fprintf(stderr, "[main] the previous run did not end normally (its last line: \"%s\"); "
                        "if it crashed, the report is in ~/Library/DiagnosticReports\n", previous_last_line);
    }

    a.disp = tb_disp_create(fullscreen);
    if (!a.disp) {
        fprintf(stderr, "tb_disp_create failed\n");
        tb_receiver_fatal("receiver.fatal.display", SDL_GetError());
        return 1;
    }
    /* PWE: pairing keys, and the menu items for unencrypted connections and forgetting. */
    tb_pwe_load_keys(&a);
    tb_pairing_menu_install(tb_pwe_toggle_unencrypted, tb_pwe_forget_all, &a);
    tb_pwe_refresh_menu(&a);
    tb_pwe_refresh_notice(&a, now_ms());
    tb_receiver_refresh_login_item(&a);
    /* The login offer is a modal dialog: show it over a drawn idle screen,
     * after the port is listening, never during a session. */
    int login_offer_pending = TB_RECEIVER_OFFER_LOGIN_ITEM;

    /* SDL starts with screen-saver inhibition enabled. A Receiver that has not
     * accepted a client yet never reaches close_client(), so release the
     * assertion immediately while it is waiting for its first session. */
    SDL_EnableScreenSaver();
    fprintf(stderr, "[main] display sleep enabled while receiver is idle\n");

    struct tb_display_info boot_info;
    if (tb_disp_get_info(a.disp, &boot_info) == 0) {
        snprintf(a.panel_text, sizeof(a.panel_text), "%u x %u px (%s)",
                 boot_info.active_w, boot_info.active_h, boot_info.name);
    } else {
        tb_copy_i18n(a.panel_text, sizeof(a.panel_text), "receiver.panel.default");
    }
    /* After SDL_Init (tb_disp_create): the audio thread opens SDL devices. */
    a.audio = tb_audio_out_create();
    if (!a.audio) fprintf(stderr, "[audio] warning: no audio thread; the session's sound is dropped\n");
    {
        /* PWE (T40): the clipboard thread. Test builds never use the system
         * clipboard: a pasteboard named by TB_RECEIVER_TEST_PASTEBOARD, or a
         * private one. */
        const char *pasteboard = NULL;
#if TB_RECEIVER_TEST_HOOKS
        pasteboard = getenv("TB_RECEIVER_TEST_PASTEBOARD");
        if (!pasteboard) pasteboard = "";
        fprintf(stderr, "[test] clipboard: %s pasteboard\n", *pasteboard ? pasteboard : "a private");
#endif
        a.clipboard = tb_clipboard_create(pasteboard);
        if (!a.clipboard) fprintf(stderr, "[clipboard] warning: no clipboard thread; the clipboard is not shared\n");
    }
    a.dec = tb_dec_create(on_frame, &a);
    if (!a.dec) {
        fprintf(stderr, "tb_dec_create failed\n");
        tb_receiver_fatal("receiver.fatal.decoder", NULL);
        tb_disp_destroy(a.disp);
        return 1;
    }

    /* PWE (1.1.1, A8): permissions asked off the main loop. */
    a.permwatch = tb_permwatch_start(tb_receiver_check_permissions, TB_PERMWATCH_INTERVAL_MS,
                                     TB_PERMWATCH_MIN_GAP_MS);
    if (!a.permwatch) fprintf(stderr, "[input] no permission thread; permissions are asked on the main loop\n");

    /* Announce only once both listeners are up (PWE). */
    bonjour_update(&a, TB_PORT);

    a.last_fps_tick_ms = now_ms();
    a.last_ip_check_ms = 0;

    /* PWE (T40): name any call that holds up this loop for more than 2 s.
     * Off with TB_RECEIVER_LOOPWATCH=0 or
     *   defaults write <receiver bundle id> MainLoopWatchdog -bool false */
    {
        char setting[8];
        const int off = tb_disp_setting("TB_RECEIVER_LOOPWATCH", "MainLoopWatchdog", setting, sizeof(setting)) &&
                        strcmp(setting, "0") == 0;
        if (off) fprintf(stderr, "[watchdog] main-loop watchdog off (MainLoopWatchdog)\n");
        else if (tb_loopwatch_start() == 0) fprintf(stderr, "[watchdog] watching the main loop\n");
        else fprintf(stderr, "[watchdog] main-loop watchdog could not start\n");
    }

    while (!g_term) {
        tb_loopwatch_iteration();
        TB_LOOP_PHASE("window events (SDL_PollEvent)");
        unsigned int disp_actions = tb_disp_poll_actions(a.disp);
        int socket_activity = 0;
        TB_LOOP_PHASE("run loop sources (CFRunLoopRunInMode)");
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0, true);
        if (disp_actions & TB_DISP_ACTION_QUIT) break;
        /* PWE (1.1.1, A8): back at the receiver, perhaps from System Settings. */
        if (disp_actions & TB_DISP_ACTION_FOCUS_GAINED) tb_permwatch_kick(a.permwatch);
        if ((disp_actions & TB_DISP_ACTION_CYCLE_LANGUAGE) && a.client_fd < 0) {
            TB_LOOP_PHASE("language change");
            tb_receiver_cycle_language_preference(&a);
        }
        if (TB_RECEIVER_OFFER_LOGIN_ITEM &&
            (disp_actions & TB_DISP_ACTION_TOGGLE_LOGIN_ITEM) && a.client_fd < 0) {
            TB_LOOP_PHASE("login item toggle");
            tb_login_item_set_enabled(!tb_login_item_is_enabled());
            tb_receiver_refresh_login_item(&a);
        }

        uint64_t t = now_ms();

        if (t - a.last_ip_check_ms >= 1000) {
            char refreshed_tb_ip[64] = {0};
            char refreshed_usb_ip[64] = {0};
            char refreshed_net_ip[64] = {0};
            char refreshed_ethernet_ip[64] = {0};
            char refreshed_wifi_ip[64] = {0};
            char refreshed_tb_ip6[64] = {0};
            unsigned int refreshed_tb_ip6_if = 0;
            a.last_ip_check_ms = t;
            TB_LOOP_PHASE("address check (getifaddrs, SystemConfiguration)");
            (void)tb_net_get_tb_ip6(refreshed_tb_ip6, sizeof(refreshed_tb_ip6), &refreshed_tb_ip6_if);
            (void)tb_net_get_tb_ip(refreshed_tb_ip, sizeof(refreshed_tb_ip));
            (void)tb_net_get_link_local_ip(refreshed_usb_ip, sizeof(refreshed_usb_ip));
            (void)tb_net_get_lan_ip(refreshed_net_ip, sizeof(refreshed_net_ip));
            (void)tb_net_get_ethernet_ip(refreshed_ethernet_ip, sizeof(refreshed_ethernet_ip));
            (void)tb_net_get_wifi_ip(refreshed_wifi_ip, sizeof(refreshed_wifi_ip));

            const int have_refreshed_ip =
                refreshed_tb_ip[0] || refreshed_usb_ip[0] || refreshed_net_ip[0];
            const char *preferred_ip = refreshed_tb_ip[0] ? refreshed_tb_ip
                                     : (refreshed_usb_ip[0] ? refreshed_usb_ip
                                      : (refreshed_net_ip[0] ? refreshed_net_ip
                                      : tb_i18n_get("receiver.network.not_detected")));
            if (strcmp(a.tb_ip_text, refreshed_tb_ip) != 0 ||
                strcmp(a.usb_ip_text, refreshed_usb_ip) != 0 ||
                strcmp(a.net_ip_text, refreshed_net_ip) != 0 ||
                strcmp(a.ethernet_ip_text, refreshed_ethernet_ip) != 0 ||
                strcmp(a.wifi_ip_text, refreshed_wifi_ip) != 0 ||
                strcmp(a.tb_ip6_text, refreshed_tb_ip6) != 0 || a.tb_ip6_if != refreshed_tb_ip6_if ||
                strcmp(a.ip_text, preferred_ip) != 0) {
                snprintf(a.tb_ip_text, sizeof(a.tb_ip_text), "%s", refreshed_tb_ip);
                snprintf(a.usb_ip_text, sizeof(a.usb_ip_text), "%s", refreshed_usb_ip);
                snprintf(a.net_ip_text, sizeof(a.net_ip_text), "%s", refreshed_net_ip);
                snprintf(a.ethernet_ip_text, sizeof(a.ethernet_ip_text), "%s", refreshed_ethernet_ip);
                snprintf(a.wifi_ip_text, sizeof(a.wifi_ip_text), "%s", refreshed_wifi_ip);
                if (strcmp(a.tb_ip6_text, refreshed_tb_ip6) != 0) {
                    if (refreshed_tb_ip6[0] != '\0')
                        fprintf(stderr, "[main] Thunderbolt Bridge IPv6 = %s\n", refreshed_tb_ip6);
                    else
                        fprintf(stderr, "[main] Thunderbolt Bridge IPv6 gone\n");
                }
                snprintf(a.tb_ip6_text, sizeof(a.tb_ip6_text), "%s", refreshed_tb_ip6);
                a.tb_ip6_if = refreshed_tb_ip6_if;
                snprintf(a.ip_text, sizeof(a.ip_text), "%s", preferred_ip);
                TB_LOOP_PHASE("address change (host name, Bonjour)");
                build_display_host(a.display_host, sizeof(a.display_host), preferred_ip, have_refreshed_ip);
                if (refreshed_tb_ip[0] != '\0') {
                    fprintf(stderr, "[main] Thunderbolt Bridge IP = %s\n", refreshed_tb_ip);
                }
                if (refreshed_usb_ip[0] != '\0') {
                    fprintf(stderr, "[main] Direct USB-NCM IP = %s\n", refreshed_usb_ip);
                }
                if (refreshed_net_ip[0] != '\0') {
                    fprintf(stderr, "[main] Local network IP = %s\n", refreshed_net_ip);
                }
                if (refreshed_ethernet_ip[0] != '\0') {
                    fprintf(stderr, "[main] Ethernet IP = %s\n", refreshed_ethernet_ip);
                }
                if (refreshed_wifi_ip[0] != '\0') {
                    fprintf(stderr, "[main] Wi-Fi IP = %s\n", refreshed_wifi_ip);
                }
                bonjour_update(&a, TB_PORT);
            } else if (a.bonjour_pending && a.client_fd < 0) {
                /* The session that held back a re-registration has ended. */
                TB_LOOP_PHASE("Bonjour re-registration");
                bonjour_update(&a, TB_PORT);
            }
        }

        /* Accept new client */
        /* PWE (T47): the session ended while a cable connection waited. */
        if (a.client_fd < 0 && a.held_fd >= 0) tb_pwe_adopt_held(&a);
        if (a.client_fd < 0) {
            TB_LOOP_PHASE("accept a sender");
            /* PWE: both listeners on every pass, starting with a different one
             * each time, so connections refused on one cannot hold up the other. */
            const int listeners[2] = { a.server_fd, a.server6_fd };
            a.accept_turn ^= 1;
            for (int k = 0; k < 2 && a.client_fd < 0; k++) {
                const int which = (a.accept_turn + k) & 1;
                if (listeners[which] < 0) continue;
                const int c_is_ipv6 = which == 1;
                char ifname[IFNAMSIZ] = "";
                struct tb_accept_policy policy = { 0, 0, 0 };
                enum tb_link_kind link = TB_LINK_NETWORK;
                int c = tb_pwe_accept_checked(&a, listeners[which], c_is_ipv6, ifname, sizeof(ifname), &policy, &link);
                if (c >= 0) tb_pwe_adopt_client(&a, c, ifname, c_is_ipv6, policy, t);
            }
        } else {
            TB_LOOP_PHASE("connection tick");
            tb_conn_tick(&a.conn);   /* PWE: an older sender that waits for the profile */
            TB_LOOP_PHASE("socket read");
            int drain_result = drain_socket(&a);
            if (drain_result < 0) {
                close_client(&a);
            } else {
                socket_activity = drain_result;
                if (drain_result > 0) a.last_recv_ms = now_ms();
                if (a.close_requested) {
                    close_client(&a);
                } else {
                    const uint64_t watchdog_now_ms = now_ms();
                    uint64_t idle_ms = 0;
                    /* PWE: someone is typing the code shown (it lives 60 s). */
                    if (a.gate.code[0] && tb_conn_is_pairing(&a.conn)) a.last_recv_ms = watchdog_now_ms;
                    enum tb_idle_watchdog_result watchdog_result =
                        tb_idle_watchdog_check(watchdog_now_ms,
                                               &a.last_recv_ms,
                                               TB_SENDER_IDLE_TIMEOUT_MS,
                                               &idle_ms);
                    if (watchdog_result == TB_IDLE_WATCHDOG_CLOCK_REWOUND) {
                        fprintf(stderr,
                                "[main] monotonic clock moved backwards; "
                                "rebasing sender idle watchdog\n");
                    } else if (watchdog_result == TB_IDLE_WATCHDOG_EXPIRED) {
                        /* The sender streams frames continuously and heartbeats
                         * every 2s. Total silence means it died without a FIN
                         * (crash, pulled cable, force sleep). Without this reap,
                         * the dead fd is held forever and — because the receiver
                         * is single-client — every future connect is locked out
                         * until the app is restarted. */
                        fprintf(stderr,
                                "[main] no data from sender for %llu ms; closing stale session\n",
                                (unsigned long long)idle_ms);
                        close_client(&a);
                    } else {
                        TB_LOOP_PHASE("new connections during a session");
                        tb_pwe_screen_new_connections(&a);   /* PWE (T45, T47) */
                    }
                }
            }
        }

        if (t - a.last_permissions_poll_ms >= 250) {
            a.last_permissions_poll_ms = t;
            TB_LOOP_PHASE("permissions: the watcher's latest answer");
            tb_receiver_poll_permissions(&a);
            /* PWE (1.1.1, A8): an event tap macOS switched off for good (a
             * permission removed during the session): build it again, which
             * falls back to the window's own input if macOS refuses. */
            if (a.input_tap && t - a.last_tap_check_ms >= TB_PERMWATCH_INTERVAL_MS) {
                a.last_tap_check_ms = t;   /* at most one rebuild per 5 s */
                if (atomic_exchange(&a.tap_switched_off, 0) || !CGEventTapIsEnabled(a.input_tap)) {
                    TB_LOOP_PHASE("input: rebuild the event tap macOS switched off");
                    tb_receiver_input_log("[input] the event tap is off; asking macOS again and rebuilding it");
                    tb_permwatch_kick(a.permwatch);
                    tb_receiver_stop_input_tap(&a);
                    tb_receiver_refresh_input_capture(&a);
                }
            }
            TB_LOOP_PHASE("pairing notice");
            /* PWE: expire the pairing code; end short messages. */
            if (tb_conn_gate_tick(&a.gate, t) & PWE_SEC_EV_HIDE_CODE)
                fprintf(stderr, "[sec] pairing code expired\n");
            tb_pwe_refresh_notice(&a, t);
        }

        /* Cheap enough to poll: two private-framework getters, twice a second. */
        if (t - a.last_tweak_poll_ms >= 500) {
            a.last_tweak_poll_ms = t;
            TB_LOOP_PHASE("Night Shift / True Tone poll (CoreBrightness)");
            tb_receiver_send_display_tweaks_if_changed(&a);
        }

        if (a.client_fd < 0 || !a.session_active) {
            /* No client, or a connection that hasn't started a real streaming
             * session (e.g. a transient UI-language push during discovery):
             * stay on the windowed waiting screen, don't flash fullscreen. */
            TB_LOOP_PHASE("draw the idle screen");
            tb_disp_render_status(a.disp, a.display_host, a.status_text, a.sender_text, a.panel_text, a.mode_text, a.language_text, a.permissions_text);
            if (login_offer_pending && a.client_fd < 0) {
                login_offer_pending = 0;
                TB_LOOP_PHASE("login item offer (dialog)");
                tb_login_item_migrate();
                tb_login_item_offer_once();
                tb_receiver_refresh_login_item(&a);
            }
        } else if (!a.have_video_frame) {
            TB_LOOP_PHASE("draw the connecting screen");
            tb_disp_render_connecting(a.disp);
        }

        /* PWE (T40): the clipboard thread looks for new text while the iMac
         * drives the Mac; this loop only takes what it found and sends it. */
        {
            const int want_clipboard = strcmp(a.input_control_mode, "receiverMaster") == 0 && a.client_fd >= 0;
            TB_LOOP_PHASE("clipboard: take new text from the clipboard thread");
            if (want_clipboard != a.clipboard_polling) {
                a.clipboard_polling = want_clipboard;
                tb_clipboard_set_polling(a.clipboard, want_clipboard);
            }
            char clipboard_text[TB_CLIPBOARD_MAX_TEXT];
            if (want_clipboard && tb_clipboard_take(a.clipboard, clipboard_text, sizeof(clipboard_text))) {
                TB_LOOP_PHASE("clipboard: send to the Mac");
                tb_receiver_send_clipboard_text(&a, clipboard_text);
            }
        }

        if (strcmp(a.input_control_mode, "receiverMaster") == 0 && a.client_fd >= 0) {
            /* PWE (1.1.1): the tap's thread cannot ask AppKit; ask for it. */
            if (a.input_tap && t - a.last_space_check_ms >= 100) {
                TB_LOOP_PHASE("input: is the window on the active Space (AppKit)");
                a.last_space_check_ms = t;
                atomic_store(&a.window_on_active_space, tb_disp_window_on_active_space(a.disp));
            }
            TB_LOOP_PHASE("forward input to the Mac");
            struct tb_input_event input_event;
            while (tb_disp_pop_input_event(a.disp, &input_event)) {
                switch (input_event.kind) {
                case TB_INPUT_EVENT_MOVE:
                    tb_receiver_send_input_event(&a, "move", 1, input_event.dx, 1, input_event.dy, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_LEFT_DRAG:
                    tb_receiver_send_input_event(&a, "leftDrag", 1, input_event.dx, 1, input_event.dy, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_RIGHT_DRAG:
                    tb_receiver_send_input_event(&a, "rightDrag", 1, input_event.dx, 1, input_event.dy, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_OTHER_DRAG:
                    tb_receiver_send_input_event(&a, "otherDrag", 1, input_event.dx, 1, input_event.dy, 0, 0, 0, 0, 0, 0);
                    break;
                case TB_INPUT_EVENT_SCROLL:
                    tb_receiver_send_input_event(&a, "scroll", 0, 0, 0, 0, 1, input_event.scroll_x, 1, input_event.scroll_y, 0, 0);
                    break;
                case TB_INPUT_EVENT_LEFT_DOWN:
                    tb_receiver_send_input_button_event(&a, "leftDown", input_event.click_count);
                    break;
                case TB_INPUT_EVENT_LEFT_UP:
                    tb_receiver_send_input_button_event(&a, "leftUp", input_event.click_count);
                    break;
                case TB_INPUT_EVENT_RIGHT_DOWN:
                    tb_receiver_send_input_button_event(&a, "rightDown", input_event.click_count);
                    break;
                case TB_INPUT_EVENT_RIGHT_UP:
                    tb_receiver_send_input_button_event(&a, "rightUp", input_event.click_count);
                    break;
                case TB_INPUT_EVENT_OTHER_DOWN:
                    tb_receiver_send_input_button_event(&a, "otherDown", input_event.click_count);
                    break;
                case TB_INPUT_EVENT_OTHER_UP:
                    tb_receiver_send_input_button_event(&a, "otherUp", input_event.click_count);
                    break;
                case TB_INPUT_EVENT_KEY_DOWN:
                    tb_receiver_send_input_event(&a, "keyDown", 0, 0, 0, 0, 0, 0, 0, 0, 1, input_event.key_code);
                    break;
                case TB_INPUT_EVENT_KEY_UP:
                    tb_receiver_send_input_event(&a, "keyUp", 0, 0, 0, 0, 0, 0, 0, 0, 1, input_event.key_code);
                    break;
                case TB_INPUT_EVENT_SWITCH_PREV_TARGET:
                    tb_receiver_send_target_switch(&a, -1);
                    break;
                case TB_INPUT_EVENT_SWITCH_NEXT_TARGET:
                    tb_receiver_send_target_switch(&a, 1);
                    break;
                case TB_INPUT_EVENT_SWITCH_PREV_SPACE:
                    tb_receiver_send_space_switch(&a, -1);
                    break;
                case TB_INPUT_EVENT_SWITCH_NEXT_SPACE:
                    tb_receiver_send_space_switch(&a, 1);
                    break;
                case TB_INPUT_EVENT_DEACTIVATE_CONTROL:
                    tb_receiver_send_deactivate_control(&a);
                    break;
                case TB_INPUT_EVENT_NONE:
                default:
                    break;
                }
            }
        }

        /* A frame waiting for this refresh, or a pointer that moved. */
        TB_LOOP_PHASE("display tick (draw a waiting frame)");
        tb_disp_tick(a.disp);
        TB_LOOP_PHASE("trace and fps lines");
        tb_trace_tick(tb_trace_now_ns());

        /* FPS log. PWE (1.1.1): counted every second, logged every 10 s as
         * average, lowest and highest over the seconds that had frames (a still
         * desktop sends none), instead of one line a second. */
        if (t - a.last_fps_tick_ms >= 1000) {
            const uint64_t df = a.frames - a.last_fps_count;
            a.last_fps_count   = a.frames;
            a.last_fps_tick_ms = t;
            if (df > 0) {
                const unsigned fps = df > UINT_MAX ? UINT_MAX : (unsigned)df;
                if (a.fps_seconds == 0 || fps < a.fps_min) a.fps_min = fps;
                if (fps > a.fps_max) a.fps_max = fps;
                a.fps_sum += df;
                a.fps_seconds++;
            }
            if (a.fps_report_ms == 0) a.fps_report_ms = t;
            if (t - a.fps_report_ms >= 10000) {
                if (a.fps_seconds > 0) {
                    fprintf(stderr, "[main] fps over %u s with frames: avg %.1f, min %u, max %u\n",
                            a.fps_seconds, (double)a.fps_sum / a.fps_seconds, a.fps_min, a.fps_max);
                }
                /* PWE (1.1.1): at most one line per 10 s about catching up. */
                if (a.catchup_skipped > 0) {
                    fprintf(stderr, "[main] behind the sender in %lu read passes: %lu decoded pictures "
                                    "skipped, the newest of each backlog shown\n",
                            a.catchup_passes, a.catchup_skipped);
                    a.catchup_skipped = 0;
                    a.catchup_passes = 0;
                }
                a.fps_report_ms = t;
                a.fps_seconds = a.fps_min = a.fps_max = 0;
                a.fps_sum = 0;
            }
        }

        /* Yield when idle or when a nonblocking active socket had no data,
         * otherwise the receiver can busy-spin between incoming frame packets.
         * PWE (1.1.1): with no sender at all, nothing needs a 1 kHz loop: the
         * idle screen is presented every 100 ms and a new connection or key
         * press may wait 10 ms. A connected sender keeps the 1 ms pass. */
        if (a.client_fd < 0 || !a.have_video_frame || socket_activity == 0) {
            TB_LOOP_PHASE("idle sleep");
            SDL_Delay(a.client_fd < 0 ? 10 : 1);
        }
    }

    tb_loopwatch_stop();
    if (a.client_fd >= 0) close_client(&a);
#if TB_RECEIVER_TEST_HOOKS
    if (getenv("TB_RECEIVER_TEST_KEYCHAIN_SERVICE") && getenv("TB_RECEIVER_TEST_CLEAN_ON_EXIT")) {
        (void)pwe_keystore_delete_everything(&a.keystore);
    }
#endif
    tb_receiver_stop_input_tap(&a);
    tb_permwatch_stop(a.permwatch);   /* PWE (1.1.1) */
    a.permwatch = NULL;
    tb_rlthread_stop(a.tap_thread);   /* PWE (1.1.1) */
    a.tap_thread = NULL;
    tb_pwe_drop_held(&a);
    if (a.server_fd >= 0) close(a.server_fd);
    if (a.server6_fd >= 0) close(a.server6_fd);
    bonjour_deinit(&a);
    tb_dec_destroy(a.dec);
    /* PWE (T40): a clipboard that never gives its text must not hold up the exit. */
    const int clipboard_done = tb_clipboard_destroy(a.clipboard, 500);
    const int audio_done = tb_audio_out_destroy(a.audio, 1000);
    if (!audio_done || !clipboard_done) {
        /* PWE (T40): a worker is still inside a framework: the audio thread in
         * CoreAudio, the clipboard thread in AppKit. SDL_Quit would tear down
         * the same device or the app under it, and exit() would run the
         * frameworks' teardown under it: leave without either. */
        if (!audio_done) fprintf(stderr, "[main] bye (sound device still closing)\n");
        if (!clipboard_done) fprintf(stderr, "[main] bye (clipboard thread still waiting for the clipboard)\n");
        tb_log_stop();
        _exit(0);
    }
    tb_disp_destroy(a.disp);
    fprintf(stderr, "[main] bye\n");
    return 0;
}
