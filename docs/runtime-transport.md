# Runtime transport (A1.2)

- Status: implemented in `services/runtime-transport` (package `monexus/runtime-transport`), native targets only.
- Implements: `docs/runtime-protocol.md` (A1.2 draft) as constrained by the task scope. Deliberate deviations are listed in §2.
- Does not implement: exec/fs/PTY/git, ACP semantics, approvals, scheduling, UI, multi-primary. A1.2b registers those methods through `HandlerRegistry`.

## 1. Trust model and wire format

The node opens one outbound TLS connection to a configured primary endpoint. The primary never opens an inbound port on the node side.

- The primary's certificate and private key paths come from `TlsServerConfig`. They are validated at startup: regular file, no group/other permission bits. The transport never generates or chmods production key material.
- The node pins the CA with `TrustedRoot::CustomPemFile` and the peer leaf with `get_peer_certificate` + SHA-256 before any JSON-RPC payload is written. Both checks run in `TlsClientConfig::connect_pinned`; any mismatch closes the stream. There is no system-trust-store fallback and no plaintext path.
- A verified frame is `4-byte big-endian N` followed by `N` bytes of UTF-8 JSON, where `1 <= N <= 65,536` (`MAX_FRAME_BYTES`). Empty frames, oversized frames, invalid UTF-8/JSON, non-object top levels, duplicate keys and nesting deeper than 32 are protocol failures and close the connection.
- Frames carry the existing `monexus/contracts` JSON-RPC 2.0 envelope. One request, response or notification per frame; ordering is the stream order.
- The frame cap is 64 KiB in this slice (the draft says 1 MiB). A1.2b payloads that need more must chunk; the cap is a constant, not configurable by a caller.

## 2. Deviations from `docs/runtime-protocol.md`

| Draft | Implemented | Why |
|---|---|---|
| WSS | pinned TLS + length-prefixed frames | `moonbitlang/async@0.22.7` has no TLS-capable HTTP server, so `websocket.Conn::from_http_server` cannot be reached over TLS. |
| `protocol_version: "1.0"` string | integer `protocol_version: 1` | the `@contracts` helpers parse an integer; `PROTOCOL_VERSION_TEXT = "1.0"` remains for display and for a future envelope revision. |
| token as base64url | 32-byte token as 64 lowercase hex characters | hex is unambiguous in JSON/log-redaction tests and has a fixed length (`CREDENTIAL_HEX_LEN`). |
| heartbeat default 15000 ms | 5000 ms (`HEARTBEAT_INTERVAL_MS`) | task requirement; the server advertises the actual value in the hello result. |
| max frame 1 MiB | 64 KiB | task requirement; advertised as `max_frame_bytes`. |
| `resume` object | `resume_cursor` + `gap` bool | simpler JSON-level replay contract; see §5. |
| Ed25519 challenge-response | bearer credential over pinned TLS | no usable asymmetric signing API upstream; see §4. Optional HMAC challenge-response was not added because it would require either storing the plaintext secret or an equivalent verifier server-side. |

## 3. Pairing and credentials

- `PrimaryState::create_pairing_code()` returns a 128-bit random code (hex, single use, `PAIRING_CODE_TTL_MS = 10 min`). Only `sha256_text(code)` is stored; the plaintext code exists only in the return value.
- `runtime.pair` carries `pairing_code`, `runtime_id`, `protocol_version`, `capabilities`. Every failure (wrong, expired, consumed, revoked runtime, malformed) maps to JSON-RPC error `1000` with the same `"pairing rejected"` message. Expired and used records are removed/rejected in constant time via `constant_time_hex_eq`.
- On success the primary issues a 32-byte credential, returned once as 64 hex characters. The node writes it to `token_file` (mode 0600) when configured; the primary stores only `sha256_text(credential)` plus runtime id, generation, capabilities and expiry/revocation state.
- `runtime.hello` carries `runtime_id`, `token`, `protocol_version`, `last_ack_cursor`. The primary looks the token hash up, requires it to belong to the runtime, not be revoked/expired, and opens a session. `1003` (`revoked`) covers revoked, expired and rotated-away credentials; `1001` is an unknown token or unknown runtime.
- Default production policy is `CredentialPolicy::until_revoked()`: a credential lives until it is revoked or rotated. There is no implicit 15-minute TTL. `CredentialPolicy::fixed(ms)` exists for deployments/tests that want a bounded lifetime; an expired credential is treated exactly like a revoked one (1003) and requires re-pairing.
- Re-authentication behavior: a node that receives 1003 stops reconnecting (`NodeRunOutcome::Revoked`); it must be paired again with a new code. Rotation (`runtime.rotate`) issues a new credential, revokes the old one, closes existing sessions on their next frame, and returns the new credential once. Re-pairing a runtime revokes its previous credential.
- `PrimaryState::revoke(runtime_id, reason)` revokes all credentials for the runtime, closes its sessions, and records a bounded audit event without secrets.

Rate limits, all with a 60-second sliding window (`RATE_WINDOW_MS`):

| Scope | Key | Limit |
|---|---|---|
| Pairing per source | `pair:source` | 5 |
| Pairing global | `pair:global` | 50 |
| Auth per source | `auth:source` | 10 |
| Auth per runtime | `auth:runtime:<id>` | 20 |
| Auth global | `auth:global` | 200 |

Auth budgets are consumed before the credential is checked, so retrying with a valid bearer token is rate limited too. Every attempt consumes budget, and `1004` (`busy`) is returned once a budget is exhausted. Per-source keys use `source_host(peer)`, not the full address, so a caller cannot mint new budgets by reconnecting from a new ephemeral port. The global pairing budget is paired with the per-source budget; a single source cannot exhaust the global one by itself in the intended deployment (the per-source cap of 5 is far below 50).

## 4. TLS server API and the upstream gap

`moonbitlang/async@0.22.7` exposes `Tls::server`/`Tls::server_from_pair` in the generated `.mbti`, but the source is annotated `#internal(..., "do not use, for internal testing only")`. No published async version through 0.22.10 has a public TLS server API, and there is no WSS server.

Options considered for this slice:

1. A public upstream API: none exists in the pinned line (checked 0.22.7 and release notes through 0.22.10).
2. A thin owned FFI over OpenSSL: not thin. It would have to own the record layer, certificate/hostname verification, error mapping and the async socket integration; that is a new cryptographic transport surface, not a wrapper around the existing one. Rejected for A1.2.
3. Isolation fallback: one internal call site (`tls_adapter.mbt`), dependency pinned exactly to `moonbitlang/async@0.22.7` in `moon.mod`, server handshakes serialized through one process-wide async mutex (the upstream context is a process-wide singleton), and `doctor()` fails closed on platforms without this entry point.

Consequences, documented rather than hidden:

- `Tls::server` is **not** claimed as production-supported upstream. `DoctorReport.supported` is false on Windows native (where the stub always fails) and when the OpenSSL probe fails. Callers must not start `PrimaryServer::run` unless `doctor_supported()` is true.
- The upstream singleton context means concurrent server handshakes with different certificates race inside OpenSSL (the A1.0 spike's `TlsError record layer failure` flake). The adapter serializes all server handshakes on one mutex, and the e2e tests are strictly sequential with one PKI per test; no test relies on parallel server handshakes.
- `@socket.TcpServer::close()` does not wake a parked `accept()` in 0.22.7 (it detaches the fd without waking the event-loop waiter). `PrimaryServer::run` therefore polls the raw accept for 100 ms at a time and re-checks its closed flag; the TLS handshake runs unbounded by that poll in a child task, with its own `handshake_timeout_ms`. Without this, task-group teardown hangs forever after a test/server closes.
- `rand_bytes` is also internal; the OpenSSL probe keeps that check in the same adapter file.

## 5. Sessions, replay and the outbox contract

`runtime.hello` response fields:

```json
{"runtime_id":"rt-1","session_id":"<16 hex>","session_credential_id":"<16 hex>",
 "protocol_version":1,"heartbeat_interval_ms":5000,"heartbeat_max_missed":3,
 "max_frame_bytes":65536,"resume_cursor":0,"gap":false,
 "server_time_ms":1234567890,"draining":false}
```

- `resume_cursor` is the primary's last acknowledged cursor for the runtime. `gap` is `node_last_ack > resume_cursor`; the primary records a `cursor gap` audit event and the node must not silently skip events.
- Heartbeat: the node sends `runtime.heartbeat` every interval; the primary closes a session after `heartbeat_max_missed` intervals of silence and records `runtime.heartbeat_timeout`. Any authenticated frame also refreshes liveness and re-checks revocation/expiry.
- `runtime.bye` closes the session gracefully and replies `{"ok":true}`.
- `runtime.drain` (server → node notification) is sent after the next frame once the primary is draining. The node exits the run loop with `NodeRunOutcome::Drained` and does not reconnect for new work.
- Reconnect: `node_run` uses exponential backoff with jitter (`NodeConfig.backoff_base_ms`, `backoff_cap_ms`, `jitter_ms`), resuming from the durable outbox cursor. `max_attempts = 0` means unlimited; `AttemptsExhausted(n)` reports a bounded run.
- Revoked: `NodeRunOutcome::Revoked`; the node stops and waits for re-pairing.
- Events are outbox-first. `runtime.event` carries `seq`, `run_id`, `run_seq`, `kind`, `ts`, `payload` and a `hash` (SHA-256 over the canonical event fields). It may be sent as a notification (the node's path; the primary answers with a `runtime.ack {cursor}` notification) or as a request (the primary answers with an `EventAck {cursor, duplicate}` result). The primary dedupes on `(runtime_id, seq)`; a repeated event returns the stored ack without re-recording, and a matching `seq` with a different hash is rejected as malformed.

### Handler contract A1.2b must use

```moonbit
pub struct HandlerRegistry { ... }

pub fn HandlerRegistry::register(
  self : HandlerRegistry,
  rpc_method : String,
  handler : async (HandlerRequest) -> Result[@json.Json, @contracts.RpcError],
) -> Result[Unit, String]

pub(all) struct HandlerRequest {
  runtime_id : String
  session_id : String
  rpc_method : String
  params : Map[String, @json.Json]
  client_request_id : String
}
```

- Registration happens once at startup, before the server accepts connections; the registry is not synchronized. Reserved `runtime.*` methods cannot be replaced; duplicate and empty names are rejected.
- `params` excludes transport-owned fields only if the caller defines them that way; `client_request_id` is extracted when present and is capped at 128 characters (`MAX_CLIENT_REQUEST_ID_LEN`). It is empty when the request does not carry one.
- Returning `Ok(json)` is sent as the JSON-RPC result and cached under `(runtime_id, client_request_id)` when that id is present (`MAX_IDEMPOTENCY_ENTRIES = 256`); a retry returns the cached value without calling the handler again. Returning `Err(RpcError)` is sent as the error and is not cached. Unknown methods return `-32601` (`ERR_METHOD_NOT_FOUND`) with a bounded message.
- Handlers must not write secrets into `RpcError.message`; the transport clamps diagnostics and redacts audit detail (`safe_detail`, `clamp_text`).

### Outbox contract A1.2b must implement

```moonbit
pub(all) struct OutboxEvent {
  seq : Int64
  run_id : String
  run_seq : Int64
  kind : String
  ts : String
  payload : @json.Json
}

pub struct OutboxPort {
  pending : async (Int64, Int32) -> Result[Array[OutboxEvent], String]
  ack_through : async (Int64) -> Result[Unit, String]
  cursor : () -> Int64
}
```

- `pending(after_cursor, limit)` returns events ordered by `seq`, strictly greater than `after_cursor`, at most `limit`. It must be durable before returning: `node_run` sends them and waits for `runtime.ack`.
- `ack_through(cursor)` must persist the cursor before returning; it is called after each ack. `cursor()` returns the durable cursor and is used by a reconnect hello (`last_ack_cursor`) and for resume.
- `OutboxPort::empty()` is for nodes without events; it returns no pending events and a zero cursor. The transport does not implement storage or replay itself; the outbox port is the injection point.
- `OutboxEvent::to_wire()` builds the wire `WireEvent` (adding the payload hash); payloads are capped at 32 KiB (`MAX_EVENT_PAYLOAD_BYTES`). A serialized event larger than the frame cap is rejected before send.
- Transport-level resume is JSON-level: hello carries `last_ack_cursor`, the server answers `resume_cursor` and `gap`, and the node replays from the outbox. There is no separate binary replay channel.

## 6. Durable state and permissions

```moonbit
pub struct StateStore {
  load  : async () -> Result[StateSnapshot?, String]
  save  : async (StateSnapshot) -> Result[Unit, String]
  location : String
}

pub fn StateStore::memory() -> StateStore
pub async fn StateStore::open(dir : String) -> Result[StateStore, String]
pub fn StateSnapshot::empty() -> StateSnapshot
pub fn StateSnapshot::to_json(StateSnapshot) -> @json.Json
pub fn StateSnapshot::from_json(@json.Json) -> Result[StateSnapshot, String]
```

- `StateStore::open(dir)` requires/creates a directory with mode 0700 and stores `transport-state.json` with mode 0600. Writes go to a temp file in the same directory followed by an atomic rename with `sync=Full`; the previous snapshot is never partially overwritten.
- The snapshot contains pairing records (code hashes), credential records (token SHA-256 hashes), revocation records and ack cursors. It never contains pairing codes, plaintext credentials or bearer tokens.
- `save_token_file` creates the node token file with mode 0600 and refuses a symlink/unsafe path; `load_token_file` validates mode and content. The token is never printed, audited or logged.
- `stat_path`/`validate_secret_file`/`validate_private_dir` are the permission checks used for TLS key/certificate files, the state directory and the token file. They read metadata only and do not open key material.

## 7. Public API summary

| Area | API |
|---|---|
| Server TLS | `TlsServerConfig::new(bind_host~, bind_port~, certificate_file~, private_key_file~, handshake_timeout_ms? = 10_000)`, `ServerListener::listen`, `port`, `close`, `accept` |
| Server | `ServerConfig::new(tls~, policy~, heartbeat_interval_ms? = 5_000, heartbeat_max_missed? = 3, hello_timeout_ms? = 10_000)`, `PrimaryServer::open(config, store, handlers)`, `port`, `primary_state`, `drain`, `close`, `run` |
| State | `PrimaryState::create_pairing_code`, `pair`, `authenticate`, `open_session`, `heartbeat`, `close_session`, `revoke`, `rotate`, `accept_event`, `cursor_for`, `session_count`, `session_info`, `audit_text`, `logs`, `audit_events` |
| Node | `TlsClientConfig::new(host~, port~, ca_certificate_file~, expected_leaf_sha256~, server_name? = "localhost")`, `connect_pinned`; `pair_with_primary(config, code)`; `connect_session(config, token, last_ack_cursor)`; `node_run(config, token, outbox)`; `NodeSession`; `NodeRunOutcome` |
| Support | `doctor()` / `doctor_supported()`, `sha256_text`, `certificate_fingerprint`, `random_hex`, `constant_time_hex_eq`, `encode_frame` / `read_frame` / `write_frame` |

Error codes used by the transport: `1000` pairing rejected, `1001` unauthorized, `1002` unsupported version, `1003` revoked/expired/rotated, `1004` busy/rate limited, `1005` cursor gap (reserved for A1.2b replay), `1006` policy stale, `1007` approval required, `1008` approval invalid, `1009` path denied. Standard JSON-RPC codes `-32700`, `-32600`, `-32601`, `-32602`, `-32603` are used for framing, invalid requests, unknown methods, invalid params and internal errors.

## 8. Tests and determinism

`transport_unit_test.mbt` covers pure policy/state behavior (pairing, expiry, uniform rejection, budgets, credential lifetimes, cursors, permissions, doctor). `transport_e2e_test.mbt` runs loopback pinned TLS end to end with throwaway PKI generated by `openssl` into `@fs.tmpdir`: pairing success/expiry/consumed/wrong code, unauthorized, unsupported version, hello fields, unknown method, idempotency, heartbeat request/notification, rotation, revocation, re-pair revocation, fixed lifetime, wrong leaf pin, wrong CA, plaintext rejection, oversized frame, file-store 0600/0700, no secret text in audit/logs, heartbeat timeout, reconnect with cursor resume, drain, and node outcomes.

TLS tests are deterministic by construction: one PKI per test, sequential connections, handshakes serialized by the adapter mutex, every network operation bounded by `@async.with_timeout_opt`, and the accept loop polling so teardown cannot hang on `TcpServer::close()`. Do not copy the A1.0 spike's concurrently running server handshakes; that pattern races the upstream shared `SSL_CTX`.
