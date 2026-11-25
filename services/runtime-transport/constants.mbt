///|
/// Wire and policy constants for the A1.2 runtime transport.
///
/// The transport is a pinned-TLS stream carrying JSON-RPC 2.0 frames with a
/// 4-byte big-endian length prefix. There is deliberately no plaintext or WSS
/// variant: `moonbitlang/async@0.22.7` has no TLS-capable HTTP server, so
/// `websocket.Conn::from_http_server` cannot be used behind TLS (see
/// docs/runtime-transport.md). Frame size, method names and error codes are
/// part of the wire contract and must not change silently.

///|
pub const PROTOCOL_VERSION : Int = 1

///|
pub const PROTOCOL_VERSION_TEXT : String = "1.0"

///|
/// Hard frame cap. A frame larger than this closes the connection; the limit
/// is fixed so a caller cannot raise it to bypass the bound.
pub const MAX_FRAME_BYTES : Int = 65_536

///|
pub const MAX_FRAME_HEADER_BYTES : Int = 4

///|
/// JSON nesting cap for parsing untrusted frames.
pub const MAX_JSON_DEPTH : Int = 32

///|
/// Pairing code: 128 bits of CSPRNG entropy (hex-encoded on the wire).
pub const PAIRING_CODE_BYTES : Int = 16

///|
/// Pairing code lifetime: 10 minutes (ADR-0012 §2).
pub const PAIRING_CODE_TTL_MS : Int64 = 600_000

///|
/// Pairing failure budget per source and globally. The spike's single global
/// counter let one unauthenticated source block every other pairing attempt;
/// both scopes are enforced here.
pub const PAIRING_PER_SOURCE_LIMIT : Int = 5

///|
pub const PAIRING_GLOBAL_LIMIT : Int = 50

///|
/// Authentication attempts are budgeted per source, per runtime and globally.
/// Every attempt consumes budget before the credential is checked, so a
/// holder of a valid token cannot retry without bound.
pub const AUTH_PER_SOURCE_LIMIT : Int = 10

///|
pub const AUTH_PER_RUNTIME_LIMIT : Int = 20

///|
pub const AUTH_GLOBAL_LIMIT : Int = 200

///|
/// Failure window for all budgets.
pub const RATE_WINDOW_MS : Int64 = 60_000

///|
/// Machine credential: 32 bytes, presented as 64 lowercase hex characters over
/// pinned TLS. The primary stores only SHA-256(token).
pub const CREDENTIAL_BYTES : Int = 32

///|
pub const CREDENTIAL_HEX_LEN : Int = 64

///|
/// Production credential policy: long-lived until revoked or rotated. There is
/// no 15-minute test TTL in production; `CredentialPolicy` can still be
/// constructed with a lifetime for tests and deployments that want one.
pub fn credential_default_lifetime_ms() -> Int64? {
  None
}

///|
/// Heartbeat: node sends every interval; the primary closes after three
/// missed intervals.
pub const HEARTBEAT_INTERVAL_MS : Int64 = 5_000

///|
pub const HEARTBEAT_MAX_MISSED : Int = 3

///|
/// Reconnect backoff bounds (ADR-0012 §3).
pub const BACKOFF_BASE_MS : Int64 = 1_000

///|
pub const BACKOFF_CAP_MS : Int64 = 60_000

///|
/// Bounds for in-memory state, logs and diagnostics.
pub const MAX_LOG_LINES : Int = 512

///|
pub const MAX_AUDIT_EVENTS : Int = 512

///|
pub const MAX_PAIRING_RECORDS : Int = 256

///|
pub const MAX_REVOKED_CREDENTIALS : Int = 128

///|
pub const MAX_RATE_KEYS : Int = 512

///|
pub const MAX_IDEMPOTENCY_ENTRIES : Int = 256

///|
pub const MAX_DETAIL_LEN : Int = 240

///|
pub const MAX_RUNTIME_ID_LEN : Int = 128

///|
pub const MAX_CAPABILITIES : Int = 32

///|
pub const MAX_CAPABILITY_LEN : Int = 64

///|
pub const MAX_CLIENT_REQUEST_ID_LEN : Int = 128

///|
pub const MAX_EVENT_PAYLOAD_BYTES : Int = 32_768

///|
pub const MAX_PEER_LEN : Int = 128

///|
/// Bound on pairing code / bearer token text accepted from the wire before it
/// is hashed. Anything longer is rejected without hashing unbounded input.
pub const MAX_CODE_INPUT_LEN : Int = 128

///|
pub const MAX_TOKEN_INPUT_LEN : Int = 256

///|
/// How long an unauthenticated connection may stay silent before the primary
/// closes it.
pub const HELLO_TIMEOUT_MS : Int64 = 10_000

///|
/// Pairing rejection code. Unknown, expired, used, replayed and rate-limited
/// codes all map to this single code/message so the wire cannot be used to
/// distinguish which check failed. The distinguishing reason stays in the
/// primary audit log.
pub const ERR_PAIRING_REJECTED : Int = 1000

///|
/// Authenticated failure (unknown runtime, wrong credential, closed session).
pub const ERR_UNAUTHORIZED : Int = 1001

///|
pub const ERR_UNSUPPORTED_VERSION : Int = 1002

///|
/// Credential revoked, rotated or expired.
pub const ERR_REVOKED : Int = 1003

///|
/// Rate limit or queue/backpressure bound hit.
pub const ERR_BUSY : Int = 1004

///|
/// The primary cannot replay from the requested cursor.
pub const ERR_CURSOR_GAP : Int = 1005

///|
/// Policy snapshot stale or unverifiable (reserved for A1.3).
pub const ERR_POLICY_STALE : Int = 1006

///|
/// High-risk operation needs an owner decision (reserved for A1.3).
pub const ERR_APPROVAL_REQUIRED : Int = 1007

///|
pub const ERR_APPROVAL_INVALID : Int = 1008

///|
/// Path escapes a registered workspace root (reserved for A1.1b).
pub const ERR_PATH_DENIED : Int = 1009

///|
/// JSON-RPC method names in the runtime namespace.
pub const METHOD_PAIR : String = "runtime.pair"

///|
pub const METHOD_HELLO : String = "runtime.hello"

///|
pub const METHOD_HEARTBEAT : String = "runtime.heartbeat"

///|
pub const METHOD_ROTATE : String = "runtime.rotate"

///|
pub const METHOD_PROBE : String = "runtime.probe"

///|
pub const METHOD_BYE : String = "runtime.bye"

///|
pub const METHOD_EVENT : String = "runtime.event"

///|
pub const METHOD_ACK : String = "runtime.ack"

///|
pub const METHOD_DRAIN : String = "runtime.drain"

///|
pub const METHOD_REPLAY_GAP : String = "runtime.replay_gap"

///|
/// Transport-owned methods cannot be replaced through the handler registry.
pub fn reserved_method(method : String) -> Bool {
  method == METHOD_PAIR ||
  method == METHOD_HELLO ||
  method == METHOD_HEARTBEAT ||
  method == METHOD_ROTATE ||
  method == METHOD_PROBE ||
  method == METHOD_BYE ||
  method == METHOD_EVENT ||
  method == METHOD_ACK ||
  method == METHOD_DRAIN ||
  method == METHOD_REPLAY_GAP
}

///|
pub const AUTH_MODE_BEARER : String = "bearer"

///|
pub const CREDENTIAL_LIFETIME_UNTIL_REVOKED : String = "until_revoked"

///|
pub const CREDENTIAL_LIFETIME_FIXED : String = "fixed"
