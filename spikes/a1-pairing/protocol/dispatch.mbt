///|
/// JSON-RPC dispatch for the spike's `runtime.*` namespace.
///
/// The envelope is the existing `@contracts.RpcRequest`/`RpcResponse` shape
/// (string ids, object params, JSON-RPC 2.0 error objects), not a second
/// protocol. Unknown methods return the standard `-32601`.
///
/// Error policy follows ADR-0012 §2: every pairing failure that could reveal
/// which step failed maps to the same `pairing rejected` error; auth failures
/// map to `unauthorized`. Readable diagnostics (version mismatch, malformed
/// params) never contain secrets.

///|
pub const METHOD_RUNTIME_PAIR : String = "runtime.pair"

///|
pub const METHOD_RUNTIME_CHALLENGE : String = "runtime.challenge"

///|
pub const METHOD_RUNTIME_AUTHENTICATE : String = "runtime.authenticate"

///|
pub const METHOD_RUNTIME_AUTHENTICATE_BEARER : String =
  "runtime.authenticate_bearer"

///|
pub const METHOD_RUNTIME_ROTATE : String = "runtime.rotate"

///|
pub const METHOD_RUNTIME_HEARTBEAT : String = "runtime.heartbeat"

///|
pub const METHOD_RUNTIME_PROBE : String = "runtime.probe"

///|
fn ok_response(id : String, result : @json.Json) -> @contracts.RpcResponse {
  { id, result: Some(result), error: None }
}

///|
fn error_response(
  id : String,
  code : Int,
  message : String,
) -> @contracts.RpcResponse {
  {
    id,
    result: None,
    error: Some(
      @contracts.RpcError::new(code, bounded_redacted(message)),
    ),
  }
}

///|
fn require_string_param(
  params : Map[String, @json.Json],
  key : String,
  max_len : Int,
) -> Result[String, String] {
  match @contracts.string_field(params, key) {
    Some(value) =>
      if value != "" && value.length() <= max_len {
        Ok(value)
      } else {
        Err("missing or invalid " + key)
      }
    None => Err("missing or invalid " + key)
  }
}

///|
fn require_hex_param(
  params : Map[String, @json.Json],
  key : String,
  min_len : Int,
  max_len : Int,
) -> Result[String, String] {
  match @contracts.string_field(params, key) {
    Some(value) =>
      if value.length() >= min_len &&
        value.length() <= max_len &&
        is_hex_of_length(value, value.length()) {
        Ok(value)
      } else {
        Err("missing or invalid " + key)
      }
    None => Err("missing or invalid " + key)
  }
}

///|
fn pair_grant_json(grant : PairGrant) -> @json.Json {
  let scopes = @json.Json::array(
    grant.scopes.map(scope => @contracts.json_string(scope)),
  )
  @contracts.json_object([
    ("runtime_id", @contracts.json_string(grant.runtime_id)),
    ("credential_id", @contracts.json_string(grant.credential_id)),
    ("credential", @contracts.json_string(grant.credential)),
    ("expires_at_ms", @contracts.json_int64(grant.expires_at_ms)),
    ("generation", @contracts.json_int(grant.generation)),
    ("mode", @contracts.json_string(grant.auth_mode.name())),
    ("scopes", scopes),
    ("code_id", @contracts.json_string(grant.code_id)),
  ])
}

///|
fn challenge_json(challenge : Challenge) -> @json.Json {
  @contracts.json_object([
    ("challenge_id", @contracts.json_string(challenge.challenge_id)),
    ("challenge", @contracts.json_string(challenge.challenge)),
    ("expires_at_ms", @contracts.json_int64(challenge.expires_at_ms)),
  ])
}

///|
fn session_grant_json(grant : SessionGrant) -> @json.Json {
  @contracts.json_object([
    ("session_id", @contracts.json_string(grant.session_id)),
    ("runtime_id", @contracts.json_string(grant.runtime_id)),
    ("resume_from", @contracts.json_int64(grant.resume_from)),
    ("mode", @contracts.json_string(grant.mode.name())),
  ])
}

///|
fn heartbeat_ack_json(ack : HeartbeatAck) -> @json.Json {
  @contracts.json_object([
    ("session_id", @contracts.json_string(ack.session_id)),
    ("ack_seq", @contracts.json_int64(ack.ack_seq)),
    ("server_time_ms", @contracts.json_int64(ack.server_time_ms)),
    ("duplicate", @contracts.json_bool(ack.duplicate)),
  ])
}

///|
fn pair_error_response(id : String, error : PairError) -> @contracts.RpcResponse {
  match error {
    Rejected => error_response(id, @contracts.ERR_HOST, "pairing rejected")
    RateLimited =>
      error_response(id, @contracts.ERR_HOST, "pairing rejected")
    UnsupportedVersion(version) =>
      error_response(
        id,
        @contracts.ERR_INVALID_PARAMS,
        "unsupported protocol version: " + version.to_string(),
      )
    Malformed(message) =>
      error_response(id, @contracts.ERR_INVALID_PARAMS, message)
  }
}

///|
fn auth_error_response(id : String, error : AuthError) -> @contracts.RpcResponse {
  match error {
    Unauthorized => error_response(id, @contracts.ERR_HOST, "unauthorized")
    UnsupportedVersion(version) =>
      error_response(
        id,
        @contracts.ERR_INVALID_PARAMS,
        "unsupported protocol version: " + version.to_string(),
      )
    Malformed(message) =>
      error_response(id, @contracts.ERR_INVALID_PARAMS, message)
  }
}

///|
/// Handle one request. `entropy` is supplied by the caller from a CSPRNG
/// (`@tls.rand_bytes` in the transport harness) so this layer stays free of
/// platform I/O and tests can drive it deterministically.
pub fn PrimaryState::dispatch(
  self : PrimaryState,
  request : @contracts.RpcRequest,
  now_ms : Int64,
  entropy : Bytes,
) -> @contracts.RpcResponse {
  self.prune(now_ms)
  match request.method {
    METHOD_RUNTIME_PAIR => {
      let hello = match parse_hello(request.params) {
        Ok(value) => value
        Err(message) =>
          return error_response(
            request.id,
            @contracts.ERR_INVALID_PARAMS,
            message,
          )
      }
      let code = match require_hex_param(request.params, "code", 32, 64) {
        Ok(value) => value
        Err(message) =>
          return error_response(
            request.id,
            @contracts.ERR_INVALID_PARAMS,
            message,
          )
      }
      match self.pair(code, hello, now_ms, entropy) {
        Ok(grant) => ok_response(request.id, pair_grant_json(grant))
        Err(error) => pair_error_response(request.id, error)
      }
    }
    METHOD_RUNTIME_CHALLENGE => {
      let runtime_id = match require_string_param(
        request.params,
        "runtime_id",
        MAX_RUNTIME_ID_LEN,
      ) {
        Ok(value) => value
        Err(message) =>
          return error_response(
            request.id,
            @contracts.ERR_INVALID_PARAMS,
            message,
          )
      }
      let credential_id = match require_hex_param(
        request.params,
        "credential_id",
        16,
        16,
      ) {
        Ok(value) => value
        Err(message) =>
          return error_response(
            request.id,
            @contracts.ERR_INVALID_PARAMS,
            message,
          )
      }
      match self.begin_auth(runtime_id, credential_id, now_ms, entropy) {
        Ok(challenge) => ok_response(request.id, challenge_json(challenge))
        Err(error) => auth_error_response(request.id, error)
      }
    }
    METHOD_RUNTIME_AUTHENTICATE => {
      let challenge_id = match require_hex_param(
        request.params,
        "challenge_id",
        16,
        16,
      ) {
        Ok(value) => value
        Err(message) =>
          return error_response(
            request.id,
            @contracts.ERR_INVALID_PARAMS,
            message,
          )
      }
      let mac = match require_hex_param(request.params, "mac", 64, 64) {
        Ok(value) => value
        Err(message) =>
          return error_response(
            request.id,
            @contracts.ERR_INVALID_PARAMS,
            message,
          )
      }
      let nonce = match require_hex_param(request.params, "nonce", 32, 64) {
        Ok(value) => value
        Err(message) =>
          return error_response(
            request.id,
            @contracts.ERR_INVALID_PARAMS,
            message,
          )
      }
      match self.complete_auth(challenge_id, mac, nonce, now_ms, entropy) {
        Ok(grant) => ok_response(request.id, session_grant_json(grant))
        Err(error) => auth_error_response(request.id, error)
      }
    }
    METHOD_RUNTIME_AUTHENTICATE_BEARER => {
      let runtime_id = match require_string_param(
        request.params,
        "runtime_id",
        MAX_RUNTIME_ID_LEN,
      ) {
        Ok(value) => value
        Err(message) =>
          return error_response(
            request.id,
            @contracts.ERR_INVALID_PARAMS,
            message,
          )
      }
      let credential_id = match require_hex_param(
        request.params,
        "credential_id",
        16,
        16,
      ) {
        Ok(value) => value
        Err(message) =>
          return error_response(
            request.id,
            @contracts.ERR_INVALID_PARAMS,
            message,
          )
      }
      let credential = match require_hex_param(
        request.params,
        "credential",
        64,
        64,
      ) {
        Ok(value) => value
        Err(message) =>
          return error_response(
            request.id,
            @contracts.ERR_INVALID_PARAMS,
            message,
          )
      }
      let nonce = match require_hex_param(request.params, "nonce", 32, 64) {
        Ok(value) => value
        Err(message) =>
          return error_response(
            request.id,
            @contracts.ERR_INVALID_PARAMS,
            message,
          )
      }
      match
        self.authenticate_bearer(
          runtime_id,
          credential_id,
          credential,
          nonce,
          now_ms,
          entropy,
        ) {
        Ok(grant) => ok_response(request.id, session_grant_json(grant))
        Err(error) => auth_error_response(request.id, error)
      }
    }
    METHOD_RUNTIME_ROTATE => {
      let session_id = match require_hex_param(
        request.params,
        "session_id",
        16,
        16,
      ) {
        Ok(value) => value
        Err(message) =>
          return error_response(
            request.id,
            @contracts.ERR_INVALID_PARAMS,
            message,
          )
      }
      match self.rotate_credential(session_id, now_ms, entropy) {
        Ok(grant) => ok_response(request.id, pair_grant_json(grant))
        Err(error) => auth_error_response(request.id, error)
      }
    }
    METHOD_RUNTIME_HEARTBEAT => {
      let session_id = match require_hex_param(
        request.params,
        "session_id",
        16,
        16,
      ) {
        Ok(value) => value
        Err(message) =>
          return error_response(
            request.id,
            @contracts.ERR_INVALID_PARAMS,
            message,
          )
      }
      let seq = match @contracts.int64_field(request.params, "seq") {
        Some(value) if value > 0L => value
        _ =>
          return error_response(
            request.id,
            @contracts.ERR_INVALID_PARAMS,
            "missing or invalid seq",
          )
      }
      match self.heartbeat(session_id, seq, now_ms) {
        Ok(ack) => ok_response(request.id, heartbeat_ack_json(ack))
        Err(reason) =>
          error_response(
            request.id,
            @contracts.ERR_HOST,
            if reason == "forbidden" { "forbidden" } else { "unauthorized" },
          )
      }
    }
    METHOD_RUNTIME_PROBE => {
      let session_id = match require_hex_param(
        request.params,
        "session_id",
        16,
        16,
      ) {
        Ok(value) => value
        Err(message) =>
          return error_response(
            request.id,
            @contracts.ERR_INVALID_PARAMS,
            message,
          )
      }
      let session = match self.sessions.get(session_id) {
        Some(value) => value
        None =>
          return error_response(
            request.id,
            @contracts.ERR_HOST,
            "unauthorized",
          )
      }
      if !self.session_is_live(session, now_ms) {
        return error_response(request.id, @contracts.ERR_HOST, "unauthorized")
      }
      if !self.has_scope(session.runtime_id, "runtime.probe") {
        return error_response(request.id, @contracts.ERR_HOST, "forbidden")
      }
      ok_response(
        request.id,
        @contracts.json_object([
          ("ok", @contracts.json_bool(true)),
          ("runtime_id", @contracts.json_string(session.runtime_id)),
          ("session_id", @contracts.json_string(session.session_id)),
        ]),
      )
    }
    _ =>
      {
        let error = @contracts.method_not_found_error(request.method)
        { id: request.id, result: None, error: Some(error) }
      }
  }
}
