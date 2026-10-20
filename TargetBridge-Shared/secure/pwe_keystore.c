/* pwe_keystore.c — see pwe_keystore.h. */

#include "pwe_keystore.h"

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <sodium.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define IDENTITY_ACCOUNT "identity"
#define PEER_PREFIX      "peer."
#define RECORD_VERSION   1

/* peer record: version | pub[32] | BE64 paired_at | u8 name_len | name */
#define PEER_RECORD_MIN  (1 + PWE_SEC_KEY_BYTES + 8 + 1)

void pwe_keystore_init(struct pwe_keystore *ks, const char *service, int max_peers) {
    memset(ks, 0, sizeof(*ks));
    snprintf(ks->service, sizeof(ks->service), "%s", service ? service : "");
    ks->max_peers = max_peers;
}

static CFStringRef cfstr(const char *s) {
    return CFStringCreateWithCString(kCFAllocatorDefault, s, kCFStringEncodingUTF8);
}

static CFMutableDictionaryRef base_query(const struct pwe_keystore *ks, const char *account) {
    CFMutableDictionaryRef q = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFStringRef service = cfstr(ks->service);
    CFDictionarySetValue(q, kSecClass, kSecClassGenericPassword);
    CFDictionarySetValue(q, kSecAttrService, service);
    CFRelease(service);
    if (account) {
        CFStringRef acc = cfstr(account);
        CFDictionarySetValue(q, kSecAttrAccount, acc);
        CFRelease(acc);
    }
    return q;
}

/* 0 + data, 1 not found, -1 error. */
static int item_read(struct pwe_keystore *ks, const char *account, uint8_t *buf, size_t cap, size_t *len) {
    CFMutableDictionaryRef q = base_query(ks, account);
    CFDictionarySetValue(q, kSecReturnData, kCFBooleanTrue);
    CFDictionarySetValue(q, kSecMatchLimit, kSecMatchLimitOne);
    CFTypeRef result = NULL;
    OSStatus st = SecItemCopyMatching(q, &result);
    CFRelease(q);
    ks->last_status = (int)st;
    if (st == errSecItemNotFound) return 1;
    if (st != errSecSuccess || !result || CFGetTypeID(result) != CFDataGetTypeID()) {
        if (result) CFRelease(result);
        fprintf(stderr, "[sec] keychain read failed (%d)\n", (int)st);
        return -1;
    }
    CFDataRef data = (CFDataRef)result;
    size_t n = (size_t)CFDataGetLength(data);
    if (n > cap) { CFRelease(result); return -1; }
    memcpy(buf, CFDataGetBytePtr(data), n);
    *len = n;
    CFRelease(result);
    return 0;
}

static int item_write(struct pwe_keystore *ks, const char *account, const char *label,
                      const uint8_t *buf, size_t len) {
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, buf, (CFIndex)len);
    CFStringRef lab = cfstr(label);
    CFMutableDictionaryRef q = base_query(ks, account);
    CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attrs, kSecValueData, data);
    CFDictionarySetValue(attrs, kSecAttrLabel, lab);
    OSStatus st = SecItemUpdate(q, attrs);
    if (st == errSecItemNotFound) {
        CFDictionarySetValue(q, kSecValueData, data);
        CFDictionarySetValue(q, kSecAttrLabel, lab);
        st = SecItemAdd(q, NULL);
    }
    CFRelease(attrs);
    CFRelease(q);
    CFRelease(lab);
    CFRelease(data);
    ks->last_status = (int)st;
    if (st != errSecSuccess) {
        fprintf(stderr, "[sec] keychain write failed (%d)\n", (int)st);
        return -1;
    }
    return 0;
}

static int item_delete(struct pwe_keystore *ks, const char *account) {
    CFMutableDictionaryRef q = base_query(ks, account);
    OSStatus st = SecItemDelete(q);
    CFRelease(q);
    ks->last_status = (int)st;
    return (st == errSecSuccess || st == errSecItemNotFound) ? 0 : -1;
}

static void peer_account(const uint8_t id[PWE_SEC_ID_BYTES], char out[64]) {
    char hex[2 * PWE_SEC_ID_BYTES + 1];
    pwe_sec_id_hex(id, hex);
    snprintf(out, 64, PEER_PREFIX "%s", hex);
}

int pwe_keystore_load_identity(struct pwe_keystore *ks, const char *name, struct pwe_sec_identity *idn) {
    uint8_t buf[1 + PWE_SEC_KEY_BYTES];
    size_t len = 0;
    int rc = item_read(ks, IDENTITY_ACCOUNT, buf, sizeof(buf), &len);
    if (rc < 0) return -1;
    if (rc == 0 && len == sizeof(buf) && buf[0] == RECORD_VERSION) {
        rc = pwe_sec_identity_from_private(idn, buf + 1, name);
        sodium_memzero(buf, sizeof(buf));
        return rc;
    }
    if (rc == 0) fprintf(stderr, "[sec] stored identity unreadable; making a new one\n");
    if (pwe_sec_identity_generate(idn, name) != 0) return -1;
    buf[0] = RECORD_VERSION;
    memcpy(buf + 1, idn->priv, PWE_SEC_KEY_BYTES);
    rc = item_write(ks, IDENTITY_ACCOUNT, "PWE Screen Encore pairing key", buf, sizeof(buf));
    sodium_memzero(buf, sizeof(buf));
    return rc;
}

static int parse_peer(const uint8_t *buf, size_t len, struct pwe_keystore_peer *p) {
    if (len < PEER_RECORD_MIN || buf[0] != RECORD_VERSION) return -1;
    size_t name_len = buf[1 + PWE_SEC_KEY_BYTES + 8];
    if (len != PEER_RECORD_MIN + name_len || name_len > PWE_SEC_NAME_MAX) return -1;
    memcpy(p->pub, buf + 1, PWE_SEC_KEY_BYTES);
    int64_t t = 0;
    for (int i = 0; i < 8; i++) t = (t << 8) | buf[1 + PWE_SEC_KEY_BYTES + i];
    p->paired_at = t;
    memcpy(p->name, buf + PEER_RECORD_MIN, name_len);
    p->name[name_len] = '\0';
    pwe_sec_id_from_public(p->pub, p->id);
    return 0;
}

int pwe_keystore_find_peer(void *ud, const uint8_t id[PWE_SEC_ID_BYTES],
                           uint8_t pub[PWE_SEC_KEY_BYTES], char name[PWE_SEC_NAME_MAX + 1]) {
    struct pwe_keystore *ks = (struct pwe_keystore *)ud;
    char account[64];
    uint8_t buf[PEER_RECORD_MIN + PWE_SEC_NAME_MAX];
    size_t len = 0;
    peer_account(id, account);
    int rc = item_read(ks, account, buf, sizeof(buf), &len);
    if (rc != 0) return rc;
    struct pwe_keystore_peer p;
    if (parse_peer(buf, len, &p) != 0 || memcmp(p.id, id, PWE_SEC_ID_BYTES) != 0) {
        fprintf(stderr, "[sec] stored peer record unreadable; treating as unknown\n");
        return 1;
    }
    memcpy(pub, p.pub, PWE_SEC_KEY_BYTES);
    if (name) memcpy(name, p.name, sizeof(p.name));
    return 0;
}

/* Accounts of all peer items (attributes only: the file keychain does not
 * return data for more than one item at a time). */
static int list_accounts(struct pwe_keystore *ks, char accounts[][64], int max) {
    CFMutableDictionaryRef q = base_query(ks, NULL);
    CFDictionarySetValue(q, kSecReturnAttributes, kCFBooleanTrue);
    CFDictionarySetValue(q, kSecMatchLimit, kSecMatchLimitAll);
    CFTypeRef result = NULL;
    OSStatus st = SecItemCopyMatching(q, &result);
    CFRelease(q);
    ks->last_status = (int)st;
    if (st == errSecItemNotFound) return 0;
    if (st != errSecSuccess || !result || CFGetTypeID(result) != CFArrayGetTypeID()) {
        if (result) CFRelease(result);
        return -1;
    }
    int n = 0;
    CFArrayRef items = (CFArrayRef)result;
    for (CFIndex i = 0; i < CFArrayGetCount(items) && n < max; i++) {
        CFDictionaryRef attrs = (CFDictionaryRef)CFArrayGetValueAtIndex(items, i);
        CFStringRef acc = (CFStringRef)CFDictionaryGetValue(attrs, kSecAttrAccount);
        char buf[64];
        if (!acc || CFGetTypeID(acc) != CFStringGetTypeID() ||
            !CFStringGetCString(acc, buf, sizeof(buf), kCFStringEncodingUTF8)) continue;
        if (strncmp(buf, PEER_PREFIX, strlen(PEER_PREFIX)) != 0) continue;
        memcpy(accounts[n++], buf, sizeof(buf));
    }
    CFRelease(result);
    return n;
}

int pwe_keystore_list_peers(struct pwe_keystore *ks, struct pwe_keystore_peer *out, int max) {
    char accounts[64][64];
    int n = list_accounts(ks, accounts, 64);
    if (n < 0) return -1;
    int count = 0;
    for (int i = 0; i < n; i++) {
        uint8_t buf[PEER_RECORD_MIN + PWE_SEC_NAME_MAX];
        size_t len = 0;
        struct pwe_keystore_peer p;
        if (item_read(ks, accounts[i], buf, sizeof(buf), &len) != 0) continue;
        if (parse_peer(buf, len, &p) != 0) continue;
        /* insertion sort, newest first */
        int at = count < max ? count : max;
        while (at > 0 && out[at - 1].paired_at < p.paired_at) {
            if (at < max) out[at] = out[at - 1];
            at--;
        }
        if (at < max) {
            out[at] = p;
            if (count < max) count++;
        }
    }
    return count;
}

int pwe_keystore_save_peer(void *ud, const uint8_t id[PWE_SEC_ID_BYTES],
                           const uint8_t pub[PWE_SEC_KEY_BYTES], const char *name) {
    struct pwe_keystore *ks = (struct pwe_keystore *)ud;
    char account[64];
    peer_account(id, account);

    if (ks->max_peers > 0) {
        struct pwe_keystore_peer peers[64];
        int n = pwe_keystore_list_peers(ks, peers, 64);
        int already = 0;
        for (int i = 0; i < n; i++) if (memcmp(peers[i].id, id, PWE_SEC_ID_BYTES) == 0) already = 1;
        /* Make room by forgetting the oldest pairings. */
        for (int i = n - 1; !already && i >= 0 && n >= ks->max_peers; i--, n--) {
            fprintf(stderr, "[sec] forgetting oldest paired peer \"%s\" to make room\n", peers[i].name);
            pwe_keystore_forget_peer(ks, peers[i].id);
        }
    }

    size_t name_len = name ? strlen(name) : 0;
    if (name_len > PWE_SEC_NAME_MAX) name_len = PWE_SEC_NAME_MAX;
    uint8_t buf[PEER_RECORD_MIN + PWE_SEC_NAME_MAX];
    buf[0] = RECORD_VERSION;
    memcpy(buf + 1, pub, PWE_SEC_KEY_BYTES);
    int64_t now = (int64_t)time(NULL);
    for (int i = 0; i < 8; i++) buf[1 + PWE_SEC_KEY_BYTES + i] = (uint8_t)(now >> (8 * (7 - i)));
    buf[1 + PWE_SEC_KEY_BYTES + 8] = (uint8_t)name_len;
    if (name_len) memcpy(buf + PEER_RECORD_MIN, name, name_len);

    char label[128];
    snprintf(label, sizeof(label), "PWE Screen Encore pairing: %.*s", (int)name_len, name ? name : "");
    return item_write(ks, account, label, buf, PEER_RECORD_MIN + name_len);
}

void pwe_keystore_as_store(struct pwe_keystore *ks, struct pwe_sec_store *store) {
    store->find = pwe_keystore_find_peer;
    store->save = pwe_keystore_save_peer;
    store->ud = ks;
}

int pwe_keystore_forget_peer(struct pwe_keystore *ks, const uint8_t id[PWE_SEC_ID_BYTES]) {
    char account[64];
    peer_account(id, account);
    return item_delete(ks, account);
}

int pwe_keystore_forget_all_peers(struct pwe_keystore *ks) {
    char accounts[64][64];
    int n = list_accounts(ks, accounts, 64);
    if (n < 0) return -1;
    int rc = 0;
    for (int i = 0; i < n; i++) if (item_delete(ks, accounts[i]) != 0) rc = -1;
    return rc;
}

int pwe_keystore_delete_everything(struct pwe_keystore *ks) {
    int rc = pwe_keystore_forget_all_peers(ks);
    if (item_delete(ks, IDENTITY_ACCOUNT) != 0) rc = -1;
    return rc;
}
