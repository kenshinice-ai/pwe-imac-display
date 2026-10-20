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

/* Accept one client. Returns client fd or -1. Sets non-blocking. */
int  tb_net_accept   (int server_fd);

/* Returns IP address of first bridge* interface (Thunderbolt Bridge) in buf.
 * buf size must be at least INET_ADDRSTRLEN (16) bytes. Returns 0 on success. */
int  tb_net_get_tb_ip(char *buf, size_t bufsz);

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
 * loopback, Thunderbolt Bridge (bridge*), or a link-local address on a wired
 * enX/ethX interface (direct USB networking). Wi-Fi never counts. Exposed for
 * hardware-free unit tests. */
int  tb_net_is_direct_link(const char *ifname, const char *local_host, int is_wifi);

/* Classify an accepted client socket by the local interface it arrived on.
 * Returns 1 for a direct link, 0 otherwise. Writes the interface name to
 * `ifname` when known. */
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
