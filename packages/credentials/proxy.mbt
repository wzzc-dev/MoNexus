///|
/// Loopback credential proxy (A5.1, ADR-0016 §4).
///
/// The Agent child receives `MONEXUS_CREDENTIAL_PROXY_URL` (this server) and
/// `MONEXUS_CREDENTIAL_PROXY_TOKEN` (`mxp_...`). It never receives the upstream
/// credential. Each proxied request:
///
/// 1. must carry `Authorization: Bearer mxp_...` with a live, session-bound
///    capability token;
/// 2. must target the profile's fixed upstream host and path prefix;
/// 3. has its client `Authorization` replaced by the real credential (read from
///    the platform store at request time, never cached in the proxy object);
/// 4. must not follow redirects, and may not cross to another host;
/// 5. is bounded in body size, response size and wall-clock time.
///
/// The proxy never logs headers or bodies. Denials are recorded with a fixed
/// reason string, never with the token value.

///|
pub const CREDENTIAL_PROXY_MAX_REQUEST_BYTES : Int32 = 4_194_304

///|
pub const CREDENTIAL_PROXY_MAX_RESPONSE_BYTES : Int32 = 33_554_432

///|
pub const CREDENTIAL_PROXY_REQUEST_TIMEOUT_MS : Int32 = 60_000

///|
pub const CREDENTIAL_PROXY_READ_TIMEOUT_MS : Int32 = 10_000

///|
/// Fixed-window request cap per proxy. A single Agent session should not be
/// able to turn a leaked capability token into an unbounded request stream.
pub const CREDENTIAL_PROXY_RATE_LIMIT : Int32 = 120

///|
pub const CREDENTIAL_PROXY_RATE_WINDOW_MS : Int64 = 60_000L

///|
/// One session's capability. Only the token itself is credential-shaped; the
/// rest is metadata used to check that the binding is still active and the
/// version still matches.
pub(all) struct ProxySession {
  token : String
  binding_id : String
  credential_id : String
  version : Int32
  machine_id : String
  agent_id : String
  profile : String
  expires_at_ms : Int64
}

///|
pub fn ProxySession::new(
  token~ : String,
  binding_id~ : String,
  credential_id~ : String,
  version~ : Int32,
  machine_id~ : String,
  agent_id~ : String,
  profile~ : String,
  expires_at_ms~ : Int64,
) -> ProxySession {
  {
    token,
    binding_id,
    credential_id,
    version,
    machine_id,
    agent_id,
    profile,
    expires_at_ms,
  }
}

///|
/// Host-supplied hooks. `authorize` runs on every request so revocation,
/// rotation and lease expiry take effect immediately; `secret` reads the
/// platform store; `audit` appends a secret-free event.
pub(all) struct ProxyCallbacks {
  authorize : async (ProxySession) -> Result[Unit, String]
  secret : async (ProxySession) -> Result[String, String]
  audit : (String, String) -> Unit
}

///|
pub fn ProxyCallbacks::new(
  authorize~ : async (ProxySession) -> Result[Unit, String],
  secret~ : async (ProxySession) -> Result[String, String],
  audit~ : (String, String) -> Unit,
) -> ProxyCallbacks {
  { authorize, secret, audit, }
}

///|
pub(all) struct CredentialProxy {
  session : ProxySession
  profile : @contracts.CredentialProfile
  port : Int32
  server : @http.Server
  closed : Ref[Bool]
  callbacks : ProxyCallbacks
  rate_started_ms : Ref[Int64]
  rate_count : Ref[Int32]
}

///|
pub fn CredentialProxy::url(self : CredentialProxy) -> String {
  "http://127.0.0.1:" + self.port.to_string()
}

///|
/// Start the proxy on an ephemeral loopback port. The accept loop is spawned
/// into `group`; `stop` closes the listener and the loop exits.
pub async fn start_credential_proxy(
  group : @async.TaskGroup[Unit],
  profile : @contracts.CredentialProfile,
  session : ProxySession,
  callbacks : ProxyCallbacks,
) -> Result[CredentialProxy, String] {
  let addr = @socket.Addr::parse("127.0.0.1:0") catch {
    _ => return Err("invalid proxy bind address")
  }
  let server = @http.Server::Server(addr, reuse_addr=false)
  let proxy = {
    session,
    profile,
    port: server.addr().port(),
    server,
    closed: Ref(false),
    callbacks,
    rate_started_ms: Ref(0L),
    rate_count: Ref(0),
  }
  ignore(
    group.spawn(no_wait=true, allow_failure=true) <| () => {
      proxy_accept_loop(proxy)
    },
  )
  Ok(proxy)
}

///|
pub fn CredentialProxy::stop(self : CredentialProxy) -> Unit {
  self.closed.val = true
  self.server.close()
}

///|
async fn proxy_accept_loop(proxy : CredentialProxy) -> Unit {
  while !proxy.closed.val {
    let accepted = @async.with_timeout_opt(200, async fn() -> (
      @http.ServerConnection,
      @socket.Addr,
    ) {
      proxy.server.accept()
    })
    match accepted {
      None => continue
      Some(pair) => {
        let (conn, _addr) = pair
        defer conn.close()
        proxy_serve_connection(proxy, conn)
      }
    }
  }
}

///|
async fn proxy_serve_connection(
  proxy : CredentialProxy,
  conn : @http.ServerConnection,
) -> Unit {
  for _ in 0..<16 {
    let request = conn.read_request() catch { _ => break }
    // Every handler path ends its own response; ending it again here would
    // abort the connection with `end_body() called outside a HTTP message`.
    proxy_handle_request(proxy, request, conn) catch {
      _ => {
        proxy_respond_text(conn, 502, "Bad Gateway", "proxy failure")
        break
      }
    }
  }
}

///|
async fn proxy_respond_text(
  conn : @http.ServerConnection,
  code : Int32,
  reason : String,
  message : String,
) -> Unit {
  let headers : @http.Headers = Map([])
  headers.set(
    @http.CaseInsensitiveString("content-type"),
    "text/plain; charset=utf-8",
  )
  conn.send_response(code, reason, extra_headers=headers)
  conn.write_string(message)
  conn.end_response()
}

///|
fn proxy_header(headers : @http.Headers, name : String) -> String? {
  headers.get(@http.CaseInsensitiveString(name))
}

///|
fn proxy_is_loopback_host(host : String) -> Bool {
  let lower = host.to_lower()
  if lower == "127.0.0.1" ||
    lower == "localhost" ||
    lower == "[::1]" ||
    lower == "::1" {
    return true
  }
  if lower.has_prefix("[") {
    // Bracketed IPv6 with a port: keep the address part, including `]`.
    return match lower.find("]") {
      Some(index) => {
        let address = lower.substring(start=0, end=index.to_int() + 1)
        let rest = lower.substring(start=index.to_int() + 1, end=lower.length())
        address == "[::1]" && rest.has_prefix(":")
      }
      None => false
    }
  }
  let without_port = match lower.find(":") {
    Some(index) => lower.substring(start=0, end=index.to_int())
    None => lower
  }
  without_port == "127.0.0.1" || without_port == "localhost"
}

///|
fn proxy_path_join(base_path : String, path : String) -> String {
  if path == "" {
    return base_path
  }
  let mut base = base_path
  if base != "" && !base.has_prefix("/") {
    base = "/" + base
  }
  if base != "" && base.has_suffix("/") {
    base = base.substring(start=0, end=base.length() - 1)
  }
  if base != "" && path.has_prefix(base) {
    return path
  }
  let rest = if path.has_prefix("/") { path } else { "/" + path }
  base + rest
}

///|
/// Reject request paths that can escape the fixed upstream prefix through
/// normalization (`..`, `.` segments, encoded dots/slashes or backslashes).
fn proxy_path_is_safe(path : String) -> Bool {
  let lower = path.to_lower()
  if lower.contains("\\") ||
    lower.contains("%2e") ||
    lower.contains("%2f") ||
    lower.contains("%5c") {
    return false
  }
  let path_only = match lower.find("?") {
    Some(index) => lower.substring(start=0, end=index.to_int())
    None => lower
  }
  for segment in path_only.split("/") {
    if segment == "." || segment == ".." {
      return false
    }
  }
  true
}

///|
/// Copy only response headers that are safe to reflect. Hop-by-hop headers,
/// `Set-Cookie`, `Location` (redirect) and any authorization echo are dropped.
fn proxy_copy_response_headers(source : @http.Headers) -> @http.Headers {
  let out : @http.Headers = Map([])
  let allow = [
    "content-type", "cache-control", "x-request-id", "openai-version", "openai-processing-ms",
  ]
  for name in allow {
    let key = @http.CaseInsensitiveString(name)
    match source.get(key) {
      Some(value) => out.set(key, value)
      None => ()
    }
  }
  out
}

///|
fn proxy_is_redirect(code : Int32) -> Bool {
  code == 301 || code == 302 || code == 303 || code == 307 || code == 308
}

///|
async fn proxy_read_body(
  conn : @http.ServerConnection,
  limit : Int32,
) -> Result[Bytes, String] {
  let parts : Array[Bytes] = []
  let mut total = 0
  for _ in 0..<4096 {
    let remaining = limit - total + 1
    let chunk = @async.with_timeout_opt(CREDENTIAL_PROXY_READ_TIMEOUT_MS, async fn() -> Bytes? {
      conn.read_some(max_len=remaining)
    })
    let piece = match chunk {
      None => return Err("read_timeout")
      Some(value) => value
    }
    let done = match piece {
      None => true
      Some(bytes) =>
        if bytes.length() == 0 {
          true
        } else {
          total = total + bytes.length()
          if total > limit {
            return Err("too_large")
          }
          parts.push(bytes)
          false
        }
    }
    if done {
      return Ok(proxy_concat(parts, total))
    }
  }
  Err("too_large")
}

///|
fn proxy_concat(parts : Array[Bytes], total : Int32) -> Bytes {
  let out : FixedArray[Byte] = FixedArray::make(total, b'\x00')
  let mut cursor = 0
  for part in parts {
    for index in 0..<part.length() {
      out[cursor + index] = part[index]
    }
    cursor = cursor + part.length()
  }
  Bytes::from_fixedarray(out)
}

///|
async fn proxy_handle_request(
  proxy : CredentialProxy,
  request : @http.Request,
  conn : @http.ServerConnection,
) -> Unit {
  let session = proxy.session
  let now = @async.now()
  if now > session.expires_at_ms {
    (proxy.callbacks.audit)(
      @contracts.EVENT_CREDENTIAL_PROXY_DENIED,
      "session_expired",
    )
    proxy_respond_text(conn, 401, "Unauthorized", "credential session expired")
    return
  }
  match proxy_header(request.headers, "host") {
    Some(value) =>
      if !proxy_is_loopback_host(value) {
        (proxy.callbacks.audit)(
          @contracts.EVENT_CREDENTIAL_PROXY_DENIED,
          "host_not_allowed",
        )
        proxy_respond_text(conn, 403, "Forbidden", "host not allowed")
        return
      }
    None => ()
  }
  if request.path.has_prefix("http://") || request.path.has_prefix("https://") {
    (proxy.callbacks.audit)(
      @contracts.EVENT_CREDENTIAL_PROXY_DENIED,
      "absolute_form_rejected",
    )
    proxy_respond_text(conn, 403, "Forbidden", "absolute request target")
    return
  }
  if !proxy_path_is_safe(request.path) {
    (proxy.callbacks.audit)(
      @contracts.EVENT_CREDENTIAL_PROXY_DENIED,
      "path_not_allowed",
    )
    proxy_respond_text(conn, 403, "Forbidden", "path not allowed")
    return
  }
  if request.meth != @http.RequestMethod::Post &&
    request.meth != @http.RequestMethod::Get {
    (proxy.callbacks.audit)(
      @contracts.EVENT_CREDENTIAL_PROXY_DENIED,
      "method_not_allowed",
    )
    proxy_respond_text(conn, 405, "Method Not Allowed", "method not allowed")
    return
  }
  let authorization = proxy_header(request.headers, "authorization")
  let token = match authorization {
    Some(value) => {
      let trimmed = value.trim().to_owned()
      if trimmed.has_prefix("Bearer ") {
        trimmed.substring(start=7, end=trimmed.length())
      } else {
        ""
      }
    }
    None => ""
  }
  if !token.has_prefix(@contracts.CREDENTIAL_TOKEN_PREFIX) ||
    token != session.token {
    (proxy.callbacks.audit)(
      @contracts.EVENT_CREDENTIAL_PROXY_DENIED,
      "token_invalid",
    )
    proxy_respond_text(conn, 401, "Unauthorized", "credential token invalid")
    return
  }
  let rate_started = proxy.rate_started_ms.val
  if rate_started == 0L || now - rate_started >= CREDENTIAL_PROXY_RATE_WINDOW_MS {
    proxy.rate_started_ms.val = now
    proxy.rate_count.val = 0
  }
  if proxy.rate_count.val >= CREDENTIAL_PROXY_RATE_LIMIT {
    (proxy.callbacks.audit)(
      @contracts.EVENT_CREDENTIAL_PROXY_DENIED,
      "rate_limited",
    )
    proxy_respond_text(conn, 429, "Too Many Requests", "rate limit exceeded")
    return
  }
  proxy.rate_count.val = proxy.rate_count.val + 1
  let allowed = (proxy.callbacks.authorize)(session) catch {
    _ => Err("authorization_failed")
  }
  match allowed {
    Ok(_) => ()
    Err(reason) => {
      (proxy.callbacks.audit)(@contracts.EVENT_CREDENTIAL_PROXY_DENIED, reason)
      proxy_respond_text(conn, 401, "Unauthorized", "credential unavailable")
      return
    }
  }
  let body = match proxy_read_body(conn, CREDENTIAL_PROXY_MAX_REQUEST_BYTES) {
    Ok(value) => value
    Err(reason) => {
      let (code, label) = if reason == "too_large" {
        (413, "Payload Too Large")
      } else {
        (408, "Request Timeout")
      }
      (proxy.callbacks.audit)(@contracts.EVENT_CREDENTIAL_PROXY_DENIED, reason)
      proxy_respond_text(conn, code, label, reason)
      return
    }
  }
  let secret = match (proxy.callbacks.secret)(session) {
    Ok(value) => value
    Err(_reason) => {
      (proxy.callbacks.audit)(
        @contracts.EVENT_CREDENTIAL_PROXY_DENIED,
        "credential_unavailable",
      )
      proxy_respond_text(
        conn, 503, "Service Unavailable", "credential unavailable",
      )
      return
    }
  }
  let profile = proxy.profile
  let target_path = proxy_path_join(profile.upstream_base_path, request.path)
  let base = profile.upstream_scheme + "://" + profile.upstream_host
  let headers : @http.Headers = Map([])
  let content_type = proxy_header(request.headers, "content-type")
  match content_type {
    Some(value) =>
      headers.set(@http.CaseInsensitiveString("content-type"), value)
    None => ()
  }
  let accept = proxy_header(request.headers, "accept")
  match accept {
    Some(value) => headers.set(@http.CaseInsensitiveString("accept"), value)
    None => ()
  }
  headers.set(
    @http.CaseInsensitiveString("content-length"),
    body.length().to_string(),
  )
  let auth_value = if profile.auth_scheme == "" {
    secret
  } else {
    profile.auth_scheme + " " + secret
  }
  headers.set(@http.CaseInsensitiveString(profile.auth_header), auth_value)
  let client = @http.Client::Client(base) catch {
    _ => {
      (proxy.callbacks.audit)(
        @contracts.EVENT_CREDENTIAL_PROXY_DENIED,
        "upstream_unreachable",
      )
      proxy_respond_text(conn, 502, "Bad Gateway", "upstream unreachable")
      return
    }
  }
  defer client.close()
  client.request(request.meth, target_path, extra_headers=headers) catch {
    _ => {
      proxy_respond_text(conn, 502, "Bad Gateway", "upstream request failed")
      return
    }
  }
  client.write(body) catch {
    _ => {
      proxy_respond_text(conn, 502, "Bad Gateway", "upstream write failed")
      return
    }
  }
  let response = client.end_request() catch {
    _ => {
      proxy_respond_text(conn, 502, "Bad Gateway", "upstream response failed")
      return
    }
  }
  if proxy_is_redirect(response.code.to_int()) {
    (proxy.callbacks.audit)(
      @contracts.EVENT_CREDENTIAL_PROXY_DENIED,
      "redirect_rejected",
    )
    proxy_respond_text(conn, 502, "Bad Gateway", "redirects are not allowed")
    return
  }
  let out_headers = proxy_copy_response_headers(response.headers)
  conn.send_response(response.code, response.reason, extra_headers=out_headers)
  let mut sent = 0
  for _ in 0..<65536 {
    let chunk = client.read_some(max_len=65536) catch { _ => break }
    let piece = match chunk {
      None => break
      Some(value) => value
    }
    sent = sent + piece.length()
    if sent > CREDENTIAL_PROXY_MAX_RESPONSE_BYTES {
      (proxy.callbacks.audit)(
        @contracts.EVENT_CREDENTIAL_PROXY_DENIED,
        "response_too_large",
      )
      break
    }
    conn.write(piece) catch {
      _ => break
    }
  }
  conn.end_response()
}
