/* pwe_secure.h — PWE iMac Display: pairing, authentication and encrypted
 * sessions. One copy, compiled into both apps (receiver: Makefile; sender:
 * Xcode, through the bridging header). Pure functions over packets: no I/O,
 * no clock, no keychain. The caller passes the time and a peer store.
 *
 * Built only from published constructions with test vectors:
 *   pairing   CPace (draft-irtf-cfrg-cpace-21), ristretto255 + SHA-512,
 *             with a 6-digit code shown on the receiver;
 *   sessions  Noise_KK_25519_ChaChaPoly_SHA256 with the stored static keys;
 *   records   the two Noise transport ciphers (ChaCha20-Poly1305, 64-bit
 *             counter nonce, one key per direction).
 *
 * Wire: the existing [BE32 length][type][payload] packets, types 0x50–0x5F
 * (see proto.h). The Mac (sender) is always the initiator.
 *
 *   S→R 0x50 HELLO         magic "PWES", version 2, suites, sender id, nonce
 *   R→S 0x51 HELLO_REPLY   magic, version, suite, status, receiver id, nonce
 *  paired:
 *   S→R 0x57 KK_1          Noise -> e, es, ss
 *   R→S 0x58 KK_2          Noise <- e, ee, se          → both sides SECURE
 *  not paired yet:
 *   S→R 0x52 PAIR_REQUEST                              → receiver shows a code
 *   R→S 0x53 PAIR_READY    BE16 seconds until the code expires, u8 flags
 *                          (bit 0: the code was made just now, so a code
 *                          typed earlier is stale and is not sent)
 *   S→R 0x54 PAIR_A        Ya
 *   R→S 0x55 PAIR_B        Yb, sealed(receiver static key, receiver name)
 *   S→R 0x56 PAIR_CONFIRM  sealed(sender static key, sender name)
 *   then KK_1 / KK_2 as above, on the same connection.
 *   either  0x5E ERROR     code, BE16 detail
 *   after   0x5F SEALED    AEAD(inner type || inner payload)
 *
 * One code is good for one PAIR_A: any outcome but success replaces it.
 * Five failures in a row lock pairing for 60 s. A code expires after 60 s.
 */

#ifndef PWE_SECURE_H
#define PWE_SECURE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PWE_SEC_VERSION          2
#define PWE_SEC_SUITE_V2         1   /* CPace-ristretto255-SHA512 + Noise_KK_25519_ChaChaPoly_SHA256 */
#define PWE_SEC_KEY_BYTES        32
#define PWE_SEC_ID_BYTES         16
#define PWE_SEC_NAME_MAX         64  /* bytes of UTF-8, without the NUL */
#define PWE_SEC_CODE_DIGITS      6
#define PWE_SEC_TAG_BYTES        16
#define PWE_SEC_CODE_LIFETIME_MS 60000
#define PWE_SEC_LOCK_MS          60000
#define PWE_SEC_MAX_FAILURES     5
#define PWE_SEC_MAX_PEERS        8   /* receiver: paired Macs it remembers */

/* Packet types (mirrored in proto.h and TBMonitorProtocol.swift). */
#define PWE_PKT_SEC_HELLO        0x50
#define PWE_PKT_SEC_HELLO_REPLY  0x51
#define PWE_PKT_SEC_PAIR_REQUEST 0x52
#define PWE_PKT_SEC_PAIR_READY   0x53
#define PWE_PKT_SEC_PAIR_A       0x54
#define PWE_PKT_SEC_PAIR_B       0x55
#define PWE_PKT_SEC_PAIR_CONFIRM 0x56
#define PWE_PKT_SEC_KK_1         0x57
#define PWE_PKT_SEC_KK_2         0x58
#define PWE_PKT_SEC_ERROR        0x5E
#define PWE_PKT_SEC_SEALED       0x5F
#define PWE_PKT_IS_SEC(t)        ((t) >= 0x50 && (t) <= 0x5F)

/* HELLO_REPLY status. */
#define PWE_SEC_STATUS_KNOWN     0   /* the receiver has this sender's key: KK next */
#define PWE_SEC_STATUS_UNKNOWN   1   /* pair first */

/* ERROR codes. */
enum pwe_sec_error {
    PWE_SEC_ERR_NONE         = 0,
    PWE_SEC_ERR_NEED_PAIRING = 1,  /* the receiver does not know this sender (any more) */
    PWE_SEC_ERR_LOCKED       = 2,  /* detail = seconds left */
    PWE_SEC_ERR_WRONG_CODE   = 3,
    PWE_SEC_ERR_EXPIRED      = 4,
    PWE_SEC_ERR_VERSION      = 5,  /* no common version or suite */
    PWE_SEC_ERR_NOT_DIRECT   = 6,  /* pairing only over the cable */
    PWE_SEC_ERR_PROTOCOL     = 7,  /* unexpected or malformed message */
    PWE_SEC_ERR_STORE        = 8,  /* keychain unreadable on the side that sent it */
    PWE_SEC_ERR_CANCELLED    = 9,  /* the user cancelled code entry */
};

/* What the caller should do after a call. More than one can be set. */
enum pwe_sec_event {
    PWE_SEC_EV_NONE              = 0,
    PWE_SEC_EV_SECURE            = 1 << 0,  /* session keys ready: start the normal protocol, sealed */
    PWE_SEC_EV_NEED_CODE         = 1 << 1,  /* initiator: ask the user for the code shown on the receiver */
    PWE_SEC_EV_SHOW_CODE         = 1 << 2,  /* responder: show sec->code (new or replaced) */
    PWE_SEC_EV_HIDE_CODE         = 1 << 3,  /* responder: stop showing the code */
    PWE_SEC_EV_PAIRED            = 1 << 4,  /* a new peer was stored; peer_name is set */
    PWE_SEC_EV_WRONG_CODE        = 1 << 5,
    PWE_SEC_EV_LOCKED            = 1 << 6,  /* lock_seconds is set */
    PWE_SEC_EV_IDENTITY_CHANGED  = 1 << 7,  /* initiator: this receiver's key is not the one stored */
    PWE_SEC_EV_PEER_ERROR        = 1 << 8,  /* peer sent ERROR; peer_error / peer_error_detail set */
    PWE_SEC_EV_CLOSE             = 1 << 9,  /* close the connection (after sending out) */
};

/* Peer store, implemented by the caller (pwe_keystore.c: login keychain). */
struct pwe_sec_store {
    /* 0 and fills pub (and name, NUL-terminated, if not NULL) when known; 1 if
     * unknown; -1 if the store cannot be read. */
    int  (*find)(void *ud, const uint8_t id[PWE_SEC_ID_BYTES],
                 uint8_t pub[PWE_SEC_KEY_BYTES], char name[PWE_SEC_NAME_MAX + 1]);
    /* 0 on success, -1 on failure. */
    int  (*save)(void *ud, const uint8_t id[PWE_SEC_ID_BYTES],
                 const uint8_t pub[PWE_SEC_KEY_BYTES], const char *name);
    void *ud;
};

/* This side's long-term X25519 key pair and the id derived from it. */
struct pwe_sec_identity {
    uint8_t priv[PWE_SEC_KEY_BYTES];
    uint8_t pub[PWE_SEC_KEY_BYTES];
    uint8_t id[PWE_SEC_ID_BYTES];
    char    name[PWE_SEC_NAME_MAX + 1];   /* shown to the peer when pairing */
};

/* Receiver-wide pairing state: one code and one failure count for all
 * connections, so reconnecting does not reset the count. */
struct pwe_sec_gate {
    char     code[PWE_SEC_CODE_DIGITS + 1];   /* "" when none is shown */
    uint64_t code_expires_ms;
    uint64_t locked_until_ms;
    int      failures;                         /* consecutive */
    const char *fixed_code;                    /* tests only: NULL in the apps */
};

struct pwe_sec;   /* one per connection; opaque */

enum pwe_sec_role { PWE_SEC_INITIATOR = 0, PWE_SEC_RESPONDER = 1 };

/* Per-connection options for the responder. */
struct pwe_sec_responder_opts {
    int direct_link;   /* 1 when the peer is on the cable (Thunderbolt Bridge, USB link-local) */
};

int  pwe_sec_global_init(void);   /* sodium_init; 0 on success. Safe to call more than once. */

/* Identity: make a new key pair, or rebuild pub and id from a stored private key. */
int  pwe_sec_identity_generate(struct pwe_sec_identity *idn, const char *name);
int  pwe_sec_identity_from_private(struct pwe_sec_identity *idn,
                                   const uint8_t priv[PWE_SEC_KEY_BYTES], const char *name);
void pwe_sec_id_from_public(const uint8_t pub[PWE_SEC_KEY_BYTES], uint8_t id[PWE_SEC_ID_BYTES]);
void pwe_sec_id_hex(const uint8_t id[PWE_SEC_ID_BYTES], char out[2 * PWE_SEC_ID_BYTES + 1]);

/* Connection. `idn`, `store` and `gate` must outlive it. `gate` is responder only. */
struct pwe_sec *pwe_sec_new(enum pwe_sec_role role, const struct pwe_sec_identity *idn,
                            const struct pwe_sec_store *store, struct pwe_sec_gate *gate,
                            const struct pwe_sec_responder_opts *opts);
void pwe_sec_free(struct pwe_sec *sec);   /* wipes the keys */

/* Output: each call appends complete packets to out (cap bytes). The caller
 * sends them in order. 64 KB is always enough for handshake output. */
struct pwe_sec_out {
    uint8_t *buf;
    size_t   len;
    size_t   cap;
};

/* Initiator: send HELLO. expected_id (may be NULL) is the receiver id stored
 * for the receiver being dialled; a different id raises IDENTITY_CHANGED.
 * code (may be NULL) is a code the user already typed: pair with it at once.
 * An empty code asks to pair again even when both sides have keys (the user
 * is then asked for the code the receiver shows). */
int  pwe_sec_start(struct pwe_sec *sec, const uint8_t *expected_id, const char *code,
                   struct pwe_sec_out *out, uint64_t now_ms);

/* Initiator, before start: never pair on this connection. If the receiver does
 * not already know this sender, close instead of asking it to show a code
 * (background connections, e.g. pushing the UI language to an idle receiver). */
void pwe_sec_set_resume_only(struct pwe_sec *sec);

/* Initiator: the user typed the code (after NEED_CODE) or cancelled (code NULL). */
int  pwe_sec_submit_code(struct pwe_sec *sec, const char *code, struct pwe_sec_out *out);

/* Both: one handshake packet (PWE_PKT_IS_SEC(type), not SEALED). Returns the
 * event mask; anything with PWE_SEC_EV_CLOSE means close after sending out. */
int  pwe_sec_handle(struct pwe_sec *sec, uint8_t type, const uint8_t *payload, size_t len,
                    struct pwe_sec_out *out, uint64_t now_ms);

/* Responder: expire the code. Call about once a second, connected or not.
 * Returns PWE_SEC_EV_HIDE_CODE when the code shown has just expired. */
int  pwe_sec_gate_tick(struct pwe_sec_gate *gate, uint64_t now_ms);

/* Both: the connection closed. A pairing attempt that was under way counts as
 * a failure (it may have been a guess). Returns the event mask. */
int  pwe_sec_closed(struct pwe_sec *sec, uint64_t now_ms);

int  pwe_sec_is_secure(const struct pwe_sec *sec);
int  pwe_sec_is_pairing(const struct pwe_sec *sec);
const char    *pwe_sec_code(const struct pwe_sec *sec);        /* responder: code to show, "" if none */
const char    *pwe_sec_peer_name(const struct pwe_sec *sec);   /* "" until known */
const uint8_t *pwe_sec_peer_id(const struct pwe_sec *sec);     /* NULL until known */
int  pwe_sec_lock_seconds(const struct pwe_sec *sec);
int  pwe_sec_code_seconds(const struct pwe_sec *sec);          /* initiator: from PAIR_READY */
int  pwe_sec_peer_error(const struct pwe_sec *sec);
int  pwe_sec_peer_error_detail(const struct pwe_sec *sec);
int  pwe_sec_local_error(const struct pwe_sec *sec);            /* why this side closed, enum pwe_sec_error */

/* Records, once secure. seal: a whole outer packet [len][0x5F][ciphertext]
 * goes to out (inner_len + PWE_SEC_SEAL_OVERHEAD bytes; inner may not overlap
 * out). open: payload of a 0x5F packet, decrypted in place; on success
 * *inner_type is set and the inner payload is (*inner)[0 .. *inner_len),
 * inside payload, followed by at least PWE_SEC_TAG_BYTES spare bytes. Any
 * failure is final: close the connection. */
#define PWE_SEC_SEAL_OVERHEAD 22   /* 5 header + 1 inner type + 16 tag; a literal so Swift imports it */
int  pwe_sec_seal(struct pwe_sec *sec, uint8_t inner_type, const uint8_t *inner, size_t inner_len,
                  uint8_t *out, size_t out_cap, size_t *out_len);
int  pwe_sec_open(struct pwe_sec *sec, uint8_t *payload, size_t len,
                  uint8_t *inner_type, uint8_t **inner, size_t *inner_len);

/* Policy for sessions that are not encrypted (D3): picture, sound,
 * brightness, volume. to_receiver = 1 for packets the Mac sends. */
int  pwe_sec_plaintext_allowed(uint8_t type, int to_receiver);

/* ---- Building blocks, exposed for the test vectors ---------------------- */

/* CPace (initiator-responder setting). */
int  pwe_cpace_generator(const uint8_t *prs, size_t prs_len, const uint8_t *ci, size_t ci_len,
                         const uint8_t *sid, size_t sid_len, uint8_t g[32]);
int  pwe_cpace_share(const uint8_t g[32], const uint8_t y[32], uint8_t Y[32]);
int  pwe_cpace_isk(const uint8_t y[32], const uint8_t *sid, size_t sid_len,
                   const uint8_t Ya[32], const uint8_t *ada, size_t ada_len,
                   const uint8_t Yb[32], const uint8_t *adb, size_t adb_len,
                   int i_am_a, uint8_t isk[64]);
void pwe_cpace_sample_scalar(uint8_t y[32]);

/* Noise handshake state, KK pattern only. */
struct pwe_noise_cipher {
    uint8_t  k[32];
    uint64_t n;
    int      has_key;
};
struct pwe_noise_hs {
    uint8_t ck[32];
    uint8_t h[32];
    struct pwe_noise_cipher c;
    uint8_t s_priv[32], s_pub[32];
    uint8_t e_priv[32], e_pub[32];
    uint8_t rs[32], re[32];
    int     initiator;
    int     step;          /* messages processed */
    int     fixed_e;       /* tests: e_priv set by the caller */
};
int  pwe_noise_kk_init(struct pwe_noise_hs *hs, int initiator, const uint8_t *prologue, size_t prologue_len,
                       const uint8_t s_priv[32], const uint8_t rs_pub[32]);
void pwe_noise_set_ephemeral(struct pwe_noise_hs *hs, const uint8_t e_priv[32]);
int  pwe_noise_write(struct pwe_noise_hs *hs, const uint8_t *payload, size_t len,
                     uint8_t *out, size_t out_cap, size_t *out_len);
int  pwe_noise_read(struct pwe_noise_hs *hs, const uint8_t *msg, size_t len,
                    uint8_t *payload, size_t payload_cap, size_t *payload_len);
/* After both messages: send/recv ciphers for this side, and the handshake hash. */
int  pwe_noise_split(struct pwe_noise_hs *hs, struct pwe_noise_cipher *send,
                     struct pwe_noise_cipher *recv, uint8_t hash[32]);
int  pwe_noise_encrypt(struct pwe_noise_cipher *c, const uint8_t *ad, size_t ad_len,
                       const uint8_t *in, size_t len, uint8_t *out);          /* out: len + 16 */
int  pwe_noise_decrypt(struct pwe_noise_cipher *c, const uint8_t *ad, size_t ad_len,
                       const uint8_t *in, size_t len, uint8_t *out);          /* out: len - 16; in == out allowed */
void pwe_noise_wipe(struct pwe_noise_hs *hs);

#ifdef __cplusplus
}
#endif

#endif
