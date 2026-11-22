#ifndef POCKETPORT_PAIRING_H
#define POCKETPORT_PAIRING_H

#include <stddef.h>
#include <stdint.h>

typedef struct PocketPortPAKE PocketPortPAKE;

PocketPortPAKE *pocketport_pake_create(int server, const uint8_t *password, size_t length);
void pocketport_pake_free(PocketPortPAKE *context);
int pocketport_pake_write(PocketPortPAKE *context, int round, uint8_t *bytes, size_t capacity, size_t *length);
int pocketport_pake_read(PocketPortPAKE *context, int round, const uint8_t *bytes, size_t length);
int pocketport_pake_secret(PocketPortPAKE *context, uint8_t *secret, size_t capacity, size_t *length);
int pocketport_pake_self_test(void);

#endif
