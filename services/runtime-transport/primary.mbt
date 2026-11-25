///|
/// Primary-side transport state: pairing, bearer credentials, revocation,
/// rotation, sessions, heartbeats, ack cursors and bounded diagnostics.
///
/// Production credential policy: a machine credential is long-lived until it
/// is revoked or rotated (`until_revoked`, the default). A fixed lifetime is
/// available for deployments/tests that need one; when it expires the primary
/// rejects re-authentication with `revoked` and the node must re-pair with a
/// new one-time code. There is no silent refresh, because a refresh endpoint
/// would become an unauthenticated credential-minting oracle.
///
/// Every mutation is serialized by one async mutex, then persisted through the
/// configured `StateStore` before a secret is returned to the caller.

///|
pub(all) struct CredentialPolicy {
  mode : String
  lifetime_ms : Int64?
}

///|
pub fn CredentialPolicy::until_revoked() -> CredentialPolicy {
  { mode: CREDENTIAL_LIFETIME_UNTIL_REVOKED, lifetime_ms: None }
}

///|
pub fn CredentialPolicy::fixed(lifetime_ms : Int64) -> Result[CredentialPolicy, String] {
  if lifetime_ms <= 0L {
    return Err("credential lifetime must be positive")
  }
  Ok({ mode: CREDENTIAL_LIFETIME_FIXED, lifetime_ms: Some(lifetime_ms) })
}

///|
pub(all) struct PairingSecret {
  code : String
  code_id : String
  expires_at_ms : Int64
}

///|
pub(all) struct PairGrant {
  runtime_id : String
  credential_id : String
  credential : String
  generation : Int
  expires_at_ms : Int64?
  protocol_version : Int
}

///|
pub(all) struct AuthGrant {
  runtime_id : String
  credential_id : String
  generation : Int
  last_ack_cursor : Int64
}

///|
pub(all) struct SessionInfo {
  session_id : String
  runtime_id : String
  credential_id : String
  opened_at_ms : Int64
  last_heartbeat_ms : Int64
  last_ack_cursor : Int64
}

///|
pub(all) struct SessionGrant {
  session_id : String
  runtime_id : String
  credential_id : String
  resume_cursor : Int64
  gap : Bool
}

///|
pub suberror PairFailure {
  /// Uniform rejection. The string is the internal audit reason only and is
  /// never sent on the wire.
  PairRejected(String)
  PairRateLimited
  PairUnsupportedVersion(Int)
  PairMalformed(String)
  PairStorage(String)
}

///|
pub suberror AuthFailure {
  AuthUnauthorized
  AuthRevoked
  AuthRateLimited
  AuthUnsupportedVersion(Int)
  AuthMalformed(String)
  AuthStorage(String)
}

///|
pub suberror EventFailure {
  EventMalformed(String)
  EventStorage(String)
}

///|
pub struct PrimaryState {
  policy : CredentialPolicy
  store : StateStore
  pairings : Map[String, PairingRecord]
  credentials : Map[String, CredentialRecord]
  revoked : Array[RevokedRecord]
  acks : Map[String, AckRecord]
  sessions : Map[String, SessionInfo]
  seen_events : Array[String]
  idempotency : Map[String, @json.Json]
  idempotency_order : Array[String]
  rates : RateLimiter
  audit : AuditLog
  now : () -> Int64
  mutex : @async.Mutex
  draining : Ref[Bool]
}

///|
fn primary_default_now() -> Int64 {
  @async.now()
}

///|
/// Open the primary state and load a persisted snapshot if present. Sessions
/// are connection-scoped and are intentionally not durable.
pub async fn PrimaryState::open(
  store : StateStore,
  policy : CredentialPolicy,
) -> Result[PrimaryState, String] {
  PrimaryState::open_with_clock(store, policy, primary_default_now)
}

///|
pub async fn PrimaryState::open_with_clock(
  store : StateStore,
  policy : CredentialPolicy,
  now : () -> Int64,
) -> Result[PrimaryState, String] {
  let snapshot = match (store.load)() {
    Ok(value) => value
    Err(message) => return Err("cannot load transport state: " + message)
  }
  let state : PrimaryState = {
    policy,
    store,
    pairings: Map([]),
    credentials: Map([]),
    revoked: [],
    acks: Map([]),
    sessions: Map([]),
    seen_events: [],
    idempotency: Map([]),
    idempotency_order: [],
    rates: RateLimiter::new(now),
    audit: AuditLog::new(),
    now,
    mutex: @async.Mutex::Mutex(),
    draining: Ref(false),
  }
  match snapshot {
    Some(value) => {
      for record in value.pairings {
        state.pairings.set(record.code_hash, record)
      }
      for record in value.credentials {
        state.credentials.set(record.runtime_id, record)
      }
      for record in value.revoked {
        state.revoked.push(record)
      }
      for record in value.acks {
        state.acks.set(record.runtime_id, record)
      }
      state.prune_locked((now)())
    }
    None => ()
  }
  Ok(state)
}

///|
fn PrimaryState::snapshot_locked(self : PrimaryState) -> StateSnapshot {
  let acks : Array[AckRecord] = []
  for _key, record in self.acks {
    acks.push(record)
  }
  {
    version: 1,
    pairings: self.pairings.values().collect(),
    credentials: self.credentials.values().collect(),
    revoked: self.revoked,
    acks,
  }
}

///|
async fn PrimaryState::persist_locked(self : PrimaryState) -> Result[Unit, String] {
  (self.store.save)(self.snapshot_locked())
}

///|
fn PrimaryState::prune_locked(self : PrimaryState, now_ms : Int64) -> Unit {
  let keys = self.pairings.keys().collect()
  for key in keys {
    match self.pairings.get(key) {
      Some(record) =>
        if record.expires_at_ms <= now_ms {
          self.pairings.remove(key)
        }
      None => ()
    }
  }
  while self.pairings.length() > MAX_PAIRING_RECORDS {
    let mut oldest_key = ""
    let mut oldest_value = 0L
    let mut found = false
    for key, record in self.pairings {
      if !found || record.created_at_ms < oldest_value {
        found = true
        oldest_key = key
        oldest_value = record.created_at_ms
      }
    }
    if !found {
      break
    }
    self.pairings.remove(oldest_key)
  }
}

///|
fn PrimaryState::trim_revoked_locked(self : PrimaryState) -> Unit {
  while self.revoked.length() > MAX_REVOKED_CREDENTIALS {
    let _ = self.revoked.remove(0)
  }
}

///|
fn PrimaryState::remove_sessions_locked(self : PrimaryState, runtime_id : String) -> Unit {
  let keys = self.sessions.keys().collect()
  for key in keys {
    match self.sessions.get(key) {
      Some(session) =>
        if session.runtime_id == runtime_id {
          self.sessions.remove(key)
        }
      None => ()
    }
  }
}

///|
/// Move the credential record into the revocation list and drop any sessions
/// bound to it. Never logs the token or its hash.
fn PrimaryState::revoke_record_locked(
  self : PrimaryState,
  record : CredentialRecord,
  reason : String,
  now_ms : Int64,
) -> Unit {
  // Only remove the live record if it is still the same credential; a rotate
  // that already replaced it must not remove the newer one.
  let current = match self.credentials.get(record.runtime_id) {
    Some(value) => value.credential_id == record.credential_id
    None => false
  }
  if current {
    self.credentials.remove(record.runtime_id)
  }
  self.revoked.push({
    runtime_id: record.runtime_id,
    credential_id: record.credential_id,
    token_hash: record.token_hash,
    revoked_at_ms: now_ms,
    reason,
  })
  self.trim_revoked_locked()
  self.remove_sessions_locked(record.runtime_id)
  self.audit.record(
    "runtime.credential_revoked",
    record.runtime_id,
    "ok",
    "credential_id=" +
    record.credential_id +
    " generation=" +
    record.generation.to_string() +
    " reason=" +
    reason,
    now_ms,
  )
}

///|
fn PrimaryState::issue_credential_locked(
  self : PrimaryState,
  runtime_id : String,
  generation : Int,
  capabilities : Array[String],
  now_ms : Int64,
) -> Result[PairGrant, String] {
  let token_bytes = match random_bytes(CREDENTIAL_BYTES) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let id_bytes = match random_bytes(8) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let token = hex_of(token_bytes.exact_view())
  let credential_id = hex_of(id_bytes.exact_view())
  let expires_at_ms = match self.policy.lifetime_ms {
    Some(lifetime) => Some(now_ms + lifetime)
    None => None
  }
  self.credentials.set(runtime_id, {
    runtime_id,
    credential_id,
    token_hash: sha256_text(token),
    generation,
    issued_at_ms: now_ms,
    expires_at_ms,
    revoked: false,
    capabilities,
  })
  Ok({
    runtime_id,
    credential_id,
    credential: token,
    generation,
    expires_at_ms,
    protocol_version: PROTOCOL_VERSION,
  })
}

///|
fn PrimaryState::audit_pair_rejected(
  self : PrimaryState,
  runtime_id : String,
  reason : String,
  now_ms : Int64,
) -> Unit {
  self.audit.record(
    "runtime.pairing_rejected",
    runtime_id,
    "rejected",
    "reason=" + reason,
    now_ms,
  )
  self.audit.log_line(
    "pairing rejected runtime_id=" +
    runtime_id +
    " reason=" +
    reason,
  )
}

///|
/// Issue a new one-time pairing code. Only its SHA-256 hash enters state.
pub async fn PrimaryState::create_pairing_code(
  self : PrimaryState,
) -> Result[PairingSecret, String] {
  self.mutex.acquire()
  defer self.mutex.release()
  let now_ms = (self.now)()
  self.prune_locked(now_ms)
  let code_bytes = match random_bytes(PAIRING_CODE_BYTES) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let id_bytes = match random_bytes(8) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let code = hex_of(code_bytes.exact_view())
  let code_id = hex_of(id_bytes.exact_view())
  let code_hash = sha256_text(code)
  let record : PairingRecord = {
    code_id,
    code_hash,
    created_at_ms: now_ms,
    expires_at_ms: now_ms + PAIRING_CODE_TTL_MS,
    used: false,
  }
  self.pairings.set(code_hash, record)
  match self.persist_locked() {
    Ok(_) => ()
    Err(message) => {
      self.audit.log_line("pairing code could not be persisted: " + message)
      return Err("cannot persist pairing code")
    }
  }
  self.audit.record(
    "runtime.pairing_code_issued",
    "",
    "ok",
    "code_id=" + code_id,
    now_ms,
  )
  Ok({ code, code_id, expires_at_ms: record.expires_at_ms })
}

///|
async fn PrimaryState::pair_locked(
  self : PrimaryState,
  code : String,
  runtime_id : String,
  protocol_version : Int,
  capabilities : Array[String],
  source : String,
  now_ms : Int64,
) -> Result[PairGrant, PairFailure] {
  let source_key = source_host(source)
  if !self.rates.try_consume(
    "pair:source",
    source_key,
    PAIRING_PER_SOURCE_LIMIT,
  ) {
    self.audit_pair_rejected(runtime_id, "source_rate_limited", now_ms)
    return Err(PairRateLimited)
  }
  if !self.rates.try_consume("pair:global", "", PAIRING_GLOBAL_LIMIT) {
    self.audit_pair_rejected(runtime_id, "global_rate_limited", now_ms)
    return Err(PairRateLimited)
  }
  if !is_safe_id(runtime_id) {
    self.audit_pair_rejected(runtime_id, "malformed_runtime_id", now_ms)
    return Err(PairMalformed("invalid runtime_id"))
  }
  if protocol_version != PROTOCOL_VERSION {
    self.audit_pair_rejected(runtime_id, "unsupported_version", now_ms)
    return Err(PairUnsupportedVersion(protocol_version))
  }
  if capabilities.length() > MAX_CAPABILITIES {
    self.audit_pair_rejected(runtime_id, "malformed_capabilities", now_ms)
    return Err(PairMalformed("too many capabilities"))
  }
  for capability in capabilities {
    if !is_safe_token_text(capability, MAX_CAPABILITY_LEN) {
      self.audit_pair_rejected(runtime_id, "malformed_capability", now_ms)
      return Err(PairMalformed("invalid capability"))
    }
  }
  self.prune_locked(now_ms)
  // Hash bounded input only; an oversized code can never match a 128-bit code
  // and is rejected without hashing attacker-sized data.
  let code_hash = if code.length() > MAX_CODE_INPUT_LEN {
    sha256_text("")
  } else {
    sha256_text(code)
  }
  let record = match self.pairings.get(code_hash) {
    Some(value) => value
    None => {
      self.audit_pair_rejected(runtime_id, "unknown_code", now_ms)
      return Err(PairRejected("unknown_code"))
    }
  }
  if !constant_time_hex_eq(code_hash, record.code_hash) {
    self.audit_pair_rejected(runtime_id, "code_mismatch", now_ms)
    return Err(PairRejected("code_mismatch"))
  }
  if record.expires_at_ms <= now_ms {
    self.audit_pair_rejected(runtime_id, "expired_code", now_ms)
    return Err(PairRejected("expired_code"))
  }
  if record.used {
    self.audit_pair_rejected(runtime_id, "used_code", now_ms)
    return Err(PairRejected("used_code"))
  }
  // Single use: consume before issuing anything.
  self.pairings.set(code_hash, { ..record, used: true })
  let mut generation = 1
  match self.credentials.get(runtime_id) {
    Some(existing) => {
      generation = existing.generation + 1
      self.revoke_record_locked(existing, "re-pair", now_ms)
    }
    None => ()
  }
  let grant = match
    self.issue_credential_locked(runtime_id, generation, capabilities, now_ms) {
    Ok(value) => value
    Err(message) => {
      self.audit.record(
        "runtime.pairing_rejected",
        runtime_id,
        "error",
        "reason=entropy_unavailable",
        now_ms,
      )
      return Err(PairStorage(message))
    }
  }
  match self.persist_locked() {
    Ok(_) => ()
    Err(message) => {
      self.audit.log_line("enrollment could not be persisted: " + message)
      return Err(PairStorage(message))
    }
  }
  self.audit.record(
    "runtime.enrolled",
    runtime_id,
    "ok",
    "code_id=" +
    record.code_id +
    " credential_id=" +
    grant.credential_id +
    " generation=" +
    generation.to_string() +
    " mode=" +
    self.policy.mode,
    now_ms,
  )
  self.audit.log_line(
    "runtime enrolled runtime_id=" +
    runtime_id +
    " generation=" +
    generation.to_string(),
  )
  Ok(grant)
}

///|
/// Exchange a one-time pairing code for a machine credential. Unknown,
/// expired, already-used and rate-limited attempts all surface as the same
/// uniform rejection on the wire; only the audit entry names the reason.
pub async fn PrimaryState::pair(
  self : PrimaryState,
  code : String,
  runtime_id : String,
  protocol_version : Int,
  capabilities : Array[String],
  source : String,
) -> Result[PairGrant, PairFailure] {
  self.mutex.acquire()
  defer self.mutex.release()
  self.pair_locked(
    code,
    runtime_id,
    protocol_version,
    capabilities,
    source,
    (self.now)(),
  )
}

///|
fn PrimaryState::reject_auth(
  self : PrimaryState,
  runtime_id : String,
  reason : String,
  now_ms : Int64,
) -> Unit {
  self.audit.record(
    "runtime.auth_rejected",
    runtime_id,
    "rejected",
    "reason=" + reason,
    now_ms,
  )
  self.audit.log_line(
    "auth rejected runtime_id=" + runtime_id + " reason=" + reason,
  )
}

///|
async fn PrimaryState::authenticate_locked(
  self : PrimaryState,
  runtime_id : String,
  token : String,
  source : String,
  now_ms : Int64,
) -> Result[AuthGrant, AuthFailure] {
  let source_key = source_host(source)
  // Every attempt consumes budget before the credential is checked, so a
  // holder of a valid token cannot retry without bound either.
  if !self.rates.try_consume("auth:source", source_key, AUTH_PER_SOURCE_LIMIT) {
    self.reject_auth(runtime_id, "source_rate_limited", now_ms)
    return Err(AuthRateLimited)
  }
  if !self.rates.try_consume(
    "auth:runtime",
    clamp_text(runtime_id, MAX_RUNTIME_ID_LEN),
    AUTH_PER_RUNTIME_LIMIT,
  ) {
    self.reject_auth(runtime_id, "runtime_rate_limited", now_ms)
    return Err(AuthRateLimited)
  }
  if !self.rates.try_consume("auth:global", "", AUTH_GLOBAL_LIMIT) {
    self.reject_auth(runtime_id, "global_rate_limited", now_ms)
    return Err(AuthRateLimited)
  }
  if !is_safe_id(runtime_id) || token.length() > MAX_TOKEN_INPUT_LEN {
    self.reject_auth(runtime_id, "malformed_credential", now_ms)
    return Err(AuthUnauthorized)
  }
  let presented_hash = sha256_text(token)
  let matched = match self.credentials.get(runtime_id) {
    Some(record) =>
      if constant_time_hex_eq(presented_hash, record.token_hash) {
        Some(record)
      } else {
        None
      }
    None => None
  }
  // Scan the bounded revocation list in constant time per entry so a revoked
  // token gets the documented `revoked` code while a wrong token stays
  // uniform `unauthorized`.
  let mut revoked_match = false
  for record in self.revoked {
    if record.runtime_id == runtime_id &&
      constant_time_hex_eq(presented_hash, record.token_hash) {
      revoked_match = true
    }
  }
  let record = match matched {
    Some(value) => value
    None => {
      if revoked_match {
        self.reject_auth(runtime_id, "revoked_credential", now_ms)
        return Err(AuthRevoked)
      }
      self.reject_auth(runtime_id, "unknown_runtime_or_token", now_ms)
      return Err(AuthUnauthorized)
    }
  }
  if record.revoked {
    self.revoke_record_locked(record, "revoked", now_ms)
    let _ = self.persist_locked()
    return Err(AuthRevoked)
  }
  match record.expires_at_ms {
    Some(expires_at_ms) =>
      if expires_at_ms <= now_ms {
        self.revoke_record_locked(record, "expired", now_ms)
        match self.persist_locked() {
          Ok(_) => ()
          Err(message) =>
            self.audit.log_line("expiry could not be persisted: " + message)
        }
        self.reject_auth(runtime_id, "expired_credential", now_ms)
        return Err(AuthRevoked)
      }
    None => ()
  }
  if revoked_match {
    // A revoked hash that also matches a live record should be impossible
    // (rotation replaces the record), but fail closed if it happens.
    self.reject_auth(runtime_id, "ambiguous_credential_state", now_ms)
    return Err(AuthRevoked)
  }
  let cursor = match self.acks.get(runtime_id) {
    Some(record) => record.cursor
    None => 0L
  }
  self.audit.record(
    "runtime.authenticated",
    runtime_id,
    "ok",
    "credential_id=" +
    record.credential_id +
    " generation=" +
    record.generation.to_string(),
    now_ms,
  )
  Ok({
    runtime_id,
    credential_id: record.credential_id,
    generation: record.generation,
    last_ack_cursor: cursor,
  })
}

///|
/// Bearer authentication. Returns `revoked` only when the presented token
/// matches a revoked credential, so a node holding a revoked token stops
/// retrying while a wrong token stays a uniform `unauthorized`.
pub async fn PrimaryState::authenticate(
  self : PrimaryState,
  runtime_id : String,
  token : String,
  source : String,
) -> Result[AuthGrant, AuthFailure] {
  self.mutex.acquire()
  defer self.mutex.release()
  self.authenticate_locked(runtime_id, token, source, (self.now)())
}

///|
async fn PrimaryState::issue_session_locked(
  self : PrimaryState,
  runtime_id : String,
  token : String,
  source : String,
  last_ack_cursor : Int64,
  now_ms : Int64,
) -> Result[SessionGrant, AuthFailure] {
  let auth = match
    self.authenticate_locked(runtime_id, token, source, now_ms) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let session_bytes = match random_bytes(8) {
    Ok(value) => value
    Err(message) => return Err(AuthStorage(message))
  }
  let session_id = hex_of(session_bytes.exact_view())
  let resume_cursor = auth.last_ack_cursor
  let gap = last_ack_cursor > resume_cursor
  let session : SessionInfo = {
    session_id,
    runtime_id,
    credential_id: auth.credential_id,
    opened_at_ms: now_ms,
    last_heartbeat_ms: now_ms,
    last_ack_cursor: resume_cursor,
  }
  self.sessions.set(session_id, session)
  self.audit.record(
    "runtime.session_opened",
    runtime_id,
    "ok",
    "session_id=" +
    session_id +
    " credential_id=" +
    auth.credential_id +
    " resume_cursor=" +
    resume_cursor.to_string() +
    " gap=" +
    (if gap { "true" } else { "false" }),
    now_ms,
  )
  if gap {
    self.audit.log_line(
      "cursor gap runtime_id=" +
      runtime_id +
      " node_last_ack=" +
      last_ack_cursor.to_string() +
      " primary_cursor=" +
      resume_cursor.to_string(),
    )
  }
  Ok({
    session_id,
    runtime_id,
    credential_id: auth.credential_id,
    resume_cursor,
    gap,
  })
}

///|
/// Authenticate and open a session. `last_ack_cursor` is the node's durable
/// outbox cursor; the primary reports its own cursor and whether the node is
/// ahead of it (a `cursor_gap` diagnostic, never a silent rewind).
pub async fn PrimaryState::open_session(
  self : PrimaryState,
  runtime_id : String,
  token : String,
  source : String,
  last_ack_cursor : Int64,
) -> Result[SessionGrant, AuthFailure] {
  self.mutex.acquire()
  defer self.mutex.release()
  self.issue_session_locked(
    runtime_id,
    token,
    source,
    last_ack_cursor,
    (self.now)(),
  )
}

///|
/// Update session liveness and re-check the credential behind it. A revoked or
/// expired credential closes the session with `revoked`.
pub async fn PrimaryState::heartbeat(
  self : PrimaryState,
  session_id : String,
) -> Result[Int64, AuthFailure] {
  self.mutex.acquire()
  defer self.mutex.release()
  let now_ms = (self.now)()
  let session = match self.sessions.get(session_id) {
    Some(value) => value
    None => return Err(AuthRevoked)
  }
  let record = match self.credentials.get(session.runtime_id) {
    Some(value) =>
      if value.credential_id == session.credential_id {
        value
      } else {
        self.sessions.remove(session_id)
        self.reject_auth(session.runtime_id, "credential_replaced", now_ms)
        return Err(AuthRevoked)
      }
    None => {
      self.sessions.remove(session_id)
      self.reject_auth(session.runtime_id, "credential_gone", now_ms)
      return Err(AuthRevoked)
    }
  }
  if record.revoked {
    self.sessions.remove(session_id)
    return Err(AuthRevoked)
  }
  match record.expires_at_ms {
    Some(expires_at_ms) =>
      if expires_at_ms <= now_ms {
        self.revoke_record_locked(record, "expired", now_ms)
        let _ = self.persist_locked()
        return Err(AuthRevoked)
      }
    None => ()
  }
  let cursor = match self.acks.get(session.runtime_id) {
    Some(value) => value.cursor
    None => 0L
  }
  self.sessions.set(session_id, {
    ..session,
    last_heartbeat_ms: now_ms,
    last_ack_cursor: cursor,
  })
  Ok(cursor)
}

///|
pub async fn PrimaryState::close_session(
  self : PrimaryState,
  session_id : String,
) -> Unit {
  self.mutex.acquire()
  defer self.mutex.release()
  match self.sessions.get(session_id) {
    Some(session) => {
      self.sessions.remove(session_id)
      self.audit.record(
        "runtime.session_closed",
        session.runtime_id,
        "ok",
        "session_id=" + session_id,
        (self.now)(),
      )
    }
    None => ()
  }
}

///|
/// Revoke every credential for a runtime and drop its sessions. Idempotent;
/// returns the number of credentials revoked.
pub async fn PrimaryState::revoke(
  self : PrimaryState,
  runtime_id : String,
  reason : String,
) -> Result[Int, String] {
  self.mutex.acquire()
  defer self.mutex.release()
  let now_ms = (self.now)()
  let record = match self.credentials.get(runtime_id) {
    Some(value) => value
    None => {
      self.remove_sessions_locked(runtime_id)
      return Ok(0)
    }
  }
  self.revoke_record_locked(record, reason, now_ms)
  match self.persist_locked() {
    Ok(_) => ()
    Err(message) => return Err(message)
  }
  Ok(1)
}

///|
/// Rotate the credential: authenticate the old token, revoke it, issue a new
/// one with generation+1. Sessions bound to the old credential are closed, so
/// the node reconnects with the new token. The plaintext token is returned
/// once and never logged.
pub async fn PrimaryState::rotate(
  self : PrimaryState,
  runtime_id : String,
  token : String,
  source : String,
) -> Result[PairGrant, AuthFailure] {
  self.mutex.acquire()
  defer self.mutex.release()
  let now_ms = (self.now)()
  let auth = match self.authenticate_locked(runtime_id, token, source, now_ms) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let record = match self.credentials.get(runtime_id) {
    Some(value) =>
      if value.credential_id == auth.credential_id {
        value
      } else {
        return Err(AuthRevoked)
      }
    None => return Err(AuthRevoked)
  }
  self.revoke_record_locked(record, "rotated", now_ms)
  let grant = match self.issue_credential_locked(
    runtime_id,
    record.generation + 1,
    record.capabilities,
    now_ms,
  ) {
    Ok(value) => value
    Err(message) => return Err(AuthStorage(message))
  }
  match self.persist_locked() {
    Ok(_) => ()
    Err(message) => return Err(AuthStorage(message))
  }
  self.audit.record(
    "runtime.credential_rotated",
    runtime_id,
    "ok",
    "credential_id=" +
    grant.credential_id +
    " generation=" +
    grant.generation.to_string(),
    now_ms,
  )
  Ok(grant)
}

///|
fn PrimaryState::seen_event_index(self : PrimaryState, key : String) -> Int? {
  for index, value in self.seen_events {
    if value == key {
      return Some(index)
    }
  }
  None
}

///|
/// Accept one event from an authenticated session. Dedupe is by
/// `(runtime_id, run_id, run_seq)`; the ack cursor advances to the outbox
/// global `seq` and is persisted before it is reported. A duplicate returns
/// the current cursor without re-appending or re-persisting.
pub async fn PrimaryState::accept_event(
  self : PrimaryState,
  runtime_id : String,
  event : WireEvent,
) -> Result[EventAck, EventFailure] {
  self.mutex.acquire()
  defer self.mutex.release()
  let now_ms = (self.now)()
  if !is_safe_id(runtime_id) {
    return Err(EventMalformed("invalid runtime_id"))
  }
  if payload_is_oversized(event.payload) {
    return Err(EventMalformed("payload is too large"))
  }
  let expected_hash = event.compute_hash(runtime_id)
  if event.hash != expected_hash {
    self.audit.record(
      "runtime.event_rejected",
      runtime_id,
      "rejected",
      "reason=hash_mismatch run_id=" + event.run_id,
      now_ms,
    )
    return Err(EventMalformed("event hash mismatch"))
  }
  let key = runtime_id +
    "/" +
    event.run_id +
    "/" +
    event.run_seq.to_string()
  let cursor = match self.acks.get(runtime_id) {
    Some(record) => record.cursor
    None => 0L
  }
  match self.seen_event_index(key) {
    Some(_) => {
      self.audit.record(
        "runtime.event_duplicate",
        runtime_id,
        "ok",
        "run_id=" +
        event.run_id +
        " run_seq=" +
        event.run_seq.to_string() +
        " cursor=" +
        cursor.to_string(),
        now_ms,
      )
      return Ok({ cursor, duplicate: true })
    }
    None => ()
  }
  self.seen_events.push(key)
  while self.seen_events.length() > MAX_IDEMPOTENCY_ENTRIES {
    let _ = self.seen_events.remove(0)
  }
  let next_cursor = if event.seq > cursor { event.seq } else { cursor }
  self.acks.set(runtime_id, {
    runtime_id,
    cursor: next_cursor,
    updated_at_ms: now_ms,
  })
  match self.persist_locked() {
    Ok(_) => ()
    Err(message) => return Err(EventStorage(message))
  }
  self.audit.record(
    "runtime.event_accepted",
    runtime_id,
    "ok",
    "run_id=" +
    event.run_id +
    " run_seq=" +
    event.run_seq.to_string() +
    " cursor=" +
    next_cursor.to_string(),
    now_ms,
  )
  Ok({ cursor: next_cursor, duplicate: false })
}

///|
fn payload_is_oversized(payload : @json.Json) -> Bool {
  payload.stringify().length() > MAX_EVENT_PAYLOAD_BYTES
}

///|
/// Read-only snapshot of a session for request routing. Liveness is checked
/// separately by `heartbeat`; this is never used as an authorization decision.
pub fn PrimaryState::session_info(
  self : PrimaryState,
  session_id : String,
) -> SessionInfo? {
  self.sessions.get(session_id)
}

///|
pub fn PrimaryState::cursor_for(self : PrimaryState, runtime_id : String) -> Int64 {
  match self.acks.get(runtime_id) {
    Some(record) => record.cursor
    None => 0L
  }
}

///|
pub fn PrimaryState::session_count(self : PrimaryState) -> Int {
  self.sessions.length()
}

///|
pub fn PrimaryState::credential_count(self : PrimaryState) -> Int {
  self.credentials.length()
}

///|
pub fn PrimaryState::pairing_count(self : PrimaryState) -> Int {
  self.pairings.length()
}

///|
pub fn PrimaryState::idempotent_lookup(self : PrimaryState, key : String) -> @json.Json? {
  self.idempotency.get(key)
}

///|
pub fn PrimaryState::idempotent_remember(
  self : PrimaryState,
  key : String,
  value : @json.Json,
) -> Unit {
  if !self.idempotency.contains(key) {
    self.idempotency_order.push(key)
    while self.idempotency_order.length() > MAX_IDEMPOTENCY_ENTRIES {
      let oldest = self.idempotency_order.remove(0)
      self.idempotency.remove(oldest)
    }
  }
  self.idempotency.set(key, value)
}

///|
/// Ask the server to drain. The flag is read by every connection loop and the
/// drain notification is sent once per connection.
pub fn PrimaryState::request_drain(self : PrimaryState) -> Unit {
  self.draining.val = true
  self.audit.record(
    "runtime.draining",
    "",
    "ok",
    "reason=owner_requested",
    (self.now)(),
  )
}

///|
pub fn PrimaryState::is_draining(self : PrimaryState) -> Bool {
  self.draining.val
}

///|
pub fn PrimaryState::audit_events(self : PrimaryState) -> Array[@json.Json] {
  self.audit.events()
}

///|
pub fn PrimaryState::logs(self : PrimaryState) -> Array[String] {
  self.audit.lines()
}

///|
/// Redacted audit + log text for tests that assert no secret ever appears.
pub fn PrimaryState::audit_text(self : PrimaryState) -> String {
  self.audit.text()
}

///|
pub fn PrimaryState::log_line(self : PrimaryState, line : String) -> Unit {
  self.audit.log_line(line)
}
