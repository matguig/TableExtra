#ifndef MTP_CLIBSSH2_SHIM_H
#define MTP_CLIBSSH2_SHIM_H

// Homebrew `libssh2`. scripts/build-app.sh bundles the dylib (and its OpenSSL) into the .app.
#include "/opt/homebrew/opt/libssh2/include/libssh2.h"
#include <stdlib.h>
#include <string.h>

// Function-like and shifted macros that Swift does not import.
static inline LIBSSH2_SESSION *mtp_ssh2_session_init(void) {
    return libssh2_session_init_ex(NULL, NULL, NULL, NULL);
}

/// `LIBSSH2_KNOWNHOST_KEY_*` bits for a `LIBSSH2_HOSTKEY_TYPE_*` value.
static inline int mtp_ssh2_knownhost_keybits(int hostKeyType) {
    switch (hostKeyType) {
    case LIBSSH2_HOSTKEY_TYPE_RSA: return LIBSSH2_KNOWNHOST_KEY_SSHRSA;
    case LIBSSH2_HOSTKEY_TYPE_ECDSA_256: return LIBSSH2_KNOWNHOST_KEY_ECDSA_256;
    case LIBSSH2_HOSTKEY_TYPE_ECDSA_384: return LIBSSH2_KNOWNHOST_KEY_ECDSA_384;
    case LIBSSH2_HOSTKEY_TYPE_ECDSA_521: return LIBSSH2_KNOWNHOST_KEY_ECDSA_521;
    case LIBSSH2_HOSTKEY_TYPE_ED25519: return LIBSSH2_KNOWNHOST_KEY_ED25519;
    default: return LIBSSH2_KNOWNHOST_KEY_UNKNOWN;
    }
}

static inline int mtp_ssh2_knownhost_plain_raw(void) {
    return LIBSSH2_KNOWNHOST_TYPE_PLAIN | LIBSSH2_KNOWNHOST_KEYENC_RAW;
}

/// Answers every hidden keyboard-interactive prompt with the password stored in the session's abstract pointer.
static void mtp_ssh2_kbdint_response(const char *name, int name_len, const char *instruction, int instruction_len,
                                     int num_prompts, const LIBSSH2_USERAUTH_KBDINT_PROMPT *prompts,
                                     LIBSSH2_USERAUTH_KBDINT_RESPONSE *responses, void **abstract) {
    const char *password = (const char *)*abstract;
    for (int i = 0; i < num_prompts; i++) {
        if (password == NULL || prompts[i].echo) continue;
        responses[i].text = strdup(password);
        responses[i].length = (unsigned int)strlen(password);
    }
}

static inline int mtp_ssh2_userauth_kbdint_password(LIBSSH2_SESSION *session, const char *user, const char *password) {
    void **abstract = libssh2_session_abstract(session);
    void *previous = *abstract;
    *abstract = (void *)password;
    int rc = libssh2_userauth_keyboard_interactive_ex(session, user, (unsigned int)strlen(user), mtp_ssh2_kbdint_response);
    *abstract = previous;
    return rc;
}

#endif
