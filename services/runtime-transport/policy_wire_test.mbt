///|
/// Policy snapshot distribution tests (A1.3b).
///
/// The announcement is the only path by which the primary's policy reaches a
/// node. These tests pin the wire shape, the hash check and the 0600 state
/// file rules; the node's use of the announcement is covered by
/// `services/runtime-node/policy_approval_test.mbt`.

///|
fn pw_snapshot(
  version : String,
  issued_at_ms : Int64,
  expires_at_ms : Int64,
) -> @policy.PolicySnapshot {
  let rules = @policy.PolicyRules::new(
    allow_read_only=true,
    allowed_operations=["fs.write"],
    denied_patterns=["curl http"],
    high_risk_operations=["pty.open"],
    env_allowlist=["PATH"],
  )
  match
    @policy.PolicySnapshot::new(
      version~,
      issued_at_ms~,
      expires_at_ms~,
      rules~,
    ) {
    Ok(value) => value
    Err(message) => abort("cannot build the test snapshot: " + message)
  }
}

///|
fn pw_announcement(
  version : String,
  issued_at_ms : Int64,
  expires_at_ms : Int64,
) -> PolicyAnnouncement {
  let snapshot = pw_snapshot(version, issued_at_ms, expires_at_ms)
  match PolicyAnnouncement::from_snapshot(snapshot) {
    Ok(value) => value
    Err(message) => abort("cannot build the test announcement: " + message)
  }
}

///|
fn pw_repeat(text : String, count : Int) -> String {
  let mut out = ""
  let mut index = 0
  while index < count {
    out = out + text
    index = index + 1
  }
  out
}

///|
test "policy announcement round-trips version, hash and snapshot" {
  let announcement = pw_announcement("pol-v1", 1_000L, 9_999_999_999_999L)
  let parsed = match PolicyAnnouncement::from_json(announcement.to_json()) {
    Ok(value) => value
    Err(message) => fail("announcement did not round-trip: " + message)
  }
  assert_eq(parsed.version, "pol-v1")
  assert_eq(parsed.hash, announcement.hash)
  assert_eq(parsed.snapshot, announcement.snapshot)
  let verified = match parsed.verify() {
    Ok(value) => value
    Err(message) => fail("announcement did not verify: " + message)
  }
  assert_eq(verified.version, "pol-v1")
  assert_eq(verified.content_hash, announcement.hash)
  assert_true(verified.rules.allow_read_only)
  // The notification params use the same shape as the hello result.
  let params = parsed.to_params()
  assert_eq(
    @contracts.string_field_or(params, "version", ""),
    "pol-v1",
  )
  assert_eq(
    @contracts.string_field_or(params, "hash", ""),
    announcement.hash,
  )
  assert_eq(
    @contracts.string_field_or(params, "snapshot", ""),
    announcement.snapshot,
  )
}

///|
test "policy announcement rejects a mismatched pin, snapshot and version" {
  let snapshot = pw_snapshot("pol-v1", 1_000L, 9_999_999_999_999L)
  let other = pw_snapshot("pol-v2", 1_000L, 9_999_999_999_999L)
  // A different snapshot under v1's pin must fail verification; this is the
  // tampered-state-file and mixed-up-announcement case.
  let mixed = match
    PolicyAnnouncement::new(
      "pol-v1",
      snapshot.content_hash,
      other.encode(),
    ) {
    Ok(value) => value
    Err(message) => fail("announcement construction failed: " + message)
  }
  assert_true(mixed.verify() is Err(_))
  // A well-formed announcement whose version does not match its snapshot.
  let relabelled = match
    PolicyAnnouncement::new(
      "pol-v3",
      snapshot.content_hash,
      snapshot.encode(),
    ) {
    Ok(value) => value
    Err(message) => fail("announcement construction failed: " + message)
  }
  assert_true(relabelled.verify() is Err(_))
  // A malformed snapshot under a valid pin fails instead of half-decoding.
  let malformed = match
    PolicyAnnouncement::new("pol-v1", snapshot.content_hash, "{\"version\":") {
    Ok(value) => value
    Err(message) => fail("announcement construction failed: " + message)
  }
  assert_true(malformed.verify() is Err(_))
}

///|
test "policy announcement bounds versions, hashes and snapshot text" {
  let snapshot = pw_snapshot("pol-v1", 1_000L, 9_999_999_999_999L)
  let hash = snapshot.content_hash
  // Version text: empty, too long, or with control/whitespace characters.
  assert_true(PolicyAnnouncement::new("", hash, snapshot.encode()) is Err(_))
  assert_true(
    PolicyAnnouncement::new("pol v1", hash, snapshot.encode()) is Err(_),
  )
  assert_true(
    PolicyAnnouncement::new(pw_repeat("v", 129), hash, snapshot.encode())
    is Err(_),
  )
  // The pin must be 64 lowercase hex characters.
  assert_true(
    PolicyAnnouncement::new("pol-v1", "ABC", snapshot.encode()) is Err(_),
  )
  assert_true(
    PolicyAnnouncement::new("pol-v1", hash.to_upper(), snapshot.encode())
    is Err(_),
  )
  // Oversized snapshot text cannot be announced.
  let oversized = pw_repeat("x", MAX_POLICY_SNAPSHOT_TEXT_BYTES + 1)
  assert_true(PolicyAnnouncement::new("pol-v1", hash, oversized) is Err(_))
  // Wrong JSON shapes and missing fields are rejected, never defaulted.
  assert_true(PolicyAnnouncement::from_json(@contracts.json_string("x")) is Err(_))
  assert_true(
    PolicyAnnouncement::from_json(@contracts.json_object([])) is Err(_)
  )
  assert_true(
    PolicyAnnouncement::from_json(
      @contracts.json_object([("hash", @contracts.json_string(hash))]),
    )
    is Err(_),
  )
}

///|
async test "policy announcement persists 0600 and reloads verified" {
  let dir = @fs.tmpdir(prefix="monexus-policy-wire-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/policy.json"
  let announcement = pw_announcement("pol-v1", 1_000L, 9_999_999_999_999L)
  match
    save_policy_announcement(path, announcement.to_json().stringify()) {
    Ok(_) => ()
    Err(message) => fail("cannot persist the announcement: " + message)
  }
  match stat_path(path) {
    Some(info) => assert_eq(info.mode & 0o777, 0o600)
    None => fail("policy file is missing after save")
  }
  let loaded = match load_policy_announcement(path) {
    Ok(value) => value
    Err(message) => fail("cannot load the announcement: " + message)
  }
  assert_eq(loaded.version, "pol-v1")
  assert_eq(loaded.hash, announcement.hash)
  let verified = match loaded.verify() {
    Ok(value) => value
    Err(message) => fail("reloaded announcement did not verify: " + message)
  }
  assert_eq(verified.content_hash, announcement.hash)
  // Replacing the file is atomic and keeps it 0600.
  let next = pw_announcement("pol-v2", 1_000L, 9_999_999_999_999L)
  match save_policy_announcement(path, next.to_json().stringify()) {
    Ok(_) => ()
    Err(message) => fail("cannot replace the announcement: " + message)
  }
  assert_eq(load_policy_announcement(path).unwrap().version, "pol-v2")
  match stat_path(path) {
    Some(info) => assert_eq(info.mode & 0o777, 0o600)
    None => fail("policy file is missing after replace")
  }
}

///|
async test "policy file loading rejects wrong mode, size and tampering" {
  let dir = @fs.tmpdir(prefix="monexus-policy-wire-bad-")
  defer @fs.rmdir(dir, recursive=true)
  let announcement = pw_announcement("pol-v1", 1_000L, 9_999_999_999_999L)
  let text = announcement.to_json().stringify()
  // A 0644 file is not a private state file.
  let loose = dir + "/loose.json"
  @fs.write_file(loose, text, permission=0o644, sync=@fs.SyncMode::Data) catch {
    _ => fail("cannot write the 0644 policy file")
  }
  assert_true(load_policy_announcement(loose) is Err(_))
  // An oversized file is refused before it can fill memory or a frame.
  let oversized = dir + "/oversized.json"
  @fs.write_file(
    oversized,
    pw_repeat("x", MAX_POLICY_ANNOUNCEMENT_BYTES + 1),
    permission=0o600,
    sync=@fs.SyncMode::Data,
  ) catch {
    _ => fail("cannot write the oversized policy file")
  }
  @fs.chmod(oversized, 0o600) catch { _ => () }
  assert_true(load_policy_announcement(oversized) is Err(_))
  // A tampered file still parses, but its pin no longer matches; the node
  // calls `verify` before installing, so this can never become policy.
  let other = pw_snapshot("pol-v1", 2_000L, 9_999_999_999_999L)
  let tampered_text = match
    PolicyAnnouncement::new("pol-v1", announcement.hash, other.encode()) {
    Ok(value) => value.to_json().stringify()
    Err(message) => fail("cannot build the tampered announcement: " + message)
  }
  let tampered = dir + "/tampered.json"
  @fs.write_file(
    tampered,
    tampered_text,
    permission=0o600,
    sync=@fs.SyncMode::Data,
  ) catch {
    _ => fail("cannot write the tampered policy file")
  }
  let loaded = match load_policy_announcement(tampered) {
    Ok(value) => value
    Err(message) => fail("tampered file should still parse: " + message)
  }
  assert_true(loaded.verify() is Err(_))
}
