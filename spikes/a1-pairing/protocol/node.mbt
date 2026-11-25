///|
/// Node-side request builders and response parsers.
///
/// These functions only shape JSON-RPC params; transport and retry policy live
/// in `transport`/`e2e`. Keeping them separate means the node side can be unit
/// tested without sockets.

///|
pub const CAPABILITY_HMAC : String = "auth.hmac-sha256"

///|
pub const CAPABILITY_HEARTBEAT : String = "runtime.heartbeat.v1"

///|
pub const CAPABILITY_PROBE : String = "runtime.probe.v1"

///|
/// Capabilities advertised by the spike node. A node without
/// `CAPABILITY_HMAC` enrolls in bearer mode.
pub fn default_capabilities() -> Array[String] {
  [CAPABILITY_HMAC, CAPABILITY_HEARTBEAT, CAPABILITY_PROBE]
}

///|
/// The hello's `machine_public_key` field. With no asymmetric key pair
/// available, the node submits a SHA-256 commitment to its device secret: it
/// proves the node can hold a key, but the primary cannot verify a signature
/// against it. See README "Findings".
pub fn machine_public_key(device_secret : String) -> Result[String, String] {
  let secret = match bytes_of_hex(device_secret) {
    Some(value) => value
    None => return Err("invalid device secret")
  }
  Ok(sha256_hex(secret.exact_view()))
}

///|
pub fn hello_params(
  request_id : String,
  code : String,
  runtime_id : String,
  protocol_version : Int,
  capabilities : Array[String],
  machine_public_key : String,
  nonce : String,
) -> Map[String, @json.Json] {
  let params : Map[String, @json.Json] = Map([])
  params.set("client_request_id", @contracts.json_string(request_id))
  params.set("code", @contracts.json_string(code))
  params.set("runtime_id", @contracts.json_string(runtime_id))
  params.set("protocol_version", @contracts.json_int(protocol_version))
  params.set(
    "capabilities",
    @json.Json::array(
      capabilities.map(capability => @contracts.json_string(capability)),
    ),
  )
  params.set("machine_public_key", @contracts.json_string(machine_public_key))
  params.set("nonce", @contracts.json_string(nonce))
  params
}

///|
pub fn challenge_params(
  request_id : String,
  runtime_id : String,
  credential_id : String,
) -> Map[String, @json.Json] {
  let params : Map[String, @json.Json] = Map([])
  params.set("client_request_id", @contracts.json_string(request_id))
  params.set("runtime_id", @contracts.json_string(runtime_id))
  params.set("credential_id", @contracts.json_string(credential_id))
  params
}

///|
pub fn authenticate_params(
  request_id : String,
  challenge_id : String,
  mac : String,
  nonce : String,
) -> Map[String, @json.Json] {
  let params : Map[String, @json.Json] = Map([])
  params.set("client_request_id", @contracts.json_string(request_id))
  params.set("challenge_id", @contracts.json_string(challenge_id))
  params.set("mac", @contracts.json_string(mac))
  params.set("nonce", @contracts.json_string(nonce))
  params
}

///|
pub fn bearer_auth_params(
  request_id : String,
  runtime_id : String,
  credential_id : String,
  credential : String,
  nonce : String,
) -> Map[String, @json.Json] {
  let params : Map[String, @json.Json] = Map([])
  params.set("client_request_id", @contracts.json_string(request_id))
  params.set("runtime_id", @contracts.json_string(runtime_id))
  params.set("credential_id", @contracts.json_string(credential_id))
  params.set("credential", @contracts.json_string(credential))
  params.set("nonce", @contracts.json_string(nonce))
  params
}

///|
pub fn heartbeat_params(
  request_id : String,
  session_id : String,
  seq : Int64,
) -> Map[String, @json.Json] {
  let params : Map[String, @json.Json] = Map([])
  params.set("client_request_id", @contracts.json_string(request_id))
  params.set("session_id", @contracts.json_string(session_id))
  params.set("seq", @contracts.json_int64(seq))
  params
}

///|
pub fn probe_params(
  request_id : String,
  session_id : String,
) -> Map[String, @json.Json] {
  let params : Map[String, @json.Json] = Map([])
  params.set("client_request_id", @contracts.json_string(request_id))
  params.set("session_id", @contracts.json_string(session_id))
  params
}

///|
pub fn rotate_params(
  request_id : String,
  session_id : String,
) -> Map[String, @json.Json] {
  let params : Map[String, @json.Json] = Map([])
  params.set("client_request_id", @contracts.json_string(request_id))
  params.set("session_id", @contracts.json_string(session_id))
  params
}

///|
fn parse_auth_mode(json : @json.Json) -> AuthMode? {
  match json.as_string() {
    Some("bearer") => Some(Bearer)
    Some("hmac-sha256") => Some(ChallengeResponse)
    _ => None
  }
}

///|
fn parse_scopes(json : @json.Json) -> Array[String]? {
  let items = match json.as_array() {
    Some(value) => value
    None => return None
  }
  let scopes : Array[String] = []
  for item in items {
    match item.as_string() {
      Some(value) => scopes.push(value)
      None => return None
    }
  }
  Some(scopes)
}

///|
pub fn parse_pair_grant(json : @json.Json) -> PairGrant? {
  let object = match json.as_object() {
    Some(value) => value
    None => return None
  }
  let runtime_id = match @contracts.string_field(object, "runtime_id") {
    Some(value) => value
    None => return None
  }
  let credential_id = match @contracts.string_field(object, "credential_id") {
    Some(value) => value
    None => return None
  }
  let credential = match @contracts.string_field(object, "credential") {
    Some(value) => value
    None => return None
  }
  let expires_at_ms = match @contracts.int64_field(object, "expires_at_ms") {
    Some(value) => value
    None => return None
  }
  let generation = match @contracts.int_field(object, "generation") {
    Some(value) => value
    None => return None
  }
  let auth_mode = match object.get("mode") {
    Some(value) => match parse_auth_mode(value) {
      Some(mode) => mode
      None => return None
    }
    None => return None
  }
  let scopes = match object.get("scopes") {
    Some(value) => match parse_scopes(value) {
      Some(scopes) => scopes
      None => return None
    }
    None => return None
  }
  let code_id = match @contracts.string_field(object, "code_id") {
    Some(value) => value
    None => ""
  }
  Some({
    runtime_id,
    credential_id,
    credential,
    expires_at_ms,
    generation,
    auth_mode,
    scopes,
    code_id,
  })
}

///|
pub fn parse_challenge(json : @json.Json) -> Challenge? {
  let object = match json.as_object() {
    Some(value) => value
    None => return None
  }
  let challenge_id = match @contracts.string_field(object, "challenge_id") {
    Some(value) => value
    None => return None
  }
  let challenge = match @contracts.string_field(object, "challenge") {
    Some(value) => value
    None => return None
  }
  let expires_at_ms = match @contracts.int64_field(object, "expires_at_ms") {
    Some(value) => value
    None => return None
  }
  Some({ challenge_id, challenge, expires_at_ms })
}

///|
pub fn parse_session_grant(json : @json.Json) -> SessionGrant? {
  let object = match json.as_object() {
    Some(value) => value
    None => return None
  }
  let session_id = match @contracts.string_field(object, "session_id") {
    Some(value) => value
    None => return None
  }
  let runtime_id = match @contracts.string_field(object, "runtime_id") {
    Some(value) => value
    None => return None
  }
  let resume_from = match @contracts.int64_field(object, "resume_from") {
    Some(value) => value
    None => return None
  }
  let auth_mode = match object.get("mode") {
    Some(value) => match parse_auth_mode(value) {
      Some(mode) => mode
      None => return None
    }
    None => return None
  }
  Some({ session_id, runtime_id, resume_from, mode: auth_mode })
}

///|
pub fn parse_heartbeat_ack(json : @json.Json) -> HeartbeatAck? {
  let object = match json.as_object() {
    Some(value) => value
    None => return None
  }
  let session_id = match @contracts.string_field(object, "session_id") {
    Some(value) => value
    None => return None
  }
  let ack_seq = match @contracts.int64_field(object, "ack_seq") {
    Some(value) => value
    None => return None
  }
  let server_time_ms = match @contracts.int64_field(object, "server_time_ms") {
    Some(value) => value
    None => return None
  }
  let duplicate = match object.get("duplicate") {
    Some(value) => match value.as_bool() {
      Some(flag) => flag
      None => return None
    }
    None => false
  }
  Some({ session_id, ack_seq, server_time_ms, duplicate })
}
