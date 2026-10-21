/* secure_peer.c — PWE test hook: a minimal sender on the same pwe_secure.c,
 * for loopback runs against secure_receiver.
 *
 *   secure_peer --port 54399 --service <keychain service> [--code-file f]
 *               [--code 123456] [--frames N] [--expect-code | --expect-no-code]
 *               [--clipboard <test pasteboard> --pboard-tool <path> [--leave-read]]
 *
 * Pairs (reading the code the receiver wrote to --code-file) or resumes,
 * then sends HELLO, N 64 KB frames, a clipboard, a test packet it expects
 * back, and TEARDOWN — all sealed. Exit 0 when everything checked out.
 *
 * PWE (T40), --clipboard: against the real receiver (the smoke), instead of
 * the frames and the probe: switch to receiverMaster, put text on the iMac's
 * clipboard (the receiver's test pasteboard, read with pboard_tool), check
 * the receiver does not send it back, then copy text "on the iMac" with
 * pboard_tool and wait for the receiver to send it. --leave-read: copy once
 * more and wait 300 ms, so the receiver is reading when the peer leaves.
 */

#include "proto.h"
#include "pwe_keystore.h"
#include "pwe_secure.h"

#include <arpa/inet.h>
#include <netinet/in.h>
#include <poll.h>
#include <spawn.h>
#include <sys/wait.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static uint64_t mono_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

static int write_all(int fd, const uint8_t *p, size_t n) {
    while (n) { ssize_t w = write(fd, p, n); if (w <= 0) return -1; p += w; n -= (size_t)w; }
    return 0;
}

static int read_exact(int fd, uint8_t *p, size_t n) {
    while (n) { ssize_t r = read(fd, p, n); if (r <= 0) return -1; p += r; n -= (size_t)r; }
    return 0;
}

/* Reads one packet; payload malloc'd. */
static int read_packet(int fd, uint8_t *type, uint8_t **payload, size_t *len) {
    uint8_t h[5];
    if (read_exact(fd, h, 5) != 0) return -1;
    uint32_t l = ((uint32_t)h[0] << 24) | ((uint32_t)h[1] << 16) | ((uint32_t)h[2] << 8) | h[3];
    if (l < 1 || l > 64u * 1024 * 1024) return -1;
    *type = h[4];
    *len = l - 1;
    *payload = malloc(*len + 1);
    return read_exact(fd, *payload, *len);
}

static int send_sealed(struct pwe_sec *sec, int fd, uint8_t type, const uint8_t *p, size_t len) {
    uint8_t *out = malloc(len + PWE_SEC_SEAL_OVERHEAD);
    size_t n = 0;
    int rc = pwe_sec_seal(sec, type, p, len, out, len + PWE_SEC_SEAL_OVERHEAD, &n) == 0 ? write_all(fd, out, n) : -1;
    free(out);
    return rc;
}

/* ---- PWE (T40): the clipboard check (--clipboard) ------------------------ */

extern char **environ;

/* Runs pboard_tool with these arguments (no shell); its output in `out`. */
static int run_pboard_tool(const char *tool, const char *pasteboard, const char *verb, const char *text,
                           char *out, size_t out_size) {
    int pipefd[2];
    if (pipe(pipefd) != 0) return -1;
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, pipefd[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&fa, pipefd[0]);
    char *argv[] = { (char *)tool, (char *)pasteboard, (char *)verb, (char *)text, NULL };
    pid_t pid;
    int rc = posix_spawn(&pid, tool, &fa, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(pipefd[1]);
    size_t used = 0;
    if (rc == 0) {
        ssize_t n;
        while ((n = read(pipefd[0], out + used, out_size - 1 - used)) > 0 && used + 1 < out_size) used += (size_t)n;
    }
    out[used] = '\0';
    close(pipefd[0]);
    if (rc != 0) return -1;
    int status = 0;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
}

static void send_heartbeat(struct pwe_sec *sec, int fd) {
    static int seq;
    char hb[48];
    int n = snprintf(hb, sizeof(hb), "{\"sequence\":%d}", seq++);
    send_sealed(sec, fd, TB_PKT_HEARTBEAT, (const uint8_t *)hb, (size_t)n);
}

/* Waits up to `ms` for a CLIPBOARD packet from the receiver, keeping the
 * session alive. 1 and its JSON in `json` when one came; 0 when none. */
static int wait_clipboard(struct pwe_sec *sec, int fd, unsigned ms, char *json, size_t json_size) {
    const uint64_t until = mono_ms() + ms;
    uint64_t next_hb = 0;
    for (;;) {
        const uint64_t now = mono_ms();
        if (now >= until) return 0;
        if (now >= next_hb) { send_heartbeat(sec, fd); next_hb = now + 1000; }
        struct pollfd pfd = { fd, POLLIN, 0 };
        if (poll(&pfd, 1, 100) <= 0) continue;
        uint8_t type, *p, it, *inner;
        size_t len, il;
        if (read_packet(fd, &type, &p, &len) != 0) { fprintf(stderr, "PEER the receiver closed the session\n"); return -1; }
        int clip = type == PWE_PKT_SEC_SEALED && pwe_sec_open(sec, p, len, &it, &inner, &il) == 0 &&
                   it == TB_PKT_CLIPBOARD;
        if (clip) snprintf(json, json_size, "%.*s", (int)il, (const char *)inner);
        free(p);
        if (clip) return 1;
    }
}

static int clipboard_check(struct pwe_sec *sec, int fd, const char *pasteboard, const char *tool, int leave_read) {
    const char *mode = "{\"mode\":\"receiverMaster\"}";
    send_sealed(sec, fd, TB_PKT_INPUT_CONTROL, (const uint8_t *)mode, strlen(mode));

    /* The Mac copies: the text must reach the iMac's clipboard. */
    char mac_text[64], json[512], got[512] = "";
    snprintf(mac_text, sizeof(mac_text), "copied on the Mac %d", (int)getpid());
    snprintf(json, sizeof(json), "{\"text\":\"%s\"}", mac_text);
    uint64_t t0 = mono_ms();
    send_sealed(sec, fd, TB_PKT_CLIPBOARD, (const uint8_t *)json, strlen(json));
    while (mono_ms() - t0 < 8000) {
        if (run_pboard_tool(tool, pasteboard, "get", NULL, got, sizeof(got)) == 0 && !strcmp(got, mac_text)) break;
        send_heartbeat(sec, fd);
        usleep(50000);
    }
    if (strcmp(got, mac_text) != 0) { fprintf(stderr, "PEER the Mac's text never reached the iMac (\"%s\")\n", got); return 1; }
    printf("PEER clipboard Mac -> iMac after %llu ms\n", (unsigned long long)(mono_ms() - t0));

    /* Nothing comes back: the receiver must not echo the Mac's own text. */
    int r = wait_clipboard(sec, fd, 1500, json, sizeof(json));
    if (r != 0) { fprintf(stderr, "PEER the receiver sent %s (echo)\n", r > 0 ? json : "nothing: closed"); return 1; }
    printf("PEER no echo of the Mac's text\n");

    /* Someone copies on the iMac: the receiver sends it. */
    char imac_text[64];
    snprintf(imac_text, sizeof(imac_text), "copied on the iMac %d", (int)getpid());
    if (run_pboard_tool(tool, pasteboard, "set", imac_text, got, sizeof(got)) != 0) {
        fprintf(stderr, "PEER pboard_tool could not copy\n"); return 1;
    }
    t0 = mono_ms();
    r = wait_clipboard(sec, fd, 8000, json, sizeof(json));
    if (r <= 0 || !strstr(json, imac_text)) {
        fprintf(stderr, "PEER the iMac's copy never came (%s)\n", r > 0 ? json : "nothing"); return 1;
    }
    printf("PEER clipboard iMac -> Mac after %llu ms\n", (unsigned long long)(mono_ms() - t0));

    if (leave_read) {
        (void)run_pboard_tool(tool, pasteboard, "set", "copied as the Mac leaves", got, sizeof(got));
        usleep(300000);
    }
    return 0;
}

int main(int argc, char **argv) {
    int port = 54399, frames = 30, expect = 0;   /* 1 = must ask for a code, -1 = must not */
    int forget = 0, leave_read = 0;
    const char *service = NULL, *code_file = NULL, *code = NULL;
    const char *pasteboard = NULL, *pboard_tool = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--port") && i + 1 < argc) port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--service") && i + 1 < argc) service = argv[++i];
        else if (!strcmp(argv[i], "--code-file") && i + 1 < argc) code_file = argv[++i];
        else if (!strcmp(argv[i], "--code") && i + 1 < argc) code = argv[++i];
        else if (!strcmp(argv[i], "--frames") && i + 1 < argc) frames = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--expect-code")) expect = 1;
        else if (!strcmp(argv[i], "--expect-no-code")) expect = -1;
        else if (!strcmp(argv[i], "--forget-everything")) forget = 1;
        else if (!strcmp(argv[i], "--clipboard") && i + 1 < argc) pasteboard = argv[++i];
        else if (!strcmp(argv[i], "--pboard-tool") && i + 1 < argc) pboard_tool = argv[++i];
        else if (!strcmp(argv[i], "--leave-read")) leave_read = 1;
        else { fprintf(stderr, "unknown option %s\n", argv[i]); return 2; }
    }
    if (!service || pwe_sec_global_init() != 0) return 2;

    struct pwe_keystore ks;
    struct pwe_sec_identity idn;
    struct pwe_sec_store store;
    pwe_keystore_init(&ks, service, 0);
    if (forget) return pwe_keystore_delete_everything(&ks) == 0 ? 0 : 1;
    if (pwe_keystore_load_identity(&ks, "Loopback Mac", &idn) != 0) { fprintf(stderr, "keychain\n"); return 1; }
    pwe_keystore_as_store(&ks, &store);

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons((uint16_t)port) };
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) != 0) { perror("connect"); return 1; }
    struct timeval tv = { 10, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    struct pwe_sec *sec = pwe_sec_new(PWE_SEC_INITIATOR, &idn, &store, NULL, NULL);
    uint8_t obuf[65536];
    struct pwe_sec_out out = { obuf, 0, sizeof(obuf) };
    pwe_sec_start(sec, NULL, code, &out, mono_ms());
    write_all(fd, out.buf, out.len);

    int asked = 0;
    double t_start = (double)mono_ms();
    while (!pwe_sec_is_secure(sec)) {
        uint8_t type, *p;
        size_t len;
        if (read_packet(fd, &type, &p, &len) != 0) { fprintf(stderr, "PEER closed during handshake\n"); return 1; }
        out.len = 0;
        int ev = pwe_sec_handle(sec, type, p, len, &out, mono_ms());
        free(p);
        if (ev & PWE_SEC_EV_NEED_CODE) {
            asked = 1;
            char c[16] = "";
            for (int i = 0; i < 100 && code_file; i++) {   /* the "user" reads the iMac's screen */
                FILE *f = fopen(code_file, "r");
                if (f && fgets(c, sizeof(c), f)) { fclose(f); break; }
                if (f) fclose(f);
                usleep(50000);
            }
            c[strcspn(c, "\r\n")] = '\0';
            printf("PEER entering code %s\n", c);
            pwe_sec_submit_code(sec, c, &out);
        }
        if (out.len) write_all(fd, out.buf, out.len);
        if (ev & PWE_SEC_EV_CLOSE) {
            fprintf(stderr, "PEER handshake failed: local %d peer %d\n",
                    pwe_sec_local_error(sec), pwe_sec_peer_error(sec));
            return 1;
        }
    }
    double t_secure = (double)mono_ms();
    printf("PEER secure with \"%s\" after %.0f ms (code asked: %d)\n",
           pwe_sec_peer_name(sec), t_secure - t_start, asked);
    if (expect == 1 && !asked) { fprintf(stderr, "PEER expected to be asked for a code\n"); return 1; }
    if (expect == -1 && asked) { fprintf(stderr, "PEER was asked for a code on a paired connection\n"); return 1; }

    /* The receiver speaks first once ready: a sealed display profile. */
    uint8_t type, *p, it, *inner;
    size_t len, il;
    if (read_packet(fd, &type, &p, &len) != 0 || type != PWE_PKT_SEC_SEALED ||
        pwe_sec_open(sec, p, len, &it, &inner, &il) != 0 || it != TB_PKT_DISPLAY_PROFILE) {
        fprintf(stderr, "PEER no sealed display profile\n");
        return 1;
    }
    printf("PEER profile %.*s\n", (int)il, (const char *)inner);
    free(p);

    const char *hello = "{\"senderName\":\"Loopback Mac\",\"uiLanguage\":\"en\"}";
    send_sealed(sec, fd, TB_PKT_HELLO_RECEIVER, (const uint8_t *)hello, strlen(hello));
    if (pasteboard) {
        if (!pboard_tool) { fprintf(stderr, "--clipboard needs --pboard-tool\n"); return 2; }
        int rc = clipboard_check(sec, fd, pasteboard, pboard_tool, leave_read);
        send_sealed(sec, fd, TB_PKT_TEARDOWN, (const uint8_t *)"{\"reason\":\"done\"}", 17);
        if (rc == 0) printf("PEER ok clipboard\n");
        pwe_sec_free(sec);
        close(fd);
        return rc;
    }
    uint8_t *frame = malloc(65536);
    for (int i = 0; i < 65536; i++) frame[i] = (uint8_t)i;
    for (int i = 0; i < frames; i++) send_sealed(sec, fd, TB_PKT_FRAME, frame, 65536);
    free(frame);
    const char *clip = "{\"text\":\"loopback clipboard\"}";
    send_sealed(sec, fd, TB_PKT_CLIPBOARD, (const uint8_t *)clip, strlen(clip));
    const char *probe = "echo-me-0123456789";
    send_sealed(sec, fd, TB_PKT_TEST_DATA, (const uint8_t *)probe, strlen(probe));
    if (read_packet(fd, &type, &p, &len) != 0 || type != PWE_PKT_SEC_SEALED ||
        pwe_sec_open(sec, p, len, &it, &inner, &il) != 0 || it != TB_PKT_TEST_DATA ||
        il != strlen(probe) || memcmp(inner, probe, il) != 0) {
        fprintf(stderr, "PEER test packet did not come back\n");
        return 1;
    }
    free(p);
    send_sealed(sec, fd, TB_PKT_TEARDOWN, (const uint8_t *)"{\"reason\":\"done\"}", 17);
    printf("PEER ok frames=%d echo=ok\n", frames);
    pwe_sec_free(sec);
    close(fd);
    return 0;
}
