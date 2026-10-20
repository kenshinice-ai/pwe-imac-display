/* pwe_keystore.h — PWE Screen Encore: pairing keys in the login keychain.
 *
 * Generic-password items under one service name per app:
 *   account "identity"         this side's X25519 private key
 *   account "peer.<id hex>"    a paired peer: public key, name, pairing date
 *
 * The file-based login keychain is used on purpose: it needs no entitlement
 * under Developer ID, and its access list follows the code signature. There
 * is no fallback to plain files: if the keychain cannot be read, pairing and
 * encrypted connections fail and say so.
 */

#ifndef PWE_KEYSTORE_H
#define PWE_KEYSTORE_H

#include "pwe_secure.h"

#ifdef __cplusplus
extern "C" {
#endif

struct pwe_keystore {
    char service[128];
    int  max_peers;          /* 0 = no limit; otherwise the oldest pairing makes room */
    int  last_status;        /* last OSStatus from Security, for logs */
};

struct pwe_keystore_peer {
    uint8_t id[PWE_SEC_ID_BYTES];
    uint8_t pub[PWE_SEC_KEY_BYTES];
    char    name[PWE_SEC_NAME_MAX + 1];
    int64_t paired_at;       /* Unix seconds */
};

void pwe_keystore_init(struct pwe_keystore *ks, const char *service, int max_peers);

/* Load this side's identity, creating and storing a new one the first time.
 * 0 on success, -1 if the keychain cannot be read or written. */
int  pwe_keystore_load_identity(struct pwe_keystore *ks, const char *name, struct pwe_sec_identity *idn);

/* pwe_sec_store callbacks (ud = the keystore). */
int  pwe_keystore_find_peer(void *ks, const uint8_t id[PWE_SEC_ID_BYTES],
                            uint8_t pub[PWE_SEC_KEY_BYTES], char name[PWE_SEC_NAME_MAX + 1]);
int  pwe_keystore_save_peer(void *ks, const uint8_t id[PWE_SEC_ID_BYTES],
                            const uint8_t pub[PWE_SEC_KEY_BYTES], const char *name);
void pwe_keystore_as_store(struct pwe_keystore *ks, struct pwe_sec_store *store);

/* Paired peers, newest first. Returns the count (<= max), or -1. */
int  pwe_keystore_list_peers(struct pwe_keystore *ks, struct pwe_keystore_peer *out, int max);
int  pwe_keystore_forget_peer(struct pwe_keystore *ks, const uint8_t id[PWE_SEC_ID_BYTES]);
int  pwe_keystore_forget_all_peers(struct pwe_keystore *ks);
/* Removes the identity too (tests, and a full reset). */
int  pwe_keystore_delete_everything(struct pwe_keystore *ks);

#ifdef __cplusplus
}
#endif

#endif
