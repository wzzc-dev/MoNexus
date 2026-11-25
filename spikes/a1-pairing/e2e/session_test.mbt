///|
/// Full primary/node flows over pinned loopback TLS: one-time pairing,
/// heartbeat, reconnect with the machine credential, revocation and rotation.
/// Only 127.0.0.1:0 listeners are used; the PKI lives in a temp dir and is
/// removed at the end of every test.

///|
async test "pair, heartbeat and HMAC reconnect over pinned TLS" {
  let pki = @transport.generate_test_pki()
  defer pki.cleanup()
  let server = @transport.tls_listen_localhost()
  defer server.close()
  let port = server.addr().port()
  let state = @protocol.PrimaryState::new("org_local")
  let (code, _code_id) = match
    state.create_pairing_code(@tls.rand_bytes(16), @tls.rand_bytes(8), @async.now()) {
    Ok(value) => value
    Err(message) => abort(message)
  }
  let runtime_id = "rt_e2e_hmac"
  let device_secret = @protocol.hex_of(@tls.rand_bytes(32).exact_view())
  let machine_key = match @protocol.machine_public_key(device_secret) {
    Ok(value) => value
    Err(message) => abort(message)
  }
  @async.with_timeout(20_000, () => @async.with_task_group(group => {
    group.spawn_bg(() => {
      serve_frames(server, pki, state, 4)
      serve_frames(server, pki, state, 4)
    })
    // First connection: pair, authenticate, heartbeat once.
    let (tls, tcp) = @transport.connect_pinned(
      port,
      pki.ca_cert,
      pki.leaf_fingerprint_sha256,
    )
    let hello = @protocol.hello_params(
      "pair-1",
      code,
      runtime_id,
      @protocol.PROTOCOL_VERSION,
      @protocol.default_capabilities(),
      machine_key,
      @protocol.hex_of(@tls.rand_bytes(16).exact_view()),
    )
    let grant_json = expect_result(
      rpc(tls, "pair-1", @protocol.METHOD_RUNTIME_PAIR, hello),
    )
    let grant = match @protocol.parse_pair_grant(grant_json) {
      Some(value) => value
      None => abort("pair grant did not parse")
    }
    assert_eq(grant.runtime_id, runtime_id)
    assert_eq(grant.generation, 1)
    assert_eq(grant.auth_mode.name(), "hmac-sha256")
    let session1 = hmac_auth(
      tls,
      "c1",
      runtime_id,
      grant.credential_id,
      grant.credential,
      @protocol.hex_of(@tls.rand_bytes(16).exact_view()),
    )
    assert_eq(session1.mode.name(), "hmac-sha256")
    assert_eq(session1.resume_from, 0L)
    let ack1_json = expect_result(
      rpc(
        tls,
        "hb-1",
        @protocol.METHOD_RUNTIME_HEARTBEAT,
        @protocol.heartbeat_params("hb-1", session1.session_id, 1L),
      ),
    )
    let ack1 = match @protocol.parse_heartbeat_ack(ack1_json) {
      Some(value) => value
      None => abort("heartbeat ack did not parse")
    }
    assert_eq(ack1.ack_seq, 1L)
    assert_false(ack1.duplicate)
    @transport.close_stream(tls, tcp)
    // Second connection: reconnect with the machine credential and resume.
    let (tls2, tcp2) = @transport.connect_pinned(
      port,
      pki.ca_cert,
      pki.leaf_fingerprint_sha256,
    )
    defer @transport.close_stream(tls2, tcp2)
    let session2 = hmac_auth(
      tls2,
      "c2",
      runtime_id,
      grant.credential_id,
      grant.credential,
      @protocol.hex_of(@tls.rand_bytes(16).exact_view()),
    )
    assert_eq(session2.resume_from, 1L)
    assert_true(session2.session_id != session1.session_id)
    let ack2_json = expect_result(
      rpc(
        tls2,
        "hb-2",
        @protocol.METHOD_RUNTIME_HEARTBEAT,
        @protocol.heartbeat_params("hb-2", session2.session_id, 2L),
      ),
    )
    let ack2 = match @protocol.parse_heartbeat_ack(ack2_json) {
      Some(value) => value
      None => abort("heartbeat ack did not parse")
    }
    assert_eq(ack2.ack_seq, 2L)
    // One-time pairing code: a second use is refused uniformly.
    let replay = rpc(tls2, "pair-2", @protocol.METHOD_RUNTIME_PAIR, hello)
    expect_error(replay, @contracts.ERR_HOST, "pairing rejected")
  }))
}

///|
async test "revocation invalidates the bearer credential over TLS" {
  let pki = @transport.generate_test_pki()
  defer pki.cleanup()
  let server = @transport.tls_listen_localhost()
  defer server.close()
  let port = server.addr().port()
  let state = @protocol.PrimaryState::new("org_local")
  let (code, _) = match
    state.create_pairing_code(@tls.rand_bytes(16), @tls.rand_bytes(8), @async.now()) {
    Ok(value) => value
    Err(message) => abort(message)
  }
  let runtime_id = "rt_e2e_bearer"
  let machine_key = match @protocol.machine_public_key(
    @protocol.hex_of(@tls.rand_bytes(32).exact_view()),
  ) {
    Ok(value) => value
    Err(message) => abort(message)
  }
  @async.with_timeout(20_000, () => @async.with_task_group(group => {
    group.spawn_bg(() => {
      serve_frames(server, pki, state, 3)
      serve_frames(server, pki, state, 2)
    })
    // Pairing without the HMAC capability selects bearer mode.
    let (tls, tcp) = @transport.connect_pinned(
      port,
      pki.ca_cert,
      pki.leaf_fingerprint_sha256,
    )
    let hello = @protocol.hello_params(
      "pair-1",
      code,
      runtime_id,
      @protocol.PROTOCOL_VERSION,
      [@protocol.CAPABILITY_HEARTBEAT],
      machine_key,
      @protocol.hex_of(@tls.rand_bytes(16).exact_view()),
    )
    let grant = match @protocol.parse_pair_grant(
      expect_result(rpc(tls, "pair-1", @protocol.METHOD_RUNTIME_PAIR, hello)),
    ) {
      Some(value) => value
      None => abort("pair grant did not parse")
    }
    assert_eq(grant.auth_mode.name(), "bearer")
    let session = bearer_auth(
      tls,
      "c1",
      runtime_id,
      grant.credential_id,
      grant.credential,
      @protocol.hex_of(@tls.rand_bytes(16).exact_view()),
    )
    assert_eq(session.mode.name(), "bearer")
    let _ = match
      @protocol.parse_heartbeat_ack(
        expect_result(
          rpc(
            tls,
            "hb-1",
            @protocol.METHOD_RUNTIME_HEARTBEAT,
            @protocol.heartbeat_params("hb-1", session.session_id, 3L),
          ),
        ),
      ) {
      Some(value) => value
      None => abort("heartbeat ack did not parse")
    }
    @transport.close_stream(tls, tcp)
    // Revoke while no connection is open, then try to reconnect.
    assert_true(state.revoke_runtime(runtime_id, "test revoke", @async.now()))
    let (tls2, tcp2) = @transport.connect_pinned(
      port,
      pki.ca_cert,
      pki.leaf_fingerprint_sha256,
    )
    defer @transport.close_stream(tls2, tcp2)
    let revoked_auth = rpc(
      tls2,
      "c2-auth",
      @protocol.METHOD_RUNTIME_AUTHENTICATE_BEARER,
      @protocol.bearer_auth_params(
        "c2-auth",
        runtime_id,
        grant.credential_id,
        grant.credential,
        @protocol.hex_of(@tls.rand_bytes(16).exact_view()),
      ),
    )
    expect_error(revoked_auth, @contracts.ERR_HOST, "unauthorized")
    let stale_heartbeat = rpc(
      tls2,
      "c2-hb",
      @protocol.METHOD_RUNTIME_HEARTBEAT,
      @protocol.heartbeat_params("c2-hb", session.session_id, 4L),
    )
    expect_error(stale_heartbeat, @contracts.ERR_HOST, "unauthorized")
  }))
}

///|
async test "rotation replaces the credential and keeps the runtime id" {
  let pki = @transport.generate_test_pki()
  defer pki.cleanup()
  let server = @transport.tls_listen_localhost()
  defer server.close()
  let port = server.addr().port()
  let state = @protocol.PrimaryState::new("org_local")
  let (code, _) = match
    state.create_pairing_code(@tls.rand_bytes(16), @tls.rand_bytes(8), @async.now()) {
    Ok(value) => value
    Err(message) => abort(message)
  }
  let runtime_id = "rt_e2e_rotate"
  let machine_key = match @protocol.machine_public_key(
    @protocol.hex_of(@tls.rand_bytes(32).exact_view()),
  ) {
    Ok(value) => value
    Err(message) => abort(message)
  }
  @async.with_timeout(20_000, () => @async.with_task_group(group => {
    group.spawn_bg(() => {
      serve_frames(server, pki, state, 4)
      serve_frames(server, pki, state, 3)
    })
    let (tls, tcp) = @transport.connect_pinned(
      port,
      pki.ca_cert,
      pki.leaf_fingerprint_sha256,
    )
    let hello = @protocol.hello_params(
      "pair-1",
      code,
      runtime_id,
      @protocol.PROTOCOL_VERSION,
      @protocol.default_capabilities(),
      machine_key,
      @protocol.hex_of(@tls.rand_bytes(16).exact_view()),
    )
    let grant = match @protocol.parse_pair_grant(
      expect_result(rpc(tls, "pair-1", @protocol.METHOD_RUNTIME_PAIR, hello)),
    ) {
      Some(value) => value
      None => abort("pair grant did not parse")
    }
    let session = hmac_auth(
      tls,
      "c1",
      runtime_id,
      grant.credential_id,
      grant.credential,
      @protocol.hex_of(@tls.rand_bytes(16).exact_view()),
    )
    let rotated = match @protocol.parse_pair_grant(
      expect_result(
        rpc(
          tls,
          "rotate-1",
          @protocol.METHOD_RUNTIME_ROTATE,
          @protocol.rotate_params("rotate-1", session.session_id),
        ),
      ),
    ) {
      Some(value) => value
      None => abort("rotation grant did not parse")
    }
    assert_eq(rotated.runtime_id, runtime_id)
    assert_eq(rotated.generation, 2)
    assert_true(rotated.credential_id != grant.credential_id)
    @transport.close_stream(tls, tcp)
    // Old credential is refused; new credential reconnects.
    let (tls2, tcp2) = @transport.connect_pinned(
      port,
      pki.ca_cert,
      pki.leaf_fingerprint_sha256,
    )
    defer @transport.close_stream(tls2, tcp2)
    let old_attempt = rpc(
      tls2,
      "old-challenge",
      @protocol.METHOD_RUNTIME_CHALLENGE,
      @protocol.challenge_params(
        "old-challenge",
        runtime_id,
        grant.credential_id,
      ),
    )
    expect_error(old_attempt, @contracts.ERR_HOST, "unauthorized")
    let session2 = hmac_auth(
      tls2,
      "new",
      runtime_id,
      rotated.credential_id,
      rotated.credential,
      @protocol.hex_of(@tls.rand_bytes(16).exact_view()),
    )
    assert_eq(session2.runtime_id, runtime_id)
    assert_eq(session2.mode.name(), "hmac-sha256")
  }))
}
