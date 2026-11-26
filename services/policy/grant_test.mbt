///|
/// Approval grant tests: binding, freshness, single-use nonces and safe
/// diagnostics.

///|
fn vector_digest() -> String {
  vector_request().digest()
}

///|
fn grant_with(
  run_id? : String = "run_1",
  command_digest? : String = vector_request().digest(),
  policy_version? : String = "pol-1",
  policy_hash? : String = test_snapshot().content_hash,
  nonce? : String = "nonce-0123456789abcdef",
  issued_at_ms? : Int64 = TEST_T0,
  expires_at_ms? : Int64 = TEST_T0 + 300_000L,
  reason? : String = "owner approved one command",
  decision_id? : String = "dec_1",
) -> @policy.ApprovalGrant {
  match
    @policy.ApprovalGrant::new(
      run_id~,
      command_digest~,
      policy_version~,
      policy_hash~,
      nonce~,
      issued_at_ms~,
      expires_at_ms~,
      reason~,
      decision_id~,
    ) {
    Ok(value) => value
    Err(reason) => abort("could not build test grant: " + reason)
  }
}

///|
test "grant: a valid grant verifies once and then replays" {
  let grant = grant_with()
  let consumed = @policy.ConsumedNonces::new()
  match
    @policy.verify_and_consume_for_request(
      grant,
      "run_1",
      vector_request(),
      Some(test_snapshot()),
      TEST_T0 + 1_000L,
      consumed,
    ) {
    Ok(_) => ()
    Err(error) => fail("valid grant was rejected: " + error.label())
  }
  assert_true(consumed.contains("nonce-0123456789abcdef"))
  match
    @policy.verify_and_consume_for_request(
      grant,
      "run_1",
      vector_request(),
      Some(test_snapshot()),
      TEST_T0 + 2_000L,
      consumed,
    ) {
    Ok(_) => fail("replayed grant was accepted")
    Err(error) => assert_eq(error.label(), "replayed_nonce")
  }
}

///|
test "grant: encode/decode round-trip" {
  let grant = grant_with(reason="owner approved", decision_id="dec_42")
  let decoded = match @policy.ApprovalGrant::decode(grant.encode()) {
    Ok(value) => value
    Err(error) => fail("grant decode failed: " + error)
  }
  assert_eq(decoded.run_id, "run_1")
  assert_eq(decoded.command_digest, vector_digest())
  assert_eq(decoded.policy_version, "pol-1")
  assert_eq(decoded.nonce, "nonce-0123456789abcdef")
  assert_eq(decoded.issued_at_ms, TEST_T0)
  assert_eq(decoded.expires_at_ms, TEST_T0 + 300_000L)
  assert_eq(decoded.reason, "owner approved")
  assert_eq(decoded.decision_id, "dec_42")
}

///|
test "grant: wrong run is rejected" {
  let grant = grant_with()
  match
    @policy.verify_grant(
      grant,
      "run_2",
      vector_digest(),
      Some(test_snapshot()),
      TEST_T0,
    ) {
    Ok(_) => fail("grant for another run was accepted")
    Err(error) => assert_eq(error.label(), "run_mismatch")
  }
}

///|
test "grant: wrong digest is rejected" {
  let grant = grant_with()
  let other = @policy.ExecutionRequest::new(
    operation=@policy.PolicyOperation::Exec,
    argv=["git", "status"],
    cwd="/home/user/ws",
    workspace_root="/home/user/ws",
    env_names=["LANG", "PATH"],
  )
  match
    @policy.verify_grant_for_request(
      grant,
      "run_1",
      other,
      Some(test_snapshot()),
      TEST_T0,
    ) {
    Ok(_) => fail("grant bound to another digest was accepted")
    Err(error) => assert_eq(error.label(), "digest_mismatch")
  }
}

///|
test "grant: a different policy snapshot hash is rejected" {
  let grant = grant_with(
    policy_hash="0000000000000000000000000000000000000000000000000000000000000000",
  )
  match
    @policy.verify_grant(
      grant,
      "run_1",
      vector_digest(),
      Some(test_snapshot()),
      TEST_T0,
    ) {
    Ok(_) => fail("grant naming another snapshot hash was accepted")
    Err(error) => assert_eq(error.label(), "policy_hash_mismatch")
  }
}

///|
test "grant: decoding requires the policy snapshot hash" {
  let grant = grant_with()
  let broken = grant.encode().replace(
    old="\"policy_hash\":\"" + test_snapshot().content_hash + "\",",
    new="",
  )
  match @policy.ApprovalGrant::decode(broken) {
    Ok(_) => fail("grant without a policy hash was accepted")
    Err(reason) => assert_true(reason.contains("policy_hash"))
  }
}

///|
test "grant: unknown policy version is rejected" {
  let grant = grant_with(policy_version="pol-2")
  match
    @policy.verify_grant(
      grant,
      "run_1",
      vector_digest(),
      Some(test_snapshot()),
      TEST_T0,
    ) {
    Ok(_) => fail("grant for another policy version was accepted")
    Err(error) => assert_eq(error.label(), "policy_version_mismatch")
  }
}

///|
test "grant: missing or stale policy is rejected" {
  let grant = grant_with()
  match
    @policy.verify_grant(grant, "run_1", vector_digest(), None, TEST_T0) {
    Ok(_) => fail("grant was accepted without a policy snapshot")
    Err(error) => assert_eq(error.label(), "policy_unavailable")
  }
  match
    @policy.verify_grant(
      grant,
      "run_1",
      vector_digest(),
      Some(test_snapshot()),
      TEST_T0 + 3_600_001L,
    ) {
    Ok(_) => fail("grant was accepted against a stale snapshot")
    Err(error) => assert_eq(error.label(), "policy_stale")
  }
}

///|
test "grant: expired and not-yet-valid grants are rejected" {
  let expired = grant_with()
  match
    @policy.verify_grant(
      expired,
      "run_1",
      vector_digest(),
      Some(test_snapshot()),
      TEST_T0 + 300_001L,
    ) {
    Ok(_) => fail("expired grant was accepted")
    Err(error) => assert_eq(error.label(), "expired")
  }
  let future = grant_with(
    issued_at_ms=TEST_T0 + 120_000L,
    expires_at_ms=TEST_T0 + 180_000L,
  )
  match
    @policy.verify_grant(
      future,
      "run_1",
      vector_digest(),
      Some(test_snapshot()),
      TEST_T0,
    ) {
    Ok(_) => fail("not-yet-valid grant was accepted")
    Err(error) => assert_eq(error.label(), "not_yet_valid")
  }
}

///|
test "grant: lifetime beyond the maximum is rejected" {
  match
    @policy.ApprovalGrant::new(
      run_id="run_1",
      command_digest=vector_digest(),
      policy_version="pol-1",
      policy_hash=test_snapshot().content_hash,
      nonce="nonce-0123456789abcdef",
      issued_at_ms=TEST_T0,
      expires_at_ms=TEST_T0 + 600_001L,
    ) {
    Ok(_) => fail("over-long grant lifetime was accepted")
    Err(reason) => assert_true(reason.contains("lifetime"))
  }
  let grant = grant_with()
  let tampered = grant.encode().replace(
    old="\"expires_at_ms\":" + (TEST_T0 + 300_000L).to_string(),
    new="\"expires_at_ms\":" + (TEST_T0 + 600_001L).to_string(),
  )
  match @policy.ApprovalGrant::decode(tampered) {
    Ok(_) => fail("decoded grant with over-long lifetime")
    Err(reason) => assert_true(reason.contains("lifetime"))
  }
}

///|
test "grant: malformed grants and unknown keys are rejected" {
  match @policy.ApprovalGrant::decode("{not json") {
    Ok(_) => fail("malformed JSON was accepted")
    Err(reason) => assert_true(reason.contains("not valid JSON"))
  }
  let grant = grant_with()
  let extended = grant.encode().replace(
    old="\"run_id\":\"run_1\"",
    new="\"run_id\":\"run_1\",\"surprise\":1",
  )
  match @policy.ApprovalGrant::decode(extended) {
    Ok(_) => fail("unknown grant field was accepted")
    Err(reason) => assert_true(reason.contains("unknown field"))
  }
  let upgraded = grant.encode().replace(
    old="\"format_version\":1",
    new="\"format_version\":2",
  )
  match @policy.ApprovalGrant::decode(upgraded) {
    Ok(_) => fail("unknown grant format version was accepted")
    Err(reason) => assert_true(reason.contains("unknown format_version"))
  }
}

///|
test "grant: failed attempts do not burn a valid nonce" {
  let grant = grant_with()
  let consumed = @policy.ConsumedNonces::new()
  match
    @policy.verify_and_consume_for_request(
      grant,
      "run_2",
      vector_request(),
      Some(test_snapshot()),
      TEST_T0,
      consumed,
    ) {
    Ok(_) => fail("wrong run was accepted")
    Err(error) => assert_eq(error.label(), "run_mismatch")
  }
  assert_false(consumed.contains("nonce-0123456789abcdef"))
  match
    @policy.verify_and_consume_for_request(
      grant,
      "run_1",
      vector_request(),
      Some(test_snapshot()),
      TEST_T0,
      consumed,
    ) {
    Ok(_) => ()
    Err(error) => fail("grant was burned by a failed attempt: " + error.label())
  }
}

///|
test "grant: consumed-nonce memory is bounded and evicts the earliest expiry" {
  let consumed = @policy.ConsumedNonces::new(capacity=2)
  assert_eq(consumed.capacity(), 2)
  let nonces : Array[String] = [
    "nonce-aaaaaaaaaaaaaaaa",
    "nonce-bbbbbbbbbbbbbbbb",
    "nonce-cccccccccccccccc",
  ]
  let expiries : Array[Int64] = [
    TEST_T0 + 100_000L,
    TEST_T0 + 200_000L,
    TEST_T0 + 300_000L,
  ]
  let mut index = 0
  while index < nonces.length() {
    let grant = grant_with(
      nonce=nonces[index],
      expires_at_ms=expiries[index],
    )
    match
      @policy.verify_and_consume_for_request(
        grant,
        "run_1",
        vector_request(),
        Some(test_snapshot()),
        TEST_T0,
        consumed,
      ) {
      Ok(_) => ()
      Err(error) => fail("grant was rejected: " + error.label())
    }
    index = index + 1
  }
  assert_eq(consumed.count(), 2)
  assert_false(consumed.contains(nonces[0]))
  assert_true(consumed.contains(nonces[1]))
  assert_true(consumed.contains(nonces[2]))
}

///|
test "grant: errors and encodings do not echo the nonce" {
  let nonce = "nonce-0123456789abcdef"
  let grant = grant_with(nonce=nonce)
  let errors : Array[@policy.GrantError] = [
    @policy.GrantError::MalformedGrant,
    @policy.GrantError::RunMismatch,
    @policy.GrantError::DigestMismatch,
    @policy.GrantError::PolicyUnavailable,
    @policy.GrantError::PolicyVersionMismatch,
    @policy.GrantError::PolicyHashMismatch,
    @policy.GrantError::PolicyStale,
    @policy.GrantError::NotYetValid,
    @policy.GrantError::Expired,
    @policy.GrantError::TtlTooLong,
    @policy.GrantError::ReplayedNonce,
  ]
  for error in errors {
    assert_false(error.message().contains(nonce))
  }
  let decision = @policy.evaluate(
    @policy.PolicyContext::with_snapshot(
      test_snapshot(),
      now_ms=TEST_T0,
      primary_reachable=true,
    ),
    vector_request(),
  )
  assert_false(decision.encode().contains(nonce))
  // Decoding diagnostics are fixed text as well.
  let broken = grant.encode().replace(
    old="\"nonce\":\"" + nonce + "\"",
    new="\"nonce\":12345",
  )
  match @policy.ApprovalGrant::decode(broken) {
    Ok(_) => fail("numeric nonce was accepted")
    Err(reason) => {
      assert_true(reason.contains("nonce"))
      assert_false(reason.contains(nonce))
    }
  }
}
