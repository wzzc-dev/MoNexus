///|
/// Loopback TLS end-to-end tests.
///
/// Every test generates a throwaway PKI with `openssl` inside an
/// `@fs.tmpdir` directory (a CA, a server leaf with SAN localhost, and an
/// unrelated CA/leaf used to exercise both pinning layers). Servers and
/// clients are strictly sequential: the transport serializes server
/// handshakes through one process-wide mutex, and these tests never overlap
/// handshakes, so they do not reproduce the A1.0 spike's OpenSSL race.
///
/// The tests use only the public package API plus `@contracts`, `@json`,
/// `@tls`, `@socket`, `@fs` and `@process`.

///|
struct E2ePki {
  dir : String
  ca_file : String
  leaf_cert : String
  leaf_key : String
  leaf_sha : String
  other_ca_file : String
  other_leaf_sha : String
}

///|
async fn e2e_run(dir : String, script : String) -> Unit {
  let collected = @process.collect_output("sh", ["-c", script], cwd=dir) catch {
    error => {
      let _ = error
      fail("cannot run openssl")
    }
  }
  let (code, _stdout, stderr) = collected
  if code != 0 {
    let message = stderr.text() catch { _ => "openssl failed" }
    assert_true(false)
    fail("openssl failed: " + message)
  }
}

///|
async fn e2e_make_pki() -> E2ePki {
  let dir = @fs.tmpdir(prefix="monexus-transport-e2e-")
  let script = "set -e\n" +
    "umask 077\n" +
    "openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 2 -keyout ca.key -out ca.pem -subj '/CN=MoNexus Test CA' -addext 'basicConstraints=critical,CA:TRUE' 2>/dev/null\n" +
    "openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 2 -keyout other-ca.key -out other-ca.pem -subj '/CN=Other Test CA' -addext 'basicConstraints=critical,CA:TRUE' 2>/dev/null\n" +
    "openssl req -newkey rsa:2048 -nodes -sha256 -keyout leaf.key -out leaf.csr -subj '/CN=localhost' 2>/dev/null\n" +
    "printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\\nextendedKeyUsage=serverAuth\\n' > leaf.ext\n" +
    "openssl x509 -req -sha256 -days 2 -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out leaf.pem -extfile leaf.ext 2>/dev/null\n" +
    "openssl req -newkey rsa:2048 -nodes -sha256 -keyout other-leaf.key -out other-leaf.csr -subj '/CN=localhost' 2>/dev/null\n" +
    "printf 'subjectAltName=DNS:localhost,IP:127.0.0.1\\nextendedKeyUsage=serverAuth\\n' > other-leaf.ext\n" +
    "openssl x509 -req -sha256 -days 2 -in other-leaf.csr -CA other-ca.pem -CAkey other-ca.key -CAcreateserial -out other-leaf.pem -extfile other-leaf.ext 2>/dev/null\n" +
    "openssl x509 -in leaf.pem -outform DER -out leaf.der\n" +
    "openssl x509 -in other-leaf.pem -outform DER -out other-leaf.der\n" +
    "chmod 600 ca.key other-ca.key leaf.key other-leaf.key ca.pem other-ca.pem leaf.pem other-leaf.pem\n"
  e2e_run(dir, script)
  let leaf_der = @fs.read_file(dir + "/leaf.der") catch { _ => fail("read leaf der") }
  let other_der = @fs.read_file(dir + "/other-leaf.der") catch {
    _ => fail("read other leaf der")
  }
  {
    dir,
    ca_file: dir + "/ca.pem",
    leaf_cert: dir + "/leaf.pem",
    leaf_key: dir + "/leaf.key",
    leaf_sha: certificate_fingerprint(leaf_der.binary().exact_view()),
    other_ca_file: dir + "/other-ca.pem",
    other_leaf_sha: certificate_fingerprint(other_der.binary().exact_view()),
  }
}

///|
fn e2e_client_config(
  pki : E2ePki,
  port : Int,
  expected_leaf_sha256 : String,
) -> TlsClientConfig {
  TlsClientConfig::new(
    host="127.0.0.1",
    port=port,
    ca_certificate_file=pki.ca_file,
    expected_leaf_sha256=expected_leaf_sha256,
    server_name="localhost",
  )
}

///|
async fn e2e_connect(config : TlsClientConfig) -> TlsStream {
  let attempted = @async.with_timeout_opt(10_000, () => {
    config.connect_pinned()
  })
  match attempted {
    None => {
      assert_true(false)
      fail("pinned TLS connect timed out")
    }
    Some(Ok(value)) => value
    Some(Err(message)) => {
      assert_true(false)
      fail("pinned TLS connect failed: " + message)
    }
  }
}

///|
async fn e2e_raw_tls(
  pki : E2ePki,
  port : Int,
  expected_leaf_sha256 : String,
) -> (@tls.Tls, @socket.Tcp) {
  let addr = @socket.Addr::parse("127.0.0.1:" + port.to_string()) catch {
    _ => fail("invalid test address")
  }
  let tcp = @socket.Tcp::connect(addr) catch {
    _ => fail("cannot connect test client")
  }
  let handshake = @async.with_timeout_opt(10_000, () => {
    let tls = @tls.Tls::client(
      tcp,
      host="localhost",
      trust=@tls.TrustedRoot::CustomPemFile(pki.ca_file),
    ) catch {
      error => return Err(safe_error(error))
    }
    Ok(tls)
  })
  let tls = match handshake {
    None => {
      tcp.close()
      fail("raw TLS handshake timed out")
    }
    Some(Err(message)) => {
      tcp.close()
      fail("raw TLS handshake failed: " + message)
    }
    Some(Ok(value)) => value
  }
  match verify_peer_pin(tls, expected_leaf_sha256) {
    Ok(_) => ()
    Err(message) => {
      tls.close()
      tcp.close()
      fail("raw TLS pin failed: " + message)
    }
  }
  (tls, tcp)
}

///|
fn e2e_params(entries : Array[(String, @json.Json)]) -> Map[String, @json.Json] {
  let params : Map[String, @json.Json] = Map([])
  for entry in entries {
    params.set(entry.0, entry.1)
  }
  params
}

///|
fn e2e_pair_params(code : String, runtime_id : String) -> Map[String, @json.Json] {
  e2e_params([
    ("pairing_code", @contracts.json_string(code)),
    ("runtime_id", @contracts.json_string(runtime_id)),
    ("protocol_version", @contracts.json_int(PROTOCOL_VERSION)),
    ("capabilities", @contracts.json_string_array([])),
  ])
}

///|
fn e2e_hello_params(
  runtime_id : String,
  token : String,
  protocol_version : Int,
  last_ack_cursor : Int64,
) -> Map[String, @json.Json] {
  e2e_params([
    ("runtime_id", @contracts.json_string(runtime_id)),
    ("token", @contracts.json_string(token)),
    ("protocol_version", @contracts.json_int(protocol_version)),
    ("last_ack_cursor", @contracts.json_int64(last_ack_cursor)),
  ])
}

///|
async fn e2e_request(
  stream : TlsStream,
  id : String,
  rpc_method : String,
  params : Map[String, @json.Json],
) -> @contracts.RpcResponse {
  let request = @contracts.RpcRequest::new(id, rpc_method, params)
  let exchanged = @async.with_timeout_opt(10_000, () => {
    stream.write(request.to_json()) catch {
      error => return Err("request write failed: " + safe_error(error))
    }
    let frame = stream.read() catch {
      error => return Err("response read failed: " + safe_error(error))
    }
    Ok(frame)
  })
  let frame = match exchanged {
    None => fail("request timed out: " + id + " " + rpc_method)
    Some(Ok(value)) => value
    Some(Err(message)) => fail(message)
  }
  match @contracts.parse_response(frame) {
    Ok(value) => value
    Err(message) => fail("invalid response frame: " + safe_detail(message))
  }
}

///|
async fn e2e_expect_error(response : @contracts.RpcResponse, code : Int) -> String {
  match response.error {
    Some(error) => {
      assert_eq(error.code, code)
      error.message
    }
    None => {
      assert_true(false)
      fail("expected JSON-RPC error " + code.to_string())
    }
  }
}

///|
async fn e2e_result_object(response : @contracts.RpcResponse) -> Map[String, @json.Json] {
  match response.result {
    Some(value) =>
      match @contracts.as_object(value) {
        Some(object) => object
        None => {
          assert_true(false)
          fail("result is not an object")
        }
      }
    None => {
      assert_true(false)
      fail("response has no result")
    }
  }
}

///|
async fn e2e_result_credential(response : @contracts.RpcResponse) -> String {
  let object = e2e_result_object(response)
  let credential = @contracts.string_field_or(object, "credential", "")
  if !is_hex_of_length(credential, CREDENTIAL_HEX_LEN) {
    assert_true(false)
    fail("result has no valid credential")
  }
  credential
}

///|
///|
async fn e2e_send_hello(
  config : TlsClientConfig,
  runtime_id : String,
  token : String,
  protocol_version : Int,
  last_ack_cursor : Int64,
) -> TlsStream {
  let stream = e2e_connect(config)
  let response = e2e_request(
    stream,
    "hello-1",
    METHOD_HELLO,
    e2e_hello_params(runtime_id, token, protocol_version, last_ack_cursor),
  )
  let object = e2e_result_object(response)
  if @contracts.string_field_or(object, "session_id", "") == "" {
    stream.close()
    assert_true(false)
    fail("hello did not open a session")
  }
  stream
}

///|
async fn e2e_with_primary(
  pki : E2ePki,
  store : StateStore,
  policy : CredentialPolicy,
  heartbeat_interval_ms : Int64,
  heartbeat_max_missed : Int,
  handlers : HandlerRegistry,
  body : async (PrimaryServer) -> Unit,
) -> Unit {
  let tls = TlsServerConfig::new(
    bind_host="127.0.0.1",
    bind_port=0,
    certificate_file=pki.leaf_cert,
    private_key_file=pki.leaf_key,
    handshake_timeout_ms=5_000L,
  )
  let config = ServerConfig::new(
    tls=tls,
    policy=policy,
    heartbeat_interval_ms=heartbeat_interval_ms,
    heartbeat_max_missed=heartbeat_max_missed,
    hello_timeout_ms=5_000L,
  )
  let server = match PrimaryServer::open(config, store, handlers) {
    Ok(value) => value
    Err(message) => {
      assert_true(false)
      fail("cannot open primary server: " + message)
    }
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => server.run())
    defer server.close()
    body(server)
  })
}

///|
async test "pairing, JSON-RPC session, rotation and revocation over pinned TLS" {
  let pki = e2e_make_pki()
  defer @fs.rmdir(pki.dir, recursive=true)
  let calls : Ref[Int] = Ref(0)
  let handlers = HandlerRegistry::new()
  let registered = handlers.register("demo.echo", async fn(request) {
    calls.val = calls.val + 1
    let value = match request.params.get("value") {
      Some(value) => value
      None => @contracts.json_null()
    }
    Ok(@contracts.json_object([
      ("echo", value),
      ("client_request_id", @contracts.json_string(request.client_request_id)),
    ]))
  })
  match registered {
    Ok(_) => ()
    Err(_) => fail("cannot register test handler")
  }
  e2e_with_primary(
    pki,
    StateStore::memory(),
    CredentialPolicy::until_revoked(),
    5_000L,
    3,
    handlers,
    async fn(server) {
      let port = server.port()
      let state = server.primary_state()
      let client = e2e_client_config(pki, port, pki.leaf_sha)
      let secret = match state.create_pairing_code() {
        Ok(value) => value
        Err(_) => fail("cannot create pairing code")
      }
      // Pairing succeeds through the node client and persists a 0600 token.
      let token_path = pki.dir + "/node-token"
      let node = NodeConfig::new(
        runtime_id="rt-e2e",
        tls=client,
        token_file=Some(token_path),
      )
      let paired = @async.with_timeout_opt(5_000, () => {
        pair_with_primary(node, secret.code)
      })
      let grant = match paired {
        None => fail("pairing timed out")
        Some(Ok(value)) => value
        Some(Err(_)) => fail("pairing failed")
      }
      assert_eq(grant.runtime_id, "rt-e2e")
      assert_true(is_hex_of_length(grant.credential, CREDENTIAL_HEX_LEN))
      assert_true(grant.expires_at_ms is None)
      assert_eq(grant.protocol_version, PROTOCOL_VERSION)
      match stat_path(token_path) {
        Some(info) => assert_eq(info.mode & 0o777, 0o600)
        None => assert_true(false)
      }
      // A consumed code and a wrong code get the same uniform rejection.
      let consumed_stream = e2e_connect(client)
      let consumed = e2e_request(
        consumed_stream,
        "p2",
        METHOD_PAIR,
        e2e_pair_params(secret.code, "rt-e2e"),
      )
      let consumed_message = e2e_expect_error(consumed, ERR_PAIRING_REJECTED)
      consumed_stream.close()
      let wrong_stream = e2e_connect(client)
      let wrong = e2e_request(
        wrong_stream,
        "p3",
        METHOD_PAIR,
        e2e_pair_params("00000000000000000000000000000000", "rt-e2e"),
      )
      let wrong_message = e2e_expect_error(wrong, ERR_PAIRING_REJECTED)
      wrong_stream.close()
      assert_eq(consumed_message, "pairing rejected")
      assert_eq(wrong_message, consumed_message)
      // A request before hello is unauthorized and closes the connection.
      let unauth_stream = e2e_connect(client)
      let unauth = e2e_request(
        unauth_stream,
        "u1",
        METHOD_HEARTBEAT,
        Map([]),
      )
      let _ = e2e_expect_error(unauth, ERR_UNAUTHORIZED)
      unauth_stream.close()
      // A mismatched protocol version is refused before any state changes.
      let version_stream = e2e_connect(client)
      let version = e2e_request(
        version_stream,
        "v1",
        METHOD_HELLO,
        e2e_hello_params("rt-e2e", grant.credential, 2, 0L),
      )
      let _ = e2e_expect_error(version, ERR_UNSUPPORTED_VERSION)
      version_stream.close()
      // A valid hello opens a session and reports cursor state.
      let stream = e2e_connect(client)
      let hello = e2e_request(
        stream,
        "h1",
        METHOD_HELLO,
        e2e_hello_params("rt-e2e", grant.credential, PROTOCOL_VERSION, 0L),
      )
      let hello_object = e2e_result_object(hello)
      assert_eq(@contracts.string_field_or(hello_object, "runtime_id", ""), "rt-e2e")
      assert_true(
        @contracts.string_field_or(hello_object, "session_id", "").length() == 16,
      )
      assert_eq(@contracts.int64_field_or(hello_object, "resume_cursor", -1L), 0L)
      assert_eq(@contracts.bool_field_or(hello_object, "gap", true), false)
      assert_eq(
        @contracts.int64_field_or(hello_object, "heartbeat_interval_ms", 0L),
        5_000L,
      )
      // Unknown methods return the stable -32601 code.
      let unknown = e2e_request(stream, "m1", "demo.missing", Map([]))
      let _ = e2e_expect_error(unknown, @contracts.ERR_METHOD_NOT_FOUND)
      // client_request_id makes a retry idempotent: one execution, same result.
      let echo_params = e2e_params([
        ("client_request_id", @contracts.json_string("echo-1")),
        ("value", @contracts.json_string("hello")),
      ])
      let first = e2e_request(stream, "e1", "demo.echo", echo_params)
      let second = e2e_request(stream, "e2", "demo.echo", echo_params)
      assert_eq(calls.val, 1)
      assert_eq(
        first.result.unwrap_or(@contracts.json_null()).stringify(),
        second.result.unwrap_or(@contracts.json_null()).stringify(),
      )
      // Heartbeats are ordinary requests and notifications.
      let beat = e2e_request(stream, "hb-1", METHOD_HEARTBEAT, Map([]))
      let beat_object = e2e_result_object(beat)
      assert_eq(@contracts.int64_field_or(beat_object, "ack_cursor", -1L), 0L)
      let notification = @contracts.RpcNotification::new(METHOD_HEARTBEAT, Map([]))
      stream.write(notification.to_json()) catch {
        _ => fail("heartbeat notification write failed")
      }
      let ack_frame = stream.read() catch { _ => fail("ack read failed") }
      let ack = match @contracts.parse_notification(ack_frame) {
        Ok(value) => value
        Err(_) => fail("ack is not a notification")
      }
      assert_eq(ack.method, METHOD_ACK)
      assert_eq(@contracts.int64_field_or(ack.params, "cursor", -1L), 0L)
      // Rotation issues a new credential and closes the old session.
      let rotate = e2e_request(
        stream,
        "r1",
        METHOD_ROTATE,
        e2e_params([("token", @contracts.json_string(grant.credential))]),
      )
      let rotated_credential = e2e_result_credential(rotate)
      assert_true(rotated_credential != grant.credential)
      let after_rotate = e2e_request(stream, "hb-2", METHOD_HEARTBEAT, Map([]))
      let _ = e2e_expect_error(after_rotate, ERR_REVOKED)
      stream.close()
      // The old token is revoked; the new one authenticates.
      let old_token_stream = e2e_connect(client)
      let old_hello = e2e_request(
        old_token_stream,
        "h2",
        METHOD_HELLO,
        e2e_hello_params("rt-e2e", grant.credential, PROTOCOL_VERSION, 0L),
      )
      let _ = e2e_expect_error(old_hello, ERR_REVOKED)
      old_token_stream.close()
      let session_stream = e2e_send_hello(
        client,
        "rt-e2e",
        rotated_credential,
        PROTOCOL_VERSION,
        0L,
      )
      // Revocation closes a live session at its next frame.
      let _ = state.revoke("rt-e2e", "test")
      let revoked = e2e_request(session_stream, "hb-3", METHOD_HEARTBEAT, Map([]))
      let _ = e2e_expect_error(revoked, ERR_REVOKED)
      session_stream.close()
      let revoked_hello_stream = e2e_connect(client)
      let revoked_hello = e2e_request(
        revoked_hello_stream,
        "h3",
        METHOD_HELLO,
        e2e_hello_params("rt-e2e", rotated_credential, PROTOCOL_VERSION, 0L),
      )
      let _ = e2e_expect_error(revoked_hello, ERR_REVOKED)
      revoked_hello_stream.close()
      // A trustworthy CA with the wrong leaf pin fails closed after handshake.
      let wrong_leaf = e2e_client_config(pki, port, pki.other_leaf_sha)
      match wrong_leaf.connect_pinned() {
        Ok(stream) => {
          stream.close()
          assert_true(false)
        }
        Err(message) => assert_true(message.contains("pin"))
      }
      // An unrelated CA cannot even complete the handshake.
      let wrong_ca = TlsClientConfig::new(
        host="127.0.0.1",
        port=port,
        ca_certificate_file=pki.other_ca_file,
        expected_leaf_sha256=pki.leaf_sha,
        server_name="localhost",
      )
      match wrong_ca.connect_pinned() {
        Ok(stream) => {
          stream.close()
          assert_true(false)
        }
        Err(_) => assert_true(true)
      }
      // Plain TCP bytes are never accepted as a frame.
      let addr = @socket.Addr::parse("127.0.0.1:" + port.to_string()) catch {
        _ => fail("invalid plaintext test address")
      }
      let plain = @socket.Tcp::connect(addr) catch {
        _ => fail("cannot connect plaintext test client")
      }
      let plain_frame = @contracts.RpcRequest::new(
        "plain-1",
        METHOD_HEARTBEAT,
        Map([]),
      ).to_json().stringify()
      plain.write(@utf8.encode(plain_frame)) catch { _ => () }
      let plain_read = @async.with_timeout_opt(2_000, () => {
        let chunk = plain.read_some() catch { _ => return None }
        chunk
      })
      match plain_read {
        None => assert_true(true)
        Some(None) => assert_true(true)
        Some(Some(bytes)) => {
          let text = @utf8.decode(bytes.exact_view()) catch { _ => "" }
          assert_true(!text.contains("jsonrpc"))
        }
      }
      plain.close()
      // A frame header above 64 KiB is rejected and the connection closed.
      let (raw_tls, raw_tcp) = e2e_raw_tls(pki, port, pki.leaf_sha)
      let oversized = MAX_FRAME_BYTES + 1
      let header = Bytes::makei(4, index => {
        ((oversized >> ((3 - index) * 8)) & 0xff).to_byte()
      })
      raw_tls.write(header) catch { _ => () }
      let oversize_read = @async.with_timeout_opt(2_000, () => {
        let chunk = raw_tls.read_some() catch { _ => return None }
        chunk
      })
      match oversize_read {
        None => assert_true(true)
        Some(None) => assert_true(true)
        Some(Some(_)) => assert_true(false)
      }
      raw_tls.close()
      raw_tcp.close()
      // TLS still works after the rejected/plaintext connections.
      let final_stream = e2e_connect(client)
      final_stream.close()
      // Audit and logs never contain a pairing code or a plaintext credential.
      let audit = state.audit_text()
      let logs = state.logs().join("\n")
      assert_true(!audit.contains(secret.code))
      assert_true(!audit.contains(grant.credential))
      assert_true(!audit.contains(rotated_credential))
      assert_true(!logs.contains(secret.code))
      assert_true(!logs.contains(grant.credential))
      assert_true(!logs.contains(rotated_credential))
    },
  )
}

///|
async fn e2e_pair_raw(
  client : TlsClientConfig,
  code : String,
  runtime_id : String,
) -> String {
  let stream = e2e_connect(client)
  let response = e2e_request(
    stream,
    "pair-init",
    METHOD_PAIR,
    e2e_pair_params(code, runtime_id),
  )
  let credential = e2e_result_credential(response)
  stream.close()
  credential
}

///|
fn e2e_session_details(state : PrimaryState) -> Array[String] {
  let details : Array[String] = []
  for event in state.audit_events() {
    match @contracts.as_object(event) {
      Some(object) =>
        if @contracts.string_field_or(object, "action", "") ==
          "runtime.session_opened" {
          details.push(@contracts.string_field_or(object, "detail", ""))
        }
      None => ()
    }
  }
  details
}

///|
async fn e2e_wait_for(
  condition : () -> Bool,
  timeout_ms : Int32,
) -> Bool {
  let deadline = @async.now() + timeout_ms.to_int64()
  while !condition() && @async.now() < deadline {
    @async.sleep(10)
  }
  condition()
}

///|
async test "pairing expiry and per-source pairing/auth rate limits over TLS" {
  let pki = e2e_make_pki()
  defer @fs.rmdir(pki.dir, recursive=true)
  let handlers = HandlerRegistry::new()
  // A pairing record that expired before the server opened. The snapshot
  // holds only the code hash, exactly as the file store would.
  let expired_code = "11111111111111111111111111111111"
  let now = @async.now()
  let store = StateStore::memory()
  let snapshot = StateSnapshot::empty()
  snapshot.pairings.push({
    code_id: "0011223344556677",
    code_hash: sha256_text(expired_code),
    created_at_ms: now - 900_000L,
    expires_at_ms: now - 1_000L,
    used: false,
  })
  match (store.save)(snapshot) {
    Ok(_) => ()
    Err(_) => fail("cannot seed state store")
  }
  e2e_with_primary(
    pki,
    store,
    CredentialPolicy::until_revoked(),
    5_000L,
    3,
    handlers,
    async fn(server) {
      let port = server.port()
      let state = server.primary_state()
      let client = e2e_client_config(pki, port, pki.leaf_sha)
      let expired_stream = e2e_connect(client)
      let expired = e2e_request(
        expired_stream,
        "x1",
        METHOD_PAIR,
        e2e_pair_params(expired_code, "rt-expired"),
      )
      let _ = e2e_expect_error(expired, ERR_PAIRING_REJECTED)
      expired_stream.close()
      // The expired attempt consumed one pairing budget for this source. Four
      // more rejections exhaust it; a fresh valid code is then rate limited.
      for _i = 0; _i < PAIRING_PER_SOURCE_LIMIT - 1; _i = _i + 1 {
        let stream = e2e_connect(client)
        let response = e2e_request(
          stream,
          "x2",
          METHOD_PAIR,
          e2e_pair_params("22222222222222222222222222222222", "rt-limit"),
        )
        let _ = e2e_expect_error(response, ERR_PAIRING_REJECTED)
        stream.close()
      }
      let valid = match state.create_pairing_code() {
        Ok(value) => value
        Err(_) => fail("cannot create pairing code")
      }
      let blocked_stream = e2e_connect(client)
      let blocked = e2e_request(
        blocked_stream,
        "x3",
        METHOD_PAIR,
        e2e_pair_params(valid.code, "rt-limit"),
      )
      let _ = e2e_expect_error(blocked, ERR_BUSY)
      blocked_stream.close()
    },
  )
  // Authentication budget: ten wrong bearer attempts exhaust the per-source
  // budget, and a valid retry is still refused. (The global budget is covered
  // by the unit tests, which can use distinct source keys.)
  e2e_with_primary(
    pki,
    StateStore::memory(),
    CredentialPolicy::until_revoked(),
    5_000L,
    3,
    handlers,
    async fn(server) {
      let port = server.port()
      let state = server.primary_state()
      let client = e2e_client_config(pki, port, pki.leaf_sha)
      let secret = match state.create_pairing_code() {
        Ok(value) => value
        Err(_) => fail("cannot create pairing code")
      }
      let credential = e2e_pair_raw(client, secret.code, "rt-auth")
      let wrong_token = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      for _i = 0; _i < AUTH_PER_SOURCE_LIMIT; _i = _i + 1 {
        let stream = e2e_connect(client)
        let response = e2e_request(
          stream,
          "bad-hello",
          METHOD_HELLO,
          e2e_hello_params("rt-auth", wrong_token, PROTOCOL_VERSION, 0L),
        )
        let _ = e2e_expect_error(response, ERR_UNAUTHORIZED)
        stream.close()
      }
      let blocked_stream = e2e_connect(client)
      let blocked = e2e_request(
        blocked_stream,
        "good-hello",
        METHOD_HELLO,
        e2e_hello_params("rt-auth", credential, PROTOCOL_VERSION, 0L),
      )
      let _ = e2e_expect_error(blocked, ERR_BUSY)
      blocked_stream.close()
      assert_true(!state.audit_text().contains(secret.code))
      assert_true(!state.audit_text().contains(credential))
    },
  )
}

///|
async test "heartbeat timeout, reconnect with cursor resume and drain" {
  let pki = e2e_make_pki()
  defer @fs.rmdir(pki.dir, recursive=true)
  let handlers = HandlerRegistry::new()
  // The server times out an authenticated connection after 100 ms of silence.
  // The node heartbeats every 500 ms in the reconnect scenario, so the server
  // deterministically drops each connection and the node reconnects.
  e2e_with_primary(
    pki,
    StateStore::memory(),
    CredentialPolicy::until_revoked(),
    100L,
    1,
    handlers,
    async fn(server) {
      let port = server.port()
      let state = server.primary_state()
      let client = e2e_client_config(pki, port, pki.leaf_sha)
      let secret = match state.create_pairing_code() {
        Ok(value) => value
        Err(_) => fail("cannot create pairing code")
      }
      let silent_credential = e2e_pair_raw(client, secret.code, "rt-silent")
      let silent = e2e_send_hello(
        client,
        "rt-silent",
        silent_credential,
        PROTOCOL_VERSION,
        0L,
      )
      let started = @async.now()
      let timed_out = @async.with_timeout_opt(3_000, () => {
        let frame = silent.read() catch { _ => return None }
        Some(frame)
      })
      let elapsed = @async.now() - started
      match timed_out {
        Some(None) => assert_true(elapsed >= 50L)
        _ => assert_true(false)
      }
      silent.close()
      // Reconnect scenario with a durable outbox cursor.
      let secret2 = match state.create_pairing_code() {
        Ok(value) => value
        Err(_) => fail("cannot create pairing code")
      }
      let node_credential = e2e_pair_raw(client, secret2.code, "rt-node")
      let delivered : Ref[Int64] = Ref(0L)
      let events : Array[OutboxEvent] = [
        {
          seq: 1L,
          run_id: "run-1",
          run_seq: 1L,
          kind: "chunk",
          ts: wire_ts(0L),
          payload: @contracts.json_string("a"),
        },
        {
          seq: 2L,
          run_id: "run-1",
          run_seq: 2L,
          kind: "chunk",
          ts: wire_ts(0L),
          payload: @contracts.json_string("b"),
        },
        {
          seq: 3L,
          run_id: "run-1",
          run_seq: 3L,
          kind: "chunk",
          ts: wire_ts(0L),
          payload: @contracts.json_string("c"),
        },
      ]
      let outbox = OutboxPort::new(
        pending=async fn(after_cursor, limit) {
          let pending : Array[OutboxEvent] = []
          for event in events {
            if event.seq > after_cursor && pending.length() < limit {
              pending.push(event)
            }
          }
          Ok(pending)
        },
        ack_through=async fn(cursor) {
          delivered.val = cursor
          Ok(())
        },
        cursor=() => delivered.val,
      )
      let node = NodeConfig::new(
        runtime_id="rt-node",
        tls=client,
        heartbeat_interval_ms=500L,
        poll_timeout_ms=20L,
        backoff_base_ms=50L,
        backoff_cap_ms=200L,
        jitter_ms=0L,
        max_attempts=8,
      )
      let outcome : Ref[NodeRunOutcome?] = Ref(None)
      @async.with_task_group(group => {
        group.spawn_bg(() => {
          outcome.val = Some(node_run(node, node_credential, outbox))
        })
        let ready = e2e_wait_for(() => {
          delivered.val == 3L && e2e_session_details(state).length() >= 2
        }, 15_000)
        assert_true(ready)
        // Resume at the JSON level: hello with the durable cursor reports it
        // back and no gap, because the primary stored the same cursor.
        let resume_stream = e2e_connect(client)
        let resume_hello = e2e_request(
          resume_stream,
          "h-resume",
          METHOD_HELLO,
          e2e_hello_params("rt-node", node_credential, PROTOCOL_VERSION, 3L),
        )
        let resume_object = e2e_result_object(resume_hello)
        assert_eq(
          @contracts.int64_field_or(resume_object, "resume_cursor", -1L),
          3L,
        )
        assert_eq(
          @contracts.bool_field_or(resume_object, "gap", true),
          false,
        )
        let bye = e2e_request(resume_stream, "b-resume", METHOD_BYE, Map([]))
        assert_true(bye.error is None)
        resume_stream.close()
        server.drain()
        let done = e2e_wait_for(() => outcome.val is Some(_), 15_000)
        assert_true(done)
        match outcome.val {
          Some(NodeRunOutcome::Drained) => assert_true(true)
          Some(_) => assert_true(false)
          None => assert_true(false)
        }
      })
      assert_eq(delivered.val, 3L)
      assert_eq(state.cursor_for("rt-node"), 3L)
      // At least two sessions for the node: the first attempt and at least one
      // reconnect. The audit detail is redacted after `session_id`, so the
      // resumed cursor itself is asserted through the hello response above.
      let details = e2e_session_details(state)
      assert_true(details.length() >= 2)
      assert_true(details[details.length() - 1].contains("session_id="))
    },
  )
}

///|
async test "fixed lifetime, re-pair revocation and file-backed state" {
  let pki = e2e_make_pki()
  defer @fs.rmdir(pki.dir, recursive=true)
  let state_dir = @fs.tmpdir(prefix="monexus-transport-e2e-state-")
  defer @fs.rmdir(state_dir, recursive=true)
  // Seed a credential that already expired; only its hash is on disk.
  let expired_token = "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  let now = @async.now()
  let snapshot = StateSnapshot::empty()
  snapshot.credentials.push({
    runtime_id: "rt-lifetime",
    credential_id: "8899aabbccddeeff",
    token_hash: sha256_text(expired_token),
    generation: 1,
    issued_at_ms: now - 10_000L,
    expires_at_ms: Some(now - 1_000L),
    revoked: false,
    capabilities: [],
  })
  @fs.write_file(
    state_dir + "/transport-state.json",
    snapshot.to_json().stringify(),
    permission=0o600,
  ) catch {
    _ => fail("cannot seed state file")
  }
  @fs.chmod(state_dir, 0o700) catch { _ => () }
  let store = match StateStore::open(state_dir) {
    Ok(value) => value
    Err(_) => fail("cannot open state store")
  }
  let policy = match CredentialPolicy::fixed(10_000L) {
    Ok(value) => value
    Err(_) => fail("invalid credential policy")
  }
  let handlers = HandlerRegistry::new()
  e2e_with_primary(
    pki,
    store,
    policy,
    5_000L,
    3,
    handlers,
    async fn(server) {
      let port = server.port()
      let state = server.primary_state()
      let client = e2e_client_config(pki, port, pki.leaf_sha)
      // An expired credential authenticates as revoked and must re-pair.
      let expired_stream = e2e_connect(client)
      let expired_hello = e2e_request(
        expired_stream,
        "h-expired",
        METHOD_HELLO,
        e2e_hello_params(
          "rt-lifetime",
          expired_token,
          PROTOCOL_VERSION,
          0L,
        ),
      )
      let _ = e2e_expect_error(expired_hello, ERR_REVOKED)
      expired_stream.close()
      let secret1 = match state.create_pairing_code() {
        Ok(value) => value
        Err(_) => fail("cannot create pairing code")
      }
      let node = NodeConfig::new(runtime_id="rt-lifetime", tls=client)
      let grant1 = match pair_with_primary(node, secret1.code) {
        Ok(value) => value
        Err(_) => fail("re-pair after expiry failed")
      }
      assert_true(grant1.expires_at_ms is Some(_))
      let session1 = e2e_send_hello(
        client,
        "rt-lifetime",
        grant1.credential,
        PROTOCOL_VERSION,
        0L,
      )
      let bye1 = e2e_request(session1, "b1", METHOD_BYE, Map([]))
      assert_true(bye1.error is None)
      session1.close()
      // Pairing again for the same runtime revokes the previous credential.
      let secret2 = match state.create_pairing_code() {
        Ok(value) => value
        Err(_) => fail("cannot create pairing code")
      }
      let grant2 = match pair_with_primary(node, secret2.code) {
        Ok(value) => value
        Err(_) => fail("second pairing failed")
      }
      assert_true(grant2.credential != grant1.credential)
      assert_eq(grant2.generation, grant1.generation + 1)
      let old_stream = e2e_connect(client)
      let old_hello = e2e_request(
        old_stream,
        "h-old",
        METHOD_HELLO,
        e2e_hello_params(
          "rt-lifetime",
          grant1.credential,
          PROTOCOL_VERSION,
          0L,
        ),
      )
      let _ = e2e_expect_error(old_hello, ERR_REVOKED)
      old_stream.close()
      let session2 = e2e_send_hello(
        client,
        "rt-lifetime",
        grant2.credential,
        PROTOCOL_VERSION,
        0L,
      )
      let bye2 = e2e_request(session2, "b2", METHOD_BYE, Map([]))
      assert_true(bye2.error is None)
      session2.close()
      // File-backed state is 0600 in a 0700 directory and stores hashes only.
      let state_file = state_dir + "/transport-state.json"
      match stat_path(state_dir) {
        Some(info) => assert_eq(info.mode & 0o777, 0o700)
        None => assert_true(false)
      }
      match stat_path(state_file) {
        Some(info) => assert_eq(info.mode & 0o777, 0o600)
        None => assert_true(false)
      }
      let text = @fs.read_file(state_file).text() catch {
        _ => fail("cannot read state file")
      }
      assert_true(text.contains(sha256_text(grant2.credential)))
      assert_true(!text.contains(grant2.credential))
      assert_true(!text.contains(grant1.credential))
      assert_true(!text.contains(secret1.code))
      assert_true(!text.contains(secret2.code))
      assert_true(!text.contains(expired_token))
      let audit = state.audit_text()
      assert_true(!audit.contains(grant2.credential))
      assert_true(!audit.contains(secret1.code))
      assert_true(!audit.contains(expired_token))
    },
  )
}

///|
async test "node stops on revocation and bounds reconnect attempts" {
  let pki = e2e_make_pki()
  defer @fs.rmdir(pki.dir, recursive=true)
  let handlers = HandlerRegistry::new()
  e2e_with_primary(
    pki,
    StateStore::memory(),
    CredentialPolicy::until_revoked(),
    5_000L,
    3,
    handlers,
    async fn(server) {
      let port = server.port()
      let state = server.primary_state()
      let client = e2e_client_config(pki, port, pki.leaf_sha)
      let secret = match state.create_pairing_code() {
        Ok(value) => value
        Err(_) => fail("cannot create pairing code")
      }
      let credential = e2e_pair_raw(client, secret.code, "rt-stop")
      let node = NodeConfig::new(
        runtime_id="rt-stop",
        tls=client,
        heartbeat_interval_ms=100L,
        poll_timeout_ms=20L,
        backoff_base_ms=50L,
        backoff_cap_ms=200L,
        jitter_ms=0L,
        max_attempts=5,
      )
      // A wrong token is a uniform unauthorized and does not open a session.
      let wrong_token = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
      match connect_session(node, wrong_token, 0L) {
        Ok(_) => assert_true(false)
        Err(NodeUnauthorized) => assert_true(true)
        Err(_) => assert_true(false)
      }
      let outcome : Ref[NodeRunOutcome?] = Ref(None)
      @async.with_task_group(group => {
        group.spawn_bg(() => {
          outcome.val = Some(node_run(node, credential, OutboxPort::empty()))
        })
        let connected = e2e_wait_for(() => state.session_count() > 0, 5_000)
        assert_true(connected)
        let _ = state.revoke("rt-stop", "test")
        let stopped = e2e_wait_for(() => outcome.val is Some(_), 5_000)
        assert_true(stopped)
        match outcome.val {
          Some(NodeRunOutcome::Revoked) => assert_true(true)
          Some(_) => assert_true(false)
          None => assert_true(false)
        }
      })
    },
  )
  // An unreachable endpoint consumes the attempt budget and stops.
  let unreachable = NodeConfig::new(
    runtime_id="rt-stop",
    tls=e2e_client_config(pki, 1, pki.leaf_sha),
    heartbeat_interval_ms=100L,
    poll_timeout_ms=20L,
    backoff_base_ms=20L,
    backoff_cap_ms=50L,
    jitter_ms=0L,
    max_attempts=2,
  )
  let outcome = node_run(
    unreachable,
    "0000000000000000000000000000000000000000000000000000000000000000",
    OutboxPort::empty(),
  )
  match outcome {
    NodeRunOutcome::AttemptsExhausted(2) => assert_true(true)
    _ => assert_true(false)
  }
}

