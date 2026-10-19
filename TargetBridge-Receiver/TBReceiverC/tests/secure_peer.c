/* secure_peer.c — PWE test hook: a minimal sender on the same pwe_secure.c,
 * for loopback runs against secure_receiver.
 *
 *   secure_peer --port 54399 --service <keychain service> [--code-file f]
 *               [--code 123456] [--frames N] [--expect-code | --expect-no-code]
 *
 * Pairs (reading the code the receiver wrote to --code-file) or resumes,
 * then sends HELLO, N 64 KB frames, a clipboard, a test packet it expects
 * back, and TEARDOWN — all sealed. Exit 0 when everything checked out.
 */

#include "proto.h"
#include "pwe_keystore.h"
#include "pwe_secure.h"

#include <arpa/inet.h>
#include <netinet/in.h>
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

int main(int argc, char **argv) {
    int port = 54399, frames = 30, expect = 0;   /* 1 = must ask for a code, -1 = must not */
    int forget = 0;
    const char *service = NULL, *code_file = NULL, *code = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--port") && i + 1 < argc) port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--service") && i + 1 < argc) service = argv[++i];
        else if (!strcmp(argv[i], "--code-file") && i + 1 < argc) code_file = argv[++i];
        else if (!strcmp(argv[i], "--code") && i + 1 < argc) code = argv[++i];
        else if (!strcmp(argv[i], "--frames") && i + 1 < argc) frames = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--expect-code")) expect = 1;
        else if (!strcmp(argv[i], "--expect-no-code")) expect = -1;
        else if (!strcmp(argv[i], "--forget-everything")) forget = 1;
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
