/* pwe_secure.c — see pwe_secure.h. */

#include "pwe_secure.h"

#include <sodium.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- Constants ------------------------------------------------------------ */

static const char k_magic[4] = { 'P', 'W', 'E', 'S' };
static const char k_id_label[] = "PWE iMac Display id";
static const char k_cpace_ci[] = "PWE iMac Display pairing v2";
static const char k_pair_keys_label[] = "PWE iMac Display pair keys";
static const char k_prologue_label[] = "PWE iMac Display/2";
static const char k_noise_name[] = "Noise_KK_25519_ChaChaPoly_SHA256";
static const char k_cpace_dsi[] = "CPaceRistretto255";

_Static_assert(PWE_SEC_SEAL_OVERHEAD == 5 + 1 + PWE_SEC_TAG_BYTES, "record overhead");

#define NONCE_BYTES   16
#define HELLO_BYTES   40   /* with one suite; longer is accepted */
#define SHA512_BLOCK  128

/* ---- Small helpers -------------------------------------------------------- */

static void put_be16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v; }
static void put_be32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16); p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v;
}
static uint16_t get_be16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }

/* LEB128 length prefix (CPace prepend_len). Returns bytes written (<= 10). */
static size_t leb128(uint8_t *out, size_t v) {
    size_t n = 0;
    do {
        uint8_t b = (uint8_t)(v & 0x7f);
        v >>= 7;
        if (v) b |= 0x80;
        out[n++] = b;
    } while (v);
    return n;
}

/* Hash state that accepts lv_cat() pieces directly. */
static void sha512_lv(crypto_hash_sha512_state *st, const void *data, size_t len) {
    uint8_t pre[10];
    size_t n = leb128(pre, len);
    crypto_hash_sha512_update(st, pre, n);
    if (len) crypto_hash_sha512_update(st, (const uint8_t *)data, len);
}

static int out_packet(struct pwe_sec_out *out, uint8_t type, const uint8_t *payload, size_t len) {
    if (!out || !out->buf) return -1;
    if (out->cap - out->len < 5 + len) return -1;
    uint8_t *p = out->buf + out->len;
    put_be32(p, (uint32_t)(1 + len));
    p[4] = type;
    if (len) memcpy(p + 5, payload, len);
    out->len += 5 + len;
    return 0;
}

/* Copy a name, at most PWE_SEC_NAME_MAX bytes, never cutting a UTF-8 sequence. */
static void copy_name(char dst[PWE_SEC_NAME_MAX + 1], const char *src, size_t len) {
    if (!src) { dst[0] = '\0'; return; }
    if (len > PWE_SEC_NAME_MAX) {
        len = PWE_SEC_NAME_MAX;
        while (len > 0 && ((unsigned char)src[len] & 0xC0) == 0x80) len--;
    }
    size_t n = 0;
    for (size_t i = 0; i < len && src[i]; i++) dst[n++] = src[i];
    dst[n] = '\0';
}

int pwe_sec_global_init(void) {
    return sodium_init() < 0 ? -1 : 0;
}

/* ---- Identity -------------------------------------------------------------- */

void pwe_sec_id_from_public(const uint8_t pub[PWE_SEC_KEY_BYTES], uint8_t id[PWE_SEC_ID_BYTES]) {
    crypto_hash_sha256_state st;
    uint8_t h[32];
    crypto_hash_sha256_init(&st);
    crypto_hash_sha256_update(&st, (const uint8_t *)k_id_label, sizeof(k_id_label) - 1);
    crypto_hash_sha256_update(&st, pub, PWE_SEC_KEY_BYTES);
    crypto_hash_sha256_final(&st, h);
    memcpy(id, h, PWE_SEC_ID_BYTES);
}

void pwe_sec_id_hex(const uint8_t id[PWE_SEC_ID_BYTES], char out[2 * PWE_SEC_ID_BYTES + 1]) {
    sodium_bin2hex(out, 2 * PWE_SEC_ID_BYTES + 1, id, PWE_SEC_ID_BYTES);
}

int pwe_sec_identity_from_private(struct pwe_sec_identity *idn,
                                  const uint8_t priv[PWE_SEC_KEY_BYTES], const char *name) {
    memcpy(idn->priv, priv, PWE_SEC_KEY_BYTES);
    if (crypto_scalarmult_base(idn->pub, idn->priv) != 0) return -1;
    pwe_sec_id_from_public(idn->pub, idn->id);
    copy_name(idn->name, name, name ? strlen(name) : 0);
    return 0;
}

int pwe_sec_identity_generate(struct pwe_sec_identity *idn, const char *name) {
    uint8_t priv[PWE_SEC_KEY_BYTES];
    randombytes_buf(priv, sizeof(priv));
    int rc = pwe_sec_identity_from_private(idn, priv, name);
    sodium_memzero(priv, sizeof(priv));
    return rc;
}

/* ---- CPace (draft-irtf-cfrg-cpace-21, ristretto255 + SHA-512) ------------- */

int pwe_cpace_generator(const uint8_t *prs, size_t prs_len, const uint8_t *ci, size_t ci_len,
                        const uint8_t *sid, size_t sid_len, uint8_t g[32]) {
    static const uint8_t zeros[SHA512_BLOCK] = { 0 };
    uint8_t tmp[10];
    size_t dsi_len = sizeof(k_cpace_dsi) - 1;
    size_t pre_prs = leb128(tmp, prs_len) + prs_len;
    size_t pre_dsi = leb128(tmp, dsi_len) + dsi_len;
    size_t zpad = 0;
    if (SHA512_BLOCK > 1 + pre_prs + pre_dsi) zpad = SHA512_BLOCK - 1 - pre_prs - pre_dsi;

    crypto_hash_sha512_state st;
    uint8_t hash[64];
    crypto_hash_sha512_init(&st);
    sha512_lv(&st, k_cpace_dsi, dsi_len);
    sha512_lv(&st, prs, prs_len);
    sha512_lv(&st, zeros, zpad);
    sha512_lv(&st, ci, ci_len);
    sha512_lv(&st, sid, sid_len);
    crypto_hash_sha512_final(&st, hash);
    crypto_core_ristretto255_from_hash(g, hash);
    sodium_memzero(hash, sizeof(hash));
    sodium_memzero(&st, sizeof(st));
    return 0;
}

void pwe_cpace_sample_scalar(uint8_t y[32]) {
    /* The draft's recommended sampling: 32 random bytes, bits above 252 cleared. */
    randombytes_buf(y, 32);
    y[31] &= 0x0f;
}

int pwe_cpace_share(const uint8_t g[32], const uint8_t y[32], uint8_t Y[32]) {
    return crypto_scalarmult_ristretto255(Y, y, g) == 0 ? 0 : -1;
}

int pwe_cpace_isk(const uint8_t y[32], const uint8_t *sid, size_t sid_len,
                  const uint8_t Ya[32], const uint8_t *ada, size_t ada_len,
                  const uint8_t Yb[32], const uint8_t *adb, size_t adb_len,
                  int i_am_a, uint8_t isk[64]) {
    uint8_t K[32];
    /* scalar_mult_vfy: a share that does not decode, or a result that is the
     * identity, makes libsodium fail. Both mean abort. */
    if (crypto_scalarmult_ristretto255(K, y, i_am_a ? Yb : Ya) != 0) return -1;

    static const char dsi_isk[] = "CPaceRistretto255_ISK";
    crypto_hash_sha512_state st;
    crypto_hash_sha512_init(&st);
    sha512_lv(&st, dsi_isk, sizeof(dsi_isk) - 1);
    sha512_lv(&st, sid, sid_len);
    sha512_lv(&st, K, sizeof(K));
    /* transcript_ir(Ya, ADa, Yb, ADb) */
    sha512_lv(&st, Ya, 32);
    sha512_lv(&st, ada, ada_len);
    sha512_lv(&st, Yb, 32);
    sha512_lv(&st, adb, adb_len);
    crypto_hash_sha512_final(&st, isk);
    sodium_memzero(K, sizeof(K));
    sodium_memzero(&st, sizeof(st));
    return 0;
}

/* ---- Noise (revision 34), KK, 25519 / ChaChaPoly / SHA256 ----------------- */

static void noise_nonce(uint8_t nonce[12], uint64_t n) {
    memset(nonce, 0, 4);
    for (int i = 0; i < 8; i++) nonce[4 + i] = (uint8_t)(n >> (8 * i));
}

int pwe_noise_encrypt(struct pwe_noise_cipher *c, const uint8_t *ad, size_t ad_len,
                      const uint8_t *in, size_t len, uint8_t *out) {
    if (!c->has_key || c->n == UINT64_MAX) return -1;
    uint8_t nonce[12];
    noise_nonce(nonce, c->n);
    unsigned long long clen = 0;
    if (crypto_aead_chacha20poly1305_ietf_encrypt(out, &clen, in, len, ad, ad_len, NULL, nonce, c->k) != 0)
        return -1;
    c->n++;
    return 0;
}

int pwe_noise_decrypt(struct pwe_noise_cipher *c, const uint8_t *ad, size_t ad_len,
                      const uint8_t *in, size_t len, uint8_t *out) {
    if (!c->has_key || c->n == UINT64_MAX || len < PWE_SEC_TAG_BYTES) return -1;
    uint8_t nonce[12];
    noise_nonce(nonce, c->n);
    unsigned long long mlen = 0;
    if (crypto_aead_chacha20poly1305_ietf_decrypt(out, &mlen, NULL, in, len, ad, ad_len, nonce, c->k) != 0)
        return -1;
    c->n++;
    return 0;
}

static void hmac_sha256(const uint8_t key[32], const uint8_t *a, size_t alen,
                        const uint8_t *b, size_t blen, uint8_t out[32]) {
    crypto_auth_hmacsha256_state st;
    crypto_auth_hmacsha256_init(&st, key, 32);
    if (alen) crypto_auth_hmacsha256_update(&st, a, alen);
    if (blen) crypto_auth_hmacsha256_update(&st, b, blen);
    crypto_auth_hmacsha256_final(&st, out);
    sodium_memzero(&st, sizeof(st));
}

/* HKDF as the Noise spec defines it, two outputs. */
static void noise_hkdf2(const uint8_t ck[32], const uint8_t *ikm, size_t ikm_len,
                        uint8_t out1[32], uint8_t out2[32]) {
    uint8_t temp[32];
    static const uint8_t one = 0x01, two = 0x02;
    hmac_sha256(ck, ikm, ikm_len, NULL, 0, temp);
    hmac_sha256(temp, &one, 1, NULL, 0, out1);
    hmac_sha256(temp, out1, 32, &two, 1, out2);
    sodium_memzero(temp, sizeof(temp));
}

static void noise_mix_hash(struct pwe_noise_hs *hs, const uint8_t *data, size_t len) {
    crypto_hash_sha256_state st;
    crypto_hash_sha256_init(&st);
    crypto_hash_sha256_update(&st, hs->h, 32);
    if (len) crypto_hash_sha256_update(&st, data, len);
    crypto_hash_sha256_final(&st, hs->h);
}

static void noise_mix_key(struct pwe_noise_hs *hs, const uint8_t ikm[32]) {
    uint8_t ck[32], k[32];
    noise_hkdf2(hs->ck, ikm, 32, ck, k);
    memcpy(hs->ck, ck, 32);
    memcpy(hs->c.k, k, 32);
    hs->c.n = 0;
    hs->c.has_key = 1;
    sodium_memzero(ck, sizeof(ck));
    sodium_memzero(k, sizeof(k));
}

static int noise_dh_mix(struct pwe_noise_hs *hs, const uint8_t priv[32], const uint8_t pub[32]) {
    uint8_t shared[32];
    if (crypto_scalarmult(shared, priv, pub) != 0) return -1;   /* all-zero output: low-order point */
    noise_mix_key(hs, shared);
    sodium_memzero(shared, sizeof(shared));
    return 0;
}

int pwe_noise_kk_init(struct pwe_noise_hs *hs, int initiator, const uint8_t *prologue, size_t prologue_len,
                      const uint8_t s_priv[32], const uint8_t rs_pub[32]) {
    memset(hs, 0, sizeof(*hs));
    hs->initiator = initiator ? 1 : 0;
    /* Protocol name is exactly HASHLEN bytes: h = name, no hashing. */
    memcpy(hs->h, k_noise_name, 32);
    memcpy(hs->ck, hs->h, 32);
    noise_mix_hash(hs, prologue, prologue_len);
    memcpy(hs->s_priv, s_priv, 32);
    if (crypto_scalarmult_base(hs->s_pub, hs->s_priv) != 0) return -1;
    memcpy(hs->rs, rs_pub, 32);
    /* Pre-messages: -> s, <- s (initiator's static first, on both sides). */
    if (hs->initiator) {
        noise_mix_hash(hs, hs->s_pub, 32);
        noise_mix_hash(hs, hs->rs, 32);
    } else {
        noise_mix_hash(hs, hs->rs, 32);
        noise_mix_hash(hs, hs->s_pub, 32);
    }
    return 0;
}

void pwe_noise_set_ephemeral(struct pwe_noise_hs *hs, const uint8_t e_priv[32]) {
    memcpy(hs->e_priv, e_priv, 32);
    hs->fixed_e = 1;
}

static int noise_new_ephemeral(struct pwe_noise_hs *hs) {
    if (!hs->fixed_e) randombytes_buf(hs->e_priv, 32);
    return crypto_scalarmult_base(hs->e_pub, hs->e_priv) == 0 ? 0 : -1;
}

/* EncryptAndHash / DecryptAndHash. */
static int noise_encrypt_and_hash(struct pwe_noise_hs *hs, const uint8_t *pt, size_t len, uint8_t *out) {
    if (pwe_noise_encrypt(&hs->c, hs->h, 32, pt, len, out) != 0) return -1;
    noise_mix_hash(hs, out, len + PWE_SEC_TAG_BYTES);
    return 0;
}

static int noise_decrypt_and_hash(struct pwe_noise_hs *hs, const uint8_t *ct, size_t len, uint8_t *out) {
    uint8_t h_before[32];
    memcpy(h_before, hs->h, 32);
    if (pwe_noise_decrypt(&hs->c, h_before, 32, ct, len, out) != 0) return -1;
    noise_mix_hash(hs, ct, len);
    return 0;
}

int pwe_noise_write(struct pwe_noise_hs *hs, const uint8_t *payload, size_t len,
                    uint8_t *out, size_t out_cap, size_t *out_len) {
    int mine = (hs->initiator && hs->step == 0) || (!hs->initiator && hs->step == 1);
    if (!mine || out_cap < 32 + len + PWE_SEC_TAG_BYTES) return -1;
    if (noise_new_ephemeral(hs) != 0) return -1;
    memcpy(out, hs->e_pub, 32);
    noise_mix_hash(hs, hs->e_pub, 32);
    if (hs->step == 0) {
        /* -> e, es, ss */
        if (noise_dh_mix(hs, hs->e_priv, hs->rs) != 0) return -1;
        if (noise_dh_mix(hs, hs->s_priv, hs->rs) != 0) return -1;
    } else {
        /* <- e, ee, se (responder side: se = DH(e, rs)) */
        if (noise_dh_mix(hs, hs->e_priv, hs->re) != 0) return -1;
        if (noise_dh_mix(hs, hs->e_priv, hs->rs) != 0) return -1;
    }
    if (noise_encrypt_and_hash(hs, payload, len, out + 32) != 0) return -1;
    *out_len = 32 + len + PWE_SEC_TAG_BYTES;
    hs->step++;
    return 0;
}

int pwe_noise_read(struct pwe_noise_hs *hs, const uint8_t *msg, size_t len,
                   uint8_t *payload, size_t payload_cap, size_t *payload_len) {
    int theirs = (!hs->initiator && hs->step == 0) || (hs->initiator && hs->step == 1);
    if (!theirs || len < 32 + PWE_SEC_TAG_BYTES) return -1;
    size_t plen = len - 32 - PWE_SEC_TAG_BYTES;
    if (payload_cap < plen) return -1;
    memcpy(hs->re, msg, 32);
    noise_mix_hash(hs, hs->re, 32);
    if (hs->step == 0) {
        /* responder reads -> e, es, ss: es = DH(s, re), ss = DH(s, rs) */
        if (noise_dh_mix(hs, hs->s_priv, hs->re) != 0) return -1;
        if (noise_dh_mix(hs, hs->s_priv, hs->rs) != 0) return -1;
    } else {
        /* initiator reads <- e, ee, se: ee = DH(e, re), se = DH(s, re) */
        if (noise_dh_mix(hs, hs->e_priv, hs->re) != 0) return -1;
        if (noise_dh_mix(hs, hs->s_priv, hs->re) != 0) return -1;
    }
    if (noise_decrypt_and_hash(hs, msg + 32, len - 32, payload) != 0) return -1;
    *payload_len = plen;
    hs->step++;
    return 0;
}

int pwe_noise_split(struct pwe_noise_hs *hs, struct pwe_noise_cipher *send,
                    struct pwe_noise_cipher *recv, uint8_t hash[32]) {
    if (hs->step != 2) return -1;
    uint8_t k1[32], k2[32];
    noise_hkdf2(hs->ck, NULL, 0, k1, k2);
    struct pwe_noise_cipher *c1 = hs->initiator ? send : recv;
    struct pwe_noise_cipher *c2 = hs->initiator ? recv : send;
    memcpy(c1->k, k1, 32); c1->n = 0; c1->has_key = 1;
    memcpy(c2->k, k2, 32); c2->n = 0; c2->has_key = 1;
    if (hash) memcpy(hash, hs->h, 32);
    sodium_memzero(k1, sizeof(k1));
    sodium_memzero(k2, sizeof(k2));
    return 0;
}

void pwe_noise_wipe(struct pwe_noise_hs *hs) {
    sodium_memzero(hs, sizeof(*hs));
}

/* ---- Connection state ------------------------------------------------------ */

enum sec_state {
    /* initiator */
    ST_I_START, ST_I_HELLO_SENT, ST_I_PAIR_REQ_SENT, ST_I_NEED_CODE, ST_I_PAIR_A_SENT, ST_I_KK1_SENT,
    /* responder */
    ST_R_WAIT_HELLO, ST_R_REPLIED, ST_R_CODE_SHOWN, ST_R_WAIT_CONFIRM, ST_R_WAIT_KK1,
    /* both */
    ST_SECURE, ST_DEAD
};

struct pwe_sec {
    enum pwe_sec_role role;
    enum sec_state st;
    const struct pwe_sec_identity *idn;
    const struct pwe_sec_store *store;
    struct pwe_sec_gate *gate;
    int direct_link;

    uint8_t hello[64];  size_t hello_len;   /* first 64 bytes are bound into the prologue */
    uint8_t reply[64];  size_t reply_len;
    uint8_t sender_nonce[NONCE_BYTES], receiver_nonce[NONCE_BYTES];

    uint8_t peer_id[PWE_SEC_ID_BYTES];  int have_peer_id;
    uint8_t peer_pub[PWE_SEC_KEY_BYTES]; int have_peer_pub;
    char    peer_name[PWE_SEC_NAME_MAX + 1];
    uint8_t expected_id[PWE_SEC_ID_BYTES]; int have_expected;
    int     peer_status;                     /* initiator: status from HELLO_REPLY */
    int     pairing_available;               /* initiator: flag from HELLO_REPLY */

    char    pending_code[PWE_SEC_CODE_DIGITS + 1];
    int     force_pair;                      /* initiator: pair even if both sides know each other */
    int     resume_only;                     /* initiator: never pair on this connection */
    uint8_t y[32], Ya[32];
    uint8_t k_r2s[32], k_s2r[32];
    int     attempt_open;                    /* responder: PAIR_A taken, no confirm yet */

    struct pwe_noise_hs hs;
    struct pwe_noise_cipher tx, rx;

    int lock_seconds, code_seconds;
    int peer_error, peer_error_detail, local_error;
};

struct pwe_sec *pwe_sec_new(enum pwe_sec_role role, const struct pwe_sec_identity *idn,
                            const struct pwe_sec_store *store, struct pwe_sec_gate *gate,
                            const struct pwe_sec_responder_opts *opts) {
    if (!idn || !store || (role == PWE_SEC_RESPONDER && !gate)) return NULL;
    struct pwe_sec *sec = (struct pwe_sec *)calloc(1, sizeof(*sec));
    if (!sec) return NULL;
    sec->role = role;
    sec->st = role == PWE_SEC_INITIATOR ? ST_I_START : ST_R_WAIT_HELLO;
    sec->idn = idn;
    sec->store = store;
    sec->gate = gate;
    sec->direct_link = opts ? opts->direct_link : 0;
    return sec;
}

void pwe_sec_free(struct pwe_sec *sec) {
    if (!sec) return;
    sodium_memzero(sec, sizeof(*sec));
    free(sec);
}

int pwe_sec_is_secure(const struct pwe_sec *sec) { return sec && sec->st == ST_SECURE; }
int pwe_sec_is_pairing(const struct pwe_sec *sec) {
    if (!sec) return 0;
    switch (sec->st) {
    case ST_I_PAIR_REQ_SENT: case ST_I_NEED_CODE: case ST_I_PAIR_A_SENT:
    case ST_R_CODE_SHOWN: case ST_R_WAIT_CONFIRM:
        return 1;
    default:
        return 0;
    }
}
const char *pwe_sec_code(const struct pwe_sec *sec) {
    return (sec && sec->gate) ? sec->gate->code : "";
}
const char *pwe_sec_peer_name(const struct pwe_sec *sec) { return sec ? sec->peer_name : ""; }
const uint8_t *pwe_sec_peer_id(const struct pwe_sec *sec) {
    return (sec && sec->have_peer_id) ? sec->peer_id : NULL;
}
int pwe_sec_lock_seconds(const struct pwe_sec *sec) { return sec ? sec->lock_seconds : 0; }
int pwe_sec_code_seconds(const struct pwe_sec *sec) { return sec ? sec->code_seconds : 0; }
int pwe_sec_peer_error(const struct pwe_sec *sec) { return sec ? sec->peer_error : 0; }
int pwe_sec_peer_error_detail(const struct pwe_sec *sec) { return sec ? sec->peer_error_detail : 0; }
int pwe_sec_local_error(const struct pwe_sec *sec) { return sec ? sec->local_error : 0; }

/* Send ERROR, remember why, and mark the connection for closing. */
static int fail(struct pwe_sec *sec, struct pwe_sec_out *out, enum pwe_sec_error err, int detail, int ev) {
    uint8_t p[3];
    p[0] = (uint8_t)err;
    put_be16(p + 1, (uint16_t)(detail < 0 ? 0 : detail > 0xffff ? 0xffff : detail));
    if (out) (void)out_packet(out, PWE_PKT_SEC_ERROR, p, sizeof(p));
    sec->local_error = err;
    sec->st = ST_DEAD;
    return ev | PWE_SEC_EV_CLOSE;
}

/* Close without telling the peer (it sent the error, or the data is garbage). */
static int die(struct pwe_sec *sec, enum pwe_sec_error err, int ev) {
    sec->local_error = err;
    sec->st = ST_DEAD;
    return ev | PWE_SEC_EV_CLOSE;
}

static int valid_code(const char *code) {
    if (!code) return 0;
    for (int i = 0; i < PWE_SEC_CODE_DIGITS; i++)
        if (code[i] < '0' || code[i] > '9') return 0;
    return code[PWE_SEC_CODE_DIGITS] == '\0';
}

/* Prologue for KK, binding the negotiation: label || BE16 len || HELLO || BE16 len || REPLY. */
static size_t build_prologue(const struct pwe_sec *sec, uint8_t *buf, size_t cap) {
    size_t n = sizeof(k_prologue_label) - 1;
    if (cap < n + 4 + sec->hello_len + sec->reply_len) return 0;
    memcpy(buf, k_prologue_label, n);
    put_be16(buf + n, (uint16_t)sec->hello_len); n += 2;
    memcpy(buf + n, sec->hello, sec->hello_len); n += sec->hello_len;
    put_be16(buf + n, (uint16_t)sec->reply_len); n += 2;
    memcpy(buf + n, sec->reply, sec->reply_len); n += sec->reply_len;
    return n;
}

static int derive_pair_keys(struct pwe_sec *sec, const uint8_t isk[64]) {
    crypto_hash_sha512_state st;
    uint8_t h[64];
    crypto_hash_sha512_init(&st);
    sha512_lv(&st, k_pair_keys_label, sizeof(k_pair_keys_label) - 1);
    sha512_lv(&st, isk, 64);
    sha512_lv(&st, sec->hello, sec->hello_len);
    sha512_lv(&st, sec->reply, sec->reply_len);
    crypto_hash_sha512_final(&st, h);
    memcpy(sec->k_r2s, h, 32);
    memcpy(sec->k_s2r, h + 32, 32);
    sodium_memzero(h, sizeof(h));
    sodium_memzero(&st, sizeof(st));
    return 0;
}

static void cpace_sid(const struct pwe_sec *sec, uint8_t sid[2 * NONCE_BYTES]) {
    memcpy(sid, sec->sender_nonce, NONCE_BYTES);
    memcpy(sid + NONCE_BYTES, sec->receiver_nonce, NONCE_BYTES);
}

/* Sealed identity message used in PAIR_B / PAIR_CONFIRM: pub || u8 len || name. */
static int seal_identity(const struct pwe_sec *sec, const uint8_t key[32], uint8_t *out, size_t *out_len) {
    uint8_t pt[PWE_SEC_KEY_BYTES + 1 + PWE_SEC_NAME_MAX];
    size_t name_len = strlen(sec->idn->name);
    memcpy(pt, sec->idn->pub, PWE_SEC_KEY_BYTES);
    pt[PWE_SEC_KEY_BYTES] = (uint8_t)name_len;
    memcpy(pt + PWE_SEC_KEY_BYTES + 1, sec->idn->name, name_len);
    size_t len = PWE_SEC_KEY_BYTES + 1 + name_len;
    struct pwe_noise_cipher c = { .n = 0, .has_key = 1 };
    memcpy(c.k, key, 32);
    int rc = pwe_noise_encrypt(&c, NULL, 0, pt, len, out);
    sodium_memzero(&c, sizeof(c));
    *out_len = len + PWE_SEC_TAG_BYTES;
    return rc;
}

static int open_identity(struct pwe_sec *sec, const uint8_t key[32], const uint8_t *ct, size_t len,
                         uint8_t pub[32]) {
    uint8_t pt[PWE_SEC_KEY_BYTES + 1 + PWE_SEC_NAME_MAX];
    if (len < PWE_SEC_KEY_BYTES + 1 + PWE_SEC_TAG_BYTES || len > sizeof(pt) + PWE_SEC_TAG_BYTES) return -1;
    struct pwe_noise_cipher c = { .n = 0, .has_key = 1 };
    memcpy(c.k, key, 32);
    int rc = pwe_noise_decrypt(&c, NULL, 0, ct, len, pt);
    sodium_memzero(&c, sizeof(c));
    if (rc != 0) return -1;
    size_t plen = len - PWE_SEC_TAG_BYTES;
    size_t name_len = pt[PWE_SEC_KEY_BYTES];
    if (PWE_SEC_KEY_BYTES + 1 + name_len != plen) return -2;
    memcpy(pub, pt, 32);
    copy_name(sec->peer_name, (const char *)pt + PWE_SEC_KEY_BYTES + 1, name_len);
    return 0;
}

/* Receiver: count a failed attempt; replace the code or lock. */
static int register_failure(struct pwe_sec *sec, uint64_t now_ms) {
    struct pwe_sec_gate *g = sec->gate;
    sec->attempt_open = 0;
    g->failures++;
    g->code[0] = '\0';
    if (g->failures >= PWE_SEC_MAX_FAILURES) {
        g->locked_until_ms = now_ms + PWE_SEC_LOCK_MS;
        g->failures = 0;
        sec->lock_seconds = PWE_SEC_LOCK_MS / 1000;
        fprintf(stderr, "[sec] pairing locked for %d s after %d wrong codes\n",
                PWE_SEC_LOCK_MS / 1000, PWE_SEC_MAX_FAILURES);
        return PWE_SEC_EV_LOCKED | PWE_SEC_EV_HIDE_CODE | PWE_SEC_EV_WRONG_CODE;
    }
    if (g->fixed_code) {
        snprintf(g->code, sizeof(g->code), "%s", g->fixed_code);
    } else {
        snprintf(g->code, sizeof(g->code), "%06u", (unsigned)randombytes_uniform(1000000));
    }
    g->code_expires_ms = now_ms + PWE_SEC_CODE_LIFETIME_MS;
    return PWE_SEC_EV_SHOW_CODE | PWE_SEC_EV_WRONG_CODE;
}

int pwe_sec_gate_tick(struct pwe_sec_gate *gate, uint64_t now_ms) {
    if (gate && gate->code[0] && now_ms >= gate->code_expires_ms) {
        gate->code[0] = '\0';
        return PWE_SEC_EV_HIDE_CODE;
    }
    return PWE_SEC_EV_NONE;
}

/* ---- Initiator --------------------------------------------------------------- */

int pwe_sec_start(struct pwe_sec *sec, const uint8_t *expected_id, const char *code,
                  struct pwe_sec_out *out, uint64_t now_ms) {
    (void)now_ms;
    if (!sec || sec->role != PWE_SEC_INITIATOR || sec->st != ST_I_START) return -1;
    if (expected_id) {
        memcpy(sec->expected_id, expected_id, PWE_SEC_ID_BYTES);
        sec->have_expected = 1;
    }
    if (code) sec->force_pair = 1;
    if (code && valid_code(code)) snprintf(sec->pending_code, sizeof(sec->pending_code), "%s", code);

    uint8_t *h = sec->hello;
    randombytes_buf(sec->sender_nonce, NONCE_BYTES);
    memcpy(h, k_magic, 4);
    h[4] = PWE_SEC_VERSION;
    h[5] = 1;                    /* one suite */
    h[6] = PWE_SEC_SUITE_V2;
    h[7] = 0;                    /* flags */
    memcpy(h + 8, sec->idn->id, PWE_SEC_ID_BYTES);
    memcpy(h + 24, sec->sender_nonce, NONCE_BYTES);
    sec->hello_len = HELLO_BYTES;
    if (out_packet(out, PWE_PKT_SEC_HELLO, h, sec->hello_len) != 0) return -1;
    sec->st = ST_I_HELLO_SENT;
    return PWE_SEC_EV_NONE;
}

static int send_pair_a(struct pwe_sec *sec, struct pwe_sec_out *out) {
    uint8_t sid[2 * NONCE_BYTES], g[32];
    cpace_sid(sec, sid);
    pwe_cpace_generator((const uint8_t *)sec->pending_code, PWE_SEC_CODE_DIGITS,
                        (const uint8_t *)k_cpace_ci, sizeof(k_cpace_ci) - 1, sid, sizeof(sid), g);
    pwe_cpace_sample_scalar(sec->y);
    int rc = pwe_cpace_share(g, sec->y, sec->Ya);
    sodium_memzero(g, sizeof(g));
    if (rc != 0) return fail(sec, out, PWE_SEC_ERR_PROTOCOL, 0, 0);
    if (out_packet(out, PWE_PKT_SEC_PAIR_A, sec->Ya, 32) != 0) return die(sec, PWE_SEC_ERR_PROTOCOL, 0);
    sec->st = ST_I_PAIR_A_SENT;
    return PWE_SEC_EV_NONE;
}

static int send_kk1(struct pwe_sec *sec, struct pwe_sec_out *out) {
    uint8_t prologue[160], msg[64];
    size_t plen = build_prologue(sec, prologue, sizeof(prologue)), mlen = 0;
    if (!plen || pwe_noise_kk_init(&sec->hs, 1, prologue, plen, sec->idn->priv, sec->peer_pub) != 0 ||
        pwe_noise_write(&sec->hs, NULL, 0, msg, sizeof(msg), &mlen) != 0)
        return fail(sec, out, PWE_SEC_ERR_PROTOCOL, 0, 0);
    if (out_packet(out, PWE_PKT_SEC_KK_1, msg, mlen) != 0) return die(sec, PWE_SEC_ERR_PROTOCOL, 0);
    sec->st = ST_I_KK1_SENT;
    return PWE_SEC_EV_NONE;
}

void pwe_sec_set_resume_only(struct pwe_sec *sec) {
    if (sec && sec->role == PWE_SEC_INITIATOR) sec->resume_only = 1;
}

int pwe_sec_submit_code(struct pwe_sec *sec, const char *code, struct pwe_sec_out *out) {
    if (!sec || sec->role != PWE_SEC_INITIATOR || sec->st != ST_I_NEED_CODE) return -1;
    if (!code) return fail(sec, out, PWE_SEC_ERR_CANCELLED, 0, 0);
    if (!valid_code(code)) return -1;
    snprintf(sec->pending_code, sizeof(sec->pending_code), "%s", code);
    return send_pair_a(sec, out);
}

static int i_on_reply(struct pwe_sec *sec, const uint8_t *p, size_t len, struct pwe_sec_out *out) {
    if (len < HELLO_BYTES || memcmp(p, k_magic, 4) != 0) return fail(sec, out, PWE_SEC_ERR_PROTOCOL, 0, 0);
    if (p[4] != PWE_SEC_VERSION || p[5] != PWE_SEC_SUITE_V2) return fail(sec, out, PWE_SEC_ERR_VERSION, 0, 0);
    sec->reply_len = len > sizeof(sec->reply) ? sizeof(sec->reply) : len;
    memcpy(sec->reply, p, sec->reply_len);
    sec->peer_status = p[6];
    sec->pairing_available = p[7] & 1;
    memcpy(sec->peer_id, p + 8, PWE_SEC_ID_BYTES);
    sec->have_peer_id = 1;
    memcpy(sec->receiver_nonce, p + 24, NONCE_BYTES);

    int ev = PWE_SEC_EV_NONE;
    if (sec->have_expected && memcmp(sec->expected_id, sec->peer_id, PWE_SEC_ID_BYTES) != 0)
        ev |= PWE_SEC_EV_IDENTITY_CHANGED;

    int found = sec->store->find(sec->store->ud, sec->peer_id, sec->peer_pub, sec->peer_name);
    if (found < 0) return fail(sec, out, PWE_SEC_ERR_STORE, 0, ev);
    sec->have_peer_pub = found == 0;

    if (sec->have_peer_pub && sec->peer_status == PWE_SEC_STATUS_KNOWN && !sec->force_pair)
        return ev | send_kk1(sec, out);

    if (sec->resume_only) return fail(sec, out, PWE_SEC_ERR_CANCELLED, 0, ev);
    if (!sec->pairing_available) return fail(sec, out, PWE_SEC_ERR_NOT_DIRECT, 0, ev);
    if (out_packet(out, PWE_PKT_SEC_PAIR_REQUEST, NULL, 0) != 0) return die(sec, PWE_SEC_ERR_PROTOCOL, ev);
    sec->st = ST_I_PAIR_REQ_SENT;
    return ev;
}

static int i_on_pair_b(struct pwe_sec *sec, const uint8_t *p, size_t len, struct pwe_sec_out *out) {
    if (len < 32) return fail(sec, out, PWE_SEC_ERR_PROTOCOL, 0, 0);
    uint8_t sid[2 * NONCE_BYTES], isk[64], rpub[32], rid[PWE_SEC_ID_BYTES];
    cpace_sid(sec, sid);
    if (pwe_cpace_isk(sec->y, sid, sizeof(sid), sec->Ya, sec->idn->id, PWE_SEC_ID_BYTES,
                      p, sec->peer_id, PWE_SEC_ID_BYTES, 1, isk) != 0)
        return fail(sec, out, PWE_SEC_ERR_PROTOCOL, 0, 0);
    derive_pair_keys(sec, isk);
    sodium_memzero(isk, sizeof(isk));
    sodium_memzero(sec->y, sizeof(sec->y));
    int rc = open_identity(sec, sec->k_r2s, p + 32, len - 32, rpub);
    if (rc == -1) return fail(sec, out, PWE_SEC_ERR_WRONG_CODE, 0, PWE_SEC_EV_WRONG_CODE);
    if (rc != 0) return fail(sec, out, PWE_SEC_ERR_PROTOCOL, 0, 0);
    pwe_sec_id_from_public(rpub, rid);
    if (memcmp(rid, sec->peer_id, PWE_SEC_ID_BYTES) != 0) return fail(sec, out, PWE_SEC_ERR_PROTOCOL, 0, 0);
    if (sec->store->save(sec->store->ud, sec->peer_id, rpub, sec->peer_name) != 0)
        return fail(sec, out, PWE_SEC_ERR_STORE, 0, 0);
    memcpy(sec->peer_pub, rpub, 32);
    sec->have_peer_pub = 1;

    uint8_t ct[PWE_SEC_KEY_BYTES + 1 + PWE_SEC_NAME_MAX + PWE_SEC_TAG_BYTES];
    size_t clen = 0;
    if (seal_identity(sec, sec->k_s2r, ct, &clen) != 0) return fail(sec, out, PWE_SEC_ERR_PROTOCOL, 0, 0);
    if (out_packet(out, PWE_PKT_SEC_PAIR_CONFIRM, ct, clen) != 0) return die(sec, PWE_SEC_ERR_PROTOCOL, 0);
    sodium_memzero(sec->k_r2s, 32);
    sodium_memzero(sec->k_s2r, 32);
    sodium_memzero(sec->pending_code, sizeof(sec->pending_code));
    fprintf(stderr, "[sec] paired with \"%s\"\n", sec->peer_name);
    return PWE_SEC_EV_PAIRED | send_kk1(sec, out);
}

static int i_on_kk2(struct pwe_sec *sec, const uint8_t *p, size_t len, struct pwe_sec_out *out) {
    uint8_t payload[64];
    size_t plen = 0;
    if (pwe_noise_read(&sec->hs, p, len, payload, sizeof(payload), &plen) != 0 ||
        pwe_noise_split(&sec->hs, &sec->tx, &sec->rx, NULL) != 0)
        return fail(sec, out, PWE_SEC_ERR_PROTOCOL, 0, 0);
    pwe_noise_wipe(&sec->hs);
    sec->st = ST_SECURE;
    return PWE_SEC_EV_SECURE;
}

/* ---- Responder --------------------------------------------------------------- */

static int r_on_hello(struct pwe_sec *sec, const uint8_t *p, size_t len, struct pwe_sec_out *out) {
    if (len < 4 || memcmp(p, k_magic, 4) != 0 || len < 6) return fail(sec, out, PWE_SEC_ERR_PROTOCOL, 0, 0);
    size_t nsuites = p[5];
    if (len < 6 + nsuites + 1 + PWE_SEC_ID_BYTES + NONCE_BYTES) return fail(sec, out, PWE_SEC_ERR_PROTOCOL, 0, 0);
    int suite_ok = 0;
    for (size_t i = 0; i < nsuites; i++) if (p[6 + i] == PWE_SEC_SUITE_V2) suite_ok = 1;
    if (p[4] < PWE_SEC_VERSION || !suite_ok) return fail(sec, out, PWE_SEC_ERR_VERSION, 0, 0);
    const uint8_t *id = p + 6 + nsuites + 1;
    memcpy(sec->peer_id, id, PWE_SEC_ID_BYTES);
    sec->have_peer_id = 1;
    memcpy(sec->sender_nonce, id + PWE_SEC_ID_BYTES, NONCE_BYTES);
    sec->hello_len = len > sizeof(sec->hello) ? sizeof(sec->hello) : len;
    memcpy(sec->hello, p, sec->hello_len);

    int found = sec->store->find(sec->store->ud, sec->peer_id, sec->peer_pub, sec->peer_name);
    if (found < 0) return fail(sec, out, PWE_SEC_ERR_STORE, 0, 0);
    sec->have_peer_pub = found == 0;

    uint8_t *r = sec->reply;
    randombytes_buf(sec->receiver_nonce, NONCE_BYTES);
    memcpy(r, k_magic, 4);
    r[4] = PWE_SEC_VERSION;
    r[5] = PWE_SEC_SUITE_V2;
    r[6] = sec->have_peer_pub ? PWE_SEC_STATUS_KNOWN : PWE_SEC_STATUS_UNKNOWN;
    r[7] = sec->direct_link ? 1 : 0;   /* pairing available on this link */
    memcpy(r + 8, sec->idn->id, PWE_SEC_ID_BYTES);
    memcpy(r + 24, sec->receiver_nonce, NONCE_BYTES);
    sec->reply_len = HELLO_BYTES;
    if (out_packet(out, PWE_PKT_SEC_HELLO_REPLY, r, sec->reply_len) != 0) return die(sec, PWE_SEC_ERR_PROTOCOL, 0);
    sec->st = ST_R_REPLIED;
    return PWE_SEC_EV_NONE;
}

static int r_on_pair_request(struct pwe_sec *sec, struct pwe_sec_out *out, uint64_t now_ms) {
    struct pwe_sec_gate *g = sec->gate;
    if (!sec->direct_link) return fail(sec, out, PWE_SEC_ERR_NOT_DIRECT, 0, 0);
    if (now_ms < g->locked_until_ms) {
        sec->lock_seconds = (int)((g->locked_until_ms - now_ms + 999) / 1000);
        return fail(sec, out, PWE_SEC_ERR_LOCKED, sec->lock_seconds, PWE_SEC_EV_LOCKED);
    }
    int ev = PWE_SEC_EV_SHOW_CODE, fresh = 0;
    if (!g->code[0] || now_ms >= g->code_expires_ms) {
        if (g->fixed_code) snprintf(g->code, sizeof(g->code), "%s", g->fixed_code);
        else snprintf(g->code, sizeof(g->code), "%06u", (unsigned)randombytes_uniform(1000000));
        g->code_expires_ms = now_ms + PWE_SEC_CODE_LIFETIME_MS;
        fresh = 1;
    }
    uint8_t p[3];
    sec->code_seconds = (int)((g->code_expires_ms - now_ms) / 1000);
    put_be16(p, (uint16_t)sec->code_seconds);
    p[2] = fresh ? 1 : 0;
    if (out_packet(out, PWE_PKT_SEC_PAIR_READY, p, sizeof(p)) != 0) return die(sec, PWE_SEC_ERR_PROTOCOL, 0);
    sec->st = ST_R_CODE_SHOWN;
    return ev;
}

static int r_on_pair_a(struct pwe_sec *sec, const uint8_t *p, size_t len, struct pwe_sec_out *out,
                       uint64_t now_ms) {
    struct pwe_sec_gate *g = sec->gate;
    if (len != 32) return fail(sec, out, PWE_SEC_ERR_PROTOCOL, 0, 0);
    if (!g->code[0] || now_ms >= g->code_expires_ms) {
        g->code[0] = '\0';
        return fail(sec, out, PWE_SEC_ERR_EXPIRED, 0, PWE_SEC_EV_HIDE_CODE);
    }
    /* This code is used up now, whatever happens next. */
    char code[PWE_SEC_CODE_DIGITS + 1];
    memcpy(code, g->code, sizeof(code));
    g->code[0] = '\0';
    sec->attempt_open = 1;

    uint8_t sid[2 * NONCE_BYTES], gen[32], yb[32], Yb[32], isk[64];
    cpace_sid(sec, sid);
    pwe_cpace_generator((const uint8_t *)code, PWE_SEC_CODE_DIGITS,
                        (const uint8_t *)k_cpace_ci, sizeof(k_cpace_ci) - 1, sid, sizeof(sid), gen);
    sodium_memzero(code, sizeof(code));
    pwe_cpace_sample_scalar(yb);
    int rc = pwe_cpace_share(gen, yb, Yb);
    if (rc == 0) rc = pwe_cpace_isk(yb, sid, sizeof(sid), p, sec->peer_id, PWE_SEC_ID_BYTES,
                                    Yb, sec->idn->id, PWE_SEC_ID_BYTES, 0, isk);
    sodium_memzero(yb, sizeof(yb));
    sodium_memzero(gen, sizeof(gen));
    if (rc != 0) return fail(sec, out, PWE_SEC_ERR_PROTOCOL, 0, register_failure(sec, now_ms));
    derive_pair_keys(sec, isk);
    sodium_memzero(isk, sizeof(isk));

    uint8_t msg[32 + PWE_SEC_KEY_BYTES + 1 + PWE_SEC_NAME_MAX + PWE_SEC_TAG_BYTES];
    size_t clen = 0;
    memcpy(msg, Yb, 32);
    if (seal_identity(sec, sec->k_r2s, msg + 32, &clen) != 0) return fail(sec, out, PWE_SEC_ERR_PROTOCOL, 0, 0);
    if (out_packet(out, PWE_PKT_SEC_PAIR_B, msg, 32 + clen) != 0) return die(sec, PWE_SEC_ERR_PROTOCOL, 0);
    sec->st = ST_R_WAIT_CONFIRM;
    return PWE_SEC_EV_HIDE_CODE;
}

static int r_on_pair_confirm(struct pwe_sec *sec, const uint8_t *p, size_t len, struct pwe_sec_out *out,
                             uint64_t now_ms) {
    uint8_t spub[32], sid_check[PWE_SEC_ID_BYTES];
    int rc = open_identity(sec, sec->k_s2r, p, len, spub);
    sodium_memzero(sec->k_r2s, 32);
    sodium_memzero(sec->k_s2r, 32);
    if (rc == -1) return fail(sec, out, PWE_SEC_ERR_WRONG_CODE, 0, register_failure(sec, now_ms));
    pwe_sec_id_from_public(spub, sid_check);
    if (rc != 0 || memcmp(sid_check, sec->peer_id, PWE_SEC_ID_BYTES) != 0)
        return fail(sec, out, PWE_SEC_ERR_PROTOCOL, 0, register_failure(sec, now_ms));
    sec->attempt_open = 0;
    sec->gate->failures = 0;
    if (sec->store->save(sec->store->ud, sec->peer_id, spub, sec->peer_name) != 0)
        return fail(sec, out, PWE_SEC_ERR_STORE, 0, 0);
    memcpy(sec->peer_pub, spub, 32);
    sec->have_peer_pub = 1;
    sec->st = ST_R_WAIT_KK1;
    fprintf(stderr, "[sec] paired with \"%s\"\n", sec->peer_name);
    return PWE_SEC_EV_PAIRED;
}

static int r_on_kk1(struct pwe_sec *sec, const uint8_t *p, size_t len, struct pwe_sec_out *out) {
    if (!sec->have_peer_pub) return fail(sec, out, PWE_SEC_ERR_NEED_PAIRING, 0, 0);
    uint8_t prologue[160], payload[64], msg[64];
    size_t plen = build_prologue(sec, prologue, sizeof(prologue)), n = 0, mlen = 0;
    if (!plen || pwe_noise_kk_init(&sec->hs, 0, prologue, plen, sec->idn->priv, sec->peer_pub) != 0)
        return fail(sec, out, PWE_SEC_ERR_PROTOCOL, 0, 0);
    if (pwe_noise_read(&sec->hs, p, len, payload, sizeof(payload), &n) != 0)
        return fail(sec, out, PWE_SEC_ERR_NEED_PAIRING, 0, 0);
    if (pwe_noise_write(&sec->hs, NULL, 0, msg, sizeof(msg), &mlen) != 0 ||
        pwe_noise_split(&sec->hs, &sec->tx, &sec->rx, NULL) != 0)
        return fail(sec, out, PWE_SEC_ERR_PROTOCOL, 0, 0);
    pwe_noise_wipe(&sec->hs);
    if (out_packet(out, PWE_PKT_SEC_KK_2, msg, mlen) != 0) return die(sec, PWE_SEC_ERR_PROTOCOL, 0);
    sec->st = ST_SECURE;
    return PWE_SEC_EV_SECURE;
}

/* ---- Dispatch ---------------------------------------------------------------- */

static int on_peer_error(struct pwe_sec *sec, const uint8_t *p, size_t len, uint64_t now_ms) {
    sec->peer_error = len >= 1 ? p[0] : PWE_SEC_ERR_PROTOCOL;
    sec->peer_error_detail = len >= 3 ? get_be16(p + 1) : 0;
    int ev = PWE_SEC_EV_PEER_ERROR;
    if (sec->role == PWE_SEC_INITIATOR) {
        if (sec->peer_error == PWE_SEC_ERR_WRONG_CODE) ev |= PWE_SEC_EV_WRONG_CODE;
        if (sec->peer_error == PWE_SEC_ERR_LOCKED) {
            sec->lock_seconds = sec->peer_error_detail;
            ev |= PWE_SEC_EV_LOCKED;
        }
    } else if (sec->attempt_open) {
        ev |= register_failure(sec, now_ms);
    } else if (sec->st == ST_R_CODE_SHOWN && sec->peer_error == PWE_SEC_ERR_CANCELLED) {
        sec->gate->code[0] = '\0';
        ev |= PWE_SEC_EV_HIDE_CODE;
    }
    return die(sec, PWE_SEC_ERR_NONE, ev);
}

int pwe_sec_handle(struct pwe_sec *sec, uint8_t type, const uint8_t *payload, size_t len,
                   struct pwe_sec_out *out, uint64_t now_ms) {
    if (!sec || sec->st == ST_DEAD) return PWE_SEC_EV_CLOSE;
    if (type == PWE_PKT_SEC_ERROR) return on_peer_error(sec, payload, len, now_ms);

    if (sec->role == PWE_SEC_INITIATOR) {
        switch (sec->st) {
        case ST_I_HELLO_SENT:
            if (type == PWE_PKT_SEC_HELLO_REPLY) return i_on_reply(sec, payload, len, out);
            break;
        case ST_I_PAIR_REQ_SENT:
            if (type == PWE_PKT_SEC_PAIR_READY && len >= 2) {
                sec->code_seconds = get_be16(payload);
                int fresh = len >= 3 && (payload[2] & 1);
                /* A code typed before this one was made cannot be right. */
                if (sec->pending_code[0] && !fresh) return send_pair_a(sec, out);
                sodium_memzero(sec->pending_code, sizeof(sec->pending_code));
                sec->st = ST_I_NEED_CODE;
                return PWE_SEC_EV_NEED_CODE;
            }
            break;
        case ST_I_PAIR_A_SENT:
            if (type == PWE_PKT_SEC_PAIR_B) return i_on_pair_b(sec, payload, len, out);
            break;
        case ST_I_KK1_SENT:
            if (type == PWE_PKT_SEC_KK_2) return i_on_kk2(sec, payload, len, out);
            break;
        default:
            break;
        }
    } else {
        switch (sec->st) {
        case ST_R_WAIT_HELLO:
            if (type == PWE_PKT_SEC_HELLO) return r_on_hello(sec, payload, len, out);
            break;
        case ST_R_REPLIED:
            if (type == PWE_PKT_SEC_PAIR_REQUEST) return r_on_pair_request(sec, out, now_ms);
            if (type == PWE_PKT_SEC_KK_1) return r_on_kk1(sec, payload, len, out);
            break;
        case ST_R_CODE_SHOWN:
            if (type == PWE_PKT_SEC_PAIR_A) return r_on_pair_a(sec, payload, len, out, now_ms);
            break;
        case ST_R_WAIT_CONFIRM:
            if (type == PWE_PKT_SEC_PAIR_CONFIRM) return r_on_pair_confirm(sec, payload, len, out, now_ms);
            break;
        case ST_R_WAIT_KK1:
            if (type == PWE_PKT_SEC_KK_1) return r_on_kk1(sec, payload, len, out);
            break;
        default:
            break;
        }
    }
    /* Anything else, including a second HELLO or handshake traffic once secure. */
    int ev = 0;
    if (sec->role == PWE_SEC_RESPONDER && sec->attempt_open) ev = register_failure(sec, now_ms);
    return fail(sec, out, PWE_SEC_ERR_PROTOCOL, 0, ev);
}

int pwe_sec_closed(struct pwe_sec *sec, uint64_t now_ms) {
    if (!sec) return PWE_SEC_EV_NONE;
    int ev = PWE_SEC_EV_NONE;
    if (sec->role == PWE_SEC_RESPONDER && sec->attempt_open) ev = register_failure(sec, now_ms);
    sodium_memzero(&sec->tx, sizeof(sec->tx));
    sodium_memzero(&sec->rx, sizeof(sec->rx));
    pwe_noise_wipe(&sec->hs);
    sec->st = ST_DEAD;
    return ev;
}

/* ---- Records ----------------------------------------------------------------- */

int pwe_sec_seal(struct pwe_sec *sec, uint8_t inner_type, const uint8_t *inner, size_t inner_len,
                 uint8_t *out, size_t out_cap, size_t *out_len) {
    if (!sec || sec->st != ST_SECURE) return -1;
    size_t total = inner_len + PWE_SEC_SEAL_OVERHEAD;
    if (out_cap < total || 1 + 1 + inner_len + PWE_SEC_TAG_BYTES > 0xffffffffu) return -1;
    put_be32(out, (uint32_t)(total - 4));
    out[4] = PWE_PKT_SEC_SEALED;
    out[5] = inner_type;
    if (inner_len) memcpy(out + 6, inner, inner_len);
    if (pwe_noise_encrypt(&sec->tx, NULL, 0, out + 5, 1 + inner_len, out + 5) != 0) return -1;
    *out_len = total;
    return 0;
}

int pwe_sec_open(struct pwe_sec *sec, uint8_t *payload, size_t len,
                 uint8_t *inner_type, uint8_t **inner, size_t *inner_len) {
    if (!sec || sec->st != ST_SECURE || len < 1 + PWE_SEC_TAG_BYTES) return -1;
    if (pwe_noise_decrypt(&sec->rx, NULL, 0, payload, len, payload) != 0) {
        sec->st = ST_DEAD;
        return -1;
    }
    *inner_type = payload[0];
    *inner = payload + 1;
    *inner_len = len - 1 - PWE_SEC_TAG_BYTES;
    return 0;
}

/* ---- Unencrypted sessions (D3) ----------------------------------------------- */

int pwe_sec_plaintext_allowed(uint8_t type, int to_receiver) {
    if (to_receiver) {
        switch (type) {
        case 0x10:   /* hello */
        case 0x12:   /* create session ack */
        case 0x20: case 0x21: case 0x22: case 0x23:   /* picture and sound */
        case 0x30: case 0x31: case 0x32:              /* heartbeat, teardown, pointer position */
        case 0x39:                                    /* pointer picture */
        case 0x35: case 0x37: case 0x38:              /* brightness, volume, display tweaks */
        case 0x40:                                    /* link test */
            return 1;
        default:
            return 0;   /* 0x13 language, 0x33 input, 0x34 input mode, 0x36 clipboard, unknown */
        }
    }
    switch (type) {
    case 0x11:   /* display profile */
    case 0x30: case 0x31:
    case 0x38:
        return 1;
    default:
        return 0;   /* 0x33 input, 0x36 clipboard, unknown */
    }
}
