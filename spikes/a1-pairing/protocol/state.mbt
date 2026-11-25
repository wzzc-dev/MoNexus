///|
/// Primary-side state for the A1.0 pairing spike.
///
/// This is deliberately in-memory and single-process: the spike validates the
/// handshake, credential and heartbeat semantics only. It is not wired into
/// `services/host` and holds no durable state.
///
/// Log hygiene rules enforced here:
/// - audit events never carry a pairing code, credential value or key material,
///   only ids (code_id, credential_id, runtime_id) and short reasons;
/// - diagnostics go through `bounded_redacted`, which reuses the existing
///   `@contracts.redact_secrets` policy and caps line length.

///|
pub const PROTOCOL_VERSION : Int = 1

///|
pub const PAIRING_CODE_TTL_MS : Int64 = 300_000

///|
pub const PAIRING_CODE_BYTES : Int = 16

///|
pub const PAIRING_MAX_FAILURES : Int = 10

///|
pub const PAIRING_FAILURE_WINDOW_MS : Int64 = 60_000

///|
pub const CREDENTIAL_TTL_MS : Int64 = 900_000

///|
pub const CHALLENGE_TTL_MS : Int64 = 30_000

///|
pub const NONCE_REPLAY_WINDOW_MS : Int64 = 600_000

///|
pub const HEARTBEAT_INTERVAL_MS : Int64 = 5_000

///|
pub const HEARTBEAT_MAX_MISSED : Int = 3

///|
pub const MAX_RUNTIME_ID_LEN : Int = 128

///|
pub const MAX_CAPABILITIES : Int = 32

///|
pub const MAX_CAPABILITY_LEN : Int = 64

///|
pub const MAX_DETAIL_LEN : Int = 240

///|
pub const MAX_LOG_LINES : Int = 512

///|
pub const MAX_AUDIT_EVENTS : Int = 512

///|
pub const MAX_PAIRING_RECORDS : Int = 256

///|
/// Scopes granted to a spike enrollment. A1.1 will derive these from the
/// method manifest instead.
pub fn default_scopes() -> Array[String] {
  ["runtime.heartbeat", "runtime.probe"]
}

///|
/// How the node proves possession of its machine credential on reconnect.
///
/// `Bearer` presents the credential once over pinned TLS and the primary only
/// stores its SHA-256 hash. `ChallengeResponse` sends HMAC-SHA256 over a
/// server nonce and never puts the credential on the wire after pairing, but
/// forces the primary to retain the verification key.
pub(all) enum AuthMode {
  Bearer
  ChallengeResponse
}

///|
pub fn AuthMode::name(self : AuthMode) -> String {
  match self {
    Bearer => "bearer"
    ChallengeResponse => "hmac-sha256"
  }
}

///|
/// Parsed `runtime.hello` payload.
pub(all) struct Hello {
  runtime_id : String
  protocol_version : Int
  capabilities : Array[String]
  machine_public_key : String
  nonce : String
  request_id : String
}

///|
pub(all) struct Enrollment {
  runtime_id : String
  machine_public_key : String
  generation : Int
  credential_id : String
  credential_hash : String
  credential_secret : String?
  auth_mode : AuthMode
  scopes : Array[String]
  issued_at_ms : Int64
  expires_at_ms : Int64
  mut revoked : Bool
}

///|
pub(all) struct Session {
  session_id : String
  runtime_id : String
  credential_id : String
  auth_mode : AuthMode
  mut last_ack_seq : Int64
  mut last_heartbeat_ms : Int64
  mut closed : Bool
}

///|
pub(all) struct Challenge {
  challenge_id : String
  challenge : String
  expires_at_ms : Int64
}

///|
/// Internal record; fields stay private to the package. A challenge is
/// single-use: it is removed from the map on successful verification.
pub struct ChallengeRecord {
  runtime_id : String
  challenge : String
  expires_at_ms : Int64
}

///|
/// Internal record; fields stay private to the package. Only the hash of the
/// pairing code is stored.
pub struct PairingRecord {
  code_id : String
  code_hash : String
  expires_at_ms : Int64
  used : Bool
}

///|
pub struct PrimaryState {
  org_id : String
  pairings : Map[String, PairingRecord]
  enrollments : Map[String, Enrollment]
  credentials : Map[String, String]
  challenges : Map[String, ChallengeRecord]
  sessions : Map[String, Session]
  seen_nonces : Map[String, Int64]
  last_ack : Map[String, Int64]
  audit : Array[@contracts.EventEnvelope]
  log : Array[String]
  mut failure_window_start_ms : Int64
  mut failures : Int
  mut audit_seq : Int64
}

///|
pub fn PrimaryState::new(org_id : String) -> PrimaryState {
  {
    org_id,
    pairings: Map([]),
    enrollments: Map([]),
    credentials: Map([]),
    challenges: Map([]),
    sessions: Map([]),
    seen_nonces: Map([]),
    last_ack: Map([]),
    audit: [],
    log: [],
    failure_window_start_ms: 0L,
    failures: 0,
    audit_seq: 0L,
  }
}

///|
/// Truncate and redact a free-text diagnostic before it is stored or shown.
pub fn bounded_redacted(text : String) -> String {
  let redacted = @contracts.redact_secrets(text)
  if redacted.length() > MAX_DETAIL_LEN {
    redacted[:MAX_DETAIL_LEN].to_owned() + "..."
  } else {
    redacted
  }
}

///|
fn PrimaryState::log_line(self : PrimaryState, line : String) -> Unit {
  if self.log.length().to_int() >= MAX_LOG_LINES {
    let _ = self.log.remove(0)
  }
  self.log.push(bounded_redacted(line))
}

///|
fn PrimaryState::audit_event(
  self : PrimaryState,
  event_type : String,
  subject : String,
  now_ms : Int64,
  entries : Array[(String, @json.Json)],
) -> Unit {
  let payload : Map[String, @json.Json] = Map([])
  for pair in entries {
    let (key, value) = pair
    payload.set(key, value)
  }
  self.audit_seq = self.audit_seq + 1
  let event = @contracts.EventEnvelope::new(
    id=@contracts.new_id("evt", now_ms),
    org_id=self.org_id,
    event_type~,
    ts=@contracts.format_rfc3339(now_ms),
    subject~,
    seq=self.audit_seq,
    payload=@json.Json::object(payload),
  )
  if self.audit.length().to_int() >= MAX_AUDIT_EVENTS {
    let _ = self.audit.remove(0)
  }
  self.audit.push(event)
}

///|
/// Copy of the audit log. Entries contain ids and reasons only; callers must
/// not add secret values.
pub fn PrimaryState::audit_events(self : PrimaryState) -> Array[
  @contracts.EventEnvelope,
] {
  self.audit.copy()
}

///|
pub fn PrimaryState::log_lines(self : PrimaryState) -> Array[String] {
  self.log.copy()
}

///|
pub fn PrimaryState::log_text(self : PrimaryState) -> String {
  self.log.join("\n")
}

///|
pub fn PrimaryState::enrollment(
  self : PrimaryState,
  runtime_id : String,
) -> Enrollment? {
  self.enrollments.get(runtime_id)
}

///|
pub fn PrimaryState::session(self : PrimaryState, session_id : String) -> Session? {
  self.sessions.get(session_id)
}

///|
pub fn PrimaryState::last_ack_seq(self : PrimaryState, runtime_id : String) -> Int64 {
  match self.last_ack.get(runtime_id) {
    Some(value) => value
    None => 0L
  }
}

///|
fn PrimaryState::record_nonce(
  self : PrimaryState,
  runtime_id : String,
  nonce : String,
  now_ms : Int64,
) -> Bool {
  let key = runtime_id + ":" + nonce
  let replayed = match self.seen_nonces.get(key) {
    Some(seen_at) => now_ms - seen_at <= NONCE_REPLAY_WINDOW_MS
    None => false
  }
  if replayed {
    return false
  }
  self.seen_nonces.set(key, now_ms)
  true
}

///|
/// Drop expired pairings, challenges and replays outside the window. Bounds
/// the in-memory state so a test or a hostile peer cannot grow it forever.
pub fn PrimaryState::prune(self : PrimaryState, now_ms : Int64) -> Unit {
  let expired_codes : Array[String] = []
  for entry in self.pairings.iter() {
    let (hash, record) = entry
    if record.expires_at_ms + PAIRING_CODE_TTL_MS < now_ms || record.used {
      expired_codes.push(hash)
    }
  }
  for hash in expired_codes {
    self.pairings.remove(hash)
  }
  if self.pairings.length().to_int() > MAX_PAIRING_RECORDS {
    // Keyed by hash, so there is no creation order to rely on; used/expired
    // records are already gone, and the cap only guards against pathological
    // growth in a test or hostile peer.
    let keys : Array[String] = []
    for entry in self.pairings.iter() {
      let (hash, _) = entry
      keys.push(hash)
    }
    for hash in keys {
      if self.pairings.length().to_int() <= MAX_PAIRING_RECORDS {
        break
      }
      self.pairings.remove(hash)
    }
  }
  let expired_challenges : Array[String] = []
  for entry in self.challenges.iter() {
    let (id, record) = entry
    if record.expires_at_ms < now_ms {
      expired_challenges.push(id)
    }
  }
  for id in expired_challenges {
    self.challenges.remove(id)
  }
  let stale_nonces : Array[String] = []
  for entry in self.seen_nonces.iter() {
    let (key, seen_at) = entry
    if now_ms - seen_at > NONCE_REPLAY_WINDOW_MS {
      stale_nonces.push(key)
    }
  }
  for key in stale_nonces {
    self.seen_nonces.remove(key)
  }
}

///|
fn PrimaryState::failure_count_allows_attempt(
  self : PrimaryState,
  now_ms : Int64,
) -> Bool {
  if now_ms - self.failure_window_start_ms > PAIRING_FAILURE_WINDOW_MS {
    self.failure_window_start_ms = now_ms
    self.failures = 0
  }
  self.failures < PAIRING_MAX_FAILURES
}

///|
fn PrimaryState::record_failure(self : PrimaryState, now_ms : Int64) -> Unit {
  if now_ms - self.failure_window_start_ms > PAIRING_FAILURE_WINDOW_MS {
    self.failure_window_start_ms = now_ms
    self.failures = 0
  }
  self.failures = self.failures + 1
}

///|
fn PrimaryState::reset_failures(self : PrimaryState, now_ms : Int64) -> Unit {
  self.failure_window_start_ms = now_ms
  self.failures = 0
}

///|
fn PrimaryState::close_sessions_for(
  self : PrimaryState,
  runtime_id : String,
) -> Unit {
  for entry in self.sessions.iter() {
    let (_, session) = entry
    if session.runtime_id == runtime_id {
      session.closed = true
    }
  }
}
