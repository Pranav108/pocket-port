# PocketPort local pairing and direct transfer v1

The CLI and iOS receiver use Wi-Fi TCP with Bonjour on `local.`. Both sides disable peer-to-peer discovery. Bonjour names are hints and are not trusted identities. The QR and HTTP share protocol remains separate.

## Identity and trust

Each installation generates a P-256 signing key. The private key stays in the OS Keychain. The device ID is the lowercase hex SHA-256 of the 65-byte uncompressed SEC1 public key. The human-readable fingerprint is its first 12 uppercase hex characters. Pairing exchanges a JSON object with `name`, `platform`, and `publicKey` (standard padded Base64). The trust registry persists each identity, alias, pairing date, and last-seen date. An existing registry without its private key fails closed.

Aliases affect local device selection only. Removing a trusted peer removes the local pin. The other peer may still display a stale relationship until it is removed there or paired again.

## Framing

Control frames on both services are a four-byte unsigned big-endian length (maximum 16,384), then that many payload bytes. JSON payloads are UTF-8. UUID strings are case-insensitive. Invalid, oversized, or unexpected frames terminate the connection.

## Enrollment

The Mac advertises `_pp-pair._tcp` only during a pairing command. It generates a uniform six-digit decimal code, including leading zeros, and shows it and its fingerprint in Terminal. The code expires after 120 seconds on the Mac’s monotonic clock. The listener admits at most five attempts and handles one attempt at a time. The phone chooses a service, enters the six digits and confirms the authenticated Mac fingerprint.

The TCP stream starts with EC J-PAKE over P-256/SHA-256, using the Mbed TLS Thread 1.0 message format from release v3.6.8. The input secret is SHA-256 over the UTF-8 bytes of `PocketPort pairing v1`, a single NUL byte, and the six ASCII digits. The binary control-frame payloads, in order, are:

1. Phone round 1 (EC J-PAKE client).
2. Mac round 1 (server).
3. Mac round 2.
4. Phone round 2.

The session key is HKDF-SHA256 with the 32-byte Mbed TLS EC J-PAKE derived secret, salt equal to the SHA-256 of the four raw payloads each prefixed by their two-byte big-endian length, info `PocketPort ECJPAKE P256 v1`, and output length 32. Each subsequent frame uses AES-256-GCM under a separate key derived via HKDF-SHA256 from the session key with an empty salt and the label below as info. The label’s UTF-8 is authenticated associated data. The frame consists of the random 12-byte nonce, ciphertext and 16-byte tag. Successful authenticated decryption confirms possession of the code without sending it.

| Direction | Label | JSON payload |
| --- | --- | --- |
| Mac → phone | `mac-identity` | Mac signed identity |
| Phone → Mac | `phone-identity` | Phone signed identity, only after user approval |
| Mac → phone | `mac-confirmed` | `true`, after persisting the phone |
| Phone → Mac | `phone-confirmed` | `true`, after persisting the Mac |

A signed identity has `identity` (the object above) and `signature` (standard padded Base64). The signature is DER ECDSA P-256/SHA-256 over UTF-8 `PocketPort identity proof v1 <label>`, a single NUL byte, and the 32-byte transcript hash. Verify before accepting the identity.

If the connection fails during the final exchange, one side may already have stored the relationship. A fresh code can pair the same key again and preserves its alias. No enrollment password or session key is saved.

## Foreground receiver and direct transfer

A phone with at least one trusted Mac advertises `_pp-file._tcp` while PocketPort is active on Wi-Fi. The service name is the first 32 lowercase hex characters of its device ID. The Mac connects and both sides require TLS 1.3 with ALPN `pocketport-file/1`. Both present a self-signed P-256 certificate and require proof of the corresponding private key in the TLS handshake. Each side exact-matches the leaf public-key ID against its registry. The Mac pins only the selected recipient. The receiver obtains the actual sender ID from the authenticated TLS peer certificate, then checks current trust again before saving and acknowledging. TLS session resumption and tickets are disabled.

Each connection carries a single ping or offer. All control frames are inside TLS. The packet JSON has `kind` and optional `id` and `offer`. Status checks use `ping`/ `pong` without an ID. A transfer starts with `{"kind":"offer","id":"<UUID>","offer":{...}}`. The offer fields are:

| Field | Value |
| --- | --- |
| `id` | Same transfer UUID as the enclosing message |
| `expiresAt` | Integer Unix timestamp, normally creation plus 120 seconds. Receiver allows 15 seconds of clock skew |
| `filename` | Basename, UTF-8, at most 1,024 bytes. No slashes, NUL, control characters, `.`, or `..` |
| `project` | Optional UTF-8 label, at most 256 bytes |
| `sha256` | Lowercase hex SHA-256 of the complete file |
| `byteCount` | 0–5 MiB for Markdown/text/HTML or 0–25 MiB for PDF/images |

If the offer is new and valid, the phone replies `fetch` with the UUID. The Mac serves exactly `byteCount` raw bytes over that same authenticated connection. No filesystem path or URL travels on the wire. The phone validates the byte count, digest, format and UTF-8 where applicable, then imports atomically. It returns `receipt` with the UUID only after persistence. An already imported offer with matching metadata receives an immediate `receipt` and no bytes are sent. A conflicting reuse receives `conflict`. Responses `busy`, `invalidFile`, `rejected` and `saveFailed` also carry the UUID. A dropped connection or missing or mismatched receipt is failure from the sender’s perspective.

The receiver namespaces the transfer UUID by the authenticated sender key. It computes SHA-256 of UTF-8 `PocketPort import v1 <sender-id> <lowercase-transfer-uuid>`, keeps the first 16 bytes, sets the UUID variant to RFC 4122 and the version nibble to 8, and uses that UUID for the import. A Mac retains the transfer UUID of an unconfirmed send for up to 24 hours and reuses it for the same recipient, file digest, filename, and project label. After a confirmed send, a new request gets a new UUID. A deleted import no longer serves as a receipt.

Android can implement enrollment with an interoperable EC J-PAKE implementation, discovery using NSD, device keys using Android Keystore, mutual TLS using Android networking APIs, and the same framing and storage semantics. This repository does not include an Android client.

## Upstream cryptography

The checked-in [Mbed TLS subset](../Sources/CPocketPortPairing/vendor/LICENSE) is v3.6.8, commit `82e69999f91126589a28b70dd75b69fbcabe2711`, distributed under its Apache-2.0 license option. Only the C source and headers needed by EC J-PAKE are included. `mbedtls_config.h` is PocketPort’s minimal build configuration. The Apple targets use CryptoKit for the enrollment envelope and Apple Network/Security frameworks for TLS.
