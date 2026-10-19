/* tb_conn.c — PWE: one client connection with pairing and encrypted records.
 * See net.h for the contract and TargetBridge-Shared/secure/pwe_secure.h for
 * the protocol. Kept apart from net.c so the parser tests still build with
 * nothing but libc. */

#include "net.h"
#include "proto.h"
#include "pwe_secure.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static uint64_t mono_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

/* Same bound as main.c's send_all: 2 s without progress drops the write, so a
 * reader that stopped cannot wedge the event loop. */
static int send_all(int fd, const uint8_t *buf, size_t len) {
    const uint64_t deadline = mono_ms() + 2000;
    size_t off = 0;
    while (off < len) {
        ssize_t n = write(fd, buf + off, len - off);
        if (n > 0) { off += (size_t)n; continue; }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (mono_ms() >= deadline) {
                fprintf(stderr, "[net] send stalled for 2s; dropping write\n");
                return -1;
            }
            usleep(1000);
            continue;
        }
        return -1;
    }
    return 0;
}

static int tx_reserve(struct tb_conn *c, size_t need) {
    if (c->tx_cap >= need) return 0;
    size_t cap = c->tx_cap ? c->tx_cap : 65536;
    while (cap < need) cap *= 2;
    uint8_t *nb = (uint8_t *)realloc(c->tx, cap);
    if (!nb) return -1;
    c->tx = nb;
    c->tx_cap = cap;
    return 0;
}

static void emit(struct tb_conn *c, int ev) {
    if (ev && c->on_event) c->on_event(c, ev, c->ud);
}

/* Run one handshake step and send what it produced. */
static void handshake(struct tb_conn *c, uint8_t type, const uint8_t *payload, size_t len) {
    uint8_t buf[4096];
    struct pwe_sec_out out = { buf, 0, sizeof(buf) };
    int ev = pwe_sec_handle(c->sec, type, payload, len, &out, c->now_ms);
    if (out.len && send_all(c->fd, out.buf, out.len) != 0) ev |= PWE_SEC_EV_CLOSE;
    if (ev & PWE_SEC_EV_SECURE) {
        c->mode = TB_CONN_SECURE;
        ev |= TB_CONN_EV_READY;
        char hex[2 * PWE_SEC_ID_BYTES + 1] = "";
        if (pwe_sec_peer_id(c->sec)) pwe_sec_id_hex(pwe_sec_peer_id(c->sec), hex);
        fprintf(stderr, "[sec] encrypted session with \"%s\" (%.8s)\n", pwe_sec_peer_name(c->sec), hex);
    }
    if (ev & PWE_SEC_EV_CLOSE) {
        c->want_close = 1;
        if (!(ev & PWE_SEC_EV_PEER_ERROR)) ev |= TB_CONN_EV_SECURITY_FAILED;
        fprintf(stderr, "[sec] handshake ended (local %d, peer %d)\n",
                pwe_sec_local_error(c->sec), pwe_sec_peer_error(c->sec));
    }
    emit(c, ev);
}

static void on_raw_packet(uint8_t type, const uint8_t *payload, size_t len, void *ud) {
    struct tb_conn *c = (struct tb_conn *)ud;
    if (c->want_close) return;

    if (c->mode == TB_CONN_UNDECIDED) {
        if (type == TB_PKT_SEC_HELLO) {
            struct pwe_sec_responder_opts opts = { .direct_link = c->cfg.direct_link };
            c->sec = pwe_sec_new(PWE_SEC_RESPONDER, c->cfg.identity, c->cfg.store, c->cfg.gate, &opts);
            if (!c->sec) {
                /* No keys (keychain unreadable): say so rather than fall back. */
                static const uint8_t err[8] = { 0, 0, 0, 4, TB_PKT_SEC_ERROR, PWE_SEC_ERR_STORE, 0, 0 };
                (void)send_all(c->fd, err, sizeof(err));
                c->want_close = 1;
                emit(c, TB_CONN_EV_SECURITY_FAILED);
                return;
            }
            c->mode = TB_CONN_HANDSHAKE;
        } else if (c->cfg.allow_plaintext) {
            c->mode = TB_CONN_PLAINTEXT;
            fprintf(stderr, "[sec] unencrypted connection (compatibility mode): "
                            "picture, sound, brightness and volume only\n");
            emit(c, TB_CONN_EV_READY | TB_CONN_EV_PLAINTEXT);
            if (c->want_close) return;
        } else {
            fprintf(stderr, "[sec] refused an unencrypted connection (first packet 0x%02x)\n", type);
            c->want_close = 1;
            emit(c, TB_CONN_EV_PLAINTEXT_REFUSED);
            return;
        }
    }

    switch (c->mode) {
    case TB_CONN_HANDSHAKE:
        if (PWE_PKT_IS_SEC(type) && type != TB_PKT_SEC_SEALED) {
            handshake(c, type, payload, len);
        } else {
            /* Nothing but handshake traffic before the keys exist. */
            fprintf(stderr, "[sec] packet 0x%02x before the handshake finished; closing\n", type);
            c->want_close = 1;
            emit(c, TB_CONN_EV_SECURITY_FAILED);
        }
        return;

    case TB_CONN_SECURE: {
        if (type != TB_PKT_SEC_SEALED) {
            fprintf(stderr, "[sec] unsealed packet 0x%02x in an encrypted session; closing\n", type);
            c->want_close = 1;
            emit(c, TB_CONN_EV_SECURITY_FAILED);
            return;
        }
        /* The parser's buffer is ours: decrypt in place. */
        uint8_t inner_type = 0, *inner = NULL;
        size_t inner_len = 0;
        if (pwe_sec_open(c->sec, (uint8_t *)payload, len, &inner_type, &inner, &inner_len) != 0) {
            fprintf(stderr, "[sec] record failed authentication; closing\n");
            c->want_close = 1;
            emit(c, TB_CONN_EV_SECURITY_FAILED);
            return;
        }
        if (PWE_PKT_IS_SEC(inner_type)) return;   /* reserved inside records */
        /* Same NUL sentinel guarantee the parser gives (the tag bytes follow). */
        inner[inner_len] = '\0';
        c->on_packet(inner_type, inner, inner_len, c->ud);
        return;
    }

    case TB_CONN_PLAINTEXT:
        if (PWE_PKT_IS_SEC(type)) {
            c->want_close = 1;
            return;
        }
        if (!pwe_sec_plaintext_allowed(type, 1)) {
            if (c->withheld++ < 5)
                fprintf(stderr, "[sec] ignored packet 0x%02x: needs an encrypted session\n", type);
            return;
        }
        c->on_packet(type, payload, len, c->ud);
        return;

    default:
        return;
    }
}

int tb_conn_init(struct tb_conn *c, int fd, const struct tb_conn_config *cfg,
                 tb_pkt_cb on_packet, tb_conn_ev_cb on_event, void *ud) {
    memset(c, 0, sizeof(*c));
    c->fd = fd;
    c->mode = TB_CONN_UNDECIDED;
    if (cfg) c->cfg = *cfg;
    c->on_packet = on_packet;
    c->on_event = on_event;
    c->ud = ud;
    tb_parser_init(&c->parser, on_raw_packet, c);
    if (pwe_sec_global_init() != 0) return -1;
    if (!c->cfg.identity || !c->cfg.store || !c->cfg.gate) {
        /* Without keys only compatibility connections can work. */
        fprintf(stderr, "[sec] no pairing keys: encrypted connections are unavailable\n");
    }
    return 0;
}

int tb_conn_feed(struct tb_conn *c, const uint8_t *data, size_t n, uint64_t now_ms) {
    if (c->mode == TB_CONN_CLOSED) return -1;
    c->now_ms = now_ms;
    if (tb_parser_feed(&c->parser, data, n) < 0) return -1;
    return c->want_close ? -1 : 0;
}

int tb_conn_send(struct tb_conn *c, uint8_t type, const uint8_t *payload, size_t len) {
    if (c->want_close) return -1;
    switch (c->mode) {
    case TB_CONN_SECURE: {
        if (tx_reserve(c, len + PWE_SEC_SEAL_OVERHEAD) != 0) return -1;
        size_t out_len = 0;
        if (pwe_sec_seal(c->sec, type, payload, len, c->tx, c->tx_cap, &out_len) != 0) return -1;
        return send_all(c->fd, c->tx, out_len);
    }
    case TB_CONN_PLAINTEXT: {
        if (!pwe_sec_plaintext_allowed(type, 0)) return 1;
        if (tx_reserve(c, len + 5) != 0) return -1;
        uint32_t plen = (uint32_t)(len + 1);
        c->tx[0] = (uint8_t)(plen >> 24); c->tx[1] = (uint8_t)(plen >> 16);
        c->tx[2] = (uint8_t)(plen >> 8);  c->tx[3] = (uint8_t)plen;
        c->tx[4] = type;
        if (len) memcpy(c->tx + 5, payload, len);
        return send_all(c->fd, c->tx, len + 5);
    }
    default:
        return 1;
    }
}

int tb_conn_send_packet(struct tb_conn *c, const uint8_t *pkt, size_t len) {
    if (len < TB_HDR_BYTES) return -1;
    return tb_conn_send(c, pkt[4], pkt + TB_HDR_BYTES, len - TB_HDR_BYTES);
}

int tb_conn_gate_tick(struct pwe_sec_gate *gate, uint64_t now_ms) {
    return pwe_sec_gate_tick(gate, now_ms);
}

int tb_conn_is_secure(const struct tb_conn *c) {
    return c && c->mode == TB_CONN_SECURE;
}

int tb_conn_is_pairing(const struct tb_conn *c) {
    return c && c->sec && pwe_sec_is_pairing(c->sec);
}

void tb_conn_close(struct tb_conn *c, uint64_t now_ms) {
    if (c->mode == TB_CONN_CLOSED) return;
    if (c->sec) {
        emit(c, pwe_sec_closed(c->sec, now_ms));
        pwe_sec_free(c->sec);
        c->sec = NULL;
    }
    tb_parser_free(&c->parser);
    if (c->tx) {
        memset(c->tx, 0, c->tx_cap);
        free(c->tx);
    }
    c->tx = NULL;
    c->tx_cap = 0;
    if (c->fd >= 0) close(c->fd);
    c->fd = -1;
    c->mode = TB_CONN_CLOSED;
}
