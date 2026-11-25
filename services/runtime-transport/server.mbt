///|
/// Primary server: pinned TLS listener plus the JSON-RPC session state machine.
///
/// One connection runs one session. Before `runtime.hello` succeeds, only
/// `runtime.pair` and `runtime.hello` are accepted; anything else gets
/// `unauthorized` and the connection closes. After hello, every frame also
/// revalidates the credential behind the session, so revocation closes a live
/// connection at its next frame. Reads are bounded by the heartbeat budget
/// (three missed intervals) for authenticated connections and by a hello
/// timeout otherwise.
///
/// The server has no plaintext accept path: `ServerListener::accept` always
/// performs a TLS handshake.

///|
pub(all) struct ServerConfig {
  tls : TlsServerConfig
  policy : CredentialPolicy
  heartbeat_interval_ms : Int64
  heartbeat_max_missed : Int
  hello_timeout_ms : Int64
}

///|
pub fn ServerConfig::new(
  tls~ : TlsServerConfig,
  policy~ : CredentialPolicy,
  heartbeat_interval_ms~ : Int64 = HEARTBEAT_INTERVAL_MS,
  heartbeat_max_missed~ : Int = HEARTBEAT_MAX_MISSED,
  hello_timeout_ms~ : Int64 = HELLO_TIMEOUT_MS,
) -> ServerConfig {
  {
    tls,
    policy,
    heartbeat_interval_ms,
    heartbeat_max_missed,
    hello_timeout_ms,
  }
}

///|
pub struct PrimaryServer {
  listener : ServerListener
  state : PrimaryState
  config : ServerConfig
  handlers : HandlerRegistry
  closed : Ref[Bool]
  dispatch_mutex : @async.Mutex
}

///|
/// Open the primary: load durable state, then bind the configured TLS
/// endpoint. Fails closed when doctor reports no usable TLS server on this
/// platform or when certificate/key permissions are wrong.
pub async fn PrimaryServer::open(
  config : ServerConfig,
  store : StateStore,
  handlers : HandlerRegistry,
) -> Result[PrimaryServer, String] {
  if !doctor_supported() {
    return Err(
      "runtime transport unsupported on this platform: no public TLS server API",
    )
  }
  if config.heartbeat_interval_ms <= 0L || config.heartbeat_max_missed <= 0 {
    return Err("heartbeat interval and missed count must be positive")
  }
  let state = match PrimaryState::open(store, config.policy) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let listener = match config.tls.listen() {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  Ok({
    listener,
    state,
    config,
    handlers,
    closed: Ref(false),
    dispatch_mutex: @async.Mutex::Mutex(),
  })
}

///|
pub fn PrimaryServer::port(self : PrimaryServer) -> Int32 {
  self.listener.port()
}

///|
pub fn PrimaryServer::primary_state(self : PrimaryServer) -> PrimaryState {
  self.state
}

///|
pub fn PrimaryServer::handler_registry(self : PrimaryServer) -> HandlerRegistry {
  self.handlers
}

///|
pub fn PrimaryServer::close(self : PrimaryServer) -> Unit {
  self.closed.val = true
  self.listener.close()
}

///|
pub fn PrimaryServer::drain(self : PrimaryServer) -> Unit {
  self.state.request_drain()
}

///|
/// How long the accept loop waits for a TCP connection before re-checking the
/// closed flag. `@socket.TcpServer::close()` does not wake a parked `accept()`
/// in async 0.22.7, so a bounded accept is what makes shutdown and the test
/// harness's task-group teardown deterministic.
const ACCEPT_POLL_MS : Int32 = 100

///|
/// Accept connections until `close()` is called. Each connection is handled in
/// a child task; the group joins them on shutdown.
pub async fn PrimaryServer::run(self : PrimaryServer) -> Unit {
  @async.with_task_group(group => {
    while !self.closed.val {
      let accepted = @async.with_timeout_opt(
        ACCEPT_POLL_MS,
        () => self.listener.accept_tcp(),
      )
      match accepted {
        None => continue
        Some(Err(message)) => {
          // A failed accept (including the closed listener) is not fatal for
          // other nodes, but once closed the loop ends.
          if self.closed.val {
            break
          }
          self.state.log_line("accept failed: " + message)
          @async.sleep(10)
        }
        Some(Ok((tcp, peer))) => {
          if self.closed.val {
            tcp.close()
            break
          }
          group.spawn_bg(() => {
            self.handle_connection(tcp, peer)
          })
        }
      }
    }
  })
}

///|
struct FrameOutcome {
  session_id : String
  authenticated : Bool
  drain_sent : Bool
  close : Bool
}

///|
fn outcome_continue(session_id : String, drain_sent : Bool) -> FrameOutcome {
  { session_id, authenticated: true, drain_sent, close: false }
}

///|
fn outcome_close(session_id : String, drain_sent : Bool) -> FrameOutcome {
  { session_id, authenticated: true, drain_sent, close: true }
}

///|
fn rpc_result_response(id : String, result : @json.Json) -> @contracts.RpcResponse {
  { id, result: Some(result), error: None }
}

///|
fn rpc_error_response(id : String, error : @contracts.RpcError) -> @contracts.RpcResponse {
  { id, result: None, error: Some(error) }
}

///|
fn protocol_error(code : Int, message : String) -> @contracts.RpcError {
  @contracts.RpcError::new(code, message)
}

///|
fn pair_failure_error(failure : PairFailure) -> @contracts.RpcError {
  match failure {
    PairRejected(_) =>
      protocol_error(ERR_PAIRING_REJECTED, "pairing rejected")
    PairRateLimited => protocol_error(ERR_BUSY, "pairing rejected")
    PairUnsupportedVersion(_) =>
      protocol_error(ERR_UNSUPPORTED_VERSION, "unsupported protocol version")
    PairMalformed(_) => @contracts.RpcError::new(
      @contracts.ERR_INVALID_PARAMS,
      "invalid pairing request",
    )
    PairStorage(_) => @contracts.RpcError::new(
      @contracts.ERR_INTERNAL,
      "internal error",
    )
  }
}

///|
fn auth_failure_error(failure : AuthFailure) -> @contracts.RpcError {
  match failure {
    AuthUnauthorized => protocol_error(ERR_UNAUTHORIZED, "unauthorized")
    AuthRevoked => protocol_error(ERR_REVOKED, "credential revoked")
    AuthRateLimited => protocol_error(ERR_BUSY, "too many attempts")
    AuthUnsupportedVersion(_) =>
      protocol_error(ERR_UNSUPPORTED_VERSION, "unsupported protocol version")
    AuthMalformed(_) => @contracts.RpcError::new(
      @contracts.ERR_INVALID_PARAMS,
      "invalid authentication request",
    )
    AuthStorage(_) => @contracts.RpcError::new(
      @contracts.ERR_INTERNAL,
      "internal error",
    )
  }
}

///|
fn params_string(
  params : Map[String, @json.Json],
  key : String,
) -> Result[String, String] {
  match @contracts.string_field(params, key) {
    Some(value) => Ok(value)
    None => Err("missing " + key)
  }
}

///|
fn params_int(
  params : Map[String, @json.Json],
  key : String,
) -> Result[Int, String] {
  match @contracts.int_field(params, key) {
    Some(value) => Ok(value)
    None => Err("missing " + key)
  }
}

///|
fn params_int64_or(
  params : Map[String, @json.Json],
  key : String,
  default : Int64,
) -> Int64 {
  @contracts.int64_field_or(params, key, default)
}

///|
fn params_string_array(
  params : Map[String, @json.Json],
  key : String,
) -> Result[Array[String], String] {
  let values : Array[String] = []
  match params.get(key) {
    Some(value) =>
      match value.as_array() {
        Some(items) =>
          for item in items {
            match item.as_string() {
              Some(text) => values.push(text)
              None => return Err("invalid " + key)
            }
          }
        None => return Err(key + " must be an array")
      }
    None => ()
  }
  Ok(values)
}

///|
fn pair_grant_json(grant : PairGrant) -> @json.Json {
  let expires = match grant.expires_at_ms {
    Some(value) => @contracts.json_int64(value)
    None => @contracts.json_null()
  }
  @contracts.json_object([
    ("runtime_id", @contracts.json_string(grant.runtime_id)),
    ("credential", @contracts.json_string(grant.credential)),
    ("credential_id", @contracts.json_string(grant.credential_id)),
    ("generation", @contracts.json_int(grant.generation)),
    ("expires_at_ms", expires),
    ("protocol_version", @contracts.json_int(grant.protocol_version)),
  ])
}

///|
async fn PrimaryServer::send_json(
  self : PrimaryServer,
  stream : TlsStream,
  value : @json.Json,
) -> Bool {
  stream.write(value) catch {
    error => {
      self.state.log_line("send failed: " + safe_error(error))
      return false
    }
  }
  true
}

///|
async fn PrimaryServer::handle_connection(
  self : PrimaryServer,
  tcp : @socket.Tcp,
  peer : String,
) -> Unit {
  let stream = match self.listener.finish_handshake(tcp, peer) {
    Ok(value) => value
    Err(message) => {
      self.state.log_line("handshake failed: " + message)
      return
    }
  }
  let source = source_host(stream.peer())
  let mut session_id = ""
  let mut authenticated = false
  let mut drain_sent = false
  defer stream.close()
  while true {
    let timeout_ms = if authenticated {
      timeout_ms_of(
        self.config.heartbeat_interval_ms *
        self.config.heartbeat_max_missed.to_int64(),
      )
    } else {
      timeout_ms_of(self.config.hello_timeout_ms)
    }
    let attempt : Result[@json.Json, String]? = @async.with_timeout_opt(
      timeout_ms,
      () => {
        let frame = stream.read() catch {
          error => return Err(safe_error(error))
        }
        Ok(frame)
      },
    )
    match attempt {
      None => {
        if authenticated {
          self.state.audit.record(
            "runtime.heartbeat_timeout",
            "",
            "timeout",
            "session_id=" + session_id,
            @async.now(),
          )
          self.state.log_line(
            "heartbeat timeout session_id=" + session_id,
          )
        } else {
          self.state.log_line("unauthenticated connection timed out")
        }
        break
      }
      Some(Err(message)) => {
        self.state.log_line("connection read failed: " + message)
        break
      }
      Some(Ok(frame)) => {
        let outcome = self.handle_frame(
          stream,
          frame,
          source,
          session_id,
          authenticated,
          drain_sent,
        )
        session_id = outcome.session_id
        authenticated = outcome.authenticated
        drain_sent = outcome.drain_sent
        if outcome.close {
          break
        }
        if !drain_sent && self.state.is_draining() {
          let params : Map[String, @json.Json] = Map([])
          params.set("reason", @contracts.json_string("owner_requested"))
          let notification = @contracts.RpcNotification::new(
            METHOD_DRAIN,
            params,
          )
          if !self.send_json(stream, notification.to_json()) {
            break
          }
          drain_sent = true
        }
      }
    }
  }
  if authenticated {
    self.state.close_session(session_id)
  }
}

///|
async fn PrimaryServer::handle_frame(
  self : PrimaryServer,
  stream : TlsStream,
  frame : @json.Json,
  source : String,
  session_id : String,
  authenticated : Bool,
  drain_sent : Bool,
) -> FrameOutcome {
  match @contracts.parse_request(frame) {
    Ok(value) => {
      self.handle_request(stream, value, source, session_id, authenticated, drain_sent)
    }
    Err(_) => {
      let notification = match @contracts.parse_notification(frame) {
        Ok(value) => value
        Err(message) => {
          self.state.log_line("protocol error: " + message)
          return {
            session_id,
            authenticated,
            drain_sent,
            close: true,
          }
        }
      }
      self.handle_notification(
        stream,
        notification,
        session_id,
        authenticated,
        drain_sent,
      )
    }
  }
}

///|
async fn PrimaryServer::handle_request(
  self : PrimaryServer,
  stream : TlsStream,
  request : @contracts.RpcRequest,
  source : String,
  session_id : String,
  authenticated : Bool,
  drain_sent : Bool,
) -> FrameOutcome {
  let id = request.id
  let method = request.method
  match method {
    m if m == METHOD_PAIR => {
      let sent = self.handle_pair(stream, id, request.params, source)
      { session_id, authenticated, drain_sent, close: !sent }
    }
    m if m == METHOD_HELLO => {
      self.handle_hello(
        stream,
        id,
        request.params,
        source,
        session_id,
        authenticated,
        drain_sent,
      )
    }
    _ => {
      if !authenticated {
        let response = rpc_error_response(
          id,
          protocol_error(ERR_UNAUTHORIZED, "unauthorized"),
        )
        let _ = self.send_json(stream, response.to_json())
        return {
          session_id,
          authenticated,
          drain_sent,
          close: true,
        }
      }
      // Any frame is liveness, and the heartbeat re-check also detects a
      // credential revoked or expired since the last frame.
      match self.state.heartbeat(session_id) {
        Ok(cursor) => {
          self.handle_authenticated_request(
            stream,
            request,
            source,
            session_id,
            cursor,
            drain_sent,
          )
        }
        Err(failure) => {
          let response = rpc_error_response(id, auth_failure_error(failure))
          let _ = self.send_json(stream, response.to_json())
          outcome_close(session_id, drain_sent)
        }
      }
    }
  }
}

///|
async fn PrimaryServer::handle_pair(
  self : PrimaryServer,
  stream : TlsStream,
  id : String,
  params : Map[String, @json.Json],
  source : String,
) -> Bool {
  let code = match params_string(params, "pairing_code") {
    Ok(value) => value
    Err(message) => {
      let response = rpc_error_response(id, invalid_params_error(message))
      return self.send_json(stream, response.to_json())
    }
  }
  let runtime_id = match params_string(params, "runtime_id") {
    Ok(value) => value
    Err(message) => {
      let response = rpc_error_response(id, invalid_params_error(message))
      return self.send_json(stream, response.to_json())
    }
  }
  let protocol_version = match params_int(params, "protocol_version") {
    Ok(value) => value
    Err(message) => {
      let response = rpc_error_response(id, invalid_params_error(message))
      return self.send_json(stream, response.to_json())
    }
  }
  let capabilities = match params_string_array(params, "capabilities") {
    Ok(value) => value
    Err(message) => {
      let response = rpc_error_response(id, invalid_params_error(message))
      return self.send_json(stream, response.to_json())
    }
  }
  match
    self.state.pair(
      code,
      runtime_id,
      protocol_version,
      capabilities,
      source,
    ) {
    Ok(grant) => {
      let response = rpc_result_response(id, pair_grant_json(grant))
      self.send_json(stream, response.to_json())
    }
    Err(failure) => {
      let response = rpc_error_response(id, pair_failure_error(failure))
      self.send_json(stream, response.to_json())
    }
  }
}

///|
async fn PrimaryServer::handle_hello(
  self : PrimaryServer,
  stream : TlsStream,
  id : String,
  params : Map[String, @json.Json],
  source : String,
  session_id : String,
  authenticated : Bool,
  drain_sent : Bool,
) -> FrameOutcome {
  let _ = session_id
  let runtime_id = match params_string(params, "runtime_id") {
    Ok(value) => value
    Err(message) => {
      let response = rpc_error_response(id, invalid_params_error(message))
      let _ = self.send_json(stream, response.to_json())
      return {
        session_id: "",
        authenticated,
        drain_sent,
        close: true,
      }
    }
  }
  let token = match params_string(params, "token") {
    Ok(value) => value
    Err(message) => {
      let response = rpc_error_response(id, invalid_params_error(message))
      let _ = self.send_json(stream, response.to_json())
      return {
        session_id: "",
        authenticated,
        drain_sent,
        close: true,
      }
    }
  }
  let protocol_version = match params_int(params, "protocol_version") {
    Ok(value) =>
      if value == PROTOCOL_VERSION {
        value
      } else {
        let response = rpc_error_response(
          id,
          protocol_error(ERR_UNSUPPORTED_VERSION, "unsupported protocol version"),
        )
        let _ = self.send_json(stream, response.to_json())
        return {
          session_id: "",
          authenticated,
          drain_sent,
          close: true,
        }
      }
    Err(message) => {
      let response = rpc_error_response(id, invalid_params_error(message))
      let _ = self.send_json(stream, response.to_json())
      return {
        session_id: "",
        authenticated,
        drain_sent,
        close: true,
      }
    }
  }
  let last_ack_cursor = params_int64_or(params, "last_ack_cursor", 0L)
  let grant = match
    self.state.open_session(
      runtime_id,
      token,
      source,
      last_ack_cursor,
    ) {
    Ok(value) => value
    Err(failure) => {
      let response = rpc_error_response(id, auth_failure_error(failure))
      let _ = self.send_json(stream, response.to_json())
      return {
        session_id: "",
        authenticated,
        drain_sent,
        close: true,
      }
    }
  }
  let result = @contracts.json_object([
    ("runtime_id", @contracts.json_string(grant.runtime_id)),
    ("session_id", @contracts.json_string(grant.session_id)),
    ("session_credential_id", @contracts.json_string(grant.credential_id)),
    ("protocol_version", @contracts.json_int(protocol_version)),
    (
      "heartbeat_interval_ms",
      @contracts.json_int64(self.config.heartbeat_interval_ms),
    ),
    (
      "heartbeat_max_missed",
      @contracts.json_int(self.config.heartbeat_max_missed),
    ),
    ("max_frame_bytes", @contracts.json_int(MAX_FRAME_BYTES)),
    ("resume_cursor", @contracts.json_int64(grant.resume_cursor)),
    ("gap", @contracts.json_bool(grant.gap)),
    ("server_time_ms", @contracts.json_int64((self.state.now)())),
    ("draining", @contracts.json_bool(self.state.is_draining())),
  ])
  let response = rpc_result_response(id, result)
  if !self.send_json(stream, response.to_json()) {
    return {
      session_id: "",
      authenticated: false,
      drain_sent,
      close: true,
    }
  }
  {
    session_id: grant.session_id,
    authenticated: true,
    drain_sent,
    close: false,
  }
}

///|
async fn PrimaryServer::handle_authenticated_request(
  self : PrimaryServer,
  stream : TlsStream,
  request : @contracts.RpcRequest,
  source : String,
  session_id : String,
  ack_cursor : Int64,
  drain_sent : Bool,
) -> FrameOutcome {
  let id = request.id
  let method = request.method
  let session = match self.state.session_info(session_id) {
    Some(value) => value
    None => {
      let response = rpc_error_response(
        id,
        protocol_error(ERR_REVOKED, "credential revoked"),
      )
      let _ = self.send_json(stream, response.to_json())
      return outcome_close(session_id, drain_sent)
    }
  }
  if method == METHOD_HEARTBEAT {
    let response = rpc_result_response(
      id,
      @contracts.json_object([
        ("ack_cursor", @contracts.json_int64(ack_cursor)),
        ("draining", @contracts.json_bool(self.state.is_draining())),
      ]),
    )
    let _ = self.send_json(stream, response.to_json())
    return outcome_continue(session_id, drain_sent)
  }
  if method == METHOD_BYE {
    self.state.close_session(session_id)
    let response = rpc_result_response(
      id,
      @contracts.json_object([("ok", @contracts.json_bool(true))]),
    )
    let _ = self.send_json(stream, response.to_json())
    return {
      session_id,
      authenticated: true,
      drain_sent,
      close: true,
    }
  }
  if method == METHOD_ROTATE {
    let token = match params_string(request.params, "token") {
      Ok(value) => value
      Err(message) => {
        let response = rpc_error_response(id, invalid_params_error(message))
        let _ = self.send_json(stream, response.to_json())
        return outcome_continue(session_id, drain_sent)
      }
    }
    let grant = match
      self.state.rotate(session.runtime_id, token, source) {
      Ok(value) => value
      Err(failure) => {
        let response = rpc_error_response(id, auth_failure_error(failure))
        let _ = self.send_json(stream, response.to_json())
        return outcome_continue(session_id, drain_sent)
      }
    }
    let response = rpc_result_response(id, pair_grant_json(grant))
    let _ = self.send_json(stream, response.to_json())
    return outcome_continue(session_id, drain_sent)
  }
  if method == METHOD_EVENT {
    let event = match WireEvent::from_params(request.params) {
      Ok(value) => value
      Err(message) => {
        self.state.audit.record(
          "runtime.event_rejected",
          session.runtime_id,
          "rejected",
          "reason=" + message,
          (self.state.now)(),
        )
        let response = rpc_error_response(id, invalid_params_error(message))
        let _ = self.send_json(stream, response.to_json())
        return outcome_continue(session_id, drain_sent)
      }
    }
    match self.state.accept_event(session.runtime_id, event) {
      Ok(ack) => {
        let response = rpc_result_response(id, ack.to_json())
        let _ = self.send_json(stream, response.to_json())
        return outcome_continue(session_id, drain_sent)
      }
      Err(EventMalformed(message)) => {
        let response = rpc_error_response(id, invalid_params_error(message))
        let _ = self.send_json(stream, response.to_json())
        return outcome_continue(session_id, drain_sent)
      }
      Err(EventStorage(_)) => {
        let response = rpc_error_response(
          id,
          @contracts.RpcError::new(@contracts.ERR_INTERNAL, "internal error"),
        )
        let _ = self.send_json(stream, response.to_json())
        return outcome_close(session_id, drain_sent)
      }
    }
  }
  if method == METHOD_REPLAY_GAP {
    self.state.audit.record(
      "runtime.replay_gap",
      session.runtime_id,
      "gap",
      "reported by node",
      (self.state.now)(),
    )
    let response = rpc_result_response(
      id,
      @contracts.json_object([("ok", @contracts.json_bool(true))]),
    )
    let _ = self.send_json(stream, response.to_json())
    return outcome_continue(session_id, drain_sent)
  }
  if reserved_method(method) {
    let response = rpc_error_response(id, method_not_found_error(method))
    let _ = self.send_json(stream, response.to_json())
    return outcome_continue(session_id, drain_sent)
  }
  let result = self.dispatch_registered(session, request)
  match result {
    Ok(value) => {
      let response = rpc_result_response(id, value)
      if !self.send_json(stream, response.to_json()) {
        return outcome_close(session_id, drain_sent)
      }
      outcome_continue(session_id, drain_sent)
    }
    Err(error) => {
      let response = rpc_error_response(id, error)
      let _ = self.send_json(stream, response.to_json())
      outcome_continue(session_id, drain_sent)
    }
  }
}

///|
async fn PrimaryServer::dispatch_registered(
  self : PrimaryServer,
  session : SessionInfo,
  request : @contracts.RpcRequest,
) -> Result[@json.Json, @contracts.RpcError] {
  let handler = match self.handlers.lookup(request.method) {
    Some(value) => value
    None => return Err(method_not_found_error(request.method))
  }
  let client_request_id = match
    @contracts.string_field(request.params, "client_request_id") {
    Some(value) =>
      if value == "" || value.length() > MAX_CLIENT_REQUEST_ID_LEN {
        return Err(invalid_params_error("invalid client_request_id"))
      } else {
        value
      }
    None => ""
  }
  let cache_key = session.runtime_id + "|" + client_request_id
  if client_request_id != "" {
    match self.state.idempotent_lookup(cache_key) {
      Some(value) => return Ok(value)
      None => ()
    }
  }
  self.dispatch_mutex.acquire()
  defer self.dispatch_mutex.release()
  if client_request_id != "" {
    match self.state.idempotent_lookup(cache_key) {
      Some(value) => return Ok(value)
      None => ()
    }
  }
  let handler_request : HandlerRequest = {
    runtime_id: session.runtime_id,
    session_id: session.session_id,
    rpc_method: request.method,
    params: request.params,
    client_request_id,
  }
  match (handler)(handler_request) {
    Ok(value) => {
      if client_request_id != "" {
        self.state.idempotent_remember(cache_key, value)
      }
      Ok(value)
    }
    Err(error) => Err(error)
  }
}

///|
async fn PrimaryServer::handle_notification(
  self : PrimaryServer,
  stream : TlsStream,
  notification : @contracts.RpcNotification,
  session_id : String,
  authenticated : Bool,
  drain_sent : Bool,
) -> FrameOutcome {
  let method = notification.method
  if !authenticated {
    self.state.log_line("unauthenticated notification rejected")
    return {
      session_id,
      authenticated,
      drain_sent,
      close: true,
    }
  }
  let session = match self.state.session_info(session_id) {
    Some(value) => value
    None => return outcome_close(session_id, drain_sent)
  }
  match self.state.heartbeat(session_id) {
    Ok(_) => ()
    Err(_) => return outcome_close(session_id, drain_sent)
  }
  if method == METHOD_EVENT {
    let event = match WireEvent::from_params(notification.params) {
      Ok(value) => value
      Err(message) => {
        self.state.audit.record(
          "runtime.event_rejected",
          session.runtime_id,
          "rejected",
          "reason=" + message,
          (self.state.now)(),
        )
        return outcome_close(session_id, drain_sent)
      }
    }
    match self.state.accept_event(session.runtime_id, event) {
      Ok(ack) => {
        let params : Map[String, @json.Json] = Map([])
        params.set("cursor", @contracts.json_int64(ack.cursor))
        params.set("duplicate", @contracts.json_bool(ack.duplicate))
        let ack_notification = @contracts.RpcNotification::new(
          METHOD_ACK,
          params,
        )
        if !self.send_json(stream, ack_notification.to_json()) {
          return outcome_close(session_id, drain_sent)
        }
        outcome_continue(session_id, drain_sent)
      }
      Err(EventMalformed(_)) => outcome_close(session_id, drain_sent)
      Err(EventStorage(_)) => outcome_close(session_id, drain_sent)
    }
  } else if method == METHOD_HEARTBEAT {
    let cursor = match self.state.heartbeat(session_id) {
      Ok(value) => value
      Err(_) => return outcome_close(session_id, drain_sent)
    }
    let params : Map[String, @json.Json] = Map([])
    params.set("cursor", @contracts.json_int64(cursor))
    let ack_notification = @contracts.RpcNotification::new(METHOD_ACK, params)
    if !self.send_json(stream, ack_notification.to_json()) {
      return outcome_close(session_id, drain_sent)
    }
    outcome_continue(session_id, drain_sent)
  } else if method == METHOD_REPLAY_GAP {
    self.state.audit.record(
      "runtime.replay_gap",
      session.runtime_id,
      "gap",
      "reported by node",
      (self.state.now)(),
    )
    outcome_continue(session_id, drain_sent)
  } else if method == METHOD_BYE {
    self.state.close_session(session_id)
    {
      session_id,
      authenticated,
      drain_sent,
      close: true,
    }
  } else {
    self.state.log_line("unknown notification: " + clamp_text(method, 64))
    outcome_continue(session_id, drain_sent)
  }
}
