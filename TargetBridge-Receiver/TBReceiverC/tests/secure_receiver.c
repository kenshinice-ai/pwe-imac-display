/* secure_receiver.c — PWE test hook: a receiver made of the real connection
 * layer (tb_conn.c, pwe_secure.c, pwe_keystore.c) and nothing else, for
 * loopback tests of pairing and encrypted sessions before main.c uses them.
 *
 *   secure_receiver --port 54399 [--service <keychain service>] [--code-file f]
 *                   [--plaintext-off] [--not-direct] [--connections N]
 *
 * Prints one line per event ("CODE 482913", "READY secure=1", ...) and one
 * "SESSION ..." line per connection. Replies like a receiver would: a display
 * profile when the session is ready, an echo of every 0x40 test packet.
 * Loopback counts as the cable here (unless --not-direct); the real receiver
 * never treats loopback as direct.
 */

#include "net.h"
#include "proto.h"
#include "pwe_keystore.h"
#include "pwe_secure.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

struct mem_store { int n; uint8_t id[8][16]; uint8_t pub[8][32]; char name[8][65]; };

static int mem_find(void *ud, const uint8_t id[16], uint8_t pub[32], char name[65]) {
    struct mem_store *m = ud;
    for (int i = 0; i < m->n; i++) if (!memcmp(m->id[i], id, 16)) {
        memcpy(pub, m->pub[i], 32); if (name) memcpy(name, m->name[i], 65); return 0;
    }
    return 1;
}
static int mem_save(void *ud, const uint8_t id[16], const uint8_t pub[32], const char *name) {
    struct mem_store *m = ud;
    int i = 0;
    while (i < m->n && memcmp(m->id[i], id, 16)) i++;
    if (i == m->n) { if (m->n == 8) return -1; m->n++; }
    memcpy(m->id[i], id, 16); memcpy(m->pub[i], pub, 32); snprintf(m->name[i], 65, "%s", name);
    return 0;
}

static uint64_t mono_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

struct session {
    struct tb_conn conn;
    const char *code_file;
    int packets, by_type[256], ready, secure, closing;
    size_t bytes;
};

static void on_packet(uint8_t type, const uint8_t *payload, size_t len, void *ud) {
    struct session *s = ud;
    s->packets++;
    s->by_type[type]++;
    s->bytes += len;
    if (type == TB_PKT_TEST_DATA) {
        tb_conn_send(&s->conn, TB_PKT_TEST_DATA, payload, len);
    } else if (type == TB_PKT_CLIPBOARD) {
        printf("CLIPBOARD %.*s\n", (int)len, (const char *)payload);
    } else if (type == TB_PKT_TEARDOWN) {
        s->closing = 1;
    }
    fflush(stdout);
}

static void on_event(struct tb_conn *c, int ev, void *ud) {
    struct session *s = ud;
    struct pwe_sec_gate *gate = c->cfg.gate;
    if (ev & PWE_SEC_EV_SHOW_CODE) {
        printf("CODE %s\n", gate->code);
        if (s->code_file) {
            char tmp[1024];
            snprintf(tmp, sizeof(tmp), "%s.tmp", s->code_file);
            FILE *f = fopen(tmp, "w");
            if (f) { fprintf(f, "%s\n", gate->code); fclose(f); rename(tmp, s->code_file); }
        }
    }
    if (ev & PWE_SEC_EV_HIDE_CODE) printf("HIDE_CODE\n");
    if (ev & PWE_SEC_EV_PAIRED) printf("PAIRED %s\n", pwe_sec_peer_name(c->sec));
    if (ev & PWE_SEC_EV_WRONG_CODE) printf("WRONG_CODE\n");
    if (ev & PWE_SEC_EV_LOCKED) printf("LOCKED\n");
    if (ev & TB_CONN_EV_PLAINTEXT) printf("PLAINTEXT\n");
    if (ev & TB_CONN_EV_PLAINTEXT_REFUSED) printf("REFUSED_PLAINTEXT\n");
    if (ev & TB_CONN_EV_SECURITY_FAILED) printf("SECURITY_FAILED\n");
    if (ev & TB_CONN_EV_READY) {
        s->ready = 1;
        s->secure = tb_conn_is_secure(c);
        printf("READY secure=%d\n", s->secure);
        char profile[160];
        int n = snprintf(profile, sizeof(profile),
                         "{\"name\":\"Loopback iMac\",\"width\":5120,\"height\":2880,\"secure\":%s}",
                         s->secure ? "true" : "false");
        tb_conn_send(c, TB_PKT_DISPLAY_PROFILE, (const uint8_t *)profile, (size_t)n);
    }
    fflush(stdout);
}

int main(int argc, char **argv) {
    int port = 54399, connections = 1, plaintext = 1, direct = 1;
    const char *service = NULL, *code_file = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--port") && i + 1 < argc) port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--service") && i + 1 < argc) service = argv[++i];
        else if (!strcmp(argv[i], "--code-file") && i + 1 < argc) code_file = argv[++i];
        else if (!strcmp(argv[i], "--connections") && i + 1 < argc) connections = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--plaintext-off")) plaintext = 0;
        else if (!strcmp(argv[i], "--not-direct")) direct = 0;
        else { fprintf(stderr, "unknown option %s\n", argv[i]); return 2; }
    }
    if (pwe_sec_global_init() != 0) return 1;

    struct pwe_sec_identity idn;
    struct pwe_sec_store store;
    struct pwe_keystore ks;
    static struct mem_store mem;
    if (service) {
        pwe_keystore_init(&ks, service, PWE_SEC_MAX_PEERS);
        if (pwe_keystore_load_identity(&ks, "Loopback iMac", &idn) != 0) {
            fprintf(stderr, "keychain unavailable (%d)\n", ks.last_status);
            return 1;
        }
        pwe_keystore_as_store(&ks, &store);
    } else {
        pwe_sec_identity_generate(&idn, "Loopback iMac");
        store = (struct pwe_sec_store){ mem_find, mem_save, &mem };
    }
    struct pwe_sec_gate gate;
    memset(&gate, 0, sizeof(gate));

    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    int yes = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons((uint16_t)port) };
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(lfd, (struct sockaddr *)&a, sizeof(a)) != 0 || listen(lfd, 1) != 0) { perror("bind"); return 1; }
    printf("LISTENING %d\n", port);
    fflush(stdout);

    for (int n = 0; n < connections; n++) {
        int fd = accept(lfd, NULL, NULL);
        if (fd < 0) { perror("accept"); return 1; }
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
        struct session *s = calloc(1, sizeof(*s));
        s->code_file = code_file;
        struct tb_conn_config cfg = { &idn, &store, &gate, direct, plaintext };
        tb_conn_init(&s->conn, fd, &cfg, on_packet, on_event, s);
        uint8_t *buf = malloc(1 << 20);
        int done = 0;
        while (!done && !s->closing) {
            struct pollfd p = { fd, POLLIN, 0 };
            poll(&p, 1, 200);
            if (tb_conn_gate_tick(&gate, mono_ms()) & PWE_SEC_EV_HIDE_CODE) { printf("HIDE_CODE (expired)\n"); fflush(stdout); }
            for (;;) {
                ssize_t r = read(fd, buf, 1 << 20);
                if (r > 0) { if (tb_conn_feed(&s->conn, buf, (size_t)r, mono_ms()) < 0) { done = 1; break; } continue; }
                if (r == 0) { done = 1; break; }
                if (errno != EAGAIN && errno != EWOULDBLOCK) done = 1;
                break;
            }
        }
        printf("SESSION secure=%d packets=%d bytes=%zu hello=%d frames=%d clipboard=%d input=%d mode=%d test=%d\n",
               s->secure, s->packets, s->bytes, s->by_type[0x10], s->by_type[0x21], s->by_type[0x36],
               s->by_type[0x33], s->by_type[0x34], s->by_type[0x40]);
        fflush(stdout);
        tb_conn_close(&s->conn, mono_ms());
        free(buf);
        free(s);
    }
    if (service && getenv("PWE_HARNESS_CLEAN")) pwe_keystore_delete_everything(&ks);
    close(lfd);
    return 0;
}
