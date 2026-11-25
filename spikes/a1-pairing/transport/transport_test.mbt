///|
/// Loopback TLS tests. Every test binds 127.0.0.1:0 (ephemeral port), uses a
/// throwaway PKI generated inside `@fs.tmpdir`, and removes it afterwards.
/// No external network, no user credentials, no system trust store changes.

///|
async test "test PKI lives in a temp dir and is cleaned up" {
  let pki = generate_test_pki()
  assert_true(@fs.exists(pki.dir))
  assert_true(@fs.exists(pki.server_key))
  assert_true(@fs.exists(pki.server_cert))
  assert_true(@fs.exists(pki.other_ca_cert))
  assert_eq(pki.leaf_fingerprint_sha256.length(), 64)
  pki.cleanup()
  assert_false(@fs.exists(pki.dir))
}

///|
async test "pinned TLS loopback round-trips JSON-RPC frames" {
  let pki = generate_test_pki()
  defer pki.cleanup()
  let server = tls_listen_localhost()
  defer server.close()
  let port = server.addr().port()
  @async.with_timeout(10_000, () => @async.with_task_group(group => {
    group.spawn_bg(() => {
      let (tls, tcp, _) = accept_tls(server, pki)
      defer close_stream(tls, tcp)
      // Echo one request and one notification frame.
      for _ in 0..<2 {
        let frame = read_frame(tls)
        write_frame(tls, frame)
      }
    })
    let (client, client_tcp) = connect_pinned(
      port,
      pki.ca_cert,
      pki.leaf_fingerprint_sha256,
    )
    defer close_stream(client, client_tcp)
    let request = @json.parse(
      "{\"jsonrpc\":\"2.0\",\"id\":\"r-1\",\"method\":\"runtime.probe\",\"params\":{}}",
    )
    write_frame(client, request)
    let reply = read_frame(client)
    assert_true(reply.stringify().contains("\"id\":\"r-1\""))
    assert_true(reply.stringify().contains("runtime.probe"))
    // Notifications use the same envelope and the same framed channel.
    let notification = @contracts.RpcNotification::new(
      "runtime.progress",
      Map([("step", @contracts.json_string("pairing"))]),
    )
    write_frame(client, notification.to_json())
    let echoed = read_frame(client)
    match @contracts.parse_notification(echoed) {
      Ok(value) => assert_eq(value.method, "runtime.progress")
      Err(message) => abort("notification did not parse: " + message)
    }
  }))
}

///|
async test "wrong certificate pin fails closed before any payload" {
  let pki = generate_test_pki()
  defer pki.cleanup()
  let server = tls_listen_localhost()
  defer server.close()
  let port = server.addr().port()
  @async.with_timeout(10_000, () => @async.with_task_group(group => {
    // The server completes the handshake but must never receive a frame.
    group.spawn_bg(() => {
      let (tls, tcp, _) = accept_tls(server, pki)
      defer close_stream(tls, tcp)
      let _ = read_frame(tls)
    }, allow_failure=true)
    let wrong_pin = "0000000000000000000000000000000000000000000000000000000000000000"
    let failed = try {
      let _ = connect_pinned(port, pki.ca_cert, wrong_pin)
      false
    } catch {
      _ => true
    }
    assert_true(failed)
  }))
}

///|
async test "unrelated CA cannot complete the TLS handshake" {
  let pki = generate_test_pki()
  defer pki.cleanup()
  let server = tls_listen_localhost()
  defer server.close()
  let port = server.addr().port()
  @async.with_timeout(10_000, () => @async.with_task_group(group => {
    group.spawn_bg(() => {
      let (tls, tcp, _) = accept_tls(server, pki)
      defer close_stream(tls, tcp)
      let _ = read_frame(tls)
    }, allow_failure=true)
    let tcp = @socket.Tcp::connect(@socket.Addr::parse("127.0.0.1:\{port}"))
    let failed = try {
      let _ = @tls.Tls::client(
        tcp,
        host="localhost",
        trust=@tls.TrustedRoot::CustomPemFile(pki.other_ca_cert),
      )
      false
    } catch {
      _ => true
    }
    tcp.close()
    assert_true(failed)
  }))
}

///|
async test "plaintext client is rejected and gets no JSON response" {
  let pki = generate_test_pki()
  defer pki.cleanup()
  let server = tls_listen_localhost()
  defer server.close()
  let port = server.addr().port()
  @async.with_timeout(10_000, () => @async.with_task_group(group => {
    group.spawn_bg(() => {
      let (tls, tcp, _) = accept_tls(server, pki)
      defer close_stream(tls, tcp)
      let _ = read_frame(tls)
    }, allow_failure=true)
    let tcp = @socket.Tcp::connect(@socket.Addr::parse("127.0.0.1:\{port}"))
    defer tcp.close()
    // A plaintext JSON-RPC request, sent without a TLS handshake.
    let body = "{\"jsonrpc\":\"2.0\",\"id\":\"plain-1\",\"method\":\"runtime.probe\",\"params\":{}}"
    tcp.write(@utf8.encode(body).exact_view())
    let reply = tcp.read_some()
    let no_json = match reply {
      None => true
      Some(bytes) => {
        let text = @utf8.decode_lossy(bytes.exact_view())
        !text.contains("jsonrpc") && !text.contains("plain-1")
      }
    }
    assert_true(no_json)
  }))
}
