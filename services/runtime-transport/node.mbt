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
/// What the node serves for the primary (A1.2b).
///
/// The transport owns pairing, hello, heartbeat and event publication. The
/// application layer owns the actual runtime methods: it registers exec/fs/
/// PTY/git handlers and supplies the profile answered by the reserved
/// `runtime.probe` method. `outbox` is the durable event source.
pub struct NodeService {
  handlers : HandlerRegistry
  probe : async () -> @json.Json
  outbox : OutboxPort
  /// A1.3b: install a policy announcement from the primary. The application
  /// layer verifies the pinned hash, persists the snapshot and replaces its
  /// gate. `Err` is reported back to the primary; the previous policy stays in
  /// place, so an unverifiable update can never widen what the node allows.
  install_policy : async (PolicyAnnouncement) -> Result[Unit, String]
}

///|
pub fn NodeService::new(
  handlers~ : HandlerRegistry,
  probe~ : async () -> @json.Json,
  outbox~ : OutboxPort,
  install_policy~ : async (PolicyAnnouncement) -> Result[Unit, String],
) -> NodeService {
  { handlers, probe, outbox, install_policy }
}

///|
/// A service with no application methods; `runtime.probe` reports only the
/// protocol version and an empty capability list.
pub fn NodeService::empty(outbox : OutboxPort) -> NodeService {
  {
    handlers: HandlerRegistry::new(),
    probe: () =>
      @contracts.json_object([
        ("protocol_version", @contracts.json_int(PROTOCOL_VERSION)),
        ("capabilities", @contracts.json_string_array([])),
      ]),
    outbox,
    install_policy: async fn(_announcement) { Ok(()) },
  }
}

///|
/// Serialized frame writer shared by the serve loop and handler tasks.
struct NodeWriter {
  stream : TlsStream
  mutex : @async.Mutex
  /// Handler tasks outlive a session (`group` continues across reconnects),
  /// so one can finish after the serve loop lost the connection and try to
  /// answer. Writing then would touch a freed TLS object; sealed sends are
  /// dropped instead.
  sealed : Ref[Bool]
  closed : Ref[Bool]
}

///|
fn node_writer(stream : TlsStream) -> NodeWriter {
  { stream, mutex: @async.Mutex::Mutex(), sealed: Ref(false), closed: Ref(false) }
}

///|
/// Stop accepting frames without touching the stream. This runs when the
/// serve loop exits, before any later teardown, so a handler that has not
/// started writing yet can never begin.
fn NodeWriter::seal(self : NodeWriter) -> Unit {
  self.sealed.val = true
}

///|
/// Close the stream after in-flight writes finish. A waiting or later send
/// observes `sealed` under the mutex and drops its frame.
async fn NodeWriter::close(self : NodeWriter) -> Unit {
  self.mutex.acquire()
  defer self.mutex.release()
  self.sealed.val = true
  if self.closed.val {
    return
  }
  self.closed.val = true
  self.stream.close()
}

///|
async fn NodeWriter::send(
  self : NodeWriter,
  value : @json.Json,
) -> Result[Unit, String] {
  if self.sealed.val {
    return Err("runtime session is closed")
  }
  self.mutex.acquire()
  defer self.mutex.release()
  if self.sealed.val {
    return Err("runtime session is closed")
  }
  self.stream.write(value) catch {
    error => return Err(safe_error(error))
  }
  Ok(())
}

///|
async fn NodeWriter::respond(
  self : NodeWriter,
  id : String,
  result : @json.Json,
) -> Unit {
  let response : @contracts.RpcResponse = { id, result: Some(result), error: None }
  let _ = self.send(response.to_json())
}

///|
async fn NodeWriter::respond_error(
  self : NodeWriter,
  id : String,
  error : @contracts.RpcError,
) -> Unit {
  let response : @contracts.RpcResponse = { id, result: None, error: Some(error) }
  let _ = self.send(response.to_json())
}

///|
async fn node_send_policy_ack(
  writer : NodeWriter,
  version : String,
  hash : String,
  outcome : String,
  reason : String,
) -> Unit {
  let params : Map[String, @json.Json] = Map([])
  params.set("version", @contracts.json_string(clamp_text(version, 128)))
  params.set("hash", @contracts.json_string(clamp_text(hash, 64)))
  params.set("outcome", @contracts.json_string(outcome))
  params.set("reason", @contracts.json_string(safe_detail(reason)))
  let notification = @contracts.RpcNotification::new(METHOD_POLICY_ACK, params)
  let _ = writer.send(notification.to_json())
}

///|
async fn node_install_policy(
  writer : NodeWriter,
  service : NodeService,
  version : String,
  hash : String,
  announcement : Result[PolicyAnnouncement, String],
) -> Unit {
  match announcement {
    Ok(value) =>
      match (service.install_policy)(value) {
        Ok(_) =>
          node_send_policy_ack(
            writer,
            version,
            hash,
            POLICY_ACK_INSTALLED,
            "",
          )
        Err(message) =>
          node_send_policy_ack(
            writer,
            version,
            hash,
            POLICY_ACK_REJECTED,
            message,
          )
      }
    Err(message) =>
      node_send_policy_ack(
        writer,
        version,
        hash,
        POLICY_ACK_REJECTED,
        message,
      )
  }
}

///|
/// One authenticated session on a live pinned TLS connection.
pub struct NodeSession {
  stream : TlsStream
  writer : NodeWriter
  runtime_id : String
  session_id : String
  resume_cursor : Int64
  heartbeat_interval_ms : Int64
  gap : Bool
  /// Policy snapshot carried by the hello result. It is installed before the
  /// serve loop accepts application requests, so a reconnect never serves
  /// under an older policy than the primary announced.
  policy : PolicyAnnouncement?
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
  // A malformed announcement fails the connect rather than being ignored: an
  // unverifiable policy must never be silently skipped.
  let policy = match object.get("policy") {
    Some(value) =>
      match PolicyAnnouncement::from_json(value) {
        Ok(announcement) => Some(announcement)
        Err(message) => {
          stream.close()
          return Err(NodeProtocol("invalid policy announcement: " + message))
        }
      }
    None => None
  }
  let session : NodeSession = {
    stream,
    writer: node_writer(stream),
    runtime_id,
    session_id,
    resume_cursor,
    heartbeat_interval_ms,
    gap,
    policy,
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
/// Serve one runtime request from the primary. Registered handlers run in
/// child tasks so the read loop can keep processing heartbeats, acks and
/// other requests. Dispatch is serialized so duplicate requests observed on
/// one session cannot interleave.
async fn[X] NodeSession::serve_request(
  self : NodeSession,
  writer : NodeWriter,
  service : NodeService,
  group : @async.TaskGroup[X],
  dispatch_mutex : @async.Mutex,
  request : @contracts.RpcRequest,
) -> Unit {
  let id = request.id
  if request.method == METHOD_PROBE {
    writer.respond(id, (service.probe)())
    return
  }
  if reserved_method(request.method) {
    writer.respond_error(id, method_not_found_error(request.method))
    return
  }
  let handler = match service.handlers.lookup(request.method) {
    Some(value) => value
    None => {
      writer.respond_error(id, method_not_found_error(request.method))
      return
    }
  }
  let client_request_id = match
    @contracts.string_field(request.params, "client_request_id") {
    Some(value) =>
      if value == "" || value.length() > MAX_CLIENT_REQUEST_ID_LEN {
        ""
      } else {
        value
      }
    None => ""
  }
  group.spawn_bg(() => {
    dispatch_mutex.acquire()
    defer dispatch_mutex.release()
    let handler_request : HandlerRequest = {
      runtime_id: self.runtime_id,
      session_id: self.session_id,
      rpc_method: request.method,
      params: request.params,
      client_request_id,
    }
    match (handler)(handler_request) {
      Ok(value) => writer.respond(id, value)
      Err(error) => writer.respond_error(id, error)
    }
  }, allow_failure=true)
}

///|
async fn[X] NodeSession::serve(
  self : NodeSession,
  config : NodeConfig,
  service : NodeService,
  group : @async.TaskGroup[X],
) -> SessionEnd {
  let writer = self.writer
  // The first thing every exit does is reject late handler responses. The
  // stream itself is freed by node_serve under the writer mutex.
  defer writer.seal()
  let dispatch_mutex = @async.Mutex::Mutex()
  // Install the policy carried by hello before serving any application
  // request, and acknowledge it so the primary can audit delivery.
  match self.policy {
    Some(announcement) =>
      node_install_policy(
        writer,
        service,
        announcement.version,
        announcement.hash,
        Ok(announcement),
      )
    None => ()
  }
  let mut in_flight : OutboxEvent? = None
  let mut heartbeat_serial = 0
  let mut next_heartbeat = @async.now() + self.heartbeat_interval_ms
  while true {
    match in_flight {
      None => {
        let cursor = (service.outbox.cursor)()
        let pending = match (service.outbox.pending)(cursor, 1) {
          Ok(value) => value
          Err(message) => return SessionEnd::SessionLost(message)
        }
        if !pending.is_empty() {
          let event = pending[0]
          let params = event.to_wire().to_params(self.runtime_id)
          let notification = @contracts.RpcNotification::new(METHOD_EVENT, params)
          match writer.send(notification.to_json()) {
            Ok(_) => in_flight = Some(event)
            Err(message) => return SessionEnd::SessionLost(message)
          }
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
      match writer.send(request.to_json()) {
        Ok(_) => ()
        Err(message) => return SessionEnd::SessionLost(message)
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
        // Requests are parsed first: a request frame also carries an id, so
        // `parse_response` would accept it with an empty result.
        match @contracts.parse_request(frame) {
          Ok(request) => {
            self.serve_request(
              writer,
              service,
              group,
              dispatch_mutex,
              request,
            )
          }
          Err(_) =>
            match @contracts.parse_notification(frame) {
              Ok(notification) => {
                if notification.method == METHOD_ACK {
                  let cursor = @contracts.int64_field_or(
                    notification.params,
                    "cursor",
                    0L,
                  )
                  match (service.outbox.ack_through)(cursor) {
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
                } else if notification.method == METHOD_POLICY_UPDATE {
                  let version = @contracts.string_field_or(
                    notification.params,
                    "version",
                    "",
                  )
                  let hash = @contracts.string_field_or(
                    notification.params,
                    "hash",
                    "",
                  )
                  let announcement = PolicyAnnouncement::from_json(
                    @json.Json::object(notification.params),
                  )
                  node_install_policy(
                    writer,
                    service,
                    version,
                    hash,
                    announcement,
                  )
                } else {
                  ()
                }
              }
              Err(_) =>
                match @contracts.parse_response(frame) {
                  Ok(response) => {
                    if response.id.has_prefix("hb-") {
                      match response.error {
                        Some(error) => {
                          let mapped = node_error_from_rpc(error)
                          match mapped {
                            NodeRevoked => return SessionEnd::SessionRevoked
                            NodeUnauthorized =>
                              return SessionEnd::SessionUnauthorized
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
                        None =>
                          match response.result {
                            Some(result) => {
                              let cursor = match @contracts.as_object(result) {
                                Some(object) =>
                                  @contracts.int64_field_or(
                                    object,
                                    "ack_cursor",
                                    0L,
                                  )
                                None => 0L
                              }
                              match (service.outbox.ack_through)(cursor) {
                                Ok(_) => ()
                                Err(message) =>
                                  return SessionEnd::SessionLost(message)
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
                    } else {
                      // A late/duplicate response to an earlier request: drop
                      // it. The matching request already timed out.
                      ()
                    }
                  }
                  Err(message) => {
                    return SessionEnd::SessionLost(
                      "invalid frame: " + safe_detail(message),
                    )
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
/// Run the node: pairing already done, token in hand. Reconnects with backoff
/// and serves runtime requests plus event publication until drain, revocation
/// or the attempt budget. `group` must outlive the reconnect loop: it owns
/// processes started by `runtime.exec.start`, which continue across a
/// disconnect and are reported through the durable outbox on reconnect.
pub async fn[X] node_serve(
  config : NodeConfig,
  token : String,
  service : NodeService,
  group : @async.TaskGroup[X],
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
    let last_ack = (service.outbox.cursor)()
    let connected = connect_session(config, token, last_ack)
    match connected {
      Ok(session) => {
        let end = session.serve(config, service, group)
        // Handler tasks may still be responding; close serializes with them
        // and makes every later response a dropped no-op.
        session.writer.close()
        match end {
          SessionDrained => return NodeRunOutcome::Drained
          SessionRevoked => return NodeRunOutcome::Revoked
          SessionUnauthorized => return NodeRunOutcome::Unauthorized
          SessionLost(_) => ()
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

///|
/// Publish-only node used by pairing-only deployments and transport tests.
pub async fn node_run(
  config : NodeConfig,
  token : String,
  outbox : OutboxPort,
) -> NodeRunOutcome {
  @async.with_task_group(async fn(group : @async.TaskGroup[NodeRunOutcome]) -> NodeRunOutcome {
    node_serve(config, token, NodeService::empty(outbox), group)
  })
}
