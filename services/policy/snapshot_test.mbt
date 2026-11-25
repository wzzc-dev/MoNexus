///|
/// Policy snapshot tests: strict decoding, hash binding and freshness.

///|
const TEST_T0 : Int64 = 1_764_000_000_000L

///|
/// Rules used by the known hash vector and most risk tests. Kept in sync with
/// the documented canonical body; changing it changes the pinned hash.
fn test_rules() -> @policy.PolicyRules {
  @policy.PolicyRules::new(
    allow_read_only=true,
    allowed_operations=["fs.write"],
    allowed_argv_prefixes=["moon test"],
    denied_operations=["git.write"],
    denied_patterns=["curl | sh"],
    high_risk_operations=["pty"],
    high_risk_patterns=[],
    env_allowlist=["PATH", "HOME", "LANG"],
  )
}

///|
fn snapshot_with(
  rules : @policy.PolicyRules,
  version? : String = "pol-1",
  issued_at_ms? : Int64 = TEST_T0,
  expires_at_ms? : Int64 = TEST_T0 + 3_600_000L,
) -> @policy.PolicySnapshot {
  match
    @policy.PolicySnapshot::new(
      version~,
      issued_at_ms~,
      expires_at_ms~,
      rules~,
    ) {
    Ok(value) => value
    Err(reason) => abort("could not build test snapshot: " + reason)
  }
}

///|
fn test_snapshot() -> @policy.PolicySnapshot {
  snapshot_with(test_rules())
}

///|
test "snapshot: encode/decode round-trip keeps the content hash" {
  let snapshot = test_snapshot()
  let decoded = match @policy.PolicySnapshot::decode(snapshot.encode()) {
    Ok(value) => value
    Err(reason) => fail("decode failed: " + reason)
  }
  assert_eq(decoded.version, "pol-1")
  assert_eq(decoded.content_hash, snapshot.content_hash)
  assert_eq(decoded.issued_at_ms, TEST_T0)
  assert_eq(decoded.expires_at_ms, TEST_T0 + 3_600_000L)
  assert_true(decoded.rules.allow_read_only)
  assert_eq(decoded.rules.allowed_operations, ["fs.write"])
  assert_eq(decoded.rules.env_allowlist, ["HOME", "LANG", "PATH"])
}

///|
test "snapshot: known content hash vector" {
  // Pinned so a change to the canonical body is a deliberate, visible change.
  assert_eq(
    test_snapshot().content_hash,
    "06c9e77245c783c2cc85408c7ff659a23363cc1cc0cfcd7247b0853ec58a091d",
  )
}

///|
test "snapshot: pinned hash accepts the matching hash and rejects another" {
  let snapshot = test_snapshot()
  let encoded = snapshot.encode()
  match
    @policy.PolicySnapshot::decode_pinned(encoded, snapshot.content_hash) {
    Ok(_) => ()
    Err(reason) => fail("matching pinned hash was rejected: " + reason)
  }
  match
    @policy.PolicySnapshot::decode_pinned(
      encoded,
      "0000000000000000000000000000000000000000000000000000000000000000",
    ) {
    Ok(_) => fail("mismatched pinned hash was accepted")
    Err(_) => ()
  }
}

///|
test "snapshot: tampered rules are rejected by the content hash" {
  let encoded = test_snapshot().encode()
  let tampered = encoded.replace(old="\"pol-1\"", new="\"pol-2\"")
  assert_false(tampered == encoded)
  match @policy.PolicySnapshot::decode(tampered) {
    Ok(_) => fail("tampered snapshot was accepted")
    Err(reason) => assert_true(reason.contains("hash mismatch"))
  }
}

///|
test "snapshot: unknown format version is rejected" {
  let encoded = test_snapshot().encode()
  let upgraded = encoded.replace(
    old="\"format_version\":1",
    new="\"format_version\":2",
  )
  match @policy.PolicySnapshot::decode(upgraded) {
    Ok(_) => fail("unknown format version was accepted")
    Err(reason) => assert_true(reason.contains("unknown format_version"))
  }
}

///|
test "snapshot: malformed and incomplete JSON are rejected" {
  match @policy.PolicySnapshot::decode("{not json") {
    Ok(_) => fail("malformed JSON was accepted")
    Err(reason) => assert_true(reason.contains("not valid JSON"))
  }
  match @policy.PolicySnapshot::decode("{\"format\":\"monexus.policy.snapshot\"}") {
    Ok(_) => fail("incomplete snapshot was accepted")
    Err(reason) => assert_true(reason.contains("missing field"))
  }
}

///|
test "snapshot: unknown keys are rejected" {
  let encoded = test_snapshot().encode()
  let extended = encoded.replace(
    old="\"allow_read_only\":true",
    new="\"allow_read_only\":true,\"surprise_rule\":true",
  )
  match @policy.PolicySnapshot::decode(extended) {
    Ok(_) => fail("unknown rule key was accepted")
    Err(reason) => assert_true(reason.contains("unknown field"))
  }
}

///|
test "snapshot: invalid version and time range are rejected at construction" {
  match
    @policy.PolicySnapshot::new(
      version="bad version",
      issued_at_ms=TEST_T0,
      expires_at_ms=TEST_T0 + 1_000L,
      rules=test_rules(),
    ) {
    Ok(_) => fail("invalid version was accepted")
    Err(reason) => assert_true(reason.contains("version"))
  }
  match
    @policy.PolicySnapshot::new(
      version="pol-1",
      issued_at_ms=TEST_T0,
      expires_at_ms=TEST_T0,
      rules=test_rules(),
    ) {
    Ok(_) => fail("inverted time range was accepted")
    Err(reason) => assert_true(reason.contains("time range"))
  }
}

///|
test "snapshot: freshness follows the expiry and clock skew" {
  let snapshot = test_snapshot()
  assert_true(snapshot.is_fresh(TEST_T0))
  assert_true(snapshot.is_fresh(TEST_T0 + 3_600_000L))
  assert_false(snapshot.is_fresh(TEST_T0 + 3_600_001L))
  assert_true(snapshot.is_fresh(TEST_T0 - 30_000L))
  assert_false(snapshot.is_fresh(TEST_T0 - 61_000L))
}
