/* test_net_parser.c — hardware-free unit tests for the streaming packet
 * parser in net.c (the framing layer every receiver session depends on).
 *
 * Build & run:  make test
 *
 * Only needs net.c + POSIX — no ffmpeg, no SDL, no Thunderbolt. */

#include "../src/net.h"
#include "../src/proto.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg) do {                                              \
    g_checks++;                                                            \
    if (!(cond)) {                                                         \
        g_failures++;                                                      \
        fprintf(stderr, "FAIL %s:%d — %s\n", __FILE__, __LINE__, (msg));   \
    }                                                                      \
} while (0)

/* ---- callback capture ------------------------------------------------- */

#define MAX_CAPTURED 16

struct captured_packet {
    uint8_t type;
    size_t  len;
    uint8_t payload[1024];
    int     had_nul_sentinel;   /* payload[len] was '\0' during the callback */
};

static struct captured_packet g_captured[MAX_CAPTURED];
static int g_captured_count = 0;

static void capture_cb(uint8_t type, const uint8_t *payload, size_t len, void *ud) {
    (void)ud;
    if (g_captured_count >= MAX_CAPTURED) return;
    struct captured_packet *c = &g_captured[g_captured_count++];
    c->type = type;
    c->len = len;
    if (len <= sizeof(c->payload)) memcpy(c->payload, payload, len);
    /* net.c promises a NUL one byte past the payload so string functions in
     * the callback cannot run off the end. */
    c->had_nul_sentinel = (payload[len] == '\0');
}

static void reset_capture(void) {
    memset(g_captured, 0, sizeof(g_captured));
    g_captured_count = 0;
}

/* ---- helpers ----------------------------------------------------------- */

static void put_be32(uint8_t *dst, uint32_t v) {
    dst[0] = (uint8_t)(v >> 24);
    dst[1] = (uint8_t)(v >> 16);
    dst[2] = (uint8_t)(v >> 8);
    dst[3] = (uint8_t)v;
}

/* Builds [4B BE len][1B type][payload] into buf; returns total size. */
static size_t build_packet(uint8_t *buf, uint8_t type, const void *payload, size_t plen) {
    put_be32(buf, (uint32_t)(1 + plen));
    buf[4] = type;
    if (plen) memcpy(buf + 5, payload, plen);
    return 5 + plen;
}

/* ---- tests ------------------------------------------------------------- */

static void test_link_local_ipv4_classifier(void) {
    CHECK(tb_net_is_link_local_ipv4("169.254.189.3"), "USB-NCM link-local address");
    CHECK(tb_net_is_link_local_ipv4("169.254.0.1"), "link-local lower boundary");
    CHECK(tb_net_is_link_local_ipv4("169.254.255.254"), "link-local upper boundary");
    CHECK(!tb_net_is_link_local_ipv4("169.255.1.1"), "outside link-local prefix");
    CHECK(!tb_net_is_link_local_ipv4("10.77.77.2"), "private LAN is not link-local");
    CHECK(!tb_net_is_link_local_ipv4("not-an-ip"), "invalid address rejected");
    CHECK(!tb_net_is_link_local_ipv4(NULL), "NULL address rejected");
}

static void test_direct_link_classifier(void) {
    CHECK(tb_net_is_direct_link("lo0", "127.0.0.1", 0, 0), "loopback is direct");
    CHECK(tb_net_is_direct_link("bridge0", "169.254.10.2", 0, 1), "Thunderbolt Bridge is direct");
    CHECK(tb_net_is_direct_link("bridge0", "10.0.0.5", 0, 1), "Thunderbolt Bridge with a manual address is direct");
    CHECK(tb_net_is_direct_link("en5", "169.254.189.3", 0, 0), "USB-NCM link-local is direct");
    CHECK(!tb_net_is_direct_link("en0", "192.168.1.20", 0, 0), "Ethernet LAN is not direct");
    CHECK(!tb_net_is_direct_link("en1", "10.0.0.7", 1, 0), "Wi-Fi LAN is not direct");
    CHECK(!tb_net_is_direct_link("en1", "169.254.3.3", 1, 0), "Wi-Fi link-local is not direct");
    CHECK(!tb_net_is_direct_link("awdl0", "169.254.3.3", 0, 0), "AirDrop peer link is not direct");
    CHECK(!tb_net_is_direct_link("utun3", "10.8.0.2", 0, 0), "VPN tunnel is not direct");
    CHECK(!tb_net_is_direct_link("", "127.0.0.1", 0, 0), "unknown interface is not direct");
    CHECK(!tb_net_is_direct_link(NULL, "169.254.1.1", 0, 0), "missing interface is not direct");
    /* PWE: only a bridge the network settings know is the cable. */
    CHECK(!tb_net_is_direct_link("bridge100", "192.168.2.1", 0, 0), "a VM / Internet Sharing bridge is not direct");
    CHECK(!tb_net_is_direct_link("bridge100", "169.254.7.7", 0, 0), "an unlisted bridge is not direct, link-local or not");
    CHECK(!tb_net_is_direct_link("bridge0", "169.254.10.2", 0, 0), "a bridge0 the settings do not list is not direct");
    CHECK(tb_net_is_direct_link("lo0", "127.0.0.1", 0, 1), "loopback is unaffected by the bridge flag");
    CHECK(tb_net_is_direct_link("en5", "169.254.189.3", 0, 1), "USB-NCM is unaffected by the bridge flag");
    CHECK(!tb_net_is_direct_link("en0", "192.168.1.20", 0, 1), "Ethernet LAN is unaffected by the bridge flag");
    {
        char bridges[64];
        const int n = tb_net_cable_bridges(bridges, sizeof(bridges));
        CHECK(n >= 0 && (n == 0) == (bridges[0] == '\0'), "cable bridge list matches its count");
        printf("net cable bridges on this Mac: %s\n", n ? bridges : "none");
    }
}

/* The accept decision (PWE): every link kind x AllowLocalNetwork x
 * compatibility mode. A refused client must also get no other right. */
static void test_accept_policy(void) {
    CHECK(tb_net_link_kind("lo0", 1) == TB_LINK_LOOPBACK, "lo0 is loopback");
    CHECK(tb_net_link_kind("bridge0", 1) == TB_LINK_CABLE, "bridge0 is the cable");
    CHECK(tb_net_link_kind("en5", 1) == TB_LINK_CABLE, "USB link-local is the cable");
    CHECK(tb_net_link_kind("en1", 0) == TB_LINK_NETWORK, "Wi-Fi is the network");
    CHECK(tb_net_link_kind("lo0", 0) == TB_LINK_NETWORK, "not direct wins over the name");
    CHECK(tb_net_link_kind("", 1) == TB_LINK_NETWORK, "unknown interface is the network");
    CHECK(tb_net_link_kind(NULL, 1) == TB_LINK_NETWORK, "missing interface is the network");

    for (int network = 0; network <= 1; network++) {
        for (int compat = 0; compat <= 1; compat++) {
            struct tb_accept_policy p;

            p = tb_net_accept_policy(TB_LINK_CABLE, network, compat);
            CHECK(p.accept && p.pairing, "cable: accepted, may pair");
            CHECK(p.plaintext == compat, "cable: unencrypted only in compatibility mode");

            p = tb_net_accept_policy(TB_LINK_LOOPBACK, network, compat);
            CHECK(p.accept && !p.pairing, "loopback: accepted, never pairs");
            CHECK(p.plaintext == compat, "loopback: unencrypted only in compatibility mode");

            p = tb_net_accept_policy(TB_LINK_NETWORK, network, compat);
            CHECK(p.accept == network, "network: accepted only with AllowLocalNetwork");
            CHECK(!p.pairing, "network: never pairs");
            CHECK(!p.plaintext, "network: never unencrypted, even in compatibility mode");
        }
    }
    CHECK(!tb_net_accept_policy((enum tb_link_kind)99, 0, 1).accept,
          "unknown link kind is refused like the network");
    CHECK(!tb_net_accept_policy((enum tb_link_kind)99, 1, 1).plaintext,
          "unknown link kind is never unencrypted");
}


/* ---- PWE: IPv6 on the cable (T34) --------------------------------------- */

static struct in6_addr a6(const char *text) {
    struct in6_addr addr;
    memset(&addr, 0, sizeof(addr));
    if (inet_pton(AF_INET6, text, &addr) != 1) {
        fprintf(stderr, "bad test address %s\n", text);
        exit(2);
    }
    return addr;
}

static void test_direct_link_ipv6_classifier(void) {
    struct in6_addr ll = a6("fe80::1c2:3ff:fe04:506"), ll_peer = a6("fe80::aa:bbff:fecc:dd");
    struct in6_addr lo = a6("::1"), lo_ll = a6("fe80::1");
    struct in6_addr ula = a6("fd03:188d:4e92:2e9::5"), global = a6("2001:db8::7");
    struct in6_addr mapped = a6("::ffff:169.254.6.224"), mapped_lo = a6("::ffff:127.0.0.1");

    /* accepted */
    CHECK(tb_net_is_direct_link_ipv6("bridge0", &ll, &ll_peer, 1), "Thunderbolt Bridge, link-local both ends");
    CHECK(tb_net_is_direct_link_ipv6("lo0", &lo, &lo, 0), "loopback ::1");
    CHECK(tb_net_is_direct_link_ipv6("lo0", &lo_ll, &lo_ll, 0), "loopback fe80::1%lo0");

    /* refused: the bridge, but not both link-local, or not the Thunderbolt one */
    CHECK(!tb_net_is_direct_link_ipv6("bridge0", &ll, &global, 1), "bridge: a global peer is not direct");
    CHECK(!tb_net_is_direct_link_ipv6("bridge0", &ll, &ula, 1), "bridge: a ULA peer is not direct");
    CHECK(!tb_net_is_direct_link_ipv6("bridge0", &ula, &ll_peer, 1), "bridge: a ULA local address is not direct");
    CHECK(!tb_net_is_direct_link_ipv6("bridge0", &global, &global, 1), "bridge: global both ends is not direct");
    CHECK(!tb_net_is_direct_link_ipv6("bridge100", &ll, &ll_peer, 0), "a VM / Internet Sharing bridge is not the cable");
    CHECK(!tb_net_is_direct_link_ipv6("bridge0", &ll, &ll_peer, 0), "a bridge the settings do not know is not the cable");
    CHECK(!tb_net_is_direct_link_ipv6("bridge0", &mapped, &mapped, 1), "IPv4-mapped is never direct over IPv6");

    /* refused: every other interface has a link-local address too */
    CHECK(!tb_net_is_direct_link_ipv6("en0", &ll, &ll_peer, 0), "Ethernet LAN link-local is not direct");
    CHECK(!tb_net_is_direct_link_ipv6("en5", &ll, &ll_peer, 0), "USB link-local over IPv6 is not direct");
    CHECK(!tb_net_is_direct_link_ipv6("en1", &ll, &ll_peer, 1), "Wi-Fi link-local is not direct");
    CHECK(!tb_net_is_direct_link_ipv6("awdl0", &ll, &ll_peer, 0), "AirDrop peer link is not direct");
    CHECK(!tb_net_is_direct_link_ipv6("llw0", &ll, &ll_peer, 0), "low-latency WLAN is not direct");
    CHECK(!tb_net_is_direct_link_ipv6("utun3", &ll, &ll_peer, 0), "VPN tunnel is not direct");
    CHECK(!tb_net_is_direct_link_ipv6("en0", &global, &global, 0), "global address is not direct");

    /* refused: loopback with a foreign address, malformed input */
    CHECK(!tb_net_is_direct_link_ipv6("lo0", &lo, &global, 0), "loopback with a global peer is not direct");
    CHECK(!tb_net_is_direct_link_ipv6("lo0", &mapped_lo, &mapped_lo, 0), "IPv4-mapped loopback is not direct");
    CHECK(!tb_net_is_direct_link_ipv6("", &ll, &ll_peer, 1), "unknown interface is not direct");
    CHECK(!tb_net_is_direct_link_ipv6(NULL, &ll, &ll_peer, 1), "missing interface is not direct");
    CHECK(!tb_net_is_direct_link_ipv6("bridge0", NULL, &ll_peer, 1), "missing local address is not direct");
    CHECK(!tb_net_is_direct_link_ipv6("bridge0", &ll, NULL, 1), "missing peer address is not direct");

    /* the accept policy downstream */
    CHECK(tb_net_link_kind("bridge0", 1) == TB_LINK_CABLE, "an IPv6 bridge peer is the cable");
    CHECK(tb_net_link_kind("en0", 0) == TB_LINK_NETWORK, "an IPv6 LAN peer is the network");
}

static void test_accept_policy_by_family(void) {
    for (int network = 0; network <= 1; network++) {
        for (int compat = 0; compat <= 1; compat++) {
            const enum tb_link_kind links[3] = { TB_LINK_NETWORK, TB_LINK_LOOPBACK, TB_LINK_CABLE };
            for (int i = 0; i < 3; i++) {
                struct tb_accept_policy v4 = tb_net_accept_policy_family(links[i], 0, network, compat);
                struct tb_accept_policy base = tb_net_accept_policy(links[i], network, compat);
                CHECK(v4.accept == base.accept && v4.pairing == base.pairing && v4.plaintext == base.plaintext,
                      "IPv4: the policy is unchanged");
            }
            struct tb_accept_policy p = tb_net_accept_policy_family(TB_LINK_NETWORK, 1, network, compat);
            CHECK(!p.accept && !p.pairing && !p.plaintext, "IPv6 off the cable: refused, AllowLocalNetwork or not");
            p = tb_net_accept_policy_family(TB_LINK_CABLE, 1, network, compat);
            CHECK(p.accept && p.pairing && p.plaintext == compat, "IPv6 cable: as IPv4 cable");
            p = tb_net_accept_policy_family(TB_LINK_LOOPBACK, 1, network, compat);
            CHECK(p.accept && !p.pairing && p.plaintext == compat, "IPv6 loopback: as IPv4 loopback");
        }
    }
    CHECK(!tb_net_accept_policy_family((enum tb_link_kind)99, 1, 1, 1).accept, "IPv6 unknown link refused");
}

static void test_cable_bridges_cached(void) {
    char list[128];
    (void)tb_net_cable_bridges(list, sizeof(list));
    const unsigned long before = tb_net_cable_bridge_reads();
    int same = 1;
    char again[128];
    for (int i = 0; i < 200; i++) {
        (void)tb_net_cable_bridges(again, sizeof(again));
        same &= strcmp(list, again) == 0;
    }
    CHECK(same, "the cable bridge list is stable between calls");
    CHECK(tb_net_cable_bridge_reads() - before <= 1, "200 calls read the system settings at most once");
}

/* Connect to `host` (an address on this Mac) on `listener`'s port, accept,
 * and classify the accepted socket. Returns -1 when the dial itself failed. */
static int classify_real_connection(int listener, int family, const char *host, unsigned scope,
                                    char *ifname, size_t ifname_size) {
    struct sockaddr_storage bound;
    socklen_t bound_len = sizeof(bound);
    if (getsockname(listener, (struct sockaddr *)&bound, &bound_len) != 0) return -1;

    struct sockaddr_storage to;
    memset(&to, 0, sizeof(to));
    socklen_t to_len;
    if (family == AF_INET6) {
        struct sockaddr_in6 *sa = (struct sockaddr_in6 *)&to;
        sa->sin6_len = sizeof(*sa);
        sa->sin6_family = AF_INET6;
        sa->sin6_port = ((struct sockaddr_in6 *)&bound)->sin6_port;
        sa->sin6_scope_id = scope;
        if (inet_pton(AF_INET6, host, &sa->sin6_addr) != 1) return -1;
        to_len = sizeof(*sa);
    } else {
        struct sockaddr_in *sa = (struct sockaddr_in *)&to;
        sa->sin_len = sizeof(*sa);
        sa->sin_family = AF_INET;
        sa->sin_port = ((struct sockaddr_in *)&bound)->sin_port;
        if (inet_pton(AF_INET, host, &sa->sin_addr) != 1) return -1;
        to_len = sizeof(*sa);
    }
    int client = socket(family, SOCK_STREAM, 0);
    if (client < 0) return -1;
    /* At most a second: an address that does not answer is skipped, not waited for. */
    fcntl(client, F_SETFL, fcntl(client, F_GETFL, 0) | O_NONBLOCK);
    if (connect(client, (struct sockaddr *)&to, to_len) != 0) {
        struct pollfd w = { client, POLLOUT, 0 };
        int err = 0;
        socklen_t err_len = sizeof(err);
        if (errno != EINPROGRESS || poll(&w, 1, 1000) != 1 ||
            getsockopt(client, SOL_SOCKET, SO_ERROR, &err, &err_len) != 0 || err != 0) {
            close(client);
            return -1;
        }
    }

    struct pollfd pfd = { listener, POLLIN, 0 };
    int verdict = -1;
    if (poll(&pfd, 1, 2000) == 1) {
        int c = tb_net_accept(listener);
        if (c >= 0) {
            verdict = tb_net_client_is_direct_link(c, ifname, ifname_size);
            close(c);
        }
    }
    close(client);
    return verdict;
}

static void test_direct_link_real_sockets(void) {
    char ifname[IFNAMSIZ];

    int l4 = tb_net_listen(0);
    CHECK(l4 >= 0, "IPv4 listener on an ephemeral port");
    if (l4 >= 0) {
        CHECK(classify_real_connection(l4, AF_INET, "127.0.0.1", 0, ifname, sizeof(ifname)) == 1,
              "IPv4 loopback client is direct (unchanged)");
        CHECK(strcmp(ifname, "lo0") == 0, "IPv4 loopback client arrived on lo0");
        close(l4);
    }

    int l6 = tb_net_listen6(0);
    CHECK(l6 >= 0, "IPv6 listener on an ephemeral port");
    if (l6 < 0) return;

    CHECK(classify_real_connection(l6, AF_INET6, "::1", 0, ifname, sizeof(ifname)) == 1,
          "IPv6 ::1 client is direct");
    CHECK(strcmp(ifname, "lo0") == 0 && tb_net_link_kind(ifname, 1) == TB_LINK_LOOPBACK,
          "IPv6 ::1 client is loopback, not the cable");
    CHECK(classify_real_connection(l6, AF_INET6, "fe80::1", if_nametoindex("lo0"), ifname, sizeof(ifname)) == 1,
          "IPv6 fe80::1%lo0 client is direct");
    CHECK(strcmp(ifname, "lo0") == 0, "IPv6 fe80::1%lo0 client arrived on lo0");

    /* Refusals with real sockets: this Mac's own addresses on Wi-Fi or
     * Ethernet. Skipped when there is none. */
    int tried_ll = 0, tried_other = 0;
    struct ifaddrs *ifap = NULL;
    if (getifaddrs(&ifap) == 0) {
        for (struct ifaddrs *p = ifap; p; p = p->ifa_next) {
            if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET6) continue;
            /* Wi-Fi and Ethernet: where a stranger on the same network would come from. */
            if (strncmp(p->ifa_name, "en", 2) != 0) continue;
            if ((p->ifa_flags & IFF_UP) == 0) continue;
            struct sockaddr_in6 sa;
            memcpy(&sa, p->ifa_addr, sizeof(sa));
            const int ll = IN6_IS_ADDR_LINKLOCAL(&sa.sin6_addr);
            if ((ll && tried_ll) || (!ll && tried_other)) continue;
            unsigned scope = sa.sin6_scope_id;
            if (ll) {   /* the KAME-embedded scope, if any */
                if (!scope) scope = ((unsigned)sa.sin6_addr.s6_addr[2] << 8) | sa.sin6_addr.s6_addr[3];
                sa.sin6_addr.s6_addr[2] = sa.sin6_addr.s6_addr[3] = 0;
            }
            char host[INET6_ADDRSTRLEN];
            inet_ntop(AF_INET6, &sa.sin6_addr, host, sizeof(host));
            int v = classify_real_connection(l6, AF_INET6, host, scope, ifname, sizeof(ifname));
            if (v < 0) continue;   /* an address that does not take connections (tentative, ...) */
            char what[160];
            snprintf(what, sizeof(what), "IPv6 client on %s (%s) is refused as not direct", p->ifa_name, host);
            CHECK(v == 0, what);
            snprintf(what, sizeof(what), "IPv6 client on %s refused even with AllowLocalNetwork", p->ifa_name);
            CHECK(!tb_net_accept_policy_family(tb_net_link_kind(ifname, v), 1, 1, 1).accept, what);
            if (ll) tried_ll = 1; else tried_other = 1;
        }
        freeifaddrs(ifap);
    }
    printf("net IPv6 real-socket refusals: link-local %s, other %s\n",
           tried_ll ? "checked" : "skipped (none on this Mac)",
           tried_other ? "checked" : "skipped (none on this Mac)");
    close(l6);
}

static void test_single_packet_whole_feed(void) {
    struct tb_parser p;
    tb_parser_init(&p, capture_cb, NULL);
    reset_capture();

    uint8_t pkt[64];
    size_t n = build_packet(pkt, TB_PKT_HELLO_RECEIVER, "hi", 2);

    CHECK(tb_parser_feed(&p, pkt, n) == 0, "feed should succeed");
    CHECK(g_captured_count == 1, "exactly one packet");
    CHECK(g_captured[0].type == TB_PKT_HELLO_RECEIVER, "type preserved");
    CHECK(g_captured[0].len == 2, "payload length preserved");
    CHECK(memcmp(g_captured[0].payload, "hi", 2) == 0, "payload bytes preserved");
    CHECK(g_captured[0].had_nul_sentinel, "NUL sentinel past payload");

    tb_parser_free(&p);
}

static void test_byte_by_byte_feed(void) {
    struct tb_parser p;
    tb_parser_init(&p, capture_cb, NULL);
    reset_capture();

    uint8_t pkt[64];
    size_t n = build_packet(pkt, TB_PKT_HEARTBEAT, "\x01\x02\x03", 3);

    for (size_t i = 0; i < n; i++) {
        CHECK(tb_parser_feed(&p, pkt + i, 1) == 0, "fragmented feed should succeed");
        if (i < n - 1) {
            CHECK(g_captured_count == 0, "must not fire before final byte");
        }
    }
    CHECK(g_captured_count == 1, "fires exactly once at final byte");
    CHECK(g_captured[0].len == 3, "payload length preserved across fragments");

    tb_parser_free(&p);
}

static void test_two_contiguous_packets(void) {
    struct tb_parser p;
    tb_parser_init(&p, capture_cb, NULL);
    reset_capture();

    uint8_t buf[128];
    size_t n1 = build_packet(buf, TB_PKT_HELLO_RECEIVER, "first", 5);
    size_t n2 = build_packet(buf + n1, TB_PKT_HEARTBEAT, "second!", 7);

    CHECK(tb_parser_feed(&p, buf, n1 + n2) == 0, "feed should succeed");
    CHECK(g_captured_count == 2, "both packets fire");
    CHECK(g_captured[0].type == TB_PKT_HELLO_RECEIVER, "first type");
    CHECK(memcmp(g_captured[0].payload, "first", 5) == 0, "first payload");
    /* The NUL sentinel for packet 1 lands on packet 2's length byte; the
     * save/restore in net.c must leave packet 2 intact. */
    CHECK(g_captured[1].type == TB_PKT_HEARTBEAT, "second type intact after sentinel restore");
    CHECK(g_captured[1].len == 7, "second length intact");
    CHECK(memcmp(g_captured[1].payload, "second!", 7) == 0, "second payload intact");

    tb_parser_free(&p);
}

static void test_split_across_feeds_with_remainder(void) {
    struct tb_parser p;
    tb_parser_init(&p, capture_cb, NULL);
    reset_capture();

    uint8_t buf[128];
    size_t n1 = build_packet(buf, TB_PKT_PARAM_SETS, "abcd", 4);
    size_t n2 = build_packet(buf + n1, TB_PKT_FRAME, "efghij", 6);

    /* Feed 1.5 packets, then the rest. */
    size_t first_chunk = n1 + 3;
    CHECK(tb_parser_feed(&p, buf, first_chunk) == 0, "first chunk ok");
    CHECK(g_captured_count == 1, "only complete packet fires");
    CHECK(tb_parser_feed(&p, buf + first_chunk, n1 + n2 - first_chunk) == 0, "second chunk ok");
    CHECK(g_captured_count == 2, "remainder completes second packet");
    CHECK(g_captured[1].type == TB_PKT_FRAME, "second packet type");
    CHECK(memcmp(g_captured[1].payload, "efghij", 6) == 0, "second packet payload");

    tb_parser_free(&p);
}

static void test_zero_length_is_fatal(void) {
    struct tb_parser p;
    tb_parser_init(&p, capture_cb, NULL);
    reset_capture();

    uint8_t bad[5] = {0x00, 0x00, 0x00, 0x00, 0x30};
    CHECK(tb_parser_feed(&p, bad, sizeof(bad)) == -1, "pkt_len=0 must be rejected");
    CHECK(g_captured_count == 0, "no callback for corrupt framing");

    tb_parser_free(&p);
}

static void test_oversized_length_is_fatal(void) {
    struct tb_parser p;
    tb_parser_init(&p, capture_cb, NULL);
    reset_capture();

    uint8_t bad[5];
    put_be32(bad, 64u * 1024 * 1024 + 1);  /* one past the 64 MiB sanity cap */
    bad[4] = 0x21;
    CHECK(tb_parser_feed(&p, bad, sizeof(bad)) == -1, "oversized pkt_len must be rejected");

    uint8_t worst[5] = {0xFF, 0xFF, 0xFF, 0xFF, 0x21};
    struct tb_parser p2;
    tb_parser_init(&p2, capture_cb, NULL);
    CHECK(tb_parser_feed(&p2, worst, sizeof(worst)) == -1, "0xFFFFFFFF pkt_len must be rejected");

    tb_parser_free(&p);
    tb_parser_free(&p2);
}

static void test_large_payload_roundtrip(void) {
    struct tb_parser p;
    tb_parser_init(&p, capture_cb, NULL);
    reset_capture();

    size_t plen = 1024 * 1024;  /* 1 MiB, exercises parser_reserve growth */
    uint8_t *pkt = malloc(5 + plen);
    CHECK(pkt != NULL, "alloc");
    if (!pkt) return;
    put_be32(pkt, (uint32_t)(1 + plen));
    pkt[4] = TB_PKT_FRAME;
    for (size_t i = 0; i < plen; i++) pkt[5 + i] = (uint8_t)(i * 31);

    /* Feed in 64 KiB slices like a real socket drain. */
    size_t off = 0, total = 5 + plen;
    while (off < total) {
        size_t chunk = total - off > 65536 ? 65536 : total - off;
        CHECK(tb_parser_feed(&p, pkt + off, chunk) == 0, "chunked feed ok");
        off += chunk;
    }
    CHECK(g_captured_count == 1, "large packet fires once");
    CHECK(g_captured[0].len == plen, "large payload length preserved");

    free(pkt);
    tb_parser_free(&p);
}

int main(void) {
    test_link_local_ipv4_classifier();
    test_direct_link_classifier();
    test_accept_policy();
    test_direct_link_ipv6_classifier();
    test_direct_link_real_sockets();
    test_accept_policy_by_family();
    test_cable_bridges_cached();
    test_single_packet_whole_feed();
    test_byte_by_byte_feed();
    test_two_contiguous_packets();
    test_split_across_feeds_with_remainder();
    test_zero_length_is_fatal();
    test_oversized_length_is_fatal();
    test_large_payload_roundtrip();

    if (g_failures == 0) {
        printf("net parser tests: %d checks passed\n", g_checks);
        return 0;
    }
    fprintf(stderr, "net parser tests: %d/%d checks FAILED\n", g_failures, g_checks);
    return 1;
}
