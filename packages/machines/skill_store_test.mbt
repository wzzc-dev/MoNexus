///|
/// Skill store tests (ADR-0015 §11): additive tables, exact-tuple identity,
/// upserts, revocation, binding scopes, permission ceilings and the invocation
/// idempotency projection.

///|
fn skst_store() -> @machines.MachineStore raise {
  match @machines.MachineStore::open(":memory:") {
    Ok(value) => value
    Err(message) => fail("cannot open in-memory store: " + message)
  }
}

///|
fn skst_row(hash : String) -> @machines.SkillRow {
  {
    id: "skl_1",
    name: "repo-health",
    version: "1.0.0",
    content_hash: hash,
    key_id: "owner-key-1",
    state: "active",
    manifest_json: "{\"name\":\"repo-health\"}",
    signature: "sig-bytes",
    source: "local_directory",
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
  }
}

///|
fn skst_allow(hash : String, state : String) -> @machines.SkillAllowRow {
  {
    name: "repo-health",
    version: "1.0.0",
    content_hash: hash,
    key_id: "owner-key-1",
    state,
    reason: "owner_import",
    added_at: "2026-01-01T00:00:00Z",
    revoked_at: "",
  }
}

///|
fn skst_binding(
  scope : String,
  scope_ref : String,
  mode : String,
) -> @machines.SkillBindingRow {
  {
    scope,
    scope_ref,
    name: "repo-health",
    version: "1.0.0",
    content_hash: SKST_HASH,
    mode,
    enabled_at: "2026-01-01T00:00:00Z",
  }
}

///|
fn skst_invocation(
  request_id : String,
  status : String,
) -> @machines.SkillInvocationRow {
  {
    id: "inv_" + request_id,
    request_id,
    session_id: "ses_1",
    name: "repo-health",
    version: "1.0.0",
    content_hash: SKST_HASH,
    entry_id: "status",
    argv_hash: "argv-hash",
    status,
    exit_code: 0,
    decision_id: "",
    run_id: "run_1",
    output_bytes: 12,
    created_at: "2026-01-01T00:00:00Z",
  }
}

///|
const SKST_HASH : String =
  "sha256:1111111111111111111111111111111111111111111111111111111111111111"

///|
test "skill rows are keyed by the exact tuple and upsert in place" {
  let store = skst_store()
  match store.put_skill_row(skst_row(SKST_HASH)) {
    Ok(_) => ()
    Err(message) => fail("put_skill_row failed: " + message)
  }
  let same = match store.get_skill_row("repo-health", "1.0.0", SKST_HASH) {
    Ok(Some(value)) => value
    Ok(None) => fail("skill row was not found")
    Err(message) => fail("get_skill_row failed: " + message)
  }
  assert_eq(same.key_id, "owner-key-1")
  assert_eq(same.created_at, "2026-01-01T00:00:00Z")
  // A different version is a different identity, not an overwrite.
  let other_hash = "sha256:2222222222222222222222222222222222222222222222222222222222222222"
  let mut second = skst_row(other_hash)
  second = { ..second, id: "skl_2", version: "2.0.0" }
  match store.put_skill_row(second) {
    Ok(_) => ()
    Err(message) => fail("put_skill_row failed: " + message)
  }
  match store.list_skill_rows() {
    Ok(rows) => assert_eq(rows.length(), 2)
    Err(message) => fail("list_skill_rows failed: " + message)
  }
  // Re-putting the first tuple updates its state instead of duplicating it.
  let updated = { ..skst_row(SKST_HASH), state: "disabled" }
  match store.put_skill_row(updated) {
    Ok(_) => ()
    Err(message) => fail("put_skill_row failed: " + message)
  }
  match store.list_skill_rows() {
    Ok(rows) => {
      assert_eq(rows.length(), 2)
      assert_eq(rows[0].state, "disabled")
    }
    Err(message) => fail("list_skill_rows failed: " + message)
  }
  match store.set_skill_row_state("repo-health", "1.0.0", SKST_HASH, "active", "2026-01-02T00:00:00Z") {
    Ok(_) => ()
    Err(message) => fail("set_skill_row_state failed: " + message)
  }
  match store.remove_skill_row("repo-health", "1.0.0", SKST_HASH) {
    Ok(_) => ()
    Err(message) => fail("remove_skill_row failed: " + message)
  }
  match store.get_skill_row("repo-health", "1.0.0", SKST_HASH) {
    Ok(None) => ()
    Ok(Some(_)) => fail("removed skill row is still visible")
    Err(message) => fail("get_skill_row failed: " + message)
  }
  store.close()
}

///|
test "skill allowlist is an exact tuple with revocable state" {
  let store = skst_store()
  match store.allow_skill(skst_allow(SKST_HASH, "allowed")) {
    Ok(_) => ()
    Err(message) => fail("allow_skill failed: " + message)
  }
  match store.get_skill_allow("repo-health", "1.0.0", SKST_HASH) {
    Ok(Some(row)) => {
      assert_eq(row.state, "allowed")
      assert_eq(row.key_id, "owner-key-1")
      assert_eq(row.revoked_at, "")
    }
    Ok(None) => fail("allow row was not found")
    Err(message) => fail("get_skill_allow failed: " + message)
  }
  // A different hash is not covered by the same allow row.
  let other_hash = "sha256:3333333333333333333333333333333333333333333333333333333333333333"
  match store.get_skill_allow("repo-health", "1.0.0", other_hash) {
    Ok(None) => ()
    Ok(Some(_)) => fail("allow lookup ignored the content hash")
    Err(message) => fail("get_skill_allow failed: " + message)
  }
  match store.revoke_skill_allow("repo-health", "1.0.0", SKST_HASH, "owner_revoked", "2026-02-01T00:00:00Z") {
    Ok(_) => ()
    Err(message) => fail("revoke_skill_allow failed: " + message)
  }
  match store.list_skill_allows() {
    Ok(rows) => {
      assert_eq(rows.length(), 1)
      assert_eq(rows[0].state, @contracts.SKILL_STATUS_REVOKED)
      assert_eq(rows[0].reason, "owner_revoked")
      assert_eq(rows[0].revoked_at, "2026-02-01T00:00:00Z")
    }
    Err(message) => fail("list_skill_allows failed: " + message)
  }
  store.close()
}

///|
test "skill keys round-trip and revocation is persisted" {
  let store = skst_store()
  match store.put_skill_key("owner-key-1", "ssh-ed25519 AAAA", "2026-01-01T00:00:00Z") {
    Ok(_) => ()
    Err(message) => fail("put_skill_key failed: " + message)
  }
  match store.list_skill_keys() {
    Ok(keys) => {
      assert_eq(keys.length(), 1)
      assert_eq(keys[0].key_id, "owner-key-1")
      assert_eq(keys[0].revoked, false)
    }
    Err(message) => fail("list_skill_keys failed: " + message)
  }
  match store.revoke_skill_key("owner-key-1", "2026-02-01T00:00:00Z") {
    Ok(_) => ()
    Err(message) => fail("revoke_skill_key failed: " + message)
  }
  match store.list_skill_keys() {
    Ok(keys) => {
      assert_eq(keys.length(), 1)
      assert_eq(keys[0].revoked, true)
    }
    Err(message) => fail("list_skill_keys failed: " + message)
  }
  store.close()
}

///|
test "bindings are per-scope and removable by exact tuple" {
  let store = skst_store()
  match store.put_skill_binding(skst_binding(@contracts.SKILL_SCOPE_AGENT, "agt_1", @contracts.SKILL_MODE_LOADED)) {
    Ok(_) => ()
    Err(message) => fail("put_skill_binding failed: " + message)
  }
  match store.put_skill_binding(skst_binding(@contracts.SKILL_SCOPE_TASK, "tsk_1", @contracts.SKILL_MODE_AVAILABLE)) {
    Ok(_) => ()
    Err(message) => fail("put_skill_binding failed: " + message)
  }
  match store.put_skill_binding(skst_binding(@contracts.SKILL_SCOPE_SESSION, "ses_1", @contracts.SKILL_MODE_AVAILABLE)) {
    Ok(_) => ()
    Err(message) => fail("put_skill_binding failed: " + message)
  }
  // Same (scope, scope_ref, name) upserts in place.
  match store.put_skill_binding(skst_binding(@contracts.SKILL_SCOPE_AGENT, "agt_1", @contracts.SKILL_MODE_AVAILABLE)) {
    Ok(_) => ()
    Err(message) => fail("put_skill_binding failed: " + message)
  }
  match store.get_skill_binding(@contracts.SKILL_SCOPE_AGENT, "agt_1", "repo-health") {
    Ok(Some(row)) => assert_eq(row.mode, @contracts.SKILL_MODE_AVAILABLE)
    Ok(None) => fail("agent binding was not found")
    Err(message) => fail("get_skill_binding failed: " + message)
  }
  match store.list_skill_bindings(@contracts.SKILL_SCOPE_AGENT, "agt_1") {
    Ok(rows) => assert_eq(rows.length(), 1)
    Err(message) => fail("list_skill_bindings failed: " + message)
  }
  match store.list_all_skill_bindings() {
    Ok(rows) => assert_eq(rows.length(), 3)
    Err(message) => fail("list_all_skill_bindings failed: " + message)
  }
  match store.remove_skill_bindings_for("repo-health", "1.0.0", SKST_HASH) {
    Ok(count) => assert_eq(count, 3)
    Err(message) => fail("remove_skill_bindings_for failed: " + message)
  }
  match store.list_all_skill_bindings() {
    Ok(rows) => assert_eq(rows.length(), 0)
    Err(message) => fail("list_all_skill_bindings failed: " + message)
  }
  match store.put_skill_binding(skst_binding(@contracts.SKILL_SCOPE_TASK, "tsk_1", @contracts.SKILL_MODE_LOADED)) {
    Ok(_) => ()
    Err(message) => fail("put_skill_binding failed: " + message)
  }
  match store.remove_skill_binding(@contracts.SKILL_SCOPE_TASK, "tsk_1", "repo-health") {
    Ok(_) => ()
    Err(message) => fail("remove_skill_binding failed: " + message)
  }
  match store.get_skill_binding(@contracts.SKILL_SCOPE_TASK, "tsk_1", "repo-health") {
    Ok(None) => ()
    Ok(Some(_)) => fail("removed binding is still visible")
    Err(message) => fail("get_skill_binding failed: " + message)
  }
  store.close()
}

///|
test "per-agent permission ceilings round-trip their exact set" {
  let store = skst_store()
  match store.get_agent_skill_permissions("agt_1") {
    Ok(None) => ()
    Ok(Some(_)) => fail("an unset ceiling must be absent")
    Err(message) => fail("get_agent_skill_permissions failed: " + message)
  }
  match store.set_agent_skill_permissions(
    "agt_1",
    ["workspace.read", "git.read", "exec.readonly"],
    "2026-01-01T00:00:00Z",
  ) {
    Ok(_) => ()
    Err(message) => fail("set_agent_skill_permissions failed: " + message)
  }
  match store.get_agent_skill_permissions("agt_1") {
    Ok(Some(permissions)) =>
      assert_eq(permissions, ["workspace.read", "git.read", "exec.readonly"])
    Ok(None) => fail("ceiling was not persisted")
    Err(message) => fail("get_agent_skill_permissions failed: " + message)
  }
  match store.set_agent_skill_permissions("agt_1", ["git.read"], "2026-01-02T00:00:00Z") {
    Ok(_) => ()
    Err(message) => fail("set_agent_skill_permissions failed: " + message)
  }
  match store.get_agent_skill_permissions("agt_1") {
    Ok(Some(permissions)) => assert_eq(permissions, ["git.read"])
    Ok(None) => fail("updated ceiling was not persisted")
    Err(message) => fail("get_agent_skill_permissions failed: " + message)
  }
  store.close()
}

///|
test "invocations are idempotent by request id and list per session" {
  let store = skst_store()
  match store.record_skill_invocation(skst_invocation("req_1", "running")) {
    Ok(_) => ()
    Err(message) => fail("record_skill_invocation failed: " + message)
  }
  let finished = {
    ..skst_invocation("req_1", "succeeded"),
    exit_code: 0,
    decision_id: "dec_1",
    output_bytes: 42,
  }
  match store.record_skill_invocation(finished) {
    Ok(_) => ()
    Err(message) => fail("record_skill_invocation failed: " + message)
  }
  match store.get_skill_invocation("req_1") {
    Ok(Some(row)) => {
      assert_eq(row.status, "succeeded")
      assert_eq(row.decision_id, "dec_1")
      assert_eq(row.output_bytes, 42)
    }
    Ok(None) => fail("invocation was not found")
    Err(message) => fail("get_skill_invocation failed: " + message)
  }
  match store.record_skill_invocation(skst_invocation("req_2", "denied")) {
    Ok(_) => ()
    Err(message) => fail("record_skill_invocation failed: " + message)
  }
  match store.list_skill_invocations("ses_1") {
    Ok(rows) => assert_eq(rows.length(), 2)
    Err(message) => fail("list_skill_invocations failed: " + message)
  }
  match store.list_skill_invocations("") {
    Ok(rows) => assert_eq(rows.length(), 2)
    Err(message) => fail("list_skill_invocations failed: " + message)
  }
  match store.list_skill_invocations("ses_other") {
    Ok(rows) => assert_eq(rows.length(), 0)
    Err(message) => fail("list_skill_invocations failed: " + message)
  }
  store.close()
}
