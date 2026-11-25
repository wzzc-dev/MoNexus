///|
/// Machine credential authentication, revocation and rotation.
///
/// Two proofs are supported:
///
/// - bearer: present the credential over pinned TLS; the primary stores only
///   its SHA-256 hash and compares in constant time;
/// - HMAC challenge-response: the primary issues a short-lived nonce and the
///   node answers with HMAC-SHA256 over the transcript. This requires the
///   primary to retain the credential (verification key), because no
///   asymmetric signing API is available in this toolchain. See README.

///|
pub(all) enum AuthError {
  /// Uniform rejection: unknown runtime, wrong credential, revoked, expired,
  /// replayed or malformed challenge. The reason stays in the audit log.
  Unauthorized
  UnsupportedVersion(Int)
  Malformed(String)
}

///|
pub(all) struct SessionGrant {
  session_id : String
  runtime_id : String
  resume_from : Int64
  mode : AuthMode
}

///|
/// Transcript signed by the HMAC challenge-response proof. Both sides build
/// the same string; it binds runtime, credential challenge and client nonce.
pub fn auth_message(
  runtime_id : String,
  challenge_id : String,
  challenge : String,
  nonce : String,
) -> String {
  "monexus-a1-auth-v1\n" +
  runtime_id +
  "\n" +
  challenge_id +
  "\n" +
  challenge +
  "\n" +
  nonce
}

///|
/// Node-side MAC for `runtime.authenticate`. `credential` is the hex secret
/// issued at pairing.
pub fn auth_mac(
  credential : String,
  runtime_id : String,
  challenge_id : String,
  challenge : String,
  nonce : String,
) -> Result[String, String] {
  let key = match bytes_of_hex(credential) {
    Some(value) => value
    None => return Err("invalid credential encoding")
  }
  let message = auth_message(runtime_id, challenge_id, challenge, nonce)
  let mac = hmac_sha256_text(key.exact_view(), message)
  Ok(hex_of(mac.exact_view()))
}

///|
fn PrimaryState::enrollment_is_live(
  self : PrimaryState,
  enrollment : Enrollment,
  now_ms : Int64,
) -> Bool {
  let _ = self
  !enrollment.revoked && enrollment.expires_at_ms > now_ms
}

///|
fn PrimaryState::reject_auth(
  self : PrimaryState,
  runtime_id : String,
  reason : String,
  now_ms : Int64,
) -> Unit {
  self.log_line("auth rejected runtime_id=\{runtime_id} reason=\{reason}")
  self.audit_event(
    "runtime.auth_rejected",
    runtime_id,
    now_ms,
    [
      ("runtime_id", @contracts.json_string(runtime_id)),
      ("reason", @contracts.json_string(reason)),
    ],
  )
}

///|
/// Start a challenge-response reconnect. The runtime must already be enrolled;
/// the returned challenge is single-use and expires quickly.
pub fn PrimaryState::begin_auth(
  self : PrimaryState,
  runtime_id : String,
  credential_id : String,
  now_ms : Int64,
  entropy : Bytes,
) -> Result[Challenge, AuthError] {
  if entropy.length() < 40 {
    return Err(Malformed("insufficient entropy for challenge"))
  }
  self.prune(now_ms)
  let enrollment = match self.enrollments.get(runtime_id) {
    Some(value) => value
    None => {
      self.reject_auth(runtime_id, "unknown_runtime", now_ms)
      return Err(Unauthorized)
    }
  }
  if enrollment.credential_id != credential_id ||
    !self.enrollment_is_live(enrollment, now_ms) {
    self.reject_auth(runtime_id, "credential_mismatch", now_ms)
    return Err(Unauthorized)
  }
  let hmac_mode = match enrollment.auth_mode {
    ChallengeResponse => true
    Bearer => false
  }
  if !hmac_mode {
    self.reject_auth(runtime_id, "mode_not_supported", now_ms)
    return Err(Unauthorized)
  }
  let challenge = hex_of(entropy.exact_view()[0:32])
  let challenge_id = hex_of(entropy.exact_view()[32:40])
  let expires_at_ms = now_ms + CHALLENGE_TTL_MS
  self.challenges.set(challenge_id, {
    runtime_id,
    challenge,
    expires_at_ms,
  })
  self.log_line(
    "challenge issued runtime_id=\{runtime_id} credential_id=\{credential_id}",
  )
  Ok({ challenge_id, challenge, expires_at_ms })
}

///|
/// Verify the HMAC answer and open a session with the primary's last
/// acknowledged event sequence, so the node can resume its outbox.
pub fn PrimaryState::complete_auth(
  self : PrimaryState,
  challenge_id : String,
  mac : String,
  nonce : String,
  now_ms : Int64,
  entropy : Bytes,
) -> Result[SessionGrant, AuthError] {
  if entropy.length() < 8 {
    return Err(Malformed("insufficient entropy for session id"))
  }
  if !is_hex_of_length(mac, 64) {
    self.reject_auth("runtime_unknown", "malformed_mac", now_ms)
    return Err(Unauthorized)
  }
  let record = match self.challenges.get(challenge_id) {
    Some(value) => value
    None => {
      self.reject_auth("runtime_unknown", "unknown_challenge", now_ms)
      return Err(Unauthorized)
    }
  }
  if record.expires_at_ms <= now_ms {
    self.reject_auth(record.runtime_id, "stale_challenge", now_ms)
    self.challenges.remove(challenge_id)
    return Err(Unauthorized)
  }
  let runtime_id = record.runtime_id
  let enrollment = match self.enrollments.get(runtime_id) {
    Some(value) => value
    None => {
      self.reject_auth(runtime_id, "unknown_runtime", now_ms)
      return Err(Unauthorized)
    }
  }
  if !self.enrollment_is_live(enrollment, now_ms) {
    self.reject_auth(runtime_id, "credential_revoked", now_ms)
    return Err(Unauthorized)
  }
  let secret = match enrollment.credential_secret {
    Some(value) => value
    None => {
      self.reject_auth(runtime_id, "mode_not_supported", now_ms)
      return Err(Unauthorized)
    }
  }
  let secret_bytes = match bytes_of_hex(secret) {
    Some(value) => value
    None => return Err(Malformed("corrupt enrollment"))
  }
  let message = auth_message(runtime_id, challenge_id, record.challenge, nonce)
  let expected = hex_of(
    hmac_sha256_text(secret_bytes.exact_view(), message).exact_view(),
  )
  if !constant_time_hex_eq(expected, mac) {
    self.reject_auth(runtime_id, "bad_mac", now_ms)
    return Err(Unauthorized)
  }
  if !self.record_nonce(runtime_id, nonce, now_ms) {
    self.reject_auth(runtime_id, "replayed_auth", now_ms)
    return Err(Unauthorized)
  }
  self.challenges.remove(challenge_id)
  let session_id = hex_of(entropy.exact_view()[0:8])
  let resume_from = self.last_ack_seq(runtime_id)
  self.sessions.set(session_id, {
    session_id,
    runtime_id,
    credential_id: enrollment.credential_id,
    auth_mode: ChallengeResponse,
    last_ack_seq: resume_from,
    last_heartbeat_ms: now_ms,
    closed: false,
  })
  self.audit_event(
    "runtime.authenticated",
    runtime_id,
    now_ms,
    [
      ("runtime_id", @contracts.json_string(runtime_id)),
      ("credential_id", @contracts.json_string(enrollment.credential_id)),
      ("generation", @contracts.json_int(enrollment.generation)),
      ("mode", @contracts.json_string("hmac-sha256")),
      ("resume_from", @contracts.json_int64(resume_from)),
    ],
  )
  self.log_line(
    "session opened runtime_id=\{runtime_id} mode=hmac-sha256 resume_from=\{resume_from}",
  )
  Ok({ session_id, runtime_id, resume_from, mode: ChallengeResponse })
}

///|
/// Bearer reconnect: the credential itself is presented once over pinned TLS.
pub fn PrimaryState::authenticate_bearer(
  self : PrimaryState,
  runtime_id : String,
  credential_id : String,
  credential : String,
  nonce : String,
  now_ms : Int64,
  entropy : Bytes,
) -> Result[SessionGrant, AuthError] {
  if entropy.length() < 8 {
    return Err(Malformed("insufficient entropy for session id"))
  }
  self.prune(now_ms)
  let enrollment = match self.enrollments.get(runtime_id) {
    Some(value) => value
    None => {
      self.reject_auth(runtime_id, "unknown_runtime", now_ms)
      return Err(Unauthorized)
    }
  }
  if enrollment.credential_id != credential_id ||
    !self.enrollment_is_live(enrollment, now_ms) {
    self.reject_auth(runtime_id, "credential_mismatch", now_ms)
    return Err(Unauthorized)
  }
  let bearer_mode = match enrollment.auth_mode {
    Bearer => true
    ChallengeResponse => false
  }
  if !bearer_mode {
    self.reject_auth(runtime_id, "mode_not_supported", now_ms)
    return Err(Unauthorized)
  }
  let presented_hash = sha256_text(credential)
  if !constant_time_hex_eq(presented_hash, enrollment.credential_hash) {
    self.reject_auth(runtime_id, "bad_credential", now_ms)
    return Err(Unauthorized)
  }
  if !self.record_nonce(runtime_id, nonce, now_ms) {
    self.reject_auth(runtime_id, "replayed_auth", now_ms)
    return Err(Unauthorized)
  }
  let session_id = hex_of(entropy.exact_view()[0:8])
  let resume_from = self.last_ack_seq(runtime_id)
  self.sessions.set(session_id, {
    session_id,
    runtime_id,
    credential_id: enrollment.credential_id,
    auth_mode: Bearer,
    last_ack_seq: resume_from,
    last_heartbeat_ms: now_ms,
    closed: false,
  })
  self.audit_event(
    "runtime.authenticated",
    runtime_id,
    now_ms,
    [
      ("runtime_id", @contracts.json_string(runtime_id)),
      ("credential_id", @contracts.json_string(enrollment.credential_id)),
      ("generation", @contracts.json_int(enrollment.generation)),
      ("mode", @contracts.json_string("bearer")),
      ("resume_from", @contracts.json_int64(resume_from)),
    ],
  )
  self.log_line(
    "session opened runtime_id=\{runtime_id} mode=bearer resume_from=\{resume_from}",
  )
  Ok({ session_id, runtime_id, resume_from, mode: Bearer })
}

///|
/// Revoke an enrollment. The credential id stops authenticating immediately
/// and every open session for the runtime is closed.
pub fn PrimaryState::revoke_runtime(
  self : PrimaryState,
  runtime_id : String,
  reason : String,
  now_ms : Int64,
) -> Bool {
  let enrollment = match self.enrollments.get(runtime_id) {
    Some(value) => value
    None => {
      self.log_line("revoke ignored runtime_id=\{runtime_id} reason=unknown")
      return false
    }
  }
  self.enrollments.set(runtime_id, {
    runtime_id,
    machine_public_key: enrollment.machine_public_key,
    generation: enrollment.generation,
    credential_id: enrollment.credential_id,
    credential_hash: enrollment.credential_hash,
    credential_secret: enrollment.credential_secret,
    auth_mode: enrollment.auth_mode,
    scopes: enrollment.scopes,
    issued_at_ms: enrollment.issued_at_ms,
    expires_at_ms: enrollment.expires_at_ms,
    revoked: true,
  })
  self.credentials.remove(enrollment.credential_id)
  self.close_sessions_for(runtime_id)
  self.audit_event(
    "runtime.revoked",
    runtime_id,
    now_ms,
    [
      ("runtime_id", @contracts.json_string(runtime_id)),
      ("credential_id", @contracts.json_string(enrollment.credential_id)),
      ("generation", @contracts.json_int(enrollment.generation)),
      ("reason", @contracts.json_string(bounded_redacted(reason))),
    ],
  )
  self.log_line("runtime revoked runtime_id=\{runtime_id}")
  true
}

///|
/// Rotate the machine credential. `runtime_id` and generation lineage stay,
/// the old credential id is dropped and sessions are closed so the node has to
/// reconnect with the new credential.
pub fn PrimaryState::rotate_credential(
  self : PrimaryState,
  session_id : String,
  now_ms : Int64,
  entropy : Bytes,
) -> Result[PairGrant, AuthError] {
  if entropy.length() < 48 {
    return Err(Malformed("insufficient entropy for rotation"))
  }
  let session = match self.sessions.get(session_id) {
    Some(value) =>
      if value.closed {
        return Err(Unauthorized)
      } else {
        value
      }
    None => return Err(Unauthorized)
  }
  let runtime_id = session.runtime_id
  let enrollment = match self.enrollments.get(runtime_id) {
    Some(value) =>
      if value.revoked || value.expires_at_ms <= now_ms {
        return Err(Unauthorized)
      } else {
        value
      }
    None => return Err(Unauthorized)
  }
  let old_credential_id = enrollment.credential_id
  let credential = hex_of(entropy.exact_view()[0:32])
  let credential_id = hex_of(entropy.exact_view()[32:40])
  let credential_hash = sha256_text(credential)
  let credential_secret = match enrollment.auth_mode {
    ChallengeResponse => Some(credential)
    Bearer => None
  }
  let generation = enrollment.generation + 1
  let expires_at_ms = now_ms + CREDENTIAL_TTL_MS
  self.credentials.remove(old_credential_id)
  self.enrollments.set(runtime_id, {
    runtime_id,
    machine_public_key: enrollment.machine_public_key,
    generation,
    credential_id,
    credential_hash,
    credential_secret,
    auth_mode: enrollment.auth_mode,
    scopes: enrollment.scopes,
    issued_at_ms: now_ms,
    expires_at_ms,
    revoked: false,
  })
  self.credentials.set(credential_id, runtime_id)
  self.close_sessions_for(runtime_id)
  self.audit_event(
    "runtime.credential_rotated",
    runtime_id,
    now_ms,
    [
      ("runtime_id", @contracts.json_string(runtime_id)),
      ("old_credential_id", @contracts.json_string(old_credential_id)),
      ("credential_id", @contracts.json_string(credential_id)),
      ("generation", @contracts.json_int(generation)),
    ],
  )
  self.log_line(
    "credential rotated runtime_id=\{runtime_id} generation=\{generation}",
  )
  Ok({
    runtime_id,
    credential_id,
    credential,
    expires_at_ms,
    generation,
    auth_mode: enrollment.auth_mode,
    scopes: enrollment.scopes,
    code_id: "",
  })
}

///|
/// True when the current enrollment carries `scope`. Used by the dispatcher
/// so a scoped credential cannot call methods outside its grant.
pub fn PrimaryState::has_scope(
  self : PrimaryState,
  runtime_id : String,
  scope : String,
) -> Bool {
  match self.enrollments.get(runtime_id) {
    Some(enrollment) => enrollment.scopes.contains(scope)
    None => false
  }
}
