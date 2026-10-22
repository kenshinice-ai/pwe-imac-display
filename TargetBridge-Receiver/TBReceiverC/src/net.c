/* net.c — POSIX socket server + packet parser. */

#include "net.h"
#include "proto.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <netinet6/in6_var.h>   /* SIOCGIFAFLAG_IN6, IN6_IFF_* */
#endif

#if defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <SystemConfiguration/SystemConfiguration.h>
#endif

/* ---- Parser ----------------------------------------------------------- */

void tb_parser_init(struct tb_parser *p, tb_pkt_cb cb, void *ud) {
    p->buf = NULL;
    p->len = 0;
    p->cap = 0;
    p->cb  = cb;
    p->ud  = ud;
}

void tb_parser_free(struct tb_parser *p) {
    free(p->buf);
    p->buf = NULL;
    p->len = p->cap = 0;
}

static int parser_reserve(struct tb_parser *p, size_t need) {
    if (p->cap >= need) return 0;
    size_t nc = p->cap ? p->cap : 65536;
    while (nc < need) nc *= 2;
    uint8_t *nb = (uint8_t *)realloc(p->buf, nc);
    if (!nb) return -1;
    p->buf = nb;
    p->cap = nc;
    return 0;
}

static uint32_t read_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8)  |  (uint32_t)p[3];
}

int tb_parser_feed(struct tb_parser *p, const uint8_t *data, size_t n) {
    if (parser_reserve(p, p->len + n + 1) < 0) return -1;  /* +1 for NUL sentinel */
    memcpy(p->buf + p->len, data, n);
    p->len += n;

    size_t off = 0;
    while (p->len - off >= TB_HDR_BYTES) {
        uint32_t pkt_len = read_be32(p->buf + off);
        if (pkt_len < 1 || pkt_len > 64 * 1024 * 1024) {  /* sanity */
            fprintf(stderr, "[net] bad pkt_len=%u\n", pkt_len);
            return -1;
        }
        if (p->len - off < 4 + pkt_len) break;       /* incomplete */

        uint8_t        type    = p->buf[off + 4];
        const uint8_t *payload = p->buf + off + 5;
        size_t         plen    = pkt_len - 1;
        /* Write a NUL sentinel one byte past the payload so that string
         * functions in the callback (strstr, strchr, strtol, …) cannot
         * read beyond the packet boundary.  The +1 reservation above
         * guarantees this byte is always within the allocated buffer.
         * Save and restore the byte so a following packet's header is
         * not corrupted when two packets are contiguous in the buffer. */
        uint8_t       *sentinel = (uint8_t *)(payload + plen);
        uint8_t        saved    = *sentinel;
        *sentinel = '\0';
        p->cb(type, payload, plen, p->ud);
        *sentinel = saved;
        off += 4 + pkt_len;
    }

    /* shift remainder to front */
    if (off > 0) {
        size_t rem = p->len - off;
        if (rem > 0) memmove(p->buf, p->buf + off, rem);
        p->len = rem;
    }
    return 0;
}

/* ---- Server ----------------------------------------------------------- */

int tb_net_listen(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("[net] socket"); return -1; }

    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family      = AF_INET;
    a.sin_port        = htons(port);
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) < 0) {
        /* The caller reads errno (EADDRINUSE: another receiver); close() must not clobber it. */
        const int saved = errno;
        perror("[net] bind"); close(fd); errno = saved; return -1;
    }
    if (listen(fd, 1) < 0) {
        const int saved = errno;
        perror("[net] listen"); close(fd); errno = saved; return -1;
    }

    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    return fd;
}

int tb_net_listen6(uint16_t port) {
    int fd = socket(AF_INET6, SOCK_STREAM, 0);
    if (fd < 0) { perror("[net] socket (IPv6)"); return -1; }

    int yes = 1;
    /* IPv6 only: IPv4 clients stay on tb_net_listen's socket, where they are
     * classified exactly as before. */
    if (setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, sizeof(yes)) < 0) {
        perror("[net] IPV6_V6ONLY"); close(fd); return -1;
    }
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

    struct sockaddr_in6 a;
    memset(&a, 0, sizeof(a));
    a.sin6_len    = sizeof(a);
    a.sin6_family = AF_INET6;
    a.sin6_port   = htons(port);
    a.sin6_addr   = in6addr_any;
    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) < 0) {
        /* The caller reads errno (EADDRINUSE: another receiver); close() must not clobber it. */
        const int saved = errno;
        perror("[net] bind (IPv6)"); close(fd); errno = saved; return -1;
    }
    if (listen(fd, 1) < 0) {
        const int saved = errno;
        perror("[net] listen (IPv6)"); close(fd); errno = saved; return -1;
    }

    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    return fd;
}

int tb_net_accept(int server_fd) {
    int c = accept(server_fd, NULL, NULL);
    if (c < 0) return -1;
    int fl = fcntl(c, F_GETFL, 0);
    fcntl(c, F_SETFL, fl | O_NONBLOCK);
    int rcvbuf = 4 * 1024 * 1024;
    setsockopt(c, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
    /* disable Nagle for low latency */
    int yes = 1;
    setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
    /* Detect half-open peers (sender crashed / cable pulled without a FIN):
     * probe after 5s idle, every 5s, twice — the OS then errors the fd
     * instead of leaving the session wedged. Complements the app-level
     * idle watchdog in main.c. */
    setsockopt(c, SOL_SOCKET, SO_KEEPALIVE, &yes, sizeof(yes));
    int keep_idle = 5;
    setsockopt(c, IPPROTO_TCP, TCP_KEEPALIVE, &keep_idle, sizeof(keep_idle));
    int keep_intvl = 5;
    setsockopt(c, IPPROTO_TCP, TCP_KEEPINTVL, &keep_intvl, sizeof(keep_intvl));
    int keep_cnt = 2;
    setsockopt(c, IPPROTO_TCP, TCP_KEEPCNT, &keep_cnt, sizeof(keep_cnt));
    return c;
}

/* ---- TB Bridge IP discovery ------------------------------------------- */

static int is_likely_lan_interface_name(const char *name) {
    if (!name) return 0;
    if (strncmp(name, "lo", 2) == 0) return 0;
    if (strncmp(name, "utun", 4) == 0) return 0;
    if (strncmp(name, "awdl", 4) == 0) return 0;
    if (strncmp(name, "llw", 3) == 0) return 0;
    return strncmp(name, "en", 2) == 0 || strncmp(name, "eth", 3) == 0;
}

static int is_rfc1918_ipv4(const char *host) {
    if (!host) return 0;
    if (strncmp(host, "10.", 3) == 0) return 1;
    if (strncmp(host, "192.168.", 8) == 0) return 1;

    unsigned int a = 0, b = 0, c = 0, d = 0;
    if (sscanf(host, "%u.%u.%u.%u", &a, &b, &c, &d) != 4) return 0;
    return a == 172 && b >= 16 && b <= 31;
}

enum tb_lan_interface_kind {
    TB_LAN_INTERFACE_ETHERNET = 1,
    TB_LAN_INTERFACE_WIFI = 2
};

static int interface_matches_kind(const char *name, enum tb_lan_interface_kind kind) {
    if (!name || !*name) return 0;
#if defined(__APPLE__)
    CFArrayRef interfaces = SCNetworkInterfaceCopyAll();
    if (!interfaces) return 0;
    int matched = 0;
    CFIndex count = CFArrayGetCount(interfaces);
    for (CFIndex index = 0; index < count; index++) {
        SCNetworkInterfaceRef interface = (SCNetworkInterfaceRef)CFArrayGetValueAtIndex(interfaces, index);
        CFStringRef bsd_name = SCNetworkInterfaceGetBSDName(interface);
        CFStringRef interface_type = SCNetworkInterfaceGetInterfaceType(interface);
        if (!bsd_name || !interface_type) continue;

        char candidate_name[IFNAMSIZ] = {0};
        if (!CFStringGetCString(bsd_name, candidate_name, sizeof(candidate_name), kCFStringEncodingUTF8)) continue;
        if (strcmp(candidate_name, name) != 0) continue;

        CFStringRef expected_type = kind == TB_LAN_INTERFACE_WIFI
            ? kSCNetworkInterfaceTypeIEEE80211
            : kSCNetworkInterfaceTypeEthernet;
        matched = CFEqual(interface_type, expected_type);
        break;
    }
    CFRelease(interfaces);
    return matched;
#else
    if (kind == TB_LAN_INTERFACE_WIFI) {
        return strncmp(name, "wlan", 4) == 0 || strncmp(name, "wifi", 4) == 0;
    }
    return strncmp(name, "en", 2) == 0 || strncmp(name, "eth", 3) == 0;
#endif
}

static int get_lan_ip_for_kind(char *buf, size_t bufsz, enum tb_lan_interface_kind kind) {
    struct ifaddrs *ifap = NULL;
    if (!buf || bufsz == 0) return -1;
    buf[0] = '\0';
    if (getifaddrs(&ifap) != 0) return -1;

    int ret = -1;
    for (struct ifaddrs *p = ifap; p; p = p->ifa_next) {
        if (!p->ifa_addr) continue;
        if (p->ifa_addr->sa_family != AF_INET) continue;
        if (!interface_matches_kind(p->ifa_name, kind)) continue;

        char host[NI_MAXHOST];
        if (getnameinfo(p->ifa_addr, sizeof(struct sockaddr_in),
                        host, sizeof(host), NULL, 0, NI_NUMERICHOST) == 0 &&
            is_rfc1918_ipv4(host)) {
            snprintf(buf, bufsz, "%s", host);
            ret = 0;
            break;
        }
    }
    freeifaddrs(ifap);
    return ret;
}

/* ---- PWE: IPv6 on the Thunderbolt Bridge ---------------------------------- */

/* macOS may hand out a link-local address with its scope embedded in bytes
 * 2-3 (the KAME convention; getifaddrs on some releases). Move it to *scope
 * and clear it, so addresses compare and print the same everywhere. */
static void in6_take_embedded_scope(struct in6_addr *addr, uint32_t *scope) {
    if (!IN6_IS_ADDR_LINKLOCAL(addr)) return;
    uint32_t embedded = ((uint32_t)addr->s6_addr[2] << 8) | addr->s6_addr[3];
    if (embedded && scope && *scope == 0) *scope = embedded;
    addr->s6_addr[2] = 0;
    addr->s6_addr[3] = 0;
}

/* Bridges the system's network settings know: the Thunderbolt Bridge.
 * SystemConfiguration lists configured bridges only, so a bridge made on the
 * fly for a virtual machine or Internet Sharing (bridge100, ...) is not one.
 *
 * Asking SystemConfiguration takes milliseconds, and the receiver asks every
 * second (address check) and on every connection: the answer is cached, and
 * read again after 15 s or when the set of bridge interfaces changes. Systems
 * without SystemConfiguration have none: no bridge counts as the cable. */
#define TB_CABLE_BRIDGES_MAX 8
#define TB_CABLE_BRIDGES_TTL_MS 15000
static struct {
    char          names[TB_CABLE_BRIDGES_MAX][IFNAMSIZ];
    int           n;
    int           valid;
    uint64_t      read_ms;
    char          present[256];   /* the bridge interfaces when it was read */
    unsigned long reads;          /* SystemConfiguration reads, for tests */
} g_cable;

static uint64_t net_mono_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

/* The bridge interfaces that exist now, by name: "bridge0;bridge100;". */
static void present_bridges(char *out, size_t size) {
    out[0] = '\0';
    struct ifaddrs *ifap = NULL;
    if (getifaddrs(&ifap) != 0) return;
    size_t used = 0;
    for (struct ifaddrs *p = ifap; p; p = p->ifa_next) {
#if defined(AF_LINK)
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_LINK) continue;
#endif
        if (strncmp(p->ifa_name, "bridge", 6) != 0) continue;
        int w = snprintf(out + used, size - used, "%s;", p->ifa_name);
        if (w < 0 || (size_t)w >= size - used) break;
        used += (size_t)w;
    }
    freeifaddrs(ifap);
}

static void cable_bridges_refresh(void) {
    char present[sizeof(g_cable.present)];
    present_bridges(present, sizeof(present));
    const uint64_t now = net_mono_ms();
    if (g_cable.valid && now - g_cable.read_ms < TB_CABLE_BRIDGES_TTL_MS &&
        strcmp(present, g_cable.present) == 0) return;

    int n = 0;
#if defined(__APPLE__)
    CFArrayRef interfaces = SCNetworkInterfaceCopyAll();
    if (interfaces) {
        CFIndex count = CFArrayGetCount(interfaces);
        for (CFIndex index = 0; index < count && n < TB_CABLE_BRIDGES_MAX; index++) {
            SCNetworkInterfaceRef interface = (SCNetworkInterfaceRef)CFArrayGetValueAtIndex(interfaces, index);
            CFStringRef bsd_name = SCNetworkInterfaceGetBSDName(interface);
            char candidate[IFNAMSIZ] = {0};
            if (!bsd_name || !CFStringGetCString(bsd_name, candidate, sizeof(candidate), kCFStringEncodingUTF8)) continue;
            if (strncmp(candidate, "bridge", 6) != 0) continue;
            snprintf(g_cable.names[n++], IFNAMSIZ, "%s", candidate);
        }
        CFRelease(interfaces);
    }
#endif
    g_cable.n = n;
    g_cable.valid = 1;
    g_cable.read_ms = now;
    g_cable.reads++;
    snprintf(g_cable.present, sizeof(g_cable.present), "%s", present);
}

static int interface_is_cable_bridge(const char *name) {
    if (!name || strncmp(name, "bridge", 6) != 0) return 0;
    cable_bridges_refresh();
    for (int i = 0; i < g_cable.n; i++)
        if (strcmp(g_cable.names[i], name) == 0) return 1;
    return 0;
}

int tb_net_cable_bridges(char *buf, size_t bufsz) {
    if (!buf || bufsz == 0) return 0;
    buf[0] = '\0';
    cable_bridges_refresh();
    size_t used = 0;
    for (int i = 0; i < g_cable.n; i++) {
        int w = snprintf(buf + used, bufsz - used, "%s%s", i ? ", " : "", g_cable.names[i]);
        if (w < 0 || (size_t)w >= bufsz - used) break;
        used += (size_t)w;
    }
    return g_cable.n;
}

unsigned long tb_net_cable_bridge_reads(void) { return g_cable.reads; }

int tb_net_describe_cable_bridges(char *buf, size_t bufsz) {
    if (!buf || bufsz == 0) return 0;
    buf[0] = '\0';
    cable_bridges_refresh();
    size_t used = 0;
    for (int i = 0; i < g_cable.n; i++) {
        char members[160] = "";
#if defined(__APPLE__)
        /* For the log only: the members as ifconfig lists them. The name is
         * "bridge" and digits (SystemConfiguration), safe on a command line. */
        int digits = g_cable.names[i][6] != '\0';
        for (const char *c = g_cable.names[i] + 6; *c; c++) digits &= (*c >= '0' && *c <= '9');
        char cmd[64];
        FILE *f = NULL;
        if (digits) {
            snprintf(cmd, sizeof(cmd), "/sbin/ifconfig %s 2>/dev/null", g_cable.names[i]);
            f = popen(cmd, "r");
        }
        if (f) {
            char line[256];
            size_t mused = 0;
            while (fgets(line, sizeof(line), f)) {
                char member[IFNAMSIZ];
                if (sscanf(line, " member: %15s", member) != 1) continue;
                int w = snprintf(members + mused, sizeof(members) - mused, "%s%s", mused ? ", " : "", member);
                if (w < 0 || (size_t)w >= sizeof(members) - mused) break;
                mused += (size_t)w;
            }
            pclose(f);
        }
#endif
        int w = snprintf(buf + used, bufsz - used, "%s%s (%s)", i ? ", " : "", g_cable.names[i],
                         members[0] ? members : "no members listed");
        if (w < 0 || (size_t)w >= bufsz - used) break;
        used += (size_t)w;
    }
    return g_cable.n;
}

/* Usable for a connection now. Optimistic duplicate address detection (the
 * kernel's default for link-local) already allows it; a plain tentative or a
 * duplicate address does not. */
static int ipv6_address_usable(const char *ifname, const struct sockaddr_in6 *sa) {
#if defined(__APPLE__) && defined(SIOCGIFAFLAG_IN6)
    int s = socket(AF_INET6, SOCK_DGRAM, 0);
    if (s < 0) return 1;   /* cannot tell: let the dial find out */
    struct in6_ifreq req;
    memset(&req, 0, sizeof(req));
    snprintf(req.ifr_name, sizeof(req.ifr_name), "%s", ifname);
    memcpy(&req.ifr_ifru.ifru_addr, sa, sizeof(*sa));
    int usable = 1;
    if (ioctl(s, SIOCGIFAFLAG_IN6, &req) == 0) {
        const int f = req.ifr_ifru.ifru_flags6;
        if (f & IN6_IFF_DUPLICATED) usable = 0;
        else if ((f & IN6_IFF_TENTATIVE) && !(f & IN6_IFF_OPTIMISTIC)) usable = 0;
    }
    close(s);
    return usable;
#else
    (void)ifname; (void)sa;
    return 1;
#endif
}

int tb_net_get_tb_ip6(char *buf, size_t bufsz, unsigned int *ifindex) {
    if (!buf || bufsz == 0) return -1;
    buf[0] = '\0';
    if (ifindex) *ifindex = 0;
    struct ifaddrs *ifap = NULL;
    if (getifaddrs(&ifap) != 0) return -1;

    int ret = -1;
    for (struct ifaddrs *p = ifap; p && ret != 0; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET6) continue;
        if (strncmp(p->ifa_name, "bridge", 6) != 0) continue;
        if ((p->ifa_flags & (IFF_UP | IFF_RUNNING)) != (IFF_UP | IFF_RUNNING)) continue;
        struct sockaddr_in6 sa;
        memcpy(&sa, p->ifa_addr, sizeof(sa));
        if (!IN6_IS_ADDR_LINKLOCAL(&sa.sin6_addr)) continue;
        if (!ipv6_address_usable(p->ifa_name, (const struct sockaddr_in6 *)p->ifa_addr)) continue;
        if (!interface_is_cable_bridge(p->ifa_name)) continue;

        uint32_t scope = sa.sin6_scope_id;
        in6_take_embedded_scope(&sa.sin6_addr, &scope);
        char host[INET6_ADDRSTRLEN];
        if (!inet_ntop(AF_INET6, &sa.sin6_addr, host, sizeof(host))) continue;
        snprintf(buf, bufsz, "%s", host);
        if (ifindex) *ifindex = if_nametoindex(p->ifa_name);
        ret = 0;
    }
    freeifaddrs(ifap);
    return ret;
}

int tb_net_is_direct_link_ipv6(const char *ifname, const struct in6_addr *local,
                               const struct in6_addr *peer, int is_cable_bridge) {
    if (!ifname || !*ifname || !local || !peer) return 0;
    if (IN6_IS_ADDR_V4MAPPED(local) || IN6_IS_ADDR_V4MAPPED(peer)) return 0;
    if (strncmp(ifname, "lo", 2) == 0) {
        return (IN6_IS_ADDR_LOOPBACK(local) && IN6_IS_ADDR_LOOPBACK(peer)) ||
               (IN6_IS_ADDR_LINKLOCAL(local) && IN6_IS_ADDR_LINKLOCAL(peer));
    }
    if (strncmp(ifname, "bridge", 6) == 0 && is_cable_bridge) {
        return IN6_IS_ADDR_LINKLOCAL(local) && IN6_IS_ADDR_LINKLOCAL(peer);
    }
    return 0;
}

/* The interface an accepted IPv6 connection arrived on, and its verdict. */
static int client_is_direct_link6(int fd, const struct sockaddr_in6 *local_sa,
                                  char *ifname, size_t ifname_size) {
    struct sockaddr_in6 peer_sa;
    socklen_t peer_len = sizeof(peer_sa);
    memset(&peer_sa, 0, sizeof(peer_sa));
    if (getpeername(fd, (struct sockaddr *)&peer_sa, &peer_len) != 0) return 0;
    if (peer_sa.sin6_family != AF_INET6) return 0;

    struct in6_addr local = local_sa->sin6_addr, peer = peer_sa.sin6_addr;
    uint32_t local_scope = local_sa->sin6_scope_id, peer_scope = peer_sa.sin6_scope_id;
    in6_take_embedded_scope(&local, &local_scope);
    in6_take_embedded_scope(&peer, &peer_scope);

    char name[IFNAMSIZ] = "";
    if (IN6_IS_ADDR_LINKLOCAL(&local)) {
        /* Link-local: the scope is the interface. A peer on another link is
         * not on this one. */
        if (!local_scope || !if_indextoname(local_scope, name)) return 0;
        if (IN6_IS_ADDR_LINKLOCAL(&peer) && peer_scope && peer_scope != local_scope) name[0] = '\0';
    } else {
        struct ifaddrs *ifap = NULL;
        if (getifaddrs(&ifap) != 0) return 0;
        for (struct ifaddrs *p = ifap; p; p = p->ifa_next) {
            if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET6) continue;
            struct in6_addr candidate = ((const struct sockaddr_in6 *)p->ifa_addr)->sin6_addr;
            uint32_t unused = 0;
            in6_take_embedded_scope(&candidate, &unused);
            if (memcmp(&candidate, &local, sizeof(local)) == 0) {
                snprintf(name, sizeof(name), "%s", p->ifa_name);
                break;
            }
        }
        freeifaddrs(ifap);
    }
    if (!name[0]) return 0;
    if (ifname && ifname_size > 0) snprintf(ifname, ifname_size, "%s", name);
    return tb_net_is_direct_link_ipv6(name, &local, &peer, interface_is_cable_bridge(name));
}

int tb_net_is_link_local_ipv4(const char *host) {
    unsigned int a = 0, b = 0, c = 0, d = 0;
    if (!host) return 0;
    if (sscanf(host, "%u.%u.%u.%u", &a, &b, &c, &d) != 4) return 0;
    return a == 169 && b == 254 && c <= 255 && d <= 255;
}

int tb_net_is_direct_link(const char *ifname, const char *local_host, int is_wifi,
                          int is_cable_bridge) {
    if (!ifname || !*ifname) return 0;
    if (strncmp(ifname, "lo", 2) == 0) return 1;
    /* PWE: only the Thunderbolt Bridge, as for IPv6. */
    if (strncmp(ifname, "bridge", 6) == 0) return is_cable_bridge != 0;
    if (is_wifi) return 0;
    return is_likely_lan_interface_name(ifname) && tb_net_is_link_local_ipv4(local_host);
}

int tb_net_client_is_direct_link(int fd, char *ifname, size_t ifname_size) {
    if (ifname && ifname_size > 0) ifname[0] = '\0';

    /* PWE: an IPv6 client (tb_net_listen6) has its own rule. */
    struct sockaddr_storage any;
    socklen_t any_len = sizeof(any);
    memset(&any, 0, sizeof(any));
    if (getsockname(fd, (struct sockaddr *)&any, &any_len) != 0) return 0;
    if (any.ss_family == AF_INET6)
        return client_is_direct_link6(fd, (const struct sockaddr_in6 *)&any, ifname, ifname_size);

    struct sockaddr_in local;
    socklen_t local_len = sizeof(local);
    memset(&local, 0, sizeof(local));
    if (getsockname(fd, (struct sockaddr *)&local, &local_len) != 0) return 0;
    if (local.sin_family != AF_INET) return 0;

    char host[INET_ADDRSTRLEN] = {0};
    if (!inet_ntop(AF_INET, &local.sin_addr, host, sizeof(host))) return 0;

    struct ifaddrs *ifap = NULL;
    if (getifaddrs(&ifap) != 0) return 0;
    const char *name = NULL;
    for (struct ifaddrs *p = ifap; p; p = p->ifa_next) {
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET) continue;
        const struct sockaddr_in *candidate = (const struct sockaddr_in *)p->ifa_addr;
        if (candidate->sin_addr.s_addr == local.sin_addr.s_addr) {
            name = p->ifa_name;
            break;
        }
    }
    int direct = 0;
    if (name) {
        if (ifname && ifname_size > 0) snprintf(ifname, ifname_size, "%s", name);
        direct = tb_net_is_direct_link(name, host,
                                       interface_matches_kind(name, TB_LAN_INTERFACE_WIFI),
                                       interface_is_cable_bridge(name));
    }
    freeifaddrs(ifap);
    return direct;
}

/* ---- PWE: accept policy (net.h) ------------------------------------------ */
enum tb_link_kind tb_net_link_kind(const char *ifname, int direct) {
    if (!direct || !ifname || !*ifname) return TB_LINK_NETWORK;
    if (strncmp(ifname, "lo", 2) == 0) return TB_LINK_LOOPBACK;
    return TB_LINK_CABLE;
}

struct tb_accept_policy tb_net_accept_policy(enum tb_link_kind link,
                                             int network_allowed, int compat_mode) {
    struct tb_accept_policy p = { 0, 0, 0 };
    switch (link) {
    case TB_LINK_CABLE:
        p.accept = 1;
        p.pairing = 1;
        p.plaintext = compat_mode != 0;
        break;
    case TB_LINK_LOOPBACK:
        p.accept = 1;
        p.plaintext = compat_mode != 0;
        break;
    case TB_LINK_NETWORK:
    default:
        /* Only a paired Mac's encrypted session; pairing stays on the cable. */
        p.accept = network_allowed != 0;
        break;
    }
    return p;
}

struct tb_accept_policy tb_net_accept_policy_family(enum tb_link_kind link, int ipv6,
                                                    int network_allowed, int compat_mode) {
    /* Over IPv6 only the cable (and loopback, for tests): no sender dials a
     * receiver's IPv6 address off the cable, whatever AllowLocalNetwork says. */
    if (ipv6 && link != TB_LINK_CABLE && link != TB_LINK_LOOPBACK) {
        struct tb_accept_policy none = { 0, 0, 0 };
        return none;
    }
    return tb_net_accept_policy(link, network_allowed, compat_mode);
}

/* ---- PWE (T45): replacing a silent session (net.h) ------------------------ */
int tb_net_session_replaceable(uint64_t silent_ms, int pairing) {
    return !pairing && silent_ms >= TB_NET_STALE_SESSION_MS;
}

int tb_net_may_replace_session(uint64_t silent_ms, int pairing, enum tb_link_kind link, int accepted) {
    return accepted && link == TB_LINK_CABLE && tb_net_session_replaceable(silent_ms, pairing);
}

enum tb_session_offer tb_net_offer_during_session(uint64_t silent_ms, int pairing,
                                                  enum tb_link_kind link, int accepted) {
    if (tb_net_may_replace_session(silent_ms, pairing, link, accepted)) return TB_OFFER_REPLACE;
    if (accepted && link == TB_LINK_CABLE) return TB_OFFER_HOLD;
    return TB_OFFER_CLOSE;
}

int tb_net_get_tb_ip(char *buf, size_t bufsz) {
    struct ifaddrs *ifap = NULL;
    if (getifaddrs(&ifap) != 0) return -1;

    int ret = -1;
    for (struct ifaddrs *p = ifap; p; p = p->ifa_next) {
        if (!p->ifa_addr) continue;
        if (p->ifa_addr->sa_family != AF_INET) continue;
        if (strncmp(p->ifa_name, "bridge", 6) != 0) continue;
        /* PWE: the Thunderbolt Bridge only, as for the cable rule. */
        if (!interface_is_cable_bridge(p->ifa_name)) continue;

        char host[NI_MAXHOST];
        if (getnameinfo(p->ifa_addr, sizeof(struct sockaddr_in),
                        host, sizeof(host), NULL, 0, NI_NUMERICHOST) == 0) {
            if (strncmp(host, "169.254.", 8) == 0) {
                snprintf(buf, bufsz, "%s", host);
                ret = 0;
                break;
            }
        }
    }
    freeifaddrs(ifap);
    return ret;
}

int tb_net_get_link_local_ip(char *buf, size_t bufsz) {
    struct ifaddrs *ifap = NULL;
    if (!buf || bufsz == 0) return -1;
    buf[0] = '\0';
    if (getifaddrs(&ifap) != 0) return -1;

    int ret = -1;
    for (struct ifaddrs *p = ifap; p; p = p->ifa_next) {
        if (!p->ifa_addr) continue;
        if (p->ifa_addr->sa_family != AF_INET) continue;
        if (!is_likely_lan_interface_name(p->ifa_name)) continue;

        char host[NI_MAXHOST];
        if (getnameinfo(p->ifa_addr, sizeof(struct sockaddr_in),
                        host, sizeof(host), NULL, 0, NI_NUMERICHOST) == 0 &&
            tb_net_is_link_local_ipv4(host)) {
            snprintf(buf, bufsz, "%s", host);
            ret = 0;
            break;
        }
    }
    freeifaddrs(ifap);
    return ret;
}

int tb_net_get_lan_ip(char *buf, size_t bufsz) {
    if (tb_net_get_ethernet_ip(buf, bufsz) == 0) return 0;
    return tb_net_get_wifi_ip(buf, bufsz);
}

int tb_net_get_ethernet_ip(char *buf, size_t bufsz) {
    return get_lan_ip_for_kind(buf, bufsz, TB_LAN_INTERFACE_ETHERNET);
}

int tb_net_get_wifi_ip(char *buf, size_t bufsz) {
    return get_lan_ip_for_kind(buf, bufsz, TB_LAN_INTERFACE_WIFI);
}
