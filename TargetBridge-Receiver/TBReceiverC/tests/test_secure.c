/* test_secure.c — PWE pairing and encrypted sessions (pwe_secure.c, tb_conn.c).
 *
 *   ./test_secure           test vectors, state machine, connection layer
 *   ./test_secure --bench   ChaCha20-Poly1305 records: GB/s and CPU share at 300 Mbit/s
 *
 * Vectors: CPace draft-irtf-cfrg-cpace-21 appendix B.3 (ristretto255, SHA-512);
 * Noise_KK_25519_ChaChaPoly_SHA256 from cacophony's vectors/cacophony.txt.
 */

#include "net.h"
#include "proto.h"
#include "pwe_secure.h"

#include <sodium.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static int failures = 0;
static int checks = 0;

#define CHECK(cond, msg) do { checks++; if (!(cond)) { failures++; \
    fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, msg); } } while (0)

static size_t unhex(const char *hex, uint8_t *out, size_t cap) {
    size_t len = 0;
    if (sodium_hex2bin(out, cap, hex, strlen(hex), " \n", &len, NULL) != 0) return (size_t)-1;
    return len;
}

static int eq_hex(const uint8_t *got, size_t len, const char *hex) {
    uint8_t want[4096];
    size_t n = unhex(hex, want, sizeof(want));
    return n == len && memcmp(got, want, len) == 0;
}

/* ---- CPace ----------------------------------------------------------------- */

static void test_cpace_vectors(void) {
    const uint8_t prs[] = "Password";
    const uint8_t ci[] = { 0x0b,'A','_','i','n','i','t','i','a','t','o','r',
                           0x0b,'B','_','r','e','s','p','o','n','d','e','r' };
    uint8_t sid[16], ya[32], yb[32], g[32], Ya[32], Yb[32], isk_a[64], isk_b[64];
    unhex("7e4b4791d6a8ef019b936c79fb7f2c57", sid, sizeof(sid));
    unhex("da3d23700a9e5699258aef94dc060dfda5ebb61f02a5ea77fad53f4ff0976d08", ya, sizeof(ya));
    unhex("d2316b454718c35362d83d69df6320f38578ed5984651435e2949762d900b80d", yb, sizeof(yb));

    pwe_cpace_generator(prs, 8, ci, sizeof(ci), sid, sizeof(sid), g);
    CHECK(eq_hex(g, 32, "222b6b195fe84b1652badb6f6a3ae3d24341e7306967f0b8115b40d5698c7e56"),
          "CPace B.3.1 generator");
    CHECK(pwe_cpace_share(g, ya, Ya) == 0 &&
          eq_hex(Ya, 32, "d6bac480f2c386c394efc7c47adb9925dcd2630b64f240c50f8d0eec482b9157"), "CPace B.3.2 Ya");
    CHECK(pwe_cpace_share(g, yb, Yb) == 0 &&
          eq_hex(Yb, 32, "3ea7e0b19560d7c0b0f5734f63b955286dfa8232b5ebe63324e2d9e7433f7258"), "CPace B.3.3 Yb");

    const char *isk_hex = "b69effbf61b51d56401c0f65601abe428de8206feaaf0e32198896dcae7b35cd"
                          "2b38950a39dfd5d4a79164614c2984f7daa460b588c1e80c3fa2068af7900447";
    CHECK(pwe_cpace_isk(ya, sid, 16, Ya, (const uint8_t *)"ADa", 3, Yb, (const uint8_t *)"ADb", 3, 1, isk_a) == 0 &&
          eq_hex(isk_a, 64, isk_hex), "CPace B.3.5 ISK (A)");
    CHECK(pwe_cpace_isk(yb, sid, 16, Ya, (const uint8_t *)"ADa", 3, Yb, (const uint8_t *)"ADb", 3, 0, isk_b) == 0 &&
          eq_hex(isk_b, 64, isk_hex), "CPace B.3.5 ISK (B)");

    /* B.3.10 / B.3.11: valid input, then a non-decodable share and the identity. */
    uint8_t s[32], X[32], out[32], bad1[32], bad2[32] = { 0 }, isk[64];
    unhex("7cd0e075fa7955ba52c02759a6c90dbbfc10e6d40aea8d283e407d88cf538a05", s, sizeof(s));
    unhex("2c3c6b8c4f3800e7aef6864025b4ed79bd599117e427c41bd47d93d654b4a51c", X, sizeof(X));
    unhex("2b3c6b8c4f3800e7aef6864025b4ed79bd599117e427c41bd47d93d654b4a51c", bad1, sizeof(bad1));
    CHECK(crypto_scalarmult_ristretto255(out, s, X) == 0 &&
          eq_hex(out, 32, "7c13645fe790a468f62c39beb7388e541d8405d1ade69d1778c5fe3e7f6b600e"),
          "CPace B.3.10 scalar_mult_vfy");
    CHECK(pwe_cpace_isk(s, sid, 16, Ya, NULL, 0, bad1, NULL, 0, 1, isk) != 0, "CPace B.3.11 invalid share aborts");
    CHECK(pwe_cpace_isk(s, sid, 16, Ya, NULL, 0, bad2, NULL, 0, 1, isk) != 0, "CPace B.3.11 identity aborts");
}

/* ---- Noise KK ---------------------------------------------------------------- */

static void test_noise_vectors(void) {
    uint8_t prologue[16], is[32], ie[32], irs[32], rs[32], re[32], irs_check[32];
    size_t plen = unhex("4a6f686e2047616c74", prologue, sizeof(prologue));
    unhex("e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1", is, 32);
    unhex("893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a", ie, 32);
    unhex("31e0303fd6418d2f8c0e78b91f22e8caed0fbe48656dcf4767e4834f701b8f62", irs, 32);
    unhex("4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893", rs, 32);
    unhex("bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b", re, 32);
    crypto_scalarmult_base(irs_check, rs);
    CHECK(memcmp(irs_check, irs, 32) == 0, "Noise vector: responder static matches");
    uint8_t is_pub[32];
    crypto_scalarmult_base(is_pub, is);

    struct pwe_noise_hs I, R;
    CHECK(pwe_noise_kk_init(&I, 1, prologue, plen, is, irs) == 0, "Noise init (initiator)");
    CHECK(pwe_noise_kk_init(&R, 0, prologue, plen, rs, is_pub) == 0, "Noise init (responder)");
    pwe_noise_set_ephemeral(&I, ie);
    pwe_noise_set_ephemeral(&R, re);

    static const char *payloads[6] = {
        "4c756477696720766f6e204d69736573", "4d757272617920526f746862617264",
        "462e20412e20486179656b", "4361726c204d656e676572",
        "4a65616e2d426170746973746520536179", "457567656e2042f6686d20766f6e2042617765726b" };
    static const char *ciphertexts[6] = {
        "ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c79440177015efc1fe7a37c629af7120a96274e6ab7afcc9261901d0e09ae32a5bb96",
        "95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f144808843b274d3429adc47ca093ba63ef90f8da89fda108db471dccfa4894aa7b00003",
        "966b05bc69ec01b8454d3160a214e6f24a3d884eb31ec2408af63f",
        "0ad887fba4f611bbb4afe44ba3556b8164332ca7d5934634d63d80",
        "012b28ae646ae7830e2c5472cb023eab071c1db3d8413ec69b513b83832f974c2d",
        "bb3e6a48160d9c5971d37f975727294e0d868342db31832e54d07191ab0ca3c3703b5ed3d9" };

    uint8_t pl[64], ct[128], back[128];
    size_t pl_len, ct_len, back_len;

    pl_len = unhex(payloads[0], pl, sizeof(pl));
    CHECK(pwe_noise_write(&I, pl, pl_len, ct, sizeof(ct), &ct_len) == 0 &&
          eq_hex(ct, ct_len, ciphertexts[0]), "Noise KK message 1");
    CHECK(pwe_noise_read(&R, ct, ct_len, back, sizeof(back), &back_len) == 0 &&
          back_len == pl_len && memcmp(back, pl, pl_len) == 0, "Noise KK message 1 read");

    pl_len = unhex(payloads[1], pl, sizeof(pl));
    CHECK(pwe_noise_write(&R, pl, pl_len, ct, sizeof(ct), &ct_len) == 0 &&
          eq_hex(ct, ct_len, ciphertexts[1]), "Noise KK message 2");
    CHECK(pwe_noise_read(&I, ct, ct_len, back, sizeof(back), &back_len) == 0 &&
          back_len == pl_len && memcmp(back, pl, pl_len) == 0, "Noise KK message 2 read");

    struct pwe_noise_cipher i_tx, i_rx, r_tx, r_rx;
    uint8_t hi[32], hr[32];
    CHECK(pwe_noise_split(&I, &i_tx, &i_rx, hi) == 0 && pwe_noise_split(&R, &r_tx, &r_rx, hr) == 0, "Noise split");
    CHECK(eq_hex(hi, 32, "24c6b51ecb76277140ca018b5985bc9f03de321dae2d34dcae433dafef0131d9") &&
          memcmp(hi, hr, 32) == 0, "Noise KK handshake hash");

    /* Transport: these are exactly the record layer's cipher operations. */
    for (int m = 2; m < 6; m++) {
        int from_i = (m % 2) == 0;
        pl_len = unhex(payloads[m], pl, sizeof(pl));
        struct pwe_noise_cipher *tx = from_i ? &i_tx : &r_tx, *rx = from_i ? &r_rx : &i_rx;
        CHECK(pwe_noise_encrypt(tx, NULL, 0, pl, pl_len, ct) == 0 &&
              eq_hex(ct, pl_len + 16, ciphertexts[m]), "Noise KK transport message");
        CHECK(pwe_noise_decrypt(rx, NULL, 0, ct, pl_len + 16, back) == 0 &&
              memcmp(back, pl, pl_len) == 0, "Noise KK transport read");
    }
}

/* ---- State machine ------------------------------------------------------------- */

struct mem_store {
    int n;
    uint8_t id[16][PWE_SEC_ID_BYTES];
    uint8_t pub[16][PWE_SEC_KEY_BYTES];
    char    name[16][PWE_SEC_NAME_MAX + 1];
    int     fail_reads;
};

static int mem_find(void *ud, const uint8_t id[16], uint8_t pub[32], char name[65]) {
    struct mem_store *m = (struct mem_store *)ud;
    if (m->fail_reads) return -1;
    for (int i = 0; i < m->n; i++) if (memcmp(m->id[i], id, 16) == 0) {
        memcpy(pub, m->pub[i], 32);
        if (name) memcpy(name, m->name[i], 65);
        return 0;
    }
    return 1;
}

static int mem_save(void *ud, const uint8_t id[16], const uint8_t pub[32], const char *name) {
    struct mem_store *m = (struct mem_store *)ud;
    int i = 0;
    while (i < m->n && memcmp(m->id[i], id, 16) != 0) i++;
    if (i == m->n) { if (m->n == 16) return -1; m->n++; }
    memcpy(m->id[i], id, 16);
    memcpy(m->pub[i], pub, 32);
    snprintf(m->name[i], 65, "%s", name ? name : "");
    return 0;
}

struct side {
    struct pwe_sec *sec;
    uint8_t buf[65536];
    struct pwe_sec_out out;
    int events;            /* accumulated */
};

static void side_reset_out(struct side *s) { s->out.buf = s->buf; s->out.len = 0; s->out.cap = sizeof(s->buf); }

/* Deliver everything `from` produced to `to`; repeat until both are quiet. */
static void pump(struct side *a, struct side *b, uint64_t now) {
    for (int round = 0; round < 20; round++) {
        int moved = 0;
        struct side *pairs[2][2] = { { a, b }, { b, a } };
        for (int k = 0; k < 2; k++) {
            struct side *from = pairs[k][0], *to = pairs[k][1];
            if (!from->out.len) continue;
            uint8_t copy[65536];
            size_t len = from->out.len;
            memcpy(copy, from->buf, len);
            side_reset_out(from);
            size_t off = 0;
            while (off + 5 <= len) {
                uint32_t plen = ((uint32_t)copy[off] << 24) | ((uint32_t)copy[off + 1] << 16) |
                                ((uint32_t)copy[off + 2] << 8) | copy[off + 3];
                to->events |= pwe_sec_handle(to->sec, copy[off + 4], copy + off + 5, plen - 1, &to->out, now);
                off += 4 + plen;
            }
            moved = 1;
        }
        if (!moved) return;
    }
}

struct fixture {
    struct pwe_sec_identity mac, imac;
    struct mem_store mac_store, imac_store;
    struct pwe_sec_store mac_ss, imac_ss;
    struct pwe_sec_gate gate;
};

static void fixture_init(struct fixture *f) {
    memset(f, 0, sizeof(*f));
    pwe_sec_identity_generate(&f->mac, "Lee’s MacBook Air");
    pwe_sec_identity_generate(&f->imac, "LL-iMac-2017");
    f->mac_ss = (struct pwe_sec_store){ mem_find, mem_save, &f->mac_store };
    f->imac_ss = (struct pwe_sec_store){ mem_find, mem_save, &f->imac_store };
    f->gate.fixed_code = "482913";
}

static void open_pair(struct fixture *f, struct side *s, struct side *r, int direct) {
    memset(s, 0, sizeof(*s));
    memset(r, 0, sizeof(*r));
    struct pwe_sec_responder_opts opts = { .direct_link = direct };
    s->sec = pwe_sec_new(PWE_SEC_INITIATOR, &f->mac, &f->mac_ss, NULL, NULL);
    r->sec = pwe_sec_new(PWE_SEC_RESPONDER, &f->imac, &f->imac_ss, &f->gate, &opts);
    side_reset_out(s);
    side_reset_out(r);
}

static void close_pair(struct side *s, struct side *r, uint64_t now) {
    r->events |= pwe_sec_closed(r->sec, now);
    s->events |= pwe_sec_closed(s->sec, now);
    pwe_sec_free(s->sec);
    pwe_sec_free(r->sec);
}

static void test_pair_then_resume(void) {
    struct fixture f;
    fixture_init(&f);
    struct side s, r;
    uint64_t now = 1000;

    /* First connection: unknown on both sides → code. */
    open_pair(&f, &s, &r, 1);
    pwe_sec_start(s.sec, NULL, NULL, &s.out, now);
    pump(&s, &r, now);
    CHECK(s.events & PWE_SEC_EV_NEED_CODE, "pair: Mac asks for the code");
    CHECK(r.events & PWE_SEC_EV_SHOW_CODE, "pair: iMac shows a code");
    CHECK(strcmp(pwe_sec_code(r.sec), "482913") == 0, "pair: code on the iMac");
    CHECK(pwe_sec_code_seconds(s.sec) == 60, "pair: Mac knows the code lifetime");
    CHECK(pwe_sec_submit_code(s.sec, "48291", &s.out) == -1, "pair: 5 digits rejected locally");
    CHECK(pwe_sec_submit_code(s.sec, "482913", &s.out) == 0, "pair: code accepted for sending");
    pump(&s, &r, now + 5000);
    CHECK((s.events & PWE_SEC_EV_PAIRED) && (r.events & PWE_SEC_EV_PAIRED), "pair: both stored");
    CHECK(pwe_sec_is_secure(s.sec) && pwe_sec_is_secure(r.sec), "pair: then secure on the same connection");
    CHECK(strcmp(pwe_sec_peer_name(r.sec), "Lee’s MacBook Air") == 0, "pair: iMac knows the Mac's name");
    CHECK(strcmp(pwe_sec_peer_name(s.sec), "LL-iMac-2017") == 0, "pair: Mac knows the iMac's name");
    CHECK(f.gate.code[0] == '\0', "pair: code gone after success");
    CHECK(f.mac_store.n == 1 && f.imac_store.n == 1, "pair: one record each");

    /* Records both ways, then tamper, replay, reorder. */
    uint8_t pkt[256], pkt2[256];
    size_t n = 0, n2 = 0;
    const char *json = "{\"text\":\"secret clipboard\"}";
    CHECK(pwe_sec_seal(s.sec, 0x36, (const uint8_t *)json, strlen(json), pkt, sizeof(pkt), &n) == 0, "seal");
    CHECK(n == strlen(json) + PWE_SEC_SEAL_OVERHEAD && pkt[4] == PWE_PKT_SEC_SEALED, "seal: framing");
    CHECK(memmem(pkt, n, "secret", 6) == NULL, "seal: plaintext not visible");
    uint8_t type = 0, *inner = NULL;
    size_t inner_len = 0;
    uint8_t keep[256];
    memcpy(keep, pkt, n);
    CHECK(pwe_sec_open(r.sec, pkt + 5, n - 5, &type, &inner, &inner_len) == 0 && type == 0x36 &&
          inner_len == strlen(json) && memcmp(inner, json, inner_len) == 0, "open");
    CHECK(pwe_sec_seal(r.sec, 0x11, (const uint8_t *)"{}", 2, pkt2, sizeof(pkt2), &n2) == 0 &&
          pwe_sec_open(s.sec, pkt2 + 5, n2 - 5, &type, &inner, &inner_len) == 0 && type == 0x11,
          "records receiver to sender");

    CHECK(pwe_sec_open(r.sec, keep + 5, n - 5, &type, &inner, &inner_len) != 0, "replay rejected");
    CHECK(!pwe_sec_is_secure(r.sec), "replay is final");
    close_pair(&s, &r, now);

    /* Second connection: KK with the stored keys, no code. */
    open_pair(&f, &s, &r, 1);
    pwe_sec_start(s.sec, f.mac_store.id[0], NULL, &s.out, now);
    pump(&s, &r, now);
    CHECK(pwe_sec_is_secure(s.sec) && pwe_sec_is_secure(r.sec), "resume: secure");
    CHECK(!(s.events & (PWE_SEC_EV_NEED_CODE | PWE_SEC_EV_IDENTITY_CHANGED)) &&
          !(r.events & PWE_SEC_EV_SHOW_CODE), "resume: no code, no identity change");
    /* Tamper and reorder. */
    CHECK(pwe_sec_seal(s.sec, 0x21, (const uint8_t *)"frame-1", 7, pkt, sizeof(pkt), &n) == 0, "seal 1");
    CHECK(pwe_sec_seal(s.sec, 0x21, (const uint8_t *)"frame-2", 7, pkt2, sizeof(pkt2), &n2) == 0, "seal 2");
    CHECK(pwe_sec_open(r.sec, pkt2 + 5, n2 - 5, &type, &inner, &inner_len) != 0, "reorder rejected");
    close_pair(&s, &r, now);

    open_pair(&f, &s, &r, 1);
    pwe_sec_start(s.sec, NULL, NULL, &s.out, now);
    pump(&s, &r, now);
    CHECK(pwe_sec_seal(s.sec, 0x21, (const uint8_t *)"frame-1", 7, pkt, sizeof(pkt), &n) == 0, "seal");
    pkt[n - 20] ^= 0x01;
    CHECK(pwe_sec_open(r.sec, pkt + 5, n - 5, &type, &inner, &inner_len) != 0, "one flipped bit rejected");
    close_pair(&s, &r, now);

    /* Resume over a non-direct link is fine; pairing over it is not (next test). */
    open_pair(&f, &s, &r, 0);
    pwe_sec_start(s.sec, NULL, NULL, &s.out, now);
    pump(&s, &r, now);
    CHECK(pwe_sec_is_secure(s.sec), "resume over the network once paired");
    close_pair(&s, &r, now);

    /* The receiver was reinstalled: new key, new id. */
    uint8_t old_id[16];
    memcpy(old_id, f.imac.id, 16);
    pwe_sec_identity_generate(&f.imac, "LL-iMac-2017");
    f.imac_store.n = 0;
    open_pair(&f, &s, &r, 1);
    pwe_sec_start(s.sec, old_id, NULL, &s.out, now);
    pump(&s, &r, now);
    CHECK(s.events & PWE_SEC_EV_IDENTITY_CHANGED, "reinstalled iMac: identity changed");
    CHECK(s.events & PWE_SEC_EV_NEED_CODE, "reinstalled iMac: asks for a code");
    pwe_sec_submit_code(s.sec, NULL, &s.out);   /* user cancels */
    pump(&s, &r, now);
    CHECK(r.events & PWE_SEC_EV_HIDE_CODE, "cancel hides the code");
    close_pair(&s, &r, now);
}

static void test_wrong_codes_and_lock(void) {
    struct fixture f;
    fixture_init(&f);
    f.gate.fixed_code = NULL;   /* real random codes */
    struct side s, r;
    uint64_t now = 50000;

    for (int attempt = 1; attempt <= PWE_SEC_MAX_FAILURES; attempt++) {
        open_pair(&f, &s, &r, 1);
        pwe_sec_start(s.sec, NULL, NULL, &s.out, now);
        pump(&s, &r, now);
        char shown[8];
        snprintf(shown, sizeof(shown), "%s", pwe_sec_code(r.sec));
        char wrong[8];
        snprintf(wrong, sizeof(wrong), "%06d", (atoi(shown) + 1) % 1000000);
        pwe_sec_submit_code(s.sec, wrong, &s.out);
        pump(&s, &r, now);
        CHECK(s.events & PWE_SEC_EV_WRONG_CODE, "wrong code reported to the Mac");
        CHECK(!pwe_sec_is_secure(s.sec) && !pwe_sec_is_secure(r.sec), "wrong code: not secure");
        CHECK(f.mac_store.n == 0 && f.imac_store.n == 0, "wrong code: nothing stored");
        if (attempt < PWE_SEC_MAX_FAILURES) {
            CHECK(f.gate.code[0] && strcmp(f.gate.code, shown) != 0, "wrong code: a new code is shown");
        } else {
            CHECK(r.events & PWE_SEC_EV_LOCKED, "fifth wrong code locks");
            CHECK(f.gate.code[0] == '\0', "locked: no code shown");
        }
        close_pair(&s, &r, now);
        now += 1000;
    }

    open_pair(&f, &s, &r, 1);
    pwe_sec_start(s.sec, NULL, NULL, &s.out, now);
    pump(&s, &r, now);
    CHECK((s.events & PWE_SEC_EV_LOCKED) && pwe_sec_lock_seconds(s.sec) > 50, "locked: Mac told how long");
    CHECK(pwe_sec_peer_error(s.sec) == PWE_SEC_ERR_LOCKED, "locked: error code");
    close_pair(&s, &r, now);

    now += PWE_SEC_LOCK_MS + 1;
    open_pair(&f, &s, &r, 1);
    pwe_sec_start(s.sec, NULL, NULL, &s.out, now);
    pump(&s, &r, now);
    CHECK(s.events & PWE_SEC_EV_NEED_CODE, "after the lock: code again");
    char good[8];
    snprintf(good, sizeof(good), "%s", pwe_sec_code(r.sec));
    pwe_sec_submit_code(s.sec, good, &s.out);
    pump(&s, &r, now);
    CHECK(pwe_sec_is_secure(s.sec) && pwe_sec_is_secure(r.sec), "after the lock: right code pairs");
    CHECK(f.gate.failures == 0, "success resets the count");
    close_pair(&s, &r, now);

    /* A guess that disconnects after PAIR_B still uses up the code. */
    f.mac_store.n = f.imac_store.n = 0;
    open_pair(&f, &s, &r, 1);
    pwe_sec_start(s.sec, NULL, NULL, &s.out, now);
    pump(&s, &r, now);
    char before[8];
    snprintf(before, sizeof(before), "%s", pwe_sec_code(r.sec));
    pwe_sec_submit_code(s.sec, "000000", &s.out);
    /* deliver PAIR_A only, then drop the connection */
    uint8_t pa[64];
    size_t pal = s.out.len;
    memcpy(pa, s.buf, pal);
    side_reset_out(&s);
    r.events |= pwe_sec_handle(r.sec, pa[4], pa + 5, pal - 5, &r.out, now);
    close_pair(&s, &r, now);
    CHECK(f.gate.failures == 1 && strcmp(f.gate.code, before) != 0, "hang-up after a guess counts");

    /* Expiry. */
    open_pair(&f, &s, &r, 1);
    pwe_sec_start(s.sec, NULL, NULL, &s.out, now);
    pump(&s, &r, now);
    CHECK(pwe_sec_gate_tick(&f.gate, now + PWE_SEC_CODE_LIFETIME_MS + 1) & PWE_SEC_EV_HIDE_CODE, "code expires");
    pwe_sec_submit_code(s.sec, before, &s.out);
    pump(&s, &r, now + PWE_SEC_CODE_LIFETIME_MS + 2);
    CHECK(pwe_sec_peer_error(s.sec) == PWE_SEC_ERR_EXPIRED, "expired code refused");
    close_pair(&s, &r, now);
}

static void test_refusals(void) {
    struct fixture f;
    fixture_init(&f);
    struct side s, r;

    open_pair(&f, &s, &r, 0);
    pwe_sec_start(s.sec, NULL, NULL, &s.out, 0);
    pump(&s, &r, 0);
    CHECK(pwe_sec_local_error(s.sec) == PWE_SEC_ERR_NOT_DIRECT, "no pairing over the network (Mac side)");
    CHECK(!(r.events & PWE_SEC_EV_SHOW_CODE), "no code shown for a network peer");
    close_pair(&s, &r, 0);

    f.imac_store.fail_reads = 1;
    open_pair(&f, &s, &r, 1);
    pwe_sec_start(s.sec, NULL, NULL, &s.out, 0);
    pump(&s, &r, 0);
    CHECK(pwe_sec_peer_error(s.sec) == PWE_SEC_ERR_STORE, "unreadable keychain is reported, not skipped");
    close_pair(&s, &r, 0);
    f.imac_store.fail_reads = 0;

    /* Out-of-order handshake message. */
    open_pair(&f, &s, &r, 1);
    uint8_t junk[32] = { 0 };
    r.events |= pwe_sec_handle(r.sec, PWE_PKT_SEC_KK_1, junk, sizeof(junk), &r.out, 0);
    CHECK(r.events & PWE_SEC_EV_CLOSE, "KK_1 before HELLO closes");
    close_pair(&s, &r, 0);

    /* Policy for unencrypted sessions. */
    CHECK(pwe_sec_plaintext_allowed(0x21, 1) && pwe_sec_plaintext_allowed(0x23, 1) &&
          pwe_sec_plaintext_allowed(0x35, 1) && pwe_sec_plaintext_allowed(0x37, 1), "plaintext: picture, sound, levels");
    CHECK(!pwe_sec_plaintext_allowed(0x33, 1) && !pwe_sec_plaintext_allowed(0x34, 1) &&
          !pwe_sec_plaintext_allowed(0x36, 1) && !pwe_sec_plaintext_allowed(0x13, 1), "plaintext: no input, clipboard, mode");
    CHECK(!pwe_sec_plaintext_allowed(0x33, 0) && !pwe_sec_plaintext_allowed(0x36, 0) &&
          pwe_sec_plaintext_allowed(0x11, 0), "plaintext from the iMac: profile yes, input and clipboard no");
}

/* ---- Connection layer (tb_conn) over a socket pair ---------------------------- */

struct seen { int count; uint8_t types[64]; int events; };

static void seen_packet(uint8_t type, const uint8_t *payload, size_t len, void *ud) {
    struct seen *s = (struct seen *)ud;
    if (s->count < 64) s->types[s->count] = type;
    s->count++;
    (void)payload; (void)len;
}

static void seen_event(struct tb_conn *c, int ev, void *ud) {
    ((struct seen *)ud)->events |= ev;
    (void)c;
}

static size_t frame(uint8_t *out, uint8_t type, const char *payload) {
    size_t len = strlen(payload);
    uint32_t plen = (uint32_t)len + 1;
    out[0] = (uint8_t)(plen >> 24); out[1] = (uint8_t)(plen >> 16); out[2] = (uint8_t)(plen >> 8); out[3] = (uint8_t)plen;
    out[4] = type;
    memcpy(out + 5, payload, len);
    return len + 5;
}

static void test_conn_layer(void) {
    struct fixture f;
    fixture_init(&f);
    int sv[2];

    /* Compatibility mode on: only the allowed types reach the receiver. */
    socketpair(AF_UNIX, SOCK_STREAM, 0, sv);
    struct tb_conn_config cfg = { &f.imac, &f.imac_ss, &f.gate, 1, 1 };
    struct tb_conn c;
    struct seen seen = { 0 };
    tb_conn_init(&c, sv[0], &cfg, seen_packet, seen_event, &seen);
    uint8_t buf[512];
    size_t n = 0;
    n += frame(buf + n, 0x10, "{\"senderName\":\"old\"}");
    n += frame(buf + n, 0x33, "{\"kind\":\"keyDown\",\"keyCode\":0}");
    n += frame(buf + n, 0x36, "{\"text\":\"x\"}");
    n += frame(buf + n, 0x34, "{\"mode\":\"receiverMaster\"}");
    n += frame(buf + n, 0x35, "{\"level\":0.5}");
    CHECK(tb_conn_feed(&c, buf, n, 0) == 0, "compat: accepted");
    CHECK((seen.events & TB_CONN_EV_PLAINTEXT) && (seen.events & TB_CONN_EV_READY), "compat: warned and ready");
    CHECK(seen.count == 2 && seen.types[0] == 0x10 && seen.types[1] == 0x35, "compat: input, clipboard, mode dropped");
    CHECK(tb_conn_send(&c, 0x36, (const uint8_t *)"{}", 2) == 1, "compat: no clipboard to the Mac");
    CHECK(tb_conn_send(&c, 0x11, (const uint8_t *)"{}", 2) == 0, "compat: profile sent");
    tb_conn_close(&c, 0);
    close(sv[1]);

    /* Compatibility mode off: refused. */
    socketpair(AF_UNIX, SOCK_STREAM, 0, sv);
    cfg.allow_plaintext = 0;
    memset(&seen, 0, sizeof(seen));
    tb_conn_init(&c, sv[0], &cfg, seen_packet, seen_event, &seen);
    n = frame(buf, 0x10, "{}");
    CHECK(tb_conn_feed(&c, buf, n, 0) == -1 && (seen.events & TB_CONN_EV_PLAINTEXT_REFUSED) && seen.count == 0,
          "protected: unencrypted sender refused");
    tb_conn_close(&c, 0);
    close(sv[1]);

    /* After HELLO, a plaintext 0x33 / 0x36 is never delivered. */
    socketpair(AF_UNIX, SOCK_STREAM, 0, sv);
    cfg.allow_plaintext = 1;
    memset(&seen, 0, sizeof(seen));
    tb_conn_init(&c, sv[0], &cfg, seen_packet, seen_event, &seen);
    struct pwe_sec *mac = pwe_sec_new(PWE_SEC_INITIATOR, &f.mac, &f.mac_ss, NULL, NULL);
    uint8_t hb[256];
    struct pwe_sec_out out = { hb, 0, sizeof(hb) };
    pwe_sec_start(mac, NULL, NULL, &out, 0);
    n = out.len;
    memcpy(buf, hb, n);
    n += frame(buf + n, 0x36, "{\"text\":\"x\"}");
    CHECK(tb_conn_feed(&c, buf, n, 0) == -1 && seen.count == 0 && (seen.events & TB_CONN_EV_SECURITY_FAILED),
          "handshake: plaintext clipboard before keys closes");
    pwe_sec_free(mac);
    tb_conn_close(&c, 0);
    close(sv[1]);

    /* Oversized length prefix. */
    socketpair(AF_UNIX, SOCK_STREAM, 0, sv);
    memset(&seen, 0, sizeof(seen));
    tb_conn_init(&c, sv[0], &cfg, seen_packet, seen_event, &seen);
    uint8_t huge[5] = { 0x7f, 0xff, 0xff, 0xff, 0x50 };
    CHECK(tb_conn_feed(&c, huge, sizeof(huge), 0) == -1, "oversized packet closes");
    tb_conn_close(&c, 0);
    close(sv[1]);
}

/* ---- Benchmark ------------------------------------------------------------------ */

static double now_s(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void bench(void) {
    struct fixture f;
    fixture_init(&f);
    struct side s, r;
    open_pair(&f, &s, &r, 1);
    pwe_sec_start(s.sec, NULL, "482913", &s.out, 0);
    pump(&s, &r, 0);
    if (!pwe_sec_is_secure(s.sec)) { fprintf(stderr, "bench: no session\n"); exit(1); }

    /* 300 Mbit/s = 37.5 MB/s. HEVC 5K frames are tens to hundreds of KB; keyframes ~1 MB. */
    const size_t sizes[] = { 1500, 64 * 1024, 1024 * 1024 };
    const double target = 300e6 / 8;
    printf("ChaCha20-Poly1305 records (libsodium %s), one core\n", sodium_version_string());
    for (size_t k = 0; k < sizeof(sizes) / sizeof(sizes[0]); k++) {
        size_t len = sizes[k];
        uint8_t *inner = malloc(len), *pkt = malloc(len + PWE_SEC_SEAL_OVERHEAD);
        randombytes_buf(inner, len);
        size_t total = 0, out_len = 0;
        double t0 = now_s(), seal_t = 0, open_t = 0;
        while (now_s() - t0 < 1.0) {
            double a = now_s();
            pwe_sec_seal(s.sec, 0x21, inner, len, pkt, len + PWE_SEC_SEAL_OVERHEAD, &out_len);
            double b = now_s();
            uint8_t type, *in2;
            size_t l2;
            if (pwe_sec_open(r.sec, pkt + 5, out_len - 5, &type, &in2, &l2) != 0) { fprintf(stderr, "bench: open\n"); exit(1); }
            double c2 = now_s();
            seal_t += b - a;
            open_t += c2 - b;
            total += len;
        }
        double seal_gbs = total / seal_t / 1e9, open_gbs = total / open_t / 1e9;
        printf("  %7zu B records: seal %.2f GB/s (%.2f%% of a core at 300 Mbit/s), "
               "open %.2f GB/s (%.2f%%)\n",
               len, seal_gbs, 100.0 * target / (seal_gbs * 1e9), open_gbs, 100.0 * target / (open_gbs * 1e9));
        free(inner);
        free(pkt);
    }
    double t0 = now_s();
    int handshakes = 0;
    while (now_s() - t0 < 0.5) {
        struct side s2, r2;
        open_pair(&f, &s2, &r2, 1);
        pwe_sec_start(s2.sec, NULL, NULL, &s2.out, 0);
        pump(&s2, &r2, 0);
        close_pair(&s2, &r2, 0);
        handshakes++;
    }
    printf("  KK handshake (both sides, in process): %.0f us\n", 1e6 * (now_s() - t0) / handshakes);
    close_pair(&s, &r, 0);
}

int main(int argc, char **argv) {
    if (pwe_sec_global_init() != 0) { fprintf(stderr, "sodium_init failed\n"); return 1; }
    if (argc > 1 && strcmp(argv[1], "--bench") == 0) { bench(); return 0; }
    test_cpace_vectors();
    test_noise_vectors();
    test_pair_then_resume();
    test_wrong_codes_and_lock();
    test_refusals();
    test_conn_layer();
    printf("test_secure: %d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
