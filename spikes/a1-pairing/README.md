# A1.0 pairing and transport spike

Standalone spike for ADR-0012's security and transport prerequisites. It is
**not** wired into `services/host` or `apps/desktop`; it exists to find out
which primitives the current MoonBit toolchain actually provides before the
production runtime is touched.

## Layout

| Package | Purpose |
| --- | --- |
| `protocol/` | Pure pairing/credential/heartbeat state machine and JSON-RPC dispatch. Time and entropy are injected, so tests are deterministic. |
| `transport/` | Test-only PKI generation, pinned TLS listener/client, 4-byte length-prefixed JSON frames. |
| `e2e/` | Primary and node over pinned loopback TLS: pairing, heartbeat, reconnect, revocation, rotation. |

Run the whole spike with:

```sh
moon test --target native -p a1-pairing/protocol
moon test --target native -p a1-pairing/transport
moon test --target native -p a1-pairing/e2e
```

`transport` tests need the local `openssl` CLI (present on typical Linux CI)
to generate a throwaway CA and `DNS:localhost` leaf inside `@fs.tmpdir`. The
directory is removed by `defer` at the end of each test. No test reads
`~/.ssh`, user credentials, the repository's keys, or the system trust store;
everything binds `127.0.0.1:0`.

## What is actually available

Verified against `moonbitlang/async` 0.22.5 (resolved to 0.22.7 here) on the
native target:

- `@tls.Tls::client(inner, host?, trust?)` with
  `TrustedRoot::CustomPemFile(path)` for CA pinning and
  `Tls::get_peer_certificate() -> Bytes?` (DER) for leaf pinning.
- `@tls.Tls::server(inner, private_key_file~, certificate_file~)` using
  OpenSSL loaded through `dlopen` (libssl.so.3 / 1.1). **Caveat:** upstream
  marks this API `#internal(internal, "do not use, for internal testing
  only")`; the compiler only warns, but the API is not a supported production
  surface. **A1.0 cannot claim `Tls::server` as a supported production
  surface.** A1.2 must either obtain an upstream public API or own a thin
  FFI wrapper (the OpenSSL symbols and native stub are already in the
  dependency, but the exported MoonBit function is explicitly testing-only).
- `@tls.rand_bytes(n)` for CSPRNG entropy.
- SHA-256/SHA-1/SHA-2/SM3, HMAC, AES and ChaCha in core / `moonbitlang/x`.

## Gaps found (ADR-0012 boundaries that need revision)

### 1. No WSS server in the async HTTP stack

`@http.Server` has no TLS variant in this version, and
`@websocket.Conn::from_http_server` requires a concrete
`@http.ServerConnection` built over `@socket.Tcp`. A TLS listener therefore
cannot be handed to the WebSocket server. The spike uses the closest secure
transport available: **raw TLS with the existing `@contracts` JSON-RPC
request/response/notification objects and a 4-byte big-endian length prefix
(max 64 KiB)**.

This is a deliberate A1.0 transport deviation, not a silent downgrade: there
is no plaintext code path. `write_frame`/`read_frame` accept `@tls.Tls`
directly, and the plaintext test sends raw JSON to the TLS listener and
asserts it receives no JSON reply. ADR-0012 should say "pinned TLS stream
carrying JSON-RPC frames" for A1.0/A1.1, or schedule an upstream WSS server
change and keep WSS for a later milestone.

### 2. No asymmetric machine signatures

Neither core nor `moonbitlang/x` exposes Ed25519, ECDSA or RSA sign/verify.
ADR-0012 §2's "node proves possession of its machine private key by signing a
challenge" cannot be implemented or validated today. The hello still carries
`machine_public_key`, but in this spike it is a SHA-256 commitment to a device
secret and the primary cannot verify a signature against it.

Two honest alternatives were implemented and tested:

1. **Bearer credential over pinned TLS (default).** Pairing issues a
   256-bit credential; the primary stores only `SHA-256(credential)` and
   compares in constant time. The credential is presented once per
   connection inside the pinned TLS channel, so it is confidential in
   transit.
2. **HMAC-SHA256 challenge-response.** If the node advertises
   `auth.hmac-sha256`, the primary issues a 30-second single-use challenge and
   verifies an HMAC over a transcript binding runtime, challenge and client
   nonce. This is symmetric, so the primary must retain the verification key,
   which is weaker than a real public-key proof.

Recommendation: revise ADR-0012 to allow a symmetric device credential over
pinned TLS for A1.1, and treat asymmetric device identity as a separate
decision (OpenSSL `EVP_PKEY` FFI, or an upstream signature API). Do not claim
Ed25519 support until such a primitive exists.

## Validated behaviour

`protocol` (16 tests): 128-bit single-use codes with hash-only storage;
unknown/expired/used codes and replayed hello nonces rejected uniformly
(`pairing rejected` on the wire, reason only in audit); failure budget
(10 per 60 s) rate-limits even the correct code until the window rolls over;
version mismatch returns a readable refusal without consuming the code;
re-pairing revokes the old credential; bearer and HMAC reconnect; bad MACs,
replayed challenges and expired challenges rejected; duplicate/out-of-order
heartbeats are idempotent and never regress the ack; `resume_from` continues
from the last ack; short-lived credentials expire; scoped credentials cannot
call out-of-scope methods; revocation kills the credential and open sessions;
rotation keeps `runtime_id`, increments generation, kills the old credential
and session, and accepts the new one; malformed hellos are bounded.

`transport` (5 tests): PKI is created in a temp dir and removed; pinned TLS
loopback round-trips JSON-RPC frames; a wrong leaf fingerprint fails closed
before any frame; an unrelated CA cannot complete the handshake; a plaintext
client receives no JSON; the temp directory is cleaned up.

`e2e` (3 tests): full pairing over pinned TLS, heartbeat, HMAC reconnect with
`resume_from`, one-time code replay refused; bearer reconnect after
revocation is refused for both the credential and the stale session; rotation
over TLS invalidates the old credential and accepts the new one with the same
runtime id.

## Log hygiene

The protocol layer never logs the pairing code, credential or device secret:
pairing stores `SHA-256(code)` and the credential hash only, and every log or
audit line goes through `@contracts.redact_secrets` plus a 240-character
bound. A unit test asserts that issued codes, credentials and the device
secret never appear in the bounded log or audit text. TLS test keys live only
in the per-test temp directory and are never printed; OpenSSL errors are
bounded and never contain key material.

## Known limits / A1.1 recommendation

- **Pairing failure budget is global (10 failures per 60 s across all
  callers).** An unauthenticated flood of wrong codes or replayed hellos can
  therefore temporarily block legitimate pairing for up to one window. This
  is a residual DoS, accepted for the spike because the window is short and
  the code is high-entropy. A1.2 should scope or rate-limit the budget per
  source/runtime (for example per peer address and per runtime id) or
  explicitly document the residual risk; do not treat the current counter as
  sufficient production protection.
- State is in-memory and single-process; persistence, process restart and
  clock-skew policy are out of scope for this spike.
- Test PKI generation shells out to `openssl`; production certificate
  provisioning, rotation and storage are untouched.
- No client certificates / mTLS: device identity is the pairing-issued
  credential plus pinned server TLS.
- The TLS server API is marked internal by upstream; production use needs an
  explicit upstream commitment or an owned FFI layer.
- A1.1 should wire the `protocol` dispatch into the host behind the pinned TLS
  transport, add persisted enrollment state, and decide the asymmetric-device-
  identity question before claiming challenge signatures in the ADR.
