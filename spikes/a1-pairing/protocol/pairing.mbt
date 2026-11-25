///|
/// One-time pairing code creation and verification.
///
/// Wire behaviour (ADR-0012 §2): wrong, expired, already-used, replayed and
/// rate-limited attempts all return the same `pairing rejected` error. The
/// distinguishing reason exists only in the primary's audit log.

///|
pub(all) enum PairError {
  /// Uniform rejection: unknown, expired, used, replayed or rate-limited.
  Rejected
  RateLimited
  UnsupportedVersion(Int)
  Malformed(String)
}

///|
pub(all) struct PairGrant {
  runtime_id : String
  credential_id : String
  credential : String
  expires_at_ms : Int64
  generation : Int
  auth_mode : AuthMode
  scopes : Array[String]
  code_id : String
}

///|
fn is_safe_id(text : String) -> Bool {
  if text == "" || text.length() > MAX_RUNTIME_ID_LEN {
    return false
  }
  for index in 0..<text.length() {
    let ch = match text.get_char(index) {
      Some(value) => value
      None => return false
    }
    let ok = (ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= '0' && ch <= '9') || ch == '-' || ch == '_' || ch == '.' ||
      ch == ':'
    if !ok {
      return false
    }
  }
  true
}

///|
fn is_safe_token(text : String, max_len : Int) -> Bool {
  if text == "" || text.length() > max_len {
    return false
  }
  for index in 0..<text.length() {
    let ch = match text.get_char(index) {
      Some(value) => value
      None => return false
    }
    let ok = (ch >= 'a' && ch <= 'z') ||
      (ch >= 'A' && ch <= 'Z') ||
      (ch >= '0' && ch <= '9') || ch == '-' || ch == '_' || ch == '.' ||
      ch == ':'
    if !ok {
      return false
    }
  }
  true
}

///|
/// Validate the `runtime.hello` payload. Field lengths are bounded so a
/// hostile hello cannot grow state or logs.
pub fn parse_hello(
  params : Map[String, @json.Json],
) -> Result[Hello, String] {
  let request_id = match @contracts.string_field(params, "client_request_id") {
    Some(value) =>
      if value != "" && value.length() <= MAX_RUNTIME_ID_LEN {
        value
      } else {
        return Err("missing or invalid client_request_id")
      }
    None => return Err("missing or invalid client_request_id")
  }
  let runtime_id = match @contracts.string_field(params, "runtime_id") {
    Some(value) =>
      if is_safe_id(value) {
        value
      } else {
        return Err("missing or invalid runtime_id")
      }
    None => return Err("missing or invalid runtime_id")
  }
  let protocol_version = match @contracts.int_field(params, "protocol_version") {
    Some(value) => value
    None => return Err("missing protocol_version")
  }
  let capabilities = match params.get("capabilities") {
    Some(value) =>
      match value.as_array() {
        Some(items) =>
          if items.length().to_int() > MAX_CAPABILITIES {
            return Err("too many capabilities")
          } else {
            let capabilities : Array[String] = []
            for item in items {
              match item.as_string() {
                Some(text) =>
                  if is_safe_token(text, MAX_CAPABILITY_LEN) {
                    capabilities.push(text)
                  } else {
                    return Err("invalid capability entry")
                  }
                None => return Err("invalid capability entry")
              }
            }
            capabilities
          }
        None => return Err("capabilities must be an array")
      }
    None => return Err("missing capabilities")
  }
  let machine_public_key = match @contracts.string_field(
    params,
    "machine_public_key",
  ) {
    Some(value) =>
      if is_hex_of_length(value, 64) {
        value
      } else {
        return Err("missing or invalid machine_public_key")
      }
    None => return Err("missing or invalid machine_public_key")
  }
  let nonce = match @contracts.string_field(params, "nonce") {
    Some(value) =>
      if value.length() >= 32 &&
        value.length() <= 64 &&
        is_hex_of_length(value, value.length()) {
        value
      } else {
        return Err("missing or invalid nonce")
      }
    None => return Err("missing or invalid nonce")
  }
  Ok({
    runtime_id,
    protocol_version,
    capabilities,
    machine_public_key,
    nonce,
    request_id,
  })
}

///|
/// Create a short-TTL, high-entropy pairing code. Only the SHA-256 hash is
/// stored; the raw code is returned to the caller for out-of-band display and
/// must never be logged or persisted.
pub fn PrimaryState::create_pairing_code(
  self : PrimaryState,
  code_entropy : Bytes,
  id_entropy : Bytes,
  now_ms : Int64,
) -> Result[(String, String), String] {
  if code_entropy.length() < PAIRING_CODE_BYTES {
    return Err("insufficient entropy for pairing code")
  }
  if id_entropy.length() < 8 {
    return Err("insufficient entropy for pairing code id")
  }
  self.prune(now_ms)
  let code = hex_of(code_entropy.exact_view()[0:PAIRING_CODE_BYTES])
  let code_id = hex_of(id_entropy.exact_view()[0:8])
  let code_hash = sha256_text(code)
  let expires_at_ms = now_ms + PAIRING_CODE_TTL_MS
  self.pairings.set(code_hash, {
    code_id,
    code_hash,
    expires_at_ms,
    used: false,
  })
  self.log_line(
    "pairing code issued code_id=\{code_id} ttl_ms=\{PAIRING_CODE_TTL_MS}",
  )
  Ok((code, code_id))
}

///|
pub fn PrimaryState::pair(
  self : PrimaryState,
  code : String,
  hello : Hello,
  now_ms : Int64,
  entropy : Bytes,
) -> Result[PairGrant, PairError] {
  self.pair_with_scopes(code, hello, now_ms, entropy, default_scopes())
}

///|
/// Same as `pair`, but with an explicit scope list. The spike uses this from
/// tests to prove scope enforcement; production pairing will derive scopes
/// from the method manifest instead of accepting them from the caller.
pub fn PrimaryState::pair_with_scopes(
  self : PrimaryState,
  code : String,
  hello : Hello,
  now_ms : Int64,
  entropy : Bytes,
  scopes : Array[String],
) -> Result[PairGrant, PairError] {
  if entropy.length() < 48 {
    return Err(Malformed("insufficient entropy for enrollment"))
  }
  if hello.protocol_version != PROTOCOL_VERSION {
    self.log_line(
      "pairing rejected runtime_id=\{hello.runtime_id} reason=version",
    )
    self.audit_event(
      "runtime.pairing_rejected",
      hello.runtime_id,
      now_ms,
      [
        ("runtime_id", @contracts.json_string(hello.runtime_id)),
        ("reason", @contracts.json_string("unsupported_version")),
        ("protocol_version", @contracts.json_int(hello.protocol_version)),
      ],
    )
    return Err(UnsupportedVersion(hello.protocol_version))
  }
  if !self.failure_count_allows_attempt(now_ms) {
    self.log_line(
      "pairing rejected runtime_id=\{hello.runtime_id} reason=rate_limited",
    )
    self.audit_event(
      "runtime.pairing_rejected",
      hello.runtime_id,
      now_ms,
      [
        ("runtime_id", @contracts.json_string(hello.runtime_id)),
        ("reason", @contracts.json_string("rate_limited")),
      ],
    )
    return Err(RateLimited)
  }
  // Replays of a hello nonce are rejected even if the code is still valid.
  if !self.record_nonce(hello.runtime_id, hello.nonce, now_ms) {
    self.record_failure(now_ms)
    self.log_line(
      "pairing rejected runtime_id=\{hello.runtime_id} reason=replayed_hello",
    )
    self.audit_event(
      "runtime.pairing_rejected",
      hello.runtime_id,
      now_ms,
      [
        ("runtime_id", @contracts.json_string(hello.runtime_id)),
        ("reason", @contracts.json_string("replayed_hello")),
      ],
    )
    return Err(Rejected)
  }
  let code_hash = sha256_text(code)
  let record = match self.pairings.get(code_hash) {
    Some(value) => value
    None => {
      self.record_failure(now_ms)
      self.log_line("pairing rejected reason=unknown_code")
      self.audit_event("runtime.pairing_rejected", "runtime_unknown", now_ms, [
        ("reason", @contracts.json_string("unknown_code")),
      ])
      return Err(Rejected)
    }
  }
  let code_id = record.code_id
  if record.expires_at_ms <= now_ms {
    self.record_failure(now_ms)
    self.log_line("pairing rejected code_id=\{code_id} reason=expired_code")
    self.audit_event(
      "runtime.pairing_rejected",
      hello.runtime_id,
      now_ms,
      [
        ("code_id", @contracts.json_string(code_id)),
        ("reason", @contracts.json_string("expired_code")),
      ],
    )
    return Err(Rejected)
  }
  if record.used {
    self.record_failure(now_ms)
    self.log_line("pairing rejected code_id=\{code_id} reason=used_code")
    self.audit_event(
      "runtime.pairing_rejected",
      hello.runtime_id,
      now_ms,
      [
        ("code_id", @contracts.json_string(code_id)),
        ("reason", @contracts.json_string("used_code")),
      ],
    )
    return Err(Rejected)
  }
  // Consume the code: replace the record with its used form. A second attempt
  // with the same code then fails as `used_code` until prune drops it.
  self.pairings.set(code_hash, {
    code_id,
    code_hash,
    expires_at_ms: record.expires_at_ms,
    used: true,
  })
  let generation = match self.enrollments.get(hello.runtime_id) {
    Some(existing) => {
      if !existing.revoked {
        self.audit_event(
          "runtime.credential_revoked",
          hello.runtime_id,
          now_ms,
          [
            ("runtime_id", @contracts.json_string(hello.runtime_id)),
            (
              "credential_id",
              @contracts.json_string(existing.credential_id),
            ),
            ("reason", @contracts.json_string("re-pair")),
            ("generation", @contracts.json_int(existing.generation)),
          ],
        )
        self.credentials.remove(existing.credential_id)
      }
      existing.generation + 1
    }
    None => 1
  }
  let auth_mode = if hello.capabilities.contains(CAPABILITY_HMAC) {
    ChallengeResponse
  } else {
    Bearer
  }
  let credential = hex_of(entropy.exact_view()[0:32])
  let credential_id = hex_of(entropy.exact_view()[32:40])
  let credential_hash = sha256_text(credential)
  let credential_secret = match auth_mode {
    ChallengeResponse => Some(credential)
    Bearer => None
  }
  let expires_at_ms = now_ms + CREDENTIAL_TTL_MS
  let enrollment : Enrollment = {
    runtime_id: hello.runtime_id,
    machine_public_key: hello.machine_public_key,
    generation,
    credential_id,
    credential_hash,
    credential_secret,
    auth_mode,
    scopes,
    issued_at_ms: now_ms,
    expires_at_ms,
    revoked: false,
  }
  self.enrollments.set(hello.runtime_id, enrollment)
  self.credentials.set(credential_id, hello.runtime_id)
  self.reset_failures(now_ms)
  self.audit_event(
    "runtime.enrolled",
    hello.runtime_id,
    now_ms,
    [
      ("runtime_id", @contracts.json_string(hello.runtime_id)),
      ("code_id", @contracts.json_string(code_id)),
      ("credential_id", @contracts.json_string(credential_id)),
      ("generation", @contracts.json_int(generation)),
      ("mode", @contracts.json_string(auth_mode.name())),
      ("expires_at_ms", @contracts.json_int64(expires_at_ms)),
    ],
  )
  self.log_line(
    "runtime enrolled runtime_id=\{hello.runtime_id} generation=\{generation} mode=\{auth_mode.name()}",
  )
  Ok({
    runtime_id: hello.runtime_id,
    credential_id,
    credential,
    expires_at_ms,
    generation,
    auth_mode,
    scopes,
    code_id,
  })
}
