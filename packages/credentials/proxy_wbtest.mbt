///|
/// A5.1 loopback proxy tests: capability-token auth, fixed upstream swap,
/// path/host/redirect rejection, method and rate bounds, and immediate
/// authorization failure after revocation.

///|
fn proxy_test_headers(token : String) -> @http.Headers {
  let headers : @http.Headers = Map([])
  headers.set(@http.CaseInsensitiveString("authorization"), "Bearer " + token)
  headers.set(@http.CaseInsensitiveString("content-type"), "application/json")
  headers
}

///|
fn proxy_test_session(token : String, expires_at_ms : Int64) -> ProxySession {
  ProxySession::new(
    token~,
    binding_id="bind_proxy_test",
    credential_id="crd_proxy_test",
    version=1,
    machine_id="",
    agent_id="agent-proxy-test",
    profile="proxy-test",
    expires_at_ms~,
  )
}

///|
fn proxy_test_callbacks(
  audits : Array[String],
  secret_reads : Ref[Int32],
  authorize_ok : Ref[Bool],
) -> ProxyCallbacks {
  ProxyCallbacks::new(
    authorize=async fn(_session) {
      if authorize_ok.val {
        Ok(())
      } else {
        Err(@contracts.CREDENTIAL_REASON_REVOKED)
      }
    },
    secret=async fn(_session) {
      secret_reads.val = secret_reads.val + 1
      Ok("sk-real-upstream-secret")
    },
    audit=fn(event_type, reason) { audits.push(event_type + ":" + reason) },
  )
}

///|
async fn proxy_test_upstream_handler(
  request : @http.Request,
  _body : &@io.Reader,
  conn : @http.ServerConnection,
  seen_auth : Ref[String],
  hits : Ref[Int32],
) -> Unit {
  hits.val = hits.val + 1
  seen_auth.val = match
    request.headers.get(@http.CaseInsensitiveString("authorization")) {
    Some(value) => value
    None => ""
  }
  let headers : @http.Headers = Map([])
  if request.path.contains("redirect") {
    headers.set(
      @http.CaseInsensitiveString("location"),
      "http://evil.example/steal",
    )
    conn.send_response(302, "Found", extra_headers=headers)
    conn.write_string("")
  } else {
    headers.set(@http.CaseInsensitiveString("content-type"), "application/json")
    conn.send_response(200, "OK", extra_headers=headers)
    conn.write_string("{\"ok\":true}")
  }
  conn.end_response()
}

///|
test "proxy host and path guards" {
  assert_true(proxy_is_loopback_host("127.0.0.1:8080"))
  assert_true(proxy_is_loopback_host("localhost:1"))
  assert_true(proxy_is_loopback_host("[::1]:8080"))
  assert_true(proxy_is_loopback_host("::1"))
  assert_true(!proxy_is_loopback_host("evil.example"))
  assert_true(!proxy_is_loopback_host("127.0.0.1.evil.example"))
  assert_true(proxy_path_is_safe("/v1/messages?query=.."))
  assert_true(!proxy_path_is_safe("/v1/../admin"))
  assert_true(!proxy_path_is_safe("/v1/%2e%2e/admin"))
  assert_true(!proxy_path_is_safe("/v1\\..\\admin"))
  assert_true(!proxy_path_is_safe("/v1/%2fadmin"))
}

///|
async test "proxy swaps mxp token for the real credential and fails closed" {
  let upstream_addr = @socket.Addr::parse("127.0.0.1:0") catch {
    _ => fail("cannot parse the upstream bind address")
  }
  let upstream = @http.Server::Server(upstream_addr, reuse_addr=false)
  let upstream_port = upstream.addr().port()
  let seen_auth : Ref[String] = Ref("")
  let hits : Ref[Int32] = Ref(0)
  let audits : Array[String] = []
  let secret_reads : Ref[Int32] = Ref(0)
  let authorize_ok : Ref[Bool] = Ref(true)
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    group.spawn_bg(no_wait=true, allow_failure=true, async fn() {
      upstream.run_forever(allow_failure=true, max_connections=8) <| ((
        request,
        body,
        conn,
      ) => proxy_test_upstream_handler(request, body, conn, seen_auth, hits))
    })
    let profile = @contracts.CredentialProfile::new(
      name="proxy-test",
      upstream_scheme="http",
      upstream_host="127.0.0.1:" + upstream_port.to_string(),
      upstream_base_path="/v1",
      auth_header="authorization",
      auth_scheme="Bearer",
    )
    let now = @async.now()
    let token = @contracts.CREDENTIAL_TOKEN_PREFIX + "proxy-test-token"
    let callbacks = proxy_test_callbacks(audits, secret_reads, authorize_ok)
    let proxy = match
      start_credential_proxy(
        group,
        profile,
        proxy_test_session(token, now + 60_000L),
        callbacks,
      ) {
      Ok(value) => value
      Err(message) => fail("cannot start the proxy: " + message)
    }
    defer proxy.stop()
    // One valid request: the client token is replaced by the real secret.
    let headers = proxy_test_headers(token)
    let (response, body) = @http.post(
      proxy.url() + "/v1/messages",
      "{}",
      headers~,
    )
    assert_eq(response.code, 200)
    ignore(body.text() catch { _ => "" })
    assert_eq(seen_auth.val, "Bearer sk-real-upstream-secret")
    assert_true(!seen_auth.val.contains(token))
    assert_eq(hits.val, 1)
    // A wrong or missing capability token never reaches the upstream.
    let wrong = proxy_test_headers("mxp_wrong-token")
    let (wrong_response, wrong_body) = @http.post(
      proxy.url() + "/v1/messages",
      "{}",
      headers=wrong,
    )
    assert_eq(wrong_response.code, 401)
    ignore(wrong_body.text() catch { _ => "" })
    let (missing_response, missing_body) = @http.post(
      proxy.url() + "/v1/messages",
      "{}",
    )
    assert_eq(missing_response.code, 401)
    ignore(missing_body.text() catch { _ => "" })
    assert_eq(hits.val, 1)
    // Path escape attempts are rejected before any upstream call.
    let (path_response, path_body) = @http.get(
      proxy.url() + "/v1/%2e%2e/admin",
      headers~,
    )
    assert_eq(path_response.code, 403)
    ignore(path_body.text() catch { _ => "" })
    // Only GET and POST are accepted.
    let (put_response, put_body) = @http.request(
      proxy.url() + "/v1/messages",
      @http.RequestMethod::Put,
      headers,
      "{}",
    )
    assert_eq(put_response.code, 405)
    ignore(put_body.text() catch { _ => "" })
    assert_eq(hits.val, 1)
    // A redirect from upstream is a hard 502; Location is never reflected.
    let (redirect_response, redirect_body) = @http.post(
      proxy.url() + "/v1/redirect",
      "{}",
      headers~,
    )
    assert_eq(redirect_response.code, 502)
    ignore(redirect_body.text() catch { _ => "" })
    assert_eq(hits.val, 2)
    // Revocation takes effect for the running session, not just the next one.
    authorize_ok.val = false
    let (revoked_response, revoked_body) = @http.post(
      proxy.url() + "/v1/messages",
      "{}",
      headers~,
    )
    assert_eq(revoked_response.code, 401)
    ignore(revoked_body.text() catch { _ => "" })
    assert_eq(hits.val, 2)
    // The fixed-window cap turns a leaked token into a bounded stream.
    proxy.rate_started_ms.val = @async.now()
    proxy.rate_count.val = CREDENTIAL_PROXY_RATE_LIMIT
    authorize_ok.val = true
    let (limited_response, limited_body) = @http.post(
      proxy.url() + "/v1/messages",
      "{}",
      headers~,
    )
    assert_eq(limited_response.code, 429)
    ignore(limited_body.text() catch { _ => "" })
    assert_eq(hits.val, 2)
    // An expired session is rejected even with the right token.
    let expired_token = @contracts.CREDENTIAL_TOKEN_PREFIX + "expired-token"
    let expired = match
      start_credential_proxy(
        group,
        profile,
        proxy_test_session(expired_token, now - 1L),
        callbacks,
      ) {
      Ok(value) => value
      Err(message) => fail("cannot start the expired proxy: " + message)
    }
    defer expired.stop()
    let (expired_response, expired_body) = @http.get(
      expired.url() + "/v1/models",
      headers=proxy_test_headers(expired_token),
    )
    assert_eq(expired_response.code, 401)
    ignore(expired_body.text() catch { _ => "" })
    assert_true(audits.contains("credential.proxy.denied:token_invalid"))
    assert_true(audits.contains("credential.proxy.denied:path_not_allowed"))
    assert_true(audits.contains("credential.proxy.denied:method_not_allowed"))
    assert_true(audits.contains("credential.proxy.denied:redirect_rejected"))
    assert_true(audits.contains("credential.proxy.denied:rate_limited"))
    assert_true(audits.contains("credential.proxy.denied:session_expired"))
    assert_true(secret_reads.val >= 1)
  })
}
