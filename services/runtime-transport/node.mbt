///|
/// Node client: pairing, hello, heartbeat, outbox publication and reconnect.
///
/// A node opens outbound pinned TLS connections only. Pairing exchanges a
/// one-time code for a 32-byte credential (saved 0600 when `token_file` is
/// configured). Reconnects back off 1s → 2s → 4s … capped at 60s with jitter;
/// a `revoked` response stops retries, because retrying cannot repair a revoked
/// credential.
///
/// Event publication is one event at a time: the node sends `runtime.event`
/// (a notification), the primary answers `runtime.ack {cursor}`, and the node
/// calls `OutboxPort::ack_through`. A reconnect resumes from the durable
/// outbox cursor, so acknowledged events are never recreated.

///|
pub(all) struct NodeConfig {
  runtime_id : String
  tls : TlsClientConfig
  capabilities : Array[String]
  heartbeat_interval_ms : Int64
  poll_timeout_ms : Int64
  backoff_base_ms : Int64
  backoff_cap_ms : Int64
  jitter_ms : Int64
  /// Total connection attempts allowed; 0 means unlimited.
  max_attempts : Int
  token_file : String?
}

///|
pub fn NodeConfig::new(
  runtime_id~ : String,
  tls~ : TlsClientConfig,
  capabilities~ : Array[String] = [],
  heartbeat_interval_ms~ : Int64 = HEARTBEAT_INTERVAL_MS,
  poll_timeout_ms~ : Int64 = 250L,
  backoff_base_ms~ : Int64 = BACKOFF_BASE_MS,
  backoff_cap_ms~ : Int64 = BACKOFF_CAP_MS,
  jitter_ms~ : Int64 = 500L,
  max_attempts~ : Int = 0,
  token_file~ : String? = None,
) -> NodeConfig {
  {
    runtime_id,
    tls,
    capabilities,
    heartbeat_interval_ms,
    poll_timeout_ms,
    backoff_base_ms,
    backoff_cap_ms,
    jitter_ms,
    max_attempts,
    token_file,
  }
}

///|
pub suberror NodeConnectError {
  NodeRevoked
  NodeUnauthorized
  NodeUnsupportedVersion
  NodeTransport(String)
  NodeProtocol(String)
}

///|
pub(all) enum NodeRunOutcome {
  Drained
  Revoked
  Unauthorized
  AttemptsExhausted(Int)
  Stopped(String)
}

///|
fn node_error_from_rpc(error : @contracts.RpcError) -> NodeConnectError {
  let code = error.code
  if code == ERR_REVOKED {
    NodeRevoked
  } else if code == ERR_UNAUTHORIZED {
    NodeUnauthorized
  } else if code == ERR_UNSUPPORTED_VERSION {
    NodeUnsupportedVersion
  } else {
    NodeTransport(
      "server error " +
      code.to_string() +
      ": " +
      safe_detail(error.message),
    )
  }
}

///|
fn rpc_response_result(
  response : @contracts.RpcResponse,
) -> Result[@json.Json, NodeConnectError] {
  match response.error {
    Some(error) => Err(node_error_from_rpc(error))
    None =>
      match response.result {
        Some(value) => Ok(value)
        None => Err(NodeProtocol("response has no result"))
      }
  }
}

///|
fn parse_object_field_string(
  object : Map[String, @json.Json],
  key : String,
) -> Result[String, NodeConnectError] {
  match @contracts.string_field(object, key) {
    Some(value) => Ok(value)
    None => Err(NodeProtocol("response is missing " + key))
  }
}

///|
fn parse_object_field_int(
  object : Map[String, @json.Json],
  key : String,
) -> Result[Int, NodeConnectError] {
  match @contracts.int_field(object, key) {
    Some(value) => Ok(value)
    None => Err(NodeProtocol("response is missing " + key))
  }
}

///|
fn parse_object_field_int64(
  object : Map[String, @json.Json],
  key : String,
) -> Result[Int64, NodeConnectError] {
  match @contracts.int64_field(object, key) {
    Some(value) => Ok(value)
    None => Err(NodeProtocol("response is missing " + key))
  }
}

///|
fn parse_pair_grant_from_json(
  json : @json.Json,
) -> Result[PairGrant, NodeConnectError] {
  let object = match @contracts.as_object(json) {
    Some(value) => value
    None => return Err(NodeProtocol("pair result is not an object"))
  }
  let runtime_id = match parse_object_field_string(object, "runtime_id") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let credential = match parse_object_field_string(object, "credential") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if !is_hex_of_length(credential, CREDENTIAL_HEX_LEN) {
    return Err(NodeProtocol("pair result has a malformed credential"))
  }
  let credential_id = match parse_object_field_string(object, "credential_id") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let generation = match parse_object_field_int(object, "generation") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let protocol_version = match parse_object_field_int(object, "protocol_version") {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let expires_at_ms = match object.get("expires_at_ms") {
    Some(value) => @contracts.as_int64(value)
    None => None
  }
  Ok({
    runtime_id,
    credential_id,
    credential,
    generation,
    expires_at_ms,
    protocol_version,
  })
}

///|
async fn node_send_request(
  stream : TlsStream,
  id : String,
  rpc_method : String,
  params : Map[String, @json.Json],
) -> Result[@contracts.RpcResponse, NodeConnectError] {
  let request = @contracts.RpcRequest::new(id, rpc_method, params)
  stream.write(request.to_json()) catch {
    error => return Err(NodeTransport(safe_error(error)))
  }
  let frame = stream.read() catch {
    error => return Err(NodeTransport(safe_error(error)))
  }
  let response = match @contracts.parse_response(frame) {
    Ok(value) => value
    Err(message) => {
      return Err(NodeProtocol("invalid response: " + safe_detail(message)))
    }
  }
  Ok(response)
}

///|
/// Pair with a primary over pinned TLS. The pairing code is used once; the
/// returned credential is persisted atomically 0600 when `token_file` is set.
pub async fn pair_with_primary(
  config : NodeConfig,
  pairing_code : String,
) -> Result[PairGrant, NodeConnectError] {
  if !is_safe_id(config.runtime_id) {
    return Err(NodeProtocol("invalid runtime_id"))
  }
  let stream = match config.tls.connect_pinned() {
    Ok(value) => value
    Err(message) => return Err(NodeTransport(message))
  }
  defer stream.close()
  let params : Map[String, @json.Json] = Map([])
  params.set("pairing_code", @contracts.json_string(pairing_code))
  params.set("runtime_id", @contracts.json_string(config.runtime_id))
  params.set("protocol_version", @contracts.json_int(PROTOCOL_VERSION))
  params.set(
    "capabilities",
    @contracts.json_string_array(config.capabilities),
  )
  let response = match
    node_send_request(stream, "pair-1", METHOD_PAIR, params) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let result = match rpc_response_result(response) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let grant = match parse_pair_grant_from_json(result) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match config.token_file {
    Some(path) =>
      match save_token_file(path, grant.credential) {
        Ok(_) => ()
        Err(message) => return Err(NodeTransport(message))
      }
    None => ()
  }
  Ok(grant)
}

///|
/// One authenticated session on a live pinned TLS connection.
pub struct NodeSession {
  stream : TlsStream
  runtime_id : String
  session_id : String
  resume_cursor : Int64
  heartbeat_interval_ms : Int64
  gap : Bool
}

///|
pub fn NodeSession::session_id(self : NodeSession) -> String {
  self.session_id
}

///|
pub fn NodeSession::resume_cursor(self : NodeSession) -> Int64 {
  self.resume_cursor
}

///|
pub fn NodeSession::has_gap(self : NodeSession) -> Bool {
  self.gap
}

///|
/// Connect, send `runtime.hello` with the bearertoken and the node's durable
/// ack cursor, and return the authenticated session.
pub async fn connect_session(
  config : NodeConfig,
  token : String,
  last_ack_cursor : Int64,
) -> Result[NodeSession, NodeConnectError] {
  let stream = match config.tls.connect_pinned() {
    Ok(value) => value
    Err(message) => return Err(NodeTransport(message))
  }
  let params : Map[String, @json.Json] = Map([])
  params.set("runtime_id", @contracts.json_string(config.runtime_id))
  params.set("token", @contracts.json_string(token))
  params.set("protocol_version", @contracts.json_int(PROTOCOL_VERSION))
  params.set(
    "capabilities",
    @contracts.json_string_array(config.capabilities),
  )
  params.set("last_ack_cursor", @contracts.json_int64(last_ack_cursor))
  let response = match
    node_send_request(stream, "hello-1", METHOD_HELLO, params) {
    Ok(value) => value
    Err(error) => {
      stream.close()
      return Err(error)
    }
  }
  let result = match rpc_response_result(response) {
    Ok(value) => value
    Err(error) => {
      stream.close()
      return Err(error)
    }
  }
  let object = match @contracts.as_object(result) {
    Some(value) => value
    None => {
      stream.close()
      return Err(NodeProtocol("hello result is not an object"))
    }
  }
  let runtime_id = match parse_object_field_string(object, "runtime_id") {
    Ok(value) => value
    Err(error) => {
      stream.close()
      return Err(error)
    }
  }
  let session_id = match parse_object_field_string(object, "session_id") {
    Ok(value) => value
    Err(error) => {
      stream.close()
      return Err(error)
    }
  }
  let resume_cursor = match parse_object_field_int64(object, "resume_cursor") {
    Ok(value) => value
    Err(error) => {
      stream.close()
      return Err(error)
    }
  }
  let heartbeat_interval_ms = match
    parse_object_field_int64(object, "heartbeat_interval_ms") {
    Ok(value) =>
      if value > 0L {
        value
      } else {
        stream.close()
        return Err(NodeProtocol("invalid heartbeat interval"))
      }
    Err(error) => {
      stream.close()
      return Err(error)
    }
  }
  let gap = @contracts.bool_field_or(object, "gap", false)
  let session : NodeSession = {
    stream,
    runtime_id,
    session_id,
    resume_cursor,
    heartbeat_interval_ms,
    gap,
  }
  if gap {
    let params : Map[String, @json.Json] = Map([])
    params.set("primary_cursor", @contracts.json_int64(resume_cursor))
    params.set("node_cursor", @contracts.json_int64(last_ack_cursor))
    let notification = @contracts.RpcNotification::new(METHOD_REPLAY_GAP, params)
    session.stream.write(notification.to_json()) catch {
      error => {
        session.stream.close()
        return Err(NodeTransport(safe_error(error)))
      }
    }
  }
  Ok(session)
}

///|
enum SessionEnd {
  SessionDrained
  SessionRevoked
  SessionUnauthorized
  SessionLost(String)
}

///|
fn heartbeat_wait_ms(
  next_heartbeat_ms : Int64,
  poll_timeout_ms : Int64,
  now_ms : Int64,
) -> Int64 {
  let remaining = next_heartbeat_ms - now_ms
  if remaining <= 1L {
    1L
  } else if remaining > poll_timeout_ms {
    poll_timeout_ms
  } else {
    remaining
  }
}

///|
async fn NodeSession::serve(
  self : NodeSession,
  config : NodeConfig,
  outbox : OutboxPort,
) -> SessionEnd {
  let mut in_flight : OutboxEvent? = None
  let mut heartbeat_serial = 0
  let mut next_heartbeat = @async.now() + self.heartbeat_interval_ms
  while true {
    match in_flight {
      None => {
        let cursor = (outbox.cursor)()
        let pending = match (outbox.pending)(cursor, 1) {
          Ok(value) => value
          Err(message) => return SessionEnd::SessionLost(message)
        }
        if !pending.is_empty() {
          let event = pending[0]
          let params = event.to_wire().to_params(self.runtime_id)
          let notification = @contracts.RpcNotification::new(METHOD_EVENT, params)
          self.stream.write(notification.to_json()) catch {
            error => return SessionEnd::SessionLost(safe_error(error))
          }
          in_flight = Some(event)
        }
      }
      Some(_) => ()
    }
    let now_ms = @async.now()
    if now_ms >= next_heartbeat {
      heartbeat_serial = heartbeat_serial + 1
      let id = "hb-" + heartbeat_serial.to_string()
      let params : Map[String, @json.Json] = Map([])
      let request = @contracts.RpcRequest::new(id, METHOD_HEARTBEAT, params)
      self.stream.write(request.to_json()) catch {
        error => return SessionEnd::SessionLost(safe_error(error))
      }
      next_heartbeat = now_ms + self.heartbeat_interval_ms
    }
    let wait_ms = heartbeat_wait_ms(
      next_heartbeat,
      config.poll_timeout_ms,
      @async.now(),
    )
    let attempt : Result[@json.Json, String]? = @async.with_timeout_opt(
      timeout_ms_of(wait_ms),
      () => {
        let frame = self.stream.read() catch {
          error => return Err(safe_error(error))
        }
        Ok(frame)
      },
    )
    match attempt {
      None => continue
      Some(Err(message)) => return SessionEnd::SessionLost(message)
      Some(Ok(frame)) => {
        match @contracts.parse_notification(frame) {
          Ok(notification) => {
            if notification.method == METHOD_ACK {
              let cursor = @contracts.int64_field_or(
                notification.params,
                "cursor",
                0L,
              )
              match (outbox.ack_through)(cursor) {
                Ok(_) => ()
                Err(message) => return SessionEnd::SessionLost(message)
              }
              match in_flight {
                Some(event) =>
                  if event.seq <= cursor {
                    in_flight = None
                  }
                None => ()
              }
            } else if notification.method == METHOD_DRAIN {
              return SessionEnd::SessionDrained
            } else if notification.method == METHOD_BYE {
              return SessionEnd::SessionDrained
            } else if notification.method == METHOD_REPLAY_GAP {
              ()
            } else {
              ()
            }
          }
          Err(_) => {
            let response = match @contracts.parse_response(frame) {
              Ok(value) => value
              Err(message) => {
                return SessionEnd::SessionLost(
                  "invalid frame: " + safe_detail(message),
                )
              }
            }
            match response.error {
              Some(error) => {
                let mapped = node_error_from_rpc(error)
                match mapped {
                  NodeRevoked => return SessionEnd::SessionRevoked
                  NodeUnauthorized => return SessionEnd::SessionUnauthorized
                  _ => {
                    let detail = match mapped {
                      NodeTransport(message) => message
                      NodeProtocol(message) => message
                      _ => "heartbeat failed"
                    }
                    return SessionEnd::SessionLost(detail)
                  }
                }
              }
              None => {
                match response.result {
                  Some(result) => {
                    let cursor = match @contracts.as_object(result) {
                      Some(object) =>
                        @contracts.int64_field_or(object, "ack_cursor", 0L)
                      None => 0L
                    }
                    match (outbox.ack_through)(cursor) {
                      Ok(_) => ()
                      Err(message) => return SessionEnd::SessionLost(message)
                    }
                    match in_flight {
                      Some(event) =>
                        if event.seq <= cursor {
                          in_flight = None
                        }
                      None => ()
                    }
                  }
                  None => ()
                }
              }
            }
          }
        }
      }
    }
  } nobreak {
    SessionEnd::SessionLost("session loop ended unexpectedly")
  }
}

///|
/// Backoff for one retry, with a caller-provided jitter value so the policy is
/// testable without sleeping. `attempt` is 1-based: 1 → base, 2 → 2×base, …
/// capped at `cap_ms`; `jitter_value` is reduced modulo `jitter_ms + 1`.
pub fn backoff_delay_with(
  base_ms : Int64,
  cap_ms : Int64,
  attempt : Int,
  jitter_ms : Int64,
  jitter_value : Int64,
) -> Int64 {
  let mut delay = if base_ms > 0L { base_ms } else { 1L }
  let mut index = 1
  while index < attempt && delay < cap_ms {
    delay = delay * 2L
    index = index + 1
  }
  if cap_ms > 0L && delay > cap_ms {
    delay = cap_ms
  }
  if jitter_ms > 0L {
    let span = jitter_ms + 1L
    let jitter = if jitter_value < 0L {
      (-jitter_value) % span
    } else {
      jitter_value % span
    }
    delay = delay + jitter
    if cap_ms > 0L && delay > cap_ms {
      delay = cap_ms
    }
  }
  delay
}

///|
fn random_jitter_value() -> Int64 {
  match random_bytes(4) {
    Ok(bytes) =>
      bytes[0].to_int().to_int64() * 16_777_216L +
      bytes[1].to_int().to_int64() * 65_536L +
      bytes[2].to_int().to_int64() * 256L +
      bytes[3].to_int().to_int64()
    Err(_) => 0L
  }
}

///|
pub fn backoff_delay_ms(
  base_ms : Int64,
  cap_ms : Int64,
  attempt : Int,
  jitter_ms : Int64,
) -> Int64 {
  backoff_delay_with(base_ms, cap_ms, attempt, jitter_ms, random_jitter_value())
}

///|
/// Run the node: pair already done, token in hand. Reconnects with backoff and
/// publishes outbox events until drain, revocation or the attempt budget.
pub async fn node_run(
  config : NodeConfig,
  token : String,
  outbox : OutboxPort,
) -> NodeRunOutcome {
  if !is_safe_id(config.runtime_id) {
    return NodeRunOutcome::Stopped("invalid runtime_id")
  }
  if config.heartbeat_interval_ms <= 0L || config.poll_timeout_ms <= 0L {
    return NodeRunOutcome::Stopped("invalid heartbeat or poll interval")
  }
  let mut attempts = 0
  while true {
    attempts = attempts + 1
    let last_ack = (outbox.cursor)()
    let connected = connect_session(config, token, last_ack)
    match connected {
      Ok(session) => {
        match session.serve(config, outbox) {
          SessionDrained => {
            session.stream.close()
            return NodeRunOutcome::Drained
          }
          SessionRevoked => {
            session.stream.close()
            return NodeRunOutcome::Revoked
          }
          SessionUnauthorized => {
            session.stream.close()
            return NodeRunOutcome::Unauthorized
          }
          SessionLost(_) => {
            session.stream.close()
          }
        }
      }
      Err(NodeRevoked) => return NodeRunOutcome::Revoked
      Err(NodeUnauthorized) => return NodeRunOutcome::Unauthorized
      Err(NodeUnsupportedVersion) =>
        return NodeRunOutcome::Stopped("unsupported protocol version")
      Err(NodeTransport(_)) => ()
      Err(NodeProtocol(_)) => ()
    }
    if config.max_attempts > 0 && attempts >= config.max_attempts {
      return NodeRunOutcome::AttemptsExhausted(attempts)
    }
    let delay = backoff_delay_ms(
      config.backoff_base_ms,
      config.backoff_cap_ms,
      attempts,
      config.jitter_ms,
    )
    if delay > 0L {
      @async.sleep(timeout_ms_of(delay))
    }
  } nobreak {
    NodeRunOutcome::Stopped("node loop ended unexpectedly")
  }
}
