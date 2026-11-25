///|
/// Deterministic unit tests for the pairing/credential state machine. No
/// sockets, no clock reads: time and entropy are injected so the protocol
/// semantics can be asserted exactly.

///|
fn test_state() -> PrimaryState {
  PrimaryState::new("org_local")
}

///|
fn test_entropy(seed : Int) -> Bytes {
  Bytes::makei(96, index => ((index * 37 + seed * 11 + 13) % 256).to_byte())
}

///|
fn test_hello(
  runtime_id : String,
  nonce : String,
  capabilities : Array[String],
  version? : Int = PROTOCOL_VERSION,
) -> Hello {
  {
    runtime_id,
    protocol_version: version,
    capabilities,
    machine_public_key: sha256_text("device-secret:" + runtime_id),
    nonce,
    request_id: "req-" + nonce,
  }
}

///|
fn audit_text(state : PrimaryState) -> String {
  let parts : Array[String] = []
  for event in state.audit_events() {
    parts.push(event.to_json().stringify())
  }
  parts.join("\n")
}

///|
fn error_message(response : @contracts.RpcResponse) -> (Int, String) {
  match response.error {
    Some(error) => (error.code, error.message)
    None => (0, "no error")
  }
}

///|
fn result_json(response : @contracts.RpcResponse) -> @json.Json {
  match response.result {
    Some(value) => value
    None => abort("response has no result")
  }
}

///|
test "pairing code is high entropy, hash-only and single use" {
  let state = test_state()
  let now = 1_700_000_000_000L
  let (code, code_id) = match
    state.create_pairing_code(test_entropy(1), test_entropy(2), now) {
    Ok(value) => value
    Err(message) => abort(message)
  }
  // 16 random bytes = 128 bits, rendered as a 32-character hex code.
  assert_eq(code.length(), 32)
  assert_eq(is_hex_of_length(code, 32), true)
  assert_eq(code_id.length(), 16)
  // TTL inside the ADR bound.
  assert_true(PAIRING_CODE_TTL_MS > 0L)
  assert_true(PAIRING_CODE_TTL_MS <= 600_000L)
  // Only the hash is stored.
  let mut found_hash = false
  let mut found_code = false
  for entry in state.pairings.iter() {
    let (key, _) = entry
    if key == sha256_text(code) {
      found_hash = true
    }
    if key == code {
      found_code = true
    }
  }
  assert_true(found_hash)
  assert_false(found_code)
  // A missing or malformed hello is rejected before the code is consumed.
  let hello = test_hello("rt_a", "00112233445566778899aabbccddeeff", [
    CAPABILITY_HMAC,
  ])
  match state.pair(code, hello, now, test_entropy(3)) {
    Ok(grant) => {
      assert_eq(grant.runtime_id, "rt_a")
      assert_eq(grant.generation, 1)
      assert_eq(grant.auth_mode.name(), "hmac-sha256")
      assert_eq(grant.code_id, code_id)
    }
    Err(_) => abort("valid pairing should succeed")
  }
  // Second use of the same code is rejected even with a fresh nonce.
  let hello2 = test_hello("rt_b", "00112233445566778899aabbccddee01", [
    CAPABILITY_HMAC,
  ])
  match state.pair(code, hello2, now, test_entropy(4)) {
    Ok(_) => abort("used code must be rejected")
    Err(Rejected) => ()
    Err(_) => abort("expected uniform rejection")
  }
  assert_true(audit_text(state).contains("used_code"))
}

///|
test "expired pairing code is rejected" {
  let state = test_state()
  let now = 1_700_000_000_000L
  let (code, _) = match
    state.create_pairing_code(test_entropy(5), test_entropy(6), now) {
    Ok(value) => value
    Err(message) => abort(message)
  }
  let hello = test_hello("rt_exp", "00112233445566778899aabbccddeeff", [])
  let later = now + PAIRING_CODE_TTL_MS + 1L
  match state.pair(code, hello, later, test_entropy(7)) {
    Ok(_) => abort("expired code must be rejected")
    Err(Rejected) => ()
    Err(_) => abort("expected uniform rejection")
  }
  assert_true(audit_text(state).contains("expired_code"))
}

///|
test "unknown codes are rate limited and the window resets" {
  let state = test_state()
  let now = 1_700_000_000_000L
  let (code, _) = match
    state.create_pairing_code(test_entropy(8), test_entropy(9), now) {
    Ok(value) => value
    Err(message) => abort(message)
  }
  let hello = test_hello("rt_rl", "00112233445566778899aabbccddeeff", [])
  // Burn the failure budget with wrong codes.
  for attempt in 0..<PAIRING_MAX_FAILURES {
    let wrong = "ffffffffffffffffffffffffffffffff"
    let result = state.pair(wrong, hello, now, test_entropy(100 + attempt))
    match result {
      Ok(_) => abort("wrong code must be rejected")
      Err(Rejected) => ()
      Err(_) => abort("expected uniform rejection")
    }
  }
  // Even the correct code is now refused until the window rolls over.
  match state.pair(code, hello, now, test_entropy(200)) {
    Ok(_) => abort("rate limit must reject the correct code")
    Err(RateLimited) => ()
    Err(_) => abort("expected rate-limited rejection")
  }
  assert_true(audit_text(state).contains("rate_limited"))
  // After the window, the same code works without any state reset. The
  // nonce must be fresh: reusing the burned one is (correctly) a replay.
  let after = now + PAIRING_FAILURE_WINDOW_MS + 1L
  let hello_fresh = test_hello("rt_rl", "00112233445566778899aabbccddee00", [])
  match state.pair(code, hello_fresh, after, test_entropy(201)) {
    Ok(grant) => assert_eq(grant.generation, 1)
    Err(_) => abort("code should work after the window")
  }
}

///|
test "hello nonce replay is rejected" {
  let state = test_state()
  let now = 1_700_000_000_000L
  let nonce = "00112233445566778899aabbccddeeff"
  let (code1, _) = match
    state.create_pairing_code(test_entropy(10), test_entropy(11), now) {
    Ok(value) => value
    Err(message) => abort(message)
  }
  let hello1 = test_hello("rt_nonce", nonce, [CAPABILITY_HMAC])
  match state.pair(code1, hello1, now, test_entropy(12)) {
    Ok(_) => ()
    Err(_) => abort("first pairing should succeed")
  }
  let (code2, _) = match
    state.create_pairing_code(test_entropy(13), test_entropy(14), now) {
    Ok(value) => value
    Err(message) => abort(message)
  }
  let hello2 = test_hello("rt_nonce", nonce, [CAPABILITY_HMAC])
  match state.pair(code2, hello2, now, test_entropy(15)) {
    Ok(_) => abort("replayed hello nonce must be rejected")
    Err(Rejected) => ()
    Err(_) => abort("expected uniform rejection")
  }
  assert_true(audit_text(state).contains("replayed_hello"))
}

///|
test "protocol version mismatch is a readable refusal" {
  let state = test_state()
  let now = 1_700_000_000_000L
  let (code, _) = match
    state.create_pairing_code(test_entropy(16), test_entropy(17), now) {
    Ok(value) => value
    Err(message) => abort(message)
  }
  let hello = test_hello(
    "rt_v",
    "00112233445566778899aabbccddeeff",
    [],
    version=99,
  )
  match state.pair(code, hello, now, test_entropy(18)) {
    Ok(_) => abort("version mismatch must be refused")
    Err(UnsupportedVersion(version)) => assert_eq(version, 99)
    Err(_) => abort("expected UnsupportedVersion")
  }
  // The code was not consumed by the refused attempt.
  let hello_ok = test_hello("rt_v", "00112233445566778899aabbccddee00", [])
  match state.pair(code, hello_ok, now, test_entropy(19)) {
    Ok(_) => ()
    Err(_) => abort("code must remain usable after a version refusal")
  }
}

///|
test "re-pairing revokes the previous credential" {
  let state = test_state()
  let now = 1_700_000_000_000L
  let (code1, _) = match
    state.create_pairing_code(test_entropy(20), test_entropy(21), now) {
    Ok(value) => value
    Err(message) => abort(message)
  }
  let grant1 = match
    state.pair(
      code1,
      test_hello("rt_repair", "00112233445566778899aabbccddeeff", []),
      now,
      test_entropy(22),
    ) {
    Ok(value) => value
    Err(message) => abort("pair: " + pair_error_text(message))
  }
  let (code2, _) = match
    state.create_pairing_code(test_entropy(23), test_entropy(24), now) {
    Ok(value) => value
    Err(message) => abort(message)
  }
  let grant2 = match
    state.pair(
      code2,
      test_hello("rt_repair", "00112233445566778899aabbccddee00", []),
      now,
      test_entropy(25),
    ) {
    Ok(value) => value
    Err(message) => abort("re-pair: " + pair_error_text(message))
  }
  assert_eq(grant2.runtime_id, "rt_repair")
  assert_eq(grant2.generation, 2)
  // Old credential no longer authenticates.
  match
    state.authenticate_bearer(
      "rt_repair",
      grant1.credential_id,
      grant1.credential,
      "00112233445566778899aabbccddee01",
      now,
      test_entropy(26),
    ) {
    Ok(_) => abort("old credential must be revoked")
    Err(Unauthorized) => ()
    Err(_) => abort("expected Unauthorized")
  }
  // New credential works.
  match
    state.authenticate_bearer(
      "rt_repair",
      grant2.credential_id,
      grant2.credential,
      "00112233445566778899aabbccddee02",
      now,
      test_entropy(27),
    ) {
    Ok(_) => ()
    Err(_) => abort("new credential should authenticate")
  }
  assert_true(audit_text(state).contains("re-pair"))
}

///|
fn pair_error_text(error : PairError) -> String {
  match error {
    Rejected => "rejected"
    RateLimited => "rate limited"
    UnsupportedVersion(_) => "version"
    Malformed(message) => message
  }
}

///|
fn auth_error_text(error : AuthError) -> String {
  match error {
    Unauthorized => "unauthorized"
    UnsupportedVersion(_) => "version"
    Malformed(message) => message
  }
}

///|
test "bearer reconnect, heartbeat and revocation" {
  let state = test_state()
  let now = 1_700_000_000_000L
  let (code, _) = match
    state.create_pairing_code(test_entropy(30), test_entropy(31), now) {
    Ok(value) => value
    Err(message) => abort(message)
  }
  // No hmac capability: bearer mode.
  let grant = match
    state.pair(
      code,
      test_hello("rt_bearer", "00112233445566778899aabbccddeeff", [
        CAPABILITY_HEARTBEAT,
      ]),
      now,
      test_entropy(32),
    ) {
    Ok(value) => value
    Err(message) => abort("pair: " + pair_error_text(message))
  }
  assert_eq(grant.auth_mode.name(), "bearer")
  let session = match
    state.authenticate_bearer(
      "rt_bearer",
      grant.credential_id,
      grant.credential,
      "00112233445566778899aabbccddee01",
      now,
      test_entropy(33),
    ) {
    Ok(value) => value
    Err(message) => abort("bearer auth: " + auth_error_text(message))
  }
  assert_eq(session.mode.name(), "bearer")
  let ack = match state.heartbeat(session.session_id, 1L, now) {
    Ok(value) => value
    Err(message) => abort("heartbeat: " + message)
  }
  assert_eq(ack.ack_seq, 1L)
  assert_false(ack.duplicate)
  // Revocation invalidates both the credential and the open session.
  assert_true(state.revoke_runtime("rt_bearer", "owner disabled machine", now))
  match
    state.authenticate_bearer(
      "rt_bearer",
      grant.credential_id,
      grant.credential,
      "00112233445566778899aabbccddee02",
      now,
      test_entropy(34),
    ) {
    Ok(_) => abort("revoked credential must not authenticate")
    Err(Unauthorized) => ()
    Err(_) => abort("expected Unauthorized")
  }
  match state.heartbeat(session.session_id, 2L, now) {
    Ok(_) => abort("revoked session must not heartbeat")
    Err(message) => assert_eq(message, "unauthorized")
  }
  assert_true(audit_text(state).contains("runtime.revoked"))
}

///|
test "hmac challenge response rejects bad macs and replayed challenges" {
  let state = test_state()
  let now = 1_700_000_000_000L
  let (code, _) = match
    state.create_pairing_code(test_entropy(40), test_entropy(41), now) {
    Ok(value) => value
    Err(message) => abort(message)
  }
  let grant = match
    state.pair(
      code,
      test_hello("rt_hmac", "00112233445566778899aabbccddeeff", [
        CAPABILITY_HMAC,
      ]),
      now,
      test_entropy(42),
    ) {
    Ok(value) => value
    Err(message) => abort("pair: " + pair_error_text(message))
  }
  let challenge = match
    state.begin_auth(
      "rt_hmac",
      grant.credential_id,
      now,
      test_entropy(43),
    ) {
    Ok(value) => value
    Err(message) => abort("challenge: " + auth_error_text(message))
  }
  let nonce = "00112233445566778899aabbccddee01"
  let mac = match
    auth_mac(
      grant.credential,
      "rt_hmac",
      challenge.challenge_id,
      challenge.challenge,
      nonce,
    ) {
    Ok(value) => value
    Err(message) => abort(message)
  }
  // Wrong MAC fails closed.
  let bad_mac = "0000000000000000000000000000000000000000000000000000000000000000"
  match
    state.complete_auth(challenge.challenge_id, bad_mac, nonce, now, test_entropy(44)) {
    Ok(_) => abort("bad mac must be rejected")
    Err(Unauthorized) => ()
    Err(_) => abort("expected Unauthorized")
  }
  // Valid MAC succeeds.
  let session = match
    state.complete_auth(challenge.challenge_id, mac, nonce, now, test_entropy(45)) {
    Ok(value) => value
    Err(message) => abort("complete: " + auth_error_text(message))
  }
  assert_eq(session.mode.name(), "hmac-sha256")
  assert_eq(session.resume_from, 0L)
  // Challenge is single use: replaying the same answer fails.
  match
    state.complete_auth(challenge.challenge_id, mac, nonce, now, test_entropy(46)) {
    Ok(_) => abort("replayed challenge must be rejected")
    Err(Unauthorized) => ()
    Err(_) => abort("expected Unauthorized")
  }
  // Expired challenge is rejected.
  let challenge2 = match
    state.begin_auth(
      "rt_hmac",
      grant.credential_id,
      now,
      test_entropy(47),
    ) {
    Ok(value) => value
    Err(message) => abort("challenge: " + auth_error_text(message))
  }
  let later = now + CHALLENGE_TTL_MS + 1L
  let mac2 = match
    auth_mac(
      grant.credential,
      "rt_hmac",
      challenge2.challenge_id,
      challenge2.challenge,
      "00112233445566778899aabbccddee03",
    ) {
    Ok(value) => value
    Err(message) => abort(message)
  }
  match
    state.complete_auth(
      challenge2.challenge_id,
      mac2,
      "00112233445566778899aabbccddee03",
      later,
      test_entropy(48),
    ) {
    Ok(_) => abort("expired challenge must be rejected")
    Err(Unauthorized) => ()
    Err(_) => abort("expected Unauthorized")
  }
  assert_true(audit_text(state).contains("bad_mac"))
  assert_true(audit_text(state).contains("stale_challenge"))
}

///|
test "heartbeat is idempotent and monotonic" {
  let state = test_state()
  let now = 1_700_000_000_000L
  let (code, _) = match
    state.create_pairing_code(test_entropy(50), test_entropy(51), now) {
    Ok(value) => value
    Err(message) => abort(message)
  }
  let grant = match
    state.pair(
      code,
      test_hello("rt_hb", "00112233445566778899aabbccddeeff", [
        CAPABILITY_HEARTBEAT,
      ]),
      now,
      test_entropy(52),
    ) {
    Ok(value) => value
    Err(message) => abort("pair: " + pair_error_text(message))
  }
  let session = match
    state.authenticate_bearer(
      "rt_hb",
      grant.credential_id,
      grant.credential,
      "00112233445566778899aabbccddee01",
      now,
      test_entropy(53),
    ) {
    Ok(value) => value
    Err(message) => abort("auth: " + auth_error_text(message))
  }
  let ack1 = match state.heartbeat(session.session_id, 1L, now) {
    Ok(value) => value
    Err(_) => abort("heartbeat 1")
  }
  assert_eq(ack1.ack_seq, 1L)
  // Duplicate seq never regresses the ack.
  let ack_dup = match state.heartbeat(session.session_id, 1L, now + 100L) {
    Ok(value) => value
    Err(_) => abort("heartbeat duplicate")
  }
  assert_true(ack_dup.duplicate)
  assert_eq(ack_dup.ack_seq, 1L)
  let ack3 = match state.heartbeat(session.session_id, 3L, now + 200L) {
    Ok(value) => value
    Err(_) => abort("heartbeat 3")
  }
  assert_eq(ack3.ack_seq, 3L)
  // Out-of-order older seq is idempotent, not a regression.
  let ack_old = match state.heartbeat(session.session_id, 2L, now + 300L) {
    Ok(value) => value
    Err(_) => abort("heartbeat old")
  }
  assert_true(ack_old.duplicate)
  assert_eq(ack_old.ack_seq, 3L)
  // Staleness is computed from the injected clock.
  let live = match state.session(session.session_id) {
    Some(value) => value
    None => abort("missing session")
  }
  assert_false(session_is_stale(live, now + 1000L))
  assert_true(
    session_is_stale(
      live,
      now + HEARTBEAT_INTERVAL_MS * HEARTBEAT_MAX_MISSED.to_int64() + 301L,
    ),
  )
}

///|
test "reconnect resumes from the last acknowledged sequence" {
  let state = test_state()
  let now = 1_700_000_000_000L
  let (code, _) = match
    state.create_pairing_code(test_entropy(60), test_entropy(61), now) {
    Ok(value) => value
    Err(message) => abort(message)
  }
  let grant = match
    state.pair(
      code,
      test_hello("rt_resume", "00112233445566778899aabbccddeeff", []),
      now,
      test_entropy(62),
    ) {
    Ok(value) => value
    Err(message) => abort("pair: " + pair_error_text(message))
  }
  let first = match
    state.authenticate_bearer(
      "rt_resume",
      grant.credential_id,
      grant.credential,
      "00112233445566778899aabbccddee01",
      now,
      test_entropy(63),
    ) {
    Ok(value) => value
    Err(message) => abort("auth: " + auth_error_text(message))
  }
  let _ = match state.heartbeat(first.session_id, 7L, now) {
    Ok(value) => value
    Err(_) => abort("heartbeat")
  }
  // Simulate a dropped connection, then reconnect with a fresh nonce.
  let second = match
    state.authenticate_bearer(
      "rt_resume",
      grant.credential_id,
      grant.credential,
      "00112233445566778899aabbccddee02",
      now + 1000L,
      test_entropy(64),
    ) {
    Ok(value) => value
    Err(message) => abort("reconnect: " + auth_error_text(message))
  }
  assert_eq(second.resume_from, 7L)
  assert_true(second.session_id != first.session_id)
}

///|
test "rotation keeps runtime_id and invalidates the old credential" {
  let state = test_state()
  let now = 1_700_000_000_000L
  let (code, _) = match
    state.create_pairing_code(test_entropy(70), test_entropy(71), now) {
    Ok(value) => value
    Err(message) => abort(message)
  }
  let grant = match
    state.pair(
      code,
      test_hello("rt_rot", "00112233445566778899aabbccddeeff", [
        CAPABILITY_HMAC,
      ]),
      now,
      test_entropy(72),
    ) {
    Ok(value) => value
    Err(message) => abort("pair: " + pair_error_text(message))
  }
  let challenge = match
    state.begin_auth("rt_rot", grant.credential_id, now, test_entropy(73)) {
    Ok(value) => value
    Err(message) => abort("challenge: " + auth_error_text(message))
  }
  let nonce = "00112233445566778899aabbccddee01"
  let mac = match
    auth_mac(
      grant.credential,
      "rt_rot",
      challenge.challenge_id,
      challenge.challenge,
      nonce,
    ) {
    Ok(value) => value
    Err(message) => abort(message)
  }
  let session = match
    state.complete_auth(challenge.challenge_id, mac, nonce, now, test_entropy(74)) {
    Ok(value) => value
    Err(message) => abort("auth: " + auth_error_text(message))
  }
  let rotated = match state.rotate_credential(session.session_id, now, test_entropy(75)) {
    Ok(value) => value
    Err(message) => abort("rotate: " + auth_error_text(message))
  }
  assert_eq(rotated.runtime_id, "rt_rot")
  assert_eq(rotated.generation, grant.generation + 1)
  assert_true(rotated.credential_id != grant.credential_id)
  // Old credential cannot even start a challenge.
  match
    state.begin_auth("rt_rot", grant.credential_id, now, test_entropy(76)) {
    Ok(_) => abort("old credential must not start auth")
    Err(Unauthorized) => ()
    Err(_) => abort("expected Unauthorized")
  }
  // New credential can.
  match
    state.begin_auth("rt_rot", rotated.credential_id, now, test_entropy(77)) {
    Ok(_) => ()
    Err(_) => abort("new credential should start auth")
  }
  // The old session was closed by rotation.
  match state.heartbeat(session.session_id, 1L, now) {
    Ok(_) => abort("rotated session must be closed")
    Err(message) => assert_eq(message, "unauthorized")
  }
  assert_true(audit_text(state).contains("runtime.credential_rotated"))
}

///|
test "credential expiry and scope enforcement" {
  let state = test_state()
  let now = 1_700_000_000_000L
  let (code, _) = match
    state.create_pairing_code(test_entropy(80), test_entropy(81), now) {
    Ok(value) => value
    Err(message) => abort(message)
  }
  // Only heartbeat scope: probe must be forbidden.
  let grant = match
    state.pair_with_scopes(
      code,
      test_hello("rt_scope", "00112233445566778899aabbccddeeff", []),
      now,
      test_entropy(82),
      ["runtime.heartbeat"],
    ) {
    Ok(value) => value
    Err(message) => abort("pair: " + pair_error_text(message))
  }
  let session = match
    state.authenticate_bearer(
      "rt_scope",
      grant.credential_id,
      grant.credential,
      "00112233445566778899aabbccddee01",
      now,
      test_entropy(83),
    ) {
    Ok(value) => value
    Err(message) => abort("auth: " + auth_error_text(message))
  }
  assert_true(state.has_scope("rt_scope", "runtime.heartbeat"))
  assert_false(state.has_scope("rt_scope", "runtime.probe"))
  let probe_request = @contracts.RpcRequest::new(
    "probe-1",
    METHOD_RUNTIME_PROBE,
    probe_params("probe-1", session.session_id),
  )
  let probe_response = state.dispatch(probe_request, now, test_entropy(84))
  let (probe_code, probe_message) = error_message(probe_response)
  assert_eq(probe_code, @contracts.ERR_HOST)
  assert_eq(probe_message, "forbidden")
  // Credential expiry is enforced on a fresh reconnect attempt.
  let expired_at = now + CREDENTIAL_TTL_MS + 1L
  match
    state.authenticate_bearer(
      "rt_scope",
      grant.credential_id,
      grant.credential,
      "00112233445566778899aabbccddee02",
      expired_at,
      test_entropy(85),
    ) {
    Ok(_) => abort("expired credential must not authenticate")
    Err(Unauthorized) => ()
    Err(_) => abort("expected Unauthorized")
  }
}

///|
test "dispatch reuses the JSON-RPC envelope and uniform pairing errors" {
  let state = test_state()
  let now = 1_700_000_000_000L
  let (code, _) = match
    state.create_pairing_code(test_entropy(90), test_entropy(91), now) {
    Ok(value) => value
    Err(message) => abort(message)
  }
  let params = hello_params(
    "pair-1",
    code,
    "rt_rpc",
    PROTOCOL_VERSION,
    [CAPABILITY_HMAC],
    sha256_text("device-secret:rt_rpc"),
    "00112233445566778899aabbccddeeff",
  )
  let request = @contracts.RpcRequest::new("pair-1", METHOD_RUNTIME_PAIR, params)
  let response = state.dispatch(request, now, test_entropy(92))
  assert_eq(response.id, "pair-1")
  match response.error {
    None => ()
    Some(_) => abort("valid pairing returned an error")
  }
  let grant_json = result_json(response)
  // The wire response round-trips through the existing contracts parser.
  let parsed = @json.parse(grant_json.stringify()) catch {
    _ => abort("response is not valid JSON")
  }
  let grant = match parse_pair_grant(parsed) {
    Some(value) => value
    None => abort("pair grant did not parse")
  }
  assert_eq(grant.runtime_id, "rt_rpc")
  // Unknown methods use the standard -32601 error object.
  let unknown = state.dispatch(
    @contracts.RpcRequest::new("u-1", "runtime.nope", Map([])),
    now,
    test_entropy(93),
  )
  let (unknown_code, _) = error_message(unknown)
  assert_eq(unknown_code, @contracts.ERR_METHOD_NOT_FOUND)
  // Wrong code, expired code and used code all return the same error text.
  let wrong_params = hello_params(
    "pair-2",
    "ffffffffffffffffffffffffffffffff",
    "rt_rpc2",
    PROTOCOL_VERSION,
    [],
    sha256_text("device-secret:rt_rpc2"),
    "00112233445566778899aabbccddee01",
  )
  let wrong_response = state.dispatch(
    @contracts.RpcRequest::new("pair-2", METHOD_RUNTIME_PAIR, wrong_params),
    now,
    test_entropy(94),
  )
  let (wrong_code, wrong_message) = error_message(wrong_response)
  assert_eq(wrong_code, @contracts.ERR_HOST)
  assert_eq(wrong_message, "pairing rejected")
  // Malformed params are -32602 and never echo the input.
  let bad_response = state.dispatch(
    @contracts.RpcRequest::new(
      "pair-3",
      METHOD_RUNTIME_PAIR,
      Map([("code", @contracts.json_string("not-hex"))]),
    ),
    now,
    test_entropy(95),
  )
  let (bad_code, _) = error_message(bad_response)
  assert_eq(bad_code, @contracts.ERR_INVALID_PARAMS)
}

///|
test "hello parsing bounds hostile input" {
  let long_id = "a".repeat(200)
  let params : Map[String, @json.Json] = Map([])
  params.set("client_request_id", @contracts.json_string("r1"))
  params.set("runtime_id", @contracts.json_string(long_id))
  params.set("protocol_version", @contracts.json_int(PROTOCOL_VERSION))
  params.set("capabilities", @json.Json::array([]))
  params.set(
    "machine_public_key",
    @contracts.json_string(sha256_text("k")),
  )
  params.set(
    "nonce",
    @contracts.json_string("00112233445566778899aabbccddeeff"),
  )
  match parse_hello(params) {
    Ok(_) => abort("oversized runtime_id must be rejected")
    Err(_) => ()
  }
  params.set("runtime_id", @contracts.json_string("rt_ok"))
  params.set(
    "capabilities",
    @json.Json::array(
      Array::make(MAX_CAPABILITIES + 1, @contracts.json_string("cap")),
    ),
  )
  match parse_hello(params) {
    Ok(_) => abort("too many capabilities must be rejected")
    Err(_) => ()
  }
  params.set("capabilities", @json.Json::array([]))
  params.set("machine_public_key", @contracts.json_string("not-hex"))
  match parse_hello(params) {
    Ok(_) => abort("malformed public key must be rejected")
    Err(_) => ()
  }
  params.set("machine_public_key", @contracts.json_string(sha256_text("k")))
  params.set("nonce", @contracts.json_string("short"))
  match parse_hello(params) {
    Ok(_) => abort("short nonce must be rejected")
    Err(_) => ()
  }
}

///|
test "pairing codes, credentials and keys never reach logs or audit" {
  let state = test_state()
  let now = 1_700_000_000_000L
  let device_secret = hex_of(test_entropy(7).exact_view())
  let (code, _) = match
    state.create_pairing_code(test_entropy(110), test_entropy(111), now) {
    Ok(value) => value
    Err(message) => abort(message)
  }
  let key = match machine_public_key(device_secret) {
    Ok(value) => value
    Err(message) => abort("machine key: " + message)
  }
  let hello : Hello = {
    runtime_id: "rt_log",
    protocol_version: PROTOCOL_VERSION,
    capabilities: [CAPABILITY_HMAC],
    machine_public_key: key,
    nonce: "00112233445566778899aabbccddeeff",
    request_id: "req-log",
  }
  let grant = match state.pair(code, hello, now, test_entropy(112)) {
    Ok(value) => value
    Err(message) => abort("pair: " + pair_error_text(message))
  }
  // Force a rejection too, so audit/log lines for failures are covered.
  let wrong_params = hello_params(
    "req-log-2",
    "ffffffffffffffffffffffffffffffff",
    "rt_log",
    PROTOCOL_VERSION,
    [],
    sha256_text("k"),
    "00112233445566778899aabbccddee01",
  )
  let _ = state.dispatch(
    @contracts.RpcRequest::new("req-log-2", METHOD_RUNTIME_PAIR, wrong_params),
    now,
    test_entropy(113),
  )
  let log_text = state.log_text()
  let audit = audit_text(state)
  for secret in [code, grant.credential, device_secret] {
    assert_false(log_text.contains(secret))
    assert_false(audit.contains(secret))
  }
  // Every diagnostic line stays inside the bounded length.
  for line in state.log_lines() {
    assert_true(line.length() <= MAX_DETAIL_LEN + 3)
  }
  // The audit log does carry the ids needed for investigation.
  assert_true(audit.contains("runtime.enrolled"))
  assert_true(audit.contains(grant.credential_id))
}

///|
test "bounded_redacted reuses the contracts secret policy" {
  let secret = "sk-abcdefghijklmnopqrstuvwxyz0123456789"
  let line = "provider failed token=" + secret + " at remote"
  let cleaned = bounded_redacted(line)
  assert_false(cleaned.contains(secret))
  assert_true(cleaned.contains("[redacted]"))
  let pem = "-----BEGIN PRIVATE KEY-----\nMIIEfakekeymaterial\n-----END PRIVATE KEY-----"
  let cleaned_pem = bounded_redacted(pem)
  assert_false(cleaned_pem.contains("MIIEfakekeymaterial"))
  let long = "x".repeat(MAX_DETAIL_LEN + 100)
  assert_eq(bounded_redacted(long).length(), MAX_DETAIL_LEN + 3)
}
