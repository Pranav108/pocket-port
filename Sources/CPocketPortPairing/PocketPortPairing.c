#include "PocketPortPairing.h"
#include "mbedtls/ecjpake.h"
#include <stdlib.h>

struct PocketPortPAKE {
    mbedtls_ecjpake_context context;
};

static int random_bytes(void *unused, unsigned char *output, size_t length) {
    (void) unused;
    arc4random_buf(output, length);
    return 0;
}

PocketPortPAKE *pocketport_pake_create(int server, const uint8_t *password, size_t length) {
    PocketPortPAKE *pairing = calloc(1, sizeof(*pairing));
    if (pairing == NULL) return NULL;
    mbedtls_ecjpake_init(&pairing->context);
    if (mbedtls_ecjpake_setup(&pairing->context, server ? MBEDTLS_ECJPAKE_SERVER : MBEDTLS_ECJPAKE_CLIENT,
                            MBEDTLS_MD_SHA256, MBEDTLS_ECP_DP_SECP256R1, password, length) != 0) {
        pocketport_pake_free(pairing);
        return NULL;
    }
    return pairing;
}

void pocketport_pake_free(PocketPortPAKE *pairing) {
    if (pairing == NULL) return;
    mbedtls_ecjpake_free(&pairing->context);
    free(pairing);
}

int pocketport_pake_write(PocketPortPAKE *pairing, int round, uint8_t *bytes, size_t capacity, size_t *length) {
    if (round == 1)
        return mbedtls_ecjpake_write_round_one(&pairing->context, bytes, capacity, length, random_bytes, NULL);
    return mbedtls_ecjpake_write_round_two(&pairing->context, bytes, capacity, length, random_bytes, NULL);
}

int pocketport_pake_read(PocketPortPAKE *pairing, int round, const uint8_t *bytes, size_t length) {
    if (round == 1) return mbedtls_ecjpake_read_round_one(&pairing->context, bytes, length);
    return mbedtls_ecjpake_read_round_two(&pairing->context, bytes, length);
}

int pocketport_pake_secret(PocketPortPAKE *pairing, uint8_t *secret, size_t capacity, size_t *length) {
    return mbedtls_ecjpake_derive_secret(&pairing->context, secret, capacity, length, random_bytes, NULL);
}

int pocketport_pake_self_test(void) { return mbedtls_ecjpake_self_test(0); }
