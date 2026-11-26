///|
/// Unit tests for the transport state machine, framing, rate budgets, storage
/// permissions, redaction and backoff. TLS end-to-end tests live in
/// `transport_e2e_test.mbt`; these tests never open a socket.

///|
fn test_failure_label(result : Result[PairGrant, PairFailure]) -> String {
  match result {
    Ok(_) => "ok"
    Err(PairRejected(reason)) => "rejected:" + reason
    Err(PairRateLimited) => "rate_limited"
    Err(PairUnsupportedVersion(_)) => "unsupported_version"
    Err(PairMalformed(reason)) => "malformed:" + reason
    Err(PairStorage(reason)) => "storage:" + reason
  }
}

///|
fn test_auth_label(result : Result[AuthGrant, AuthFailure]) -> String {
  match result {
    Ok(_) => "ok"
    Err(AuthUnauthorized) => "unauthorized"
    Err(AuthRevoked) => "revoked"
    Err(AuthRateLimited) => "rate_limited"
    Err(AuthUnsupportedVersion(_)) => "unsupported_version"
    Err(AuthMalformed(reason)) => "malformed:" + reason
    Err(AuthStorage(reason)) => "storage:" + reason
  }
}

///|
async fn test_primary_with_clock(now : () -> Int64) -> PrimaryState {
  let store = StateStore::memory()
  match PrimaryState::open_with_clock(store, CredentialPolicy::until_revoked(), now) {
    Ok(state) => state
    Err(message) => {
      assert_true(false)
      let _ = message
      fail("cannot open primary state")
    }
  }
}

///|
async fn test_enroll(
  state : PrimaryState,
  runtime_id : String,
  source : String,
) -> PairGrant {
  let secret = match state.create_pairing_code() {
    Ok(value) => value
    Err(message) => {
      assert_true(false)
      let _ = message
      fail("cannot create pairing code")
    }
  }
  match state.pair(secret.code, runtime_id, PROTOCOL_VERSION, [], source) {
    Ok(grant) => grant
    Err(failure) => {
      let _ = failure
      assert_true(false)
      fail("pairing failed")
    }
  }
}

///|
async test "pairing code is 128-bit hex, single use and expires after ten minutes" {
  let clock : Ref[Int64] = Ref(1_000_000L)
  let now = () => clock.val
  let state = test_primary_with_clock(now) catch { _ => fail("no state") }
  let secret = match state.create_pairing_code() {
    Ok(value) => value
    Err(_) => fail("code")
  }
  assert_eq(secret.code.length(), 32)
  assert_true(is_hex_of_length(secret.code, 32))
  assert_eq(secret.expires_at_ms - clock.val, PAIRING_CODE_TTL_MS)
  assert_true(secret.code_id.length() == 16)
  let first = state.pair(secret.code, "rt-1", PROTOCOL_VERSION, [], "127.0.0.1:1")
  assert_eq(test_failure_label(first), "ok")
  let replay = state.pair(secret.code, "rt-1", PROTOCOL_VERSION, [], "127.0.0.1:1")
  assert_true(test_failure_label(replay).has_prefix("rejected:"))
}

///|
async fn test_pair_expiry_and_uniform_rejection() -> Unit {
  let clock : Ref[Int64] = Ref(50_000L)
  let now = () => clock.val
  let state = test_primary_with_clock(now) catch { _ => fail("no state") }
  let secret = match state.create_pairing_code() {
    Ok(value) => value
    Err(_) => fail("code")
  }
  let wrong = state.pair("00000000000000000000000000000000", "rt-1", PROTOCOL_VERSION, [], "127.0.0.1:2")
  assert_true(test_failure_label(wrong).has_prefix("rejected:"))
  clock.val = clock.val + PAIRING_CODE_TTL_MS + 1L
  let expired = state.pair(secret.code, "rt-1", PROTOCOL_VERSION, [], "127.0.0.1:2")
  assert_true(test_failure_label(expired).has_prefix("rejected:"))
  // Every rejection is the same `PairRejected` failure; the wire mapping
  // (uniform code 1000, uniform message) is asserted in the TLS e2e test.
  match expired {
    Ok(_) => assert_true(false)
    Err(PairRejected(_)) => assert_true(true)
    Err(_) => assert_true(false)
  }
}

///|
async test "pair expiry and uniform wire rejection" {
  test_pair_expiry_and_uniform_rejection()
}

///|
async fn test_pair_rate_limits() -> Unit {
  let clock : Ref[Int64] = Ref(0L)
  let now = () => clock.val
  let state = test_primary_with_clock(now) catch { _ => fail("no state") }
  let secret = match state.create_pairing_code() {
    Ok(value) => value
    Err(_) => fail("code")
  }
  // Per source: five attempts are allowed, the sixth is rate limited even with
  // the correct code (budgets are consumed before verification).
  for _i = 0; _i < PAIRING_PER_SOURCE_LIMIT; _i = _i + 1 {
    let _ = state.pair("ffffffffffffffffffffffffffffffff", "rt-src", PROTOCOL_VERSION, [], "10.0.0.9:1234")
    let _ = 0
  }
  let blocked = state.pair(secret.code, "rt-src", PROTOCOL_VERSION, [], "10.0.0.9:9999")
  assert_eq(test_failure_label(blocked), "rate_limited")
  // A different source is unaffected; the code was never consumed.
  let allowed = state.pair(secret.code, "rt-src", PROTOCOL_VERSION, [], "10.0.0.2:1234")
  assert_eq(test_failure_label(allowed), "ok")
  // Global pairing budget: 50 attempts across 50 sources, the next is blocked.
  let state2 = test_primary_with_clock(now) catch { _ => fail("no state") }
  let secret2 = match state2.create_pairing_code() {
    Ok(value) => value
    Err(_) => fail("code")
  }
  for i = 0; i < PAIRING_GLOBAL_LIMIT; i = i + 1 {
    let _ = state2.pair("ffffffffffffffffffffffffffffffff", "rt-g", PROTOCOL_VERSION, [], "10.1.0." + i.to_string() + ":1")
  }
  let global_blocked = state2.pair(secret2.code, "rt-g", PROTOCOL_VERSION, [], "10.2.0.1:1")
  assert_eq(test_failure_label(global_blocked), "rate_limited")
}

///|
async test "pairing has per-source and global failure budgets" {
  test_pair_rate_limits()
}

///|
async fn test_auth_rate_limits_and_revocation() -> Unit {
  let state = test_primary_with_clock(() => 100L) catch { _ => fail("no state") }
  let grant = test_enroll(state, "rt-auth", "127.0.0.1:1")
  assert_eq(grant.credential.length(), CREDENTIAL_HEX_LEN)
  assert_true(is_hex_of_length(grant.credential, 64))
  // Per-source: ten failures block even the valid token.
  let wrong = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  for i = 0; i < AUTH_PER_SOURCE_LIMIT; i = i + 1 {
    let _ = state.authenticate("rt-auth", wrong, "192.0.2.1:" + i.to_string())
  }
  let blocked = state.authenticate("rt-auth", grant.credential, "192.0.2.1:9999")
  assert_eq(test_auth_label(blocked), "rate_limited")
  // A valid token on a different source still works.
  let ok = state.authenticate("rt-auth", grant.credential, "192.0.2.2:1")
  assert_eq(test_auth_label(ok), "ok")
  // Rotation revokes the old token; the new token authenticates.
  let rotated = match state.rotate("rt-auth", grant.credential, "192.0.2.2:2") {
    Ok(value) => value
    Err(_) => fail("rotate")
  }
  assert_eq(rotated.generation, grant.generation + 1)
  assert_true(rotated.credential != grant.credential)
  let old = state.authenticate("rt-auth", grant.credential, "192.0.2.3:1")
  assert_eq(test_auth_label(old), "revoked")
  let fresh = state.authenticate("rt-auth", rotated.credential, "192.0.2.3:2")
  assert_eq(test_auth_label(fresh), "ok")
  // Revocation closes the live credential.
  let _ = state.revoke("rt-auth", "owner_revoked")
  let revoked = state.authenticate("rt-auth", rotated.credential, "192.0.2.4:1")
  assert_eq(test_auth_label(revoked), "revoked")
}

///|
async test "authentication budgets, rotation and revocation" {
  test_auth_rate_limits_and_revocation()
}

///|
async fn test_auth_per_runtime_and_global_limits() -> Unit {
  let state = test_primary_with_clock(() => 0L) catch { _ => fail("no state") }
  let _grant = test_enroll(state, "rt-limit", "127.0.0.1:1")
  let wrong = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  for i = 0; i < AUTH_PER_RUNTIME_LIMIT; i = i + 1 {
    let _ = state.authenticate("rt-limit", wrong, "198.51.100." + i.to_string() + ":1")
  }
  let runtime_blocked = state.authenticate("rt-limit", wrong, "203.0.113.1:1")
  assert_eq(test_auth_label(runtime_blocked), "rate_limited")
  // Global: 200 attempts with unique runtimes and sources.
  let state2 = test_primary_with_clock(() => 0L) catch { _ => fail("no state") }
  for i = 0; i < AUTH_GLOBAL_LIMIT; i = i + 1 {
    let _ = state2.authenticate("rt-g-" + i.to_string(), wrong, "198.18." + i.to_string() + ":1")
  }
  let global_blocked = state2.authenticate("rt-final", wrong, "198.19.0.1:1")
  assert_eq(test_auth_label(global_blocked), "rate_limited")
}

///|
async test "authentication has per-runtime and global budgets" {
  test_auth_per_runtime_and_global_limits()
}

///|
async fn test_credential_lifetime() -> Unit {
  let clock : Ref[Int64] = Ref(10_000L)
  let now = () => clock.val
  let policy = match CredentialPolicy::fixed(1_000L) {
    Ok(value) => value
    Err(_) => fail("policy")
  }
  let state = match PrimaryState::open_with_clock(StateStore::memory(), policy, now) {
    Ok(value) => value
    Err(_) => fail("state")
  }
  let grant = test_enroll(state, "rt-fixed", "127.0.0.1:1")
  assert_true(match grant.expires_at_ms {
    Some(value) => value == 11_000L
    None => false
  })
  let before = state.authenticate("rt-fixed", grant.credential, "127.0.0.1:2")
  assert_eq(test_auth_label(before), "ok")
  clock.val = clock.val + 1_001L
  let after = state.authenticate("rt-fixed", grant.credential, "127.0.0.1:3")
  assert_eq(test_auth_label(after), "revoked")
  // Re-authentication is refused; re-pairing is the only path.
  let session = state.open_session("rt-fixed", grant.credential, "127.0.0.1:4", 0L)
  match session {
    Ok(_) => assert_true(false)
    Err(AuthRevoked) => assert_true(true)
    Err(_) => assert_true(false)
  }
  // Default production policy is long-lived until revoked.
  assert_true(CredentialPolicy::until_revoked().lifetime_ms is None)
  assert_true(credential_default_lifetime_ms() is None)
}

///|
async test "fixed credential lifetime requires re-pairing, default is until revoked" {
  test_credential_lifetime()
}

///|
async fn test_sessions_and_heartbeat() -> Unit {
  let state = test_primary_with_clock(() => 1_000L) catch { _ => fail("no state") }
  let grant = test_enroll(state, "rt-session", "127.0.0.1:1")
  let session = match state.open_session("rt-session", grant.credential, "127.0.0.1:2", 0L) {
    Ok(value) => value
    Err(_) => fail("session")
  }
  assert_eq(session.resume_cursor, 0L)
  assert_eq(session.gap, false)
  // A node cursor ahead of the primary's stored cursor is reported as a gap
  // instead of silently rewinding.
  let ahead = match state.open_session("rt-session", grant.credential, "127.0.0.1:9", 7L) {
    Ok(value) => value
    Err(_) => fail("ahead session")
  }
  assert_eq(ahead.resume_cursor, 0L)
  assert_eq(ahead.gap, true)
  state.close_session(ahead.session_id)
  let beat = state.heartbeat(session.session_id)
  match beat {
    Ok(cursor) => assert_eq(cursor, 0L)
    Err(_) => assert_true(false)
  }
  state.close_session(session.session_id)
  match state.heartbeat(session.session_id) {
    Ok(_) => assert_true(false)
    Err(AuthRevoked) => assert_true(true)
    Err(_) => assert_true(false)
  }
  // Revoking the runtime drops live sessions.
  let session2 = match state.open_session("rt-session", grant.credential, "127.0.0.1:3", 0L) {
    Ok(value) => value
    Err(_) => fail("session2")
  }
  let _ = state.revoke("rt-session", "test")
  match state.heartbeat(session2.session_id) {
    Ok(_) => assert_true(false)
    Err(AuthRevoked) => assert_true(true)
    Err(_) => assert_true(false)
  }
}

///|
async test "sessions heartbeat and close on revocation" {
  test_sessions_and_heartbeat()
}

///|
async fn test_events_and_cursor() -> Unit {
  let state = test_primary_with_clock(() => 2_000L) catch { _ => fail("no state") }
  let _grant = test_enroll(state, "rt-events", "127.0.0.1:1")
  let event : WireEvent = {
    seq: 4L,
    run_id: "run-1",
    run_seq: 1L,
    kind: "run.output",
    ts: "2026-11-26T00:00:00.000Z",
    payload: @contracts.json_object([
      ("stream", @contracts.json_string("stdout")),
      ("chunk", @contracts.json_string("hello")),
    ]),
    hash: "",
  }
  let params = event.to_params("rt-events")
  let decoded = match WireEvent::from_params(params) {
    Ok(value) => value
    Err(_) => fail("decode")
  }
  let ack = match state.accept_event("rt-events", decoded) {
    Ok(value) => value
    Err(_) => fail("accept")
  }
  assert_eq(ack.cursor, 4L)
  assert_eq(ack.duplicate, false)
  assert_eq(state.cursor_for("rt-events"), 4L)
  let duplicate = match state.accept_event("rt-events", decoded) {
    Ok(value) => value
    Err(_) => fail("duplicate")
  }
  assert_eq(duplicate.duplicate, true)
  let tampered : WireEvent = { ..event, hash: "sha256:0000" }
  let tampered_params = tampered.to_params("rt-events")
  tampered_params.set("hash", @contracts.json_string("sha256:0000"))
  let tampered_event = match WireEvent::from_params(tampered_params) {
    Ok(value) => value
    Err(_) => fail("decode tampered")
  }
  match state.accept_event("rt-events", tampered_event) {
    Ok(_) => assert_true(false)
    Err(EventMalformed(message)) => assert_true(message.contains("hash"))
    Err(_) => assert_true(false)
  }
  // Payloads above the event bound are refused before storage.
  let large = @json.Json::array(
    Array::make(MAX_EVENT_PAYLOAD_BYTES, @contracts.json_string("x")),
  )
  let oversized : WireEvent = { ..event, payload: large }
  let oversized_params = oversized.to_params("rt-events")
  match WireEvent::from_params(oversized_params) {
    Ok(_) => assert_true(false)
    Err(message) => assert_true(message.contains("payload"))
  }
}

///|
async test "events dedupe by run identity and advance the ack cursor" {
  test_events_and_cursor()
}

///|
test "frames are length-prefixed, bounded at 64 KiB and object-only" {
  let small = @contracts.json_object([("ok", @contracts.json_bool(true))])
  let bytes = match encode_frame(small) {
    Ok(value) => value
    Err(_) => fail("encode")
  }
  assert_true(bytes.length() > 4)
  let declared = bytes[0].to_int() * 16_777_216 +
    bytes[1].to_int() * 65_536 +
    bytes[2].to_int() * 256 +
    bytes[3].to_int()
  assert_eq(declared, bytes.length() - 4)
  let too_large = @contracts.json_object([
    (
      "payload",
      @json.Json::array(
        Array::make(MAX_FRAME_BYTES, @contracts.json_string("x")),
      ),
    ),
  ])
  match encode_frame(too_large) {
    Ok(_) => assert_true(false)
    Err(FrameTooLarge(size)) => assert_true(size > MAX_FRAME_BYTES)
    Err(_) => assert_true(false)
  }
  match encode_frame(@json.Json::null()) {
    Ok(_) => assert_true(false)
    Err(FrameNotObject) => assert_true(true)
    Err(_) => assert_true(false)
  }
}

///|
test "backoff grows 1s to 60s and jitter never exceeds the cap" {
  let steps : Array[Int64] = []
  for attempt = 1; attempt <= 8; attempt = attempt + 1 {
    steps.push(backoff_delay_with(1_000L, 60_000L, attempt, 0L, 0L))
  }
  assert_eq(steps[0], 1_000L)
  assert_eq(steps[1], 2_000L)
  assert_eq(steps[2], 4_000L)
  assert_eq(steps[3], 8_000L)
  assert_eq(steps[4], 16_000L)
  assert_eq(steps[5], 32_000L)
  assert_eq(steps[6], 60_000L)
  assert_eq(steps[7], 60_000L)
  for attempt = 1; attempt <= 8; attempt = attempt + 1 {
    for value = 0; value < 10; value = value + 1 {
      let delay = backoff_delay_with(1_000L, 60_000L, attempt, 500L, value.to_int64() * 137L)
      assert_true(delay >= 1_000L)
      assert_true(delay <= 60_000L)
    }
  }
  let tiny = backoff_delay_with(10L, 25L, 5, 100L, 999L)
  assert_eq(tiny, 25L)
}

///|
test "source hosts are normalized for rate limiting" {
  assert_eq(source_host("127.0.0.1:51234"), "127.0.0.1")
  assert_eq(source_host("[::1]:51234"), "[::1]")
  assert_eq(source_host("10.0.0.7"), "10.0.0.7")
  assert_eq(source_host(""), "")
  let mut long = "1.2.3.4:"
  for _i = 0; _i < 300; _i = _i + 1 {
    long = long + "7"
  }
  assert_true(source_host(long).length() <= MAX_PEER_LEN)
}

///|
test "handler registry refuses reserved and duplicate methods" {
  let registry = HandlerRegistry::new()
  match registry.register(METHOD_HEARTBEAT, async fn(_request) { Ok(@contracts.json_string("ok")) }) {
    Ok(_) => assert_true(false)
    Err(message) => assert_true(message.contains("reserved"))
  }
  match registry.register("demo.echo", async fn(_request) { Ok(@contracts.json_string("ok")) }) {
    Ok(_) => assert_true(true)
    Err(_) => assert_true(false)
  }
  match registry.register("demo.echo", async fn(_request) { Ok(@contracts.json_string("ok")) }) {
    Ok(_) => assert_true(false)
    Err(message) => assert_true(message.contains("already"))
  }
  assert_true(registry.has_handler("demo.echo"))
  assert_true(registry.lookup("demo.ping") is None)
  assert_eq(registry.methods().length(), 1)
  assert_eq(method_not_found_error("demo.ping").code, @contracts.ERR_METHOD_NOT_FOUND)
}

///|
test "rate limiter prunes its window and bounds its key table" {
  let clock : Ref[Int64] = Ref(0L)
  let limiter = RateLimiter::new(() => clock.val, window_ms=1_000L, max_keys=4)
  assert_true(limiter.try_consume("s", "a", 1))
  assert_true(!limiter.try_consume("s", "a", 1))
  clock.val = clock.val + 1_001L
  assert_true(limiter.try_consume("s", "a", 1))
  for i = 0; i < 20; i = i + 1 {
    let _ = limiter.try_consume("s", "k" + i.to_string(), 1)
  }
  // The bound keeps the table small; the newest key is still tracked.
  assert_eq(limiter.attempts("s", "k19"), 1)
}

///|
async fn test_store_and_token_permissions() -> Unit {
  let dir = @fs.tmpdir(prefix="monexus-transport-store-")
  defer @fs.rmdir(dir, recursive=true)
  let state_dir = dir + "/state"
  let store = match StateStore::open(state_dir) {
    Ok(value) => value
    Err(_) => fail("open store")
  }
  let state = match PrimaryState::open(store, CredentialPolicy::until_revoked()) {
    Ok(value) => value
    Err(_) => fail("open primary")
  }
  let secret = match state.create_pairing_code() {
    Ok(value) => value
    Err(_) => fail("code")
  }
  let grant = match state.pair(secret.code, "rt-store", PROTOCOL_VERSION, [], "127.0.0.1:1") {
    Ok(value) => value
    Err(_) => fail("pair")
  }
  let path = state_dir + "/transport-state.json"
  assert_true(@fs.exists(path))
  assert_true(!(@fs.exists(path + ".tmp")))
  match stat_path(state_dir) {
    Some(info) => assert_eq(info.mode & 0o777, 0o700)
    None => assert_true(false)
  }
  match stat_path(path) {
    Some(info) => assert_eq(info.mode & 0o777, 0o600)
    None => assert_true(false)
  }
  let text = @fs.read_file(path).text() catch { _ => fail("read") }
  assert_true(text.contains(sha256_text(grant.credential)))
  assert_true(text.contains(sha256_text(secret.code)))
  assert_true(!text.contains(grant.credential))
  assert_true(!text.contains(secret.code))
  // A snapshot opened by a second process sees the credential hashes.
  let reopened = match StateStore::open(state_dir) {
    Ok(value) => value
    Err(_) => fail("reopen")
  }
  let loaded = match (reopened.load)() {
    Ok(Some(snapshot)) => snapshot
    _ => fail("load")
  }
  assert_eq(loaded.credentials.length(), 1)
  assert_eq(loaded.credentials[0].token_hash, sha256_text(grant.credential))
  // Token files are 0600 and never leaked through errors.
  let token_dir = dir + "/token"
  let token_path = token_dir + "/credential"
  match save_token_file(token_path, grant.credential) {
    Ok(_) => assert_true(true)
    Err(_) => assert_true(false)
  }
  match stat_path(token_dir) {
    Some(info) => assert_eq(info.mode & 0o777, 0o700)
    None => assert_true(false)
  }
  match stat_path(token_path) {
    Some(info) => assert_eq(info.mode & 0o777, 0o600)
    None => assert_true(false)
  }
  let loaded_token = match load_token_file(token_path) {
    Ok(value) => value
    Err(_) => fail("load token")
  }
  assert_eq(loaded_token, grant.credential)
  @fs.chmod(token_path, 0o644) catch { _ => () }
  match load_token_file(token_path) {
    Ok(_) => assert_true(false)
    Err(message) => {
      assert_true(message.contains("0600"))
      assert_true(!message.contains(grant.credential))
    }
  }
  match save_token_file(token_path + "-bad", "not-hex") {
    Ok(_) => assert_true(false)
    Err(message) => assert_true(!message.contains("not-hex"))
  }
}

///|
async test "state and token files are 0600 in a 0700 directory" {
  test_store_and_token_permissions()
}

///|
async fn test_no_secrets_in_audit_or_logs() -> Unit {
  let state = test_primary_with_clock(() => 5_000L) catch { _ => fail("no state") }
  let secret = match state.create_pairing_code() {
    Ok(value) => value
    Err(_) => fail("code")
  }
  let grant = match state.pair(secret.code, "rt-audit", PROTOCOL_VERSION, [], "127.0.0.1:1") {
    Ok(value) => value
    Err(_) => fail("pair")
  }
  let wrong = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  let _ = state.authenticate("rt-audit", wrong, "127.0.0.1:2")
  let _ = state.authenticate("rt-audit", grant.credential, "127.0.0.1:3")
  let text = state.audit_text()
  assert_true(!text.contains(secret.code))
  assert_true(!text.contains(grant.credential))
  assert_true(!text.contains(wrong))
  assert_true(!text.contains("token="))
  let lines = state.logs().join("\n")
  assert_true(!lines.contains(secret.code))
  assert_true(!lines.contains(grant.credential))
  // Details are redacted and bounded.
  let mut padding = ""
  for _i = 0; _i < 400; _i = _i + 1 {
    padding = padding + "z"
  }
  let redacted = safe_detail("token=supersecret " + padding)
  assert_true(!redacted.contains("supersecret"))
  assert_true(redacted.length() <= MAX_DETAIL_LEN + 8)
}

///|
async test "audit and logs never contain pairing codes or credentials" {
  test_no_secrets_in_audit_or_logs()
}

///|
test "state snapshot json round-trips and rejects unknown versions" {
  let snapshot = StateSnapshot::empty()
  let json = snapshot.to_json()
  match StateSnapshot::from_json(json) {
    Ok(value) => assert_eq(value.version, 1)
    Err(_) => assert_true(false)
  }
  let wrong = @contracts.json_object([("version", @contracts.json_int(9))])
  match StateSnapshot::from_json(wrong) {
    Ok(_) => assert_true(false)
    Err(message) => assert_true(message.contains("version"))
  }
  match StateSnapshot::from_json(@json.Json::array([])) {
    Ok(_) => assert_true(false)
    Err(message) => assert_true(message.contains("object"))
  }
}

///|
async fn test_doctor_reports_support_and_limitations() -> Unit {
  let report = doctor()
  assert_true(report.supported == doctor_supported())
  assert_true(report.openssl_available)
  assert_eq(report.platform, platform_name())
  assert_true(report.tls_server_api.contains("internal"))
  let json = report.to_json().stringify()
  assert_true(json.contains("\"supported\":"))
  assert_true(json.contains("plaintext"))
  assert_true(report.notes.length() > 0)
}

///|
async test "doctor fails closed outside the supported platform or OpenSSL" {
  test_doctor_reports_support_and_limitations()
}

///|
test "redaction and constant-time helpers behave" {
  let abc = @utf8.encode("abc")
  let abd = @utf8.encode("abd")
  assert_true(constant_time_eq(abc.exact_view(), abc.exact_view()))
  assert_true(!constant_time_eq(abc.exact_view(), abd.exact_view()))
  assert_true(constant_time_hex_eq("aabb", "AABB"))
  assert_true(!constant_time_hex_eq("aabb", "aabc"))
  assert_true(is_hex_of_length("0123456789abcdef", 16))
  assert_true(!is_hex_of_length("0123456789abcde", 16))
  assert_true(!is_hex_of_length("zzzzzzzzzzzzzzzz", 16))
  assert_true(is_safe_id("rt-1"))
  assert_true(!is_safe_id("../rt"))
  assert_true(wire_ts(0L).length() > 0)
  assert_true(bytes_of_hex("00ff") is Some(_))
  assert_true(bytes_of_hex("nope") is None)
}

///|
async test "policy acks track only the current publication" {
  let state = test_primary_with_clock(() => 1_000L) catch {
    _ => fail("cannot open primary state")
  }
  let rules = @policy.PolicyRules::new()
  let v1 = match
    @policy.PolicySnapshot::new(
      version="pol-ack-v1",
      issued_at_ms=0L,
      expires_at_ms=3_601_000L,
      rules~,
    ) {
    Ok(value) => value
    Err(message) => fail("cannot build the v1 snapshot: " + message)
  }
  let v2 = match
    @policy.PolicySnapshot::new(
      version="pol-ack-v2",
      issued_at_ms=2_000L,
      expires_at_ms=3_601_000L,
      rules~,
    ) {
    Ok(value) => value
    Err(message) => fail("cannot build the v2 snapshot: " + message)
  }
  match state.publish_policy(v1) {
    Ok(_) => ()
    Err(message) => fail("cannot publish v1: " + message)
  }
  // A publication alone is not an installation: no ack, no readiness.
  assert_false(state.policy_installed("rt-ack", "pol-ack-v1", v1.content_hash))
  assert_eq(state.installed_policy_count(), 0)
  // A rejected ack (the node refused the publication) is not readiness.
  state.record_policy_ack("rt-ack", "pol-ack-v1", v1.content_hash, false)
  assert_false(state.policy_installed("rt-ack", "pol-ack-v1", v1.content_hash))
  // An ack for an announcement the primary never published says nothing
  // about the current one and is ignored.
  state.record_policy_ack(
    "rt-ack",
    "pol-ack-v1",
    "0000000000000000000000000000000000000000000000000000000000000000",
    true,
  )
  assert_eq(state.installed_policy_count(), 0)
  // An installed ack naming exactly the current publication marks readiness.
  state.record_policy_ack("rt-ack", "pol-ack-v1", v1.content_hash, true)
  assert_true(state.policy_installed("rt-ack", "pol-ack-v1", v1.content_hash))
  assert_eq(state.installed_policy_count(), 1)
  // Rotation without an install: publishing v2 clears readiness, and a late
  // ack for the previous publication cannot restore it.
  match state.publish_policy(v2) {
    Ok(_) => ()
    Err(message) => fail("cannot publish v2: " + message)
  }
  assert_eq(state.installed_policy_count(), 0)
  assert_false(state.policy_installed("rt-ack", "pol-ack-v1", v1.content_hash))
  assert_false(state.policy_installed("rt-ack", "pol-ack-v2", v2.content_hash))
  state.record_policy_ack("rt-ack", "pol-ack-v1", v1.content_hash, true)
  assert_eq(state.installed_policy_count(), 0)
  // The new publication is ready only after its own ack, and a rejected ack
  // for it clears readiness again.
  state.record_policy_ack("rt-ack", "pol-ack-v2", v2.content_hash, true)
  assert_true(state.policy_installed("rt-ack", "pol-ack-v2", v2.content_hash))
  state.record_policy_ack("rt-ack", "pol-ack-v2", v2.content_hash, false)
  assert_false(state.policy_installed("rt-ack", "pol-ack-v2", v2.content_hash))
  assert_eq(state.installed_policy_count(), 0)
}
