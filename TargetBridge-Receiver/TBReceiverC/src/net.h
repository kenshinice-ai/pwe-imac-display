/* net.h — POSIX socket server + packet parser.
 * No ObjC, no ARC, no autoreleasepool. Pure C.
 */

#ifndef TB_NET_H
#define TB_NET_H

#include <stdint.h>
#include <stddef.h>

/* Packet callback: called for each complete packet parsed from the stream. */
typedef void (*tb_pkt_cb)(uint8_t type, const uint8_t *payload, size_t len, void *ud);

/* Streaming packet parser (handles fragmented TCP reads). */
struct tb_parser {
    uint8_t   *buf;
    size_t     len;     /* used bytes */
    size_t     cap;     /* allocated capacity */
    tb_pkt_cb  cb;
    void      *ud;
};

void tb_parser_init  (struct tb_parser *p, tb_pkt_cb cb, void *ud);
void tb_parser_free  (struct tb_parser *p);
int  tb_parser_feed  (struct tb_parser *p, const uint8_t *data, size_t n);

/* Server: returns listening fd (>=0) or -1 on failure. Non-blocking. */
int  tb_net_listen   (uint16_t port);

/* PWE: the same server on IPv6 (IPV6_V6ONLY, so the IPv4 socket above keeps
 * every IPv4 client). A Thunderbolt Bridge has an IPv6 link-local address
 * within a second of the cable going in; its IPv4 link-local address waits
 * for DHCP to give up, about 19 s on a "Using DHCP" bridge (T34). Returns -1
 * when the system has no IPv6; the receiver then runs on IPv4 alone. */
int  tb_net_listen6  (uint16_t port);

/* Accept one client. Returns client fd or -1. Sets non-blocking. */
int  tb_net_accept   (int server_fd);

/* Returns the IPv4 link-local address of the Thunderbolt Bridge (a bridge*
 * the network settings know, as for the cable rule) in buf.
 * buf size must be at least INET_ADDRSTRLEN (16) bytes. Returns 0 on success. */
int  tb_net_get_tb_ip(char *buf, size_t bufsz);

/* PWE: the Thunderbolt Bridge's IPv6 link-local address, without a scope
 * ("fe80::…"), and the bridge's interface index. Only a bridge the system's
 * network settings know (the Thunderbolt Bridge; a VM's or Internet Sharing's
 * bridge is not one), up and running, with a usable address: one still in
 * optimistic duplicate address detection counts, a duplicate does not.
 * buf: at least INET6_ADDRSTRLEN (46) bytes. Returns 0 on success. */
int  tb_net_get_tb_ip6(char *buf, size_t bufsz, unsigned int *ifindex);

/* Returns IP address of the first non-Thunderbolt enX/ethX interface using
 * IPv4 link-local addressing (169.254/16). macOS exposes direct USB-NCM
 * Mac-to-Mac links this way. Returns 0 on success. */
int  tb_net_get_link_local_ip(char *buf, size_t bufsz);

/* Returns IP address of a likely local LAN interface (for example en0/eth0, RFC1918 IPv4).
 * buf size must be at least INET_ADDRSTRLEN (16) bytes. Returns 0 on success. */
int  tb_net_get_lan_ip(char *buf, size_t bufsz);

/* Returns RFC1918 IPv4 addresses for the physical Ethernet and Wi-Fi
 * interfaces independently. Interface roles are resolved from macOS
 * SystemConfiguration instead of assuming en0/en1 numbering. */
int  tb_net_get_ethernet_ip(char *buf, size_t bufsz);
int  tb_net_get_wifi_ip(char *buf, size_t bufsz);

/* Address classifier exposed for hardware-free unit tests. */
int  tb_net_is_link_local_ipv4(const char *host);

/* Whether a connection that arrived on interface `ifname` at local address
 * `local_host` came over a direct cable rather than a shared network:
 * loopback, the Thunderbolt Bridge, or a link-local address on a wired
 * enX/ethX interface (direct USB networking). Wi-Fi never counts.
 * PWE: a bridge* counts only with `is_cable_bridge`, a bridge the system's
 * network settings know (tb_net_cable_bridges). Exposed for hardware-free
 * unit tests. */
int  tb_net_is_direct_link(const char *ifname, const char *local_host, int is_wifi,
                           int is_cable_bridge);

/* PWE: the bridges that count as the cable, as "bridge0" or "bridge0, bridge1"
 * ("" if none). Returns how many. Cached (net.c); never on the frame path. */
int  tb_net_cable_bridges(char *buf, size_t bufsz);
/* The same with each bridge's member interfaces, for the start-up log:
 * "bridge0 (en1, en2, en3)". Runs ifconfig: call it once, not in a loop. */
int  tb_net_describe_cable_bridges(char *buf, size_t bufsz);
/* How many times the list was read from SystemConfiguration (tests). */
unsigned long tb_net_cable_bridge_reads(void);

/* PWE: the same question for an IPv6 connection, hardware-free for unit tests.
 * Direct only when both ends are link-local on the Thunderbolt Bridge
 * (`is_cable_bridge`: a bridge* interface the system's network settings know),
 * or both are loopback / link-local on lo*. Every other interface is not
 * direct over IPv6, wired ones included: each of them has a link-local
 * address, so it says nothing about a cable. IPv4-mapped addresses never are. */
struct in6_addr;
int  tb_net_is_direct_link_ipv6(const char *ifname, const struct in6_addr *local,
                                const struct in6_addr *peer, int is_cable_bridge);

/* Classify an accepted client socket (IPv4 or IPv6) by the local interface it
 * arrived on. Returns 1 for a direct link, 0 otherwise. Writes the interface
 * name to `ifname` when known. */
int  tb_net_client_is_direct_link(int fd, char *ifname, size_t ifname_size);

/* ---- PWE: accept policy ----------------------------------------------------
 * What a new client may do, decided from the link it arrived on before a
 * single byte of it is read. */
enum tb_link_kind {
    TB_LINK_NETWORK = 0,   /* Wi-Fi, Ethernet LAN, VPN, unknown */
    TB_LINK_LOOPBACK,      /* this Mac (tests, local tools) */
    TB_LINK_CABLE          /* Thunderbolt Bridge, or wired link-local (USB) */
};

/* `direct` is tb_net_client_is_direct_link's verdict for `ifname`. */
enum tb_link_kind tb_net_link_kind(const char *ifname, int direct);

struct tb_accept_policy {
    int accept;      /* 0: close the socket before reading anything */
    int pairing;     /* may pair (the iMac shows a code): the cable only */
    int plaintext;   /* may stay unencrypted (compatibility mode) */
};

/* network_allowed: the build accepts every interface (DIRECT_LINK_ONLY=0) or
 * the user set AllowLocalNetwork. compat_mode: unencrypted connections are
 * allowed (AllowUnencryptedConnections).
 *   cable    -> accepted; pairing; unencrypted if compat_mode
 *   loopback -> accepted; no pairing; unencrypted if compat_mode
 *   network  -> refused unless network_allowed; then encrypted sessions of
 *               an already paired Mac only (no pairing, never unencrypted) */
struct tb_accept_policy tb_net_accept_policy(enum tb_link_kind link,
                                             int network_allowed, int compat_mode);

/* PWE: the same for a connection on the IPv4 (ipv6 = 0) or IPv6 listener.
 * IPv6: the cable and loopback as above; anything else is refused even when
 * network_allowed (Network Link dials IPv4 addresses only). */
struct tb_accept_policy tb_net_accept_policy_family(enum tb_link_kind link, int ipv6,
                                                    int network_allowed, int compat_mode);

/* ---- PWE: secure connection (tb_conn.c) ----------------------------------
 * One client connection: bytes in -> packets -> handshake or decryption ->
 * the usual packet callback. A connection whose first packet is SEC_HELLO is
 * encrypted from the handshake on; any other first packet makes it an
 * unencrypted (compatibility) connection, accepted only when allowed and then
 * limited to picture, sound, brightness and volume (pwe_sec_plaintext_allowed).
 *
 * Until the connection is decided (TB_CONN_SECURE or TB_CONN_PLAINTEXT),
 * tb_conn_send withholds everything: send the display profile on the
 * TB_CONN_EV_READY event, not on accept. */
struct pwe_sec;
struct pwe_sec_identity;
struct pwe_sec_store;
struct pwe_sec_gate;

enum tb_conn_mode {
    TB_CONN_UNDECIDED = 0,
    TB_CONN_HANDSHAKE,
    TB_CONN_SECURE,
    TB_CONN_PLAINTEXT,
    TB_CONN_CLOSED
};

struct tb_conn_config {
    const struct pwe_sec_identity *identity;
    const struct pwe_sec_store    *store;
    struct pwe_sec_gate           *gate;
    int direct_link;       /* the peer is on the cable: pairing is allowed */
    int allow_plaintext;   /* compatibility mode: accept unencrypted senders */
};

/* Events: pwe_sec_event bits (code to show, paired, locked, ...) plus these. */
#define TB_CONN_EV_READY              (1 << 16)  /* secure or plaintext: start the session */
#define TB_CONN_EV_PLAINTEXT          (1 << 17)  /* this session is not encrypted: warn */
#define TB_CONN_EV_PLAINTEXT_REFUSED  (1 << 18)  /* an unencrypted sender was turned away */
#define TB_CONN_EV_SECURITY_FAILED    (1 << 19)  /* handshake or record failure: closing */

struct tb_conn;
typedef void (*tb_conn_ev_cb)(struct tb_conn *c, int events, void *ud);

struct tb_conn {
    int                   fd;
    enum tb_conn_mode     mode;
    struct tb_parser      parser;
    struct pwe_sec       *sec;
    struct tb_conn_config cfg;
    tb_pkt_cb             on_packet;
    tb_conn_ev_cb         on_event;
    void                 *ud;
    uint8_t              *tx;
    size_t                tx_cap;
    int                   want_close;
    uint64_t              now_ms;
    unsigned long         withheld;   /* plaintext packets dropped by policy */
    uint64_t              opened_ms;  /* monotonic, at tb_conn_init */
};

int  tb_conn_init (struct tb_conn *c, int fd, const struct tb_conn_config *cfg,
                   tb_pkt_cb on_packet, tb_conn_ev_cb on_event, void *ud);
/* Returns -1 when the connection must be closed. */
int  tb_conn_feed (struct tb_conn *c, const uint8_t *data, size_t n, uint64_t now_ms);
/* 0 sent, 1 withheld (not decided yet, or not allowed unencrypted), -1 error. */
int  tb_conn_send (struct tb_conn *c, uint8_t type, const uint8_t *payload, size_t len);
/* The same for an already framed packet [BE32 len][type][payload]. */
int  tb_conn_send_packet(struct tb_conn *c, const uint8_t *pkt, size_t len);
/* Every loop while connected. An older sender may wait for the display profile
 * before it sends anything, as the receiver used to send it on accept: after
 * TB_CONN_SILENT_SENDER_MS of silence, with unencrypted connections allowed,
 * the connection becomes unencrypted (TB_CONN_EV_READY | TB_CONN_EV_PLAINTEXT).
 * A PWE sender's HELLO arrives within milliseconds of the connection. */
#define TB_CONN_SILENT_SENDER_MS 2000
void tb_conn_tick(struct tb_conn *c);
/* About once a second, connected or not (gate may be shared): expires the code. */
int  tb_conn_gate_tick(struct pwe_sec_gate *gate, uint64_t now_ms);
int  tb_conn_is_secure (const struct tb_conn *c);
int  tb_conn_is_pairing(const struct tb_conn *c);
/* Closes the socket and wipes the keys; reports a pairing attempt cut short. */
void tb_conn_close(struct tb_conn *c, uint64_t now_ms);
/* ---- end PWE ------------------------------------------------------------- */

#endif
