///|
/// Node-side snapshot and approval tests (A1.3b).
///
/// These tests drive `NodeHost::dispatch` directly with real `HandlerRequest`
/// values, so the full node path runs without TLS: snapshot installation,
/// local risk parity with `@policy.evaluate`, grant verification and the
/// replay-memory behaviour. The paired-session path is covered by
/// `host_e2e_test.mbt` and `approval_e2e_test.mbt`.

///|
fn pa_repeat(text : String, count : Int) -> String {
  let mut out = ""
  let mut index = 0
  while index < count {
    out = out + text
    index = index + 1
  }
  out
}

///|
fn pa_snapshot(
  version : String,
  issued_at_ms : Int64,
  expires_at_ms : Int64,
) -> @policy.PolicySnapshot {
  let rules = @policy.PolicyRules::new(
    allow_read_only=true,
    allowed_operations=["fs.write"],
    denied_patterns=["curl http"],
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
fn pa_fresh_snapshot(version : String) -> @policy.PolicySnapshot {
  let now = @async.now()
  pa_snapshot(version, now - 1_000L, now + 3_600_000L)
}

///|
fn pa_announcement(
  snapshot : @policy.PolicySnapshot,
) -> @transport.PolicyAnnouncement {
  match @transport.PolicyAnnouncement::from_snapshot(snapshot) {
    Ok(value) => value
    Err(message) => abort("cannot build the test announcement: " + message)
  }
}

///|
/// Run `body` against a freshly opened node whose gate is the explicit
/// single-machine override. The node and its state directory are removed
/// afterwards.
async fn pa_with_override_node(
  prefix : String,
  body : async (NodeHost, String, String) -> Unit,
) -> Unit {
  let base = @fs.tmpdir(prefix=prefix)
  defer @fs.rmdir(base, recursive=true)
  let workspace = base + "/workspace"
  @fs.mkdir(workspace, permission=0o700, recursive=true, allow_exist=false) catch {
    _ => abort("cannot create the test workspace")
  }
  let host = match
    NodeHost::open(
      "rt-policy-test",
      state_base=base,
      workspace_root=workspace,
      policy=Some(PolicyGate::allow_workspace(workspace)),
    ) {
    Ok(value) => value
    Err(message) => abort("cannot open the node host: " + message)
  }
  body(host, base, workspace)
}

///|
async fn pa_dispatch(
  host : NodeHost,
  rpc_method : String,
  params : Map[String, @json.Json],
  client_request_id : String,
) -> Result[@json.Json, @contracts.RpcError] {
  let request : @transport.HandlerRequest = {
    runtime_id: host.runtime_id(),
    session_id: "test-session",
    rpc_method,
    params,
    client_request_id,
  }
  let outcome : Ref[Result[@json.Json, @contracts.RpcError]?] = Ref(None)
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) {
    outcome.val = Some(host.dispatch(request, group))
  })
  match outcome.val {
    Some(value) => value
    None => abort("dispatch did not run")
  }
}

///|
fn pa_exec_params(
  run_id : String,
  argv : Array[String],
  approval : String,
  cwd~ : String = "",
) -> Map[String, @json.Json] {
  let params : Map[String, @json.Json] = Map([])
  params.set("run_id", @contracts.json_string(run_id))
  params.set("argv", @contracts.json_string_array(argv))
  if cwd != "" {
    params.set("cwd", @contracts.json_string(cwd))
  }
  if approval != "" {
    params.set("approval", @contracts.json_string(approval))
  }
  params
}

///|
fn pa_fs_write_params(path : String, content : String) -> Map[String, @json.Json] {
  let params : Map[String, @json.Json] = Map([])
  params.set("path", @contracts.json_string(path))
  params.set("content", @contracts.json_string(content))
  params
}

///|
fn pa_fs_read_params(path : String) -> Map[String, @json.Json] {
  let params : Map[String, @json.Json] = Map([])
  params.set("path", @contracts.json_string(path))
  params
}

///|
fn pa_json_sub(json : @json.Json, key : String) -> @json.Json {
  match @contracts.as_object(json) {
    Some(object) =>
      match object.get(key) {
        Some(value) => value
        None => @contracts.json_null()
      }
    None => @contracts.json_null()
  }
}

///|
fn pa_json_string(json : @json.Json, key : String) -> String {
  match @contracts.as_object(json) {
    Some(object) => @contracts.string_field_or(object, key, "")
    None => ""
  }
}

///|
fn pa_json_bool(json : @json.Json, key : String) -> Bool {
  match @contracts.as_object(json) {
    Some(object) => @contracts.bool_field_or(object, key, false)
    None => false
  }
}

///|
/// The node's decision-kind label. Refusals label their error payload with the
/// error kind (`approval_binding`, `policy_denied`, `policy_unverifiable`);
/// map those back onto the decision the node made.
fn pa_remote_kind(result : Result[@json.Json, @contracts.RpcError]) -> String {
  match result {
    Ok(value) => pa_json_string(pa_json_sub(value, "policy"), "kind")
    Err(error) =>
      if error.code == @transport.ERR_APPROVAL_REQUIRED {
        "approval_required"
      } else if error.code == @transport.ERR_POLICY_DENIED {
        "deny"
      } else if error.code == @transport.ERR_POLICY_STALE {
        "unverifiable"
      } else {
        "error_" + error.code.to_string()
      }
  }
}

///|
fn pa_error_string(error : @contracts.RpcError, key : String) -> String {
  match error.data {
    Some(data) => pa_json_string(data, key)
    None => ""
  }
}

///|
/// The node's decision for a dispatch. Successes carry it as bounded
/// `policy` metadata; refusals carry the same fields in the error data.
fn pa_decision_field(
  result : Result[@json.Json, @contracts.RpcError],
  key : String,
) -> String {
  match result {
    Ok(value) => pa_json_string(pa_json_sub(value, "policy"), key)
    Err(error) => pa_error_string(error, key)
  }
}

///|
fn pa_value(result : Result[@json.Json, @contracts.RpcError]) -> @json.Json {
  match result {
    Ok(value) => value
    Err(error) =>
      abort(
        "dispatch unexpectedly failed: code=" +
        error.code.to_string() +
        " message=" +
        error.message,
      )
  }
}

///|
fn pa_error(result : Result[@json.Json, @contracts.RpcError]) -> @contracts.RpcError {
  match result {
    Ok(_) => abort("dispatch unexpectedly succeeded")
    Err(error) => error
  }
}

///|
fn pa_mode(path : String) -> Int {
  match @transport.stat_path(path) {
    Some(info) => info.mode & 0o777
    None => -1
  }
}

///|
fn pa_grant(
  run_id : String,
  digest : String,
  policy_version : String,
  nonce : String,
  issued_at_ms : Int64,
  expires_at_ms : Int64,
) -> @policy.ApprovalGrant {
  match
    @policy.ApprovalGrant::new(
      run_id~,
      command_digest=digest,
      policy_version~,
      nonce~,
      issued_at_ms~,
      expires_at_ms~,
    ) {
    Ok(value) => value
    Err(message) => abort("cannot build the test grant: " + message)
  }
}

///|
/// The approval binding returned by a 1007 refusal.
struct PaBinding {
  run_id : String
  digest : String
  policy_version : String
  policy_hash : String
  risk : String
}

///|
fn pa_binding(error : @contracts.RpcError) -> PaBinding {
  if error.code != @transport.ERR_APPROVAL_REQUIRED {
    abort(
      "expected an approval binding, got code " + error.code.to_string(),
    )
  }
  if pa_error_string(error, "kind") != "approval_binding" {
    abort("approval refusal did not carry a binding")
  }
  {
    run_id: pa_error_string(error, "run_id"),
    digest: pa_error_string(error, "digest"),
    policy_version: pa_error_string(error, "policy_version"),
    policy_hash: pa_error_string(error, "policy_hash"),
    risk: pa_error_string(error, "risk"),
  }
}

///|
fn pa_local_exec_request(
  workspace_root : String,
  argv : Array[String],
) -> @policy.ExecutionRequest {
  @policy.ExecutionRequest::new(
    operation=@policy.PolicyOperation::Exec,
    argv~,
    cwd=workspace_root,
    workspace_root~,
  )
}

///|
fn pa_local_decision(
  snapshot : @policy.PolicySnapshot,
  request : @policy.ExecutionRequest,
) -> @policy.PolicyDecision {
  @policy.evaluate(
    @policy.PolicyContext::with_snapshot(
      snapshot,
      now_ms=@async.now(),
      primary_reachable=true,
    ),
    request,
  )
}

///|
test "approval grants are one-time and bound to run, digest and policy" {
  // Pure grant tests, mirroring the node's verification order. The node calls
  // the same `verify_and_consume_for_request`; these pin the labels the node
  // returns to the primary.
  let now = @async.now()
  let consumed = @policy.ConsumedNonces::new()
  let request = pa_local_exec_request(
    "/tmp/workspace",
    ["sh", "-c", "echo hi"],
  )
  let digest = request.digest()
  let grant = pa_grant(
    "run-1",
    digest,
    "pol-v1",
    "nonce-0000000001",
    now - 1_000L,
    now + 30_000L,
  )
  let snapshot = pa_fresh_snapshot("pol-v1")
  match
    @policy.verify_and_consume_for_request(
      grant,
      "run-1",
      request,
      Some(snapshot),
      now,
      consumed,
    ) {
    Ok(_) => ()
    Err(error) =>
      abort("valid grant did not verify: " + error.label())
  }
  // Same nonce, same everything: replay is refused.
  match
    @policy.verify_and_consume_for_request(
      grant,
      "run-1",
      request,
      Some(snapshot),
      now,
      consumed,
    ) {
    Ok(_) => abort("replayed grant was accepted")
    Err(error) => assert_eq(error.label(), "replayed_nonce")
  }
}

///|
async test "node installs the announced snapshot, persists it and probes it" {
  pa_with_override_node("mn-pa-install", async fn(host, _base, _workspace) {
    let snapshot = pa_fresh_snapshot("pol-v1")
    let announcement = pa_announcement(snapshot)
    match host.install_policy_announcement(announcement) {
      Ok(_) => ()
      Err(message) => abort("snapshot install failed: " + message)
    }
    assert_eq(host.policy().mode(), "snapshot")
    assert_eq(pa_mode(host.policy_path()), 0o600)
    let probe = host.probe_profile()
    assert_eq(pa_json_string(probe, "policy"), "snapshot")
    assert_eq(pa_json_string(probe, "policy_version"), snapshot.version)
    assert_eq(pa_json_string(probe, "policy_hash"), snapshot.content_hash)
    assert_true(
      host.audit_text().contains("policy.snapshot_installed"),
    )
    // Re-installing the same snapshot is idempotent and audited again.
    match host.install_policy_announcement(announcement) {
      Ok(_) => ()
      Err(message) => abort("snapshot reinstall failed: " + message)
    }
    assert_eq(host.policy().mode(), "snapshot")
  })
}

///|
async test "rejected snapshot install keeps the previous gate" {
  pa_with_override_node("mn-pa-reject", async fn(host, _base, _workspace) {
    let v1 = pa_fresh_snapshot("pol-v1")
    match host.install_policy_announcement(pa_announcement(v1)) {
      Ok(_) => ()
      Err(message) => abort("v1 install failed: " + message)
    }
    // A v2 snapshot wearing v1's pin must be refused; the gate stays at v1.
    let v2 = pa_snapshot(
      "pol-v2",
      @async.now() - 1_000L,
      @async.now() + 3_600_000L,
    )
    let mixed = match
      @transport.PolicyAnnouncement::new("pol-v1", v1.content_hash, v2.encode()) {
      Ok(value) => value
      Err(message) => abort("cannot build the mixed announcement: " + message)
    }
    assert_true(host.install_policy_announcement(mixed) is Err(_))
    assert_eq(host.policy().mode(), "snapshot")
    let probe = host.probe_profile()
    assert_eq(pa_json_string(probe, "policy_version"), "pol-v1")
    assert_eq(pa_json_string(probe, "policy_hash"), v1.content_hash)
    assert_true(host.audit_text().contains("policy.snapshot_rejected"))
    // A malformed announcement is likewise refused, never half-applied.
    let malformed = match
      @transport.PolicyAnnouncement::new(
        "pol-v1",
        v1.content_hash,
        "{\"version\":",
      ) {
      Ok(value) => value
      Err(message) => abort("cannot build the malformed announcement: " + message)
    }
    assert_true(host.install_policy_announcement(malformed) is Err(_))
    assert_eq(host.policy().mode(), "snapshot")
  })
}

///|
async test "hash-mismatched snapshot leaves a cold node fail-closed" {
  let base = @fs.tmpdir(prefix="mn-pa-cold-reject")
  defer @fs.rmdir(base, recursive=true)
  let workspace = base + "/workspace"
  @fs.mkdir(workspace, permission=0o700, recursive=true, allow_exist=false) catch {
    _ => abort("cannot create the test workspace")
  }
  let host = match
    NodeHost::open(
      "rt-cold",
      state_base=base,
      workspace_root=workspace,
      policy=None,
    ) {
    Ok(value) => value
    Err(message) => abort("cannot open the node host: " + message)
  }
  assert_eq(host.policy().mode(), "fail_closed")
  let snapshot = pa_fresh_snapshot("pol-v1")
  let other = pa_snapshot(
    "pol-v1",
    @async.now() - 2_000L,
    @async.now() + 3_600_000L,
  )
  let mixed = match
    @transport.PolicyAnnouncement::new(
      "pol-v1",
      snapshot.content_hash,
      other.encode(),
    ) {
    Ok(value) => value
    Err(message) => abort("cannot build the mixed announcement: " + message)
  }
  assert_true(host.install_policy_announcement(mixed) is Err(_))
  assert_eq(host.policy().mode(), "fail_closed")
  // High-risk work is refused outright (1006); it is never default-allowed.
  let result = pa_dispatch(
    host,
    @contracts.METHOD_RUNTIME_EXEC_START,
    pa_exec_params("run-cold", ["sh", "-c", "echo cold >> marker.txt"], ""),
    "cold-1",
  )
  let error = pa_error(result)
  assert_eq(error.code, @transport.ERR_POLICY_STALE)
  // A cold node refuses at the workspace gate before classification, so the
  // error carries no decision payload and, crucially, never an allow.
  assert_eq(pa_error_string(error, "kind"), "")
  assert_true(!@fs.exists(workspace + "/marker.txt") catch { _ => true })
}

///|
async test "persisted snapshot is restored on reopen and tampering fails closed" {
  // Seed a state directory with a verified snapshot, then reopen it with no
  // explicit policy: the persisted announcement must be re-verified and used.
  let base = @fs.tmpdir(prefix="mn-pa-restore")
  defer @fs.rmdir(base, recursive=true)
  let workspace = base + "/workspace"
  @fs.mkdir(workspace, permission=0o700, recursive=true, allow_exist=false) catch {
    _ => abort("cannot create the test workspace")
  }
  let snapshot = pa_fresh_snapshot("pol-restore")
  let announcement = pa_announcement(snapshot)
  let seeded = match
    NodeHost::open(
      "rt-restore",
      state_base=base,
      workspace_root=workspace,
      policy=Some(PolicyGate::allow_workspace(workspace)),
    ) {
    Ok(value) => value
    Err(message) => abort("cannot open the seed host: " + message)
  }
  match seeded.install_policy_announcement(announcement) {
    Ok(_) => ()
    Err(message) => abort("cannot seed the snapshot: " + message)
  }
  assert_eq(pa_mode(base + "/rt-restore/policy.json"), 0o600)
  let restored = match
    NodeHost::open(
      "rt-restore",
      state_base=base,
      workspace_root=workspace,
      policy=None,
    ) {
    Ok(value) => value
    Err(message) => abort("cannot reopen the node host: " + message)
  }
  assert_eq(restored.policy().mode(), "snapshot")
  let probe = restored.probe_profile()
  assert_eq(pa_json_string(probe, "policy_version"), "pol-restore")
  assert_eq(pa_json_string(probe, "policy_hash"), snapshot.content_hash)
  assert_true(
    restored.audit_text().contains("policy.snapshot_restored"),
  )
  // Tamper with the persisted snapshot: it still parses, but the pin no
  // longer matches, so the reopened node fails closed.
  let other = pa_snapshot(
    "pol-restore",
    @async.now() - 5_000L,
    @async.now() + 3_600_000L,
  )
  let tampered = match
    @transport.PolicyAnnouncement::new(
      "pol-restore",
      snapshot.content_hash,
      other.encode(),
    ) {
    Ok(value) => value
    Err(message) => abort("cannot build the tampered file: " + message)
  }
  @fs.write_file(
    base + "/rt-restore/policy.json",
    tampered.to_json().stringify(),
    permission=0o600,
    sync=@fs.SyncMode::Full,
  ) catch {
    _ => abort("cannot write the tampered policy file")
  }
  let after = match
    NodeHost::open(
      "rt-restore",
      state_base=base,
      workspace_root=workspace,
      policy=None,
    ) {
    Ok(value) => value
    Err(message) => abort("cannot reopen the tampered node host: " + message)
  }
  assert_eq(after.policy().mode(), "fail_closed")
  assert_true(after.audit_text().contains("policy.snapshot_rejected"))
}

///|
async test "expired snapshot keeps read-only work and holds high-risk work" {
  pa_with_override_node("mn-pa-expired", async fn(host, _base, workspace) {
    let now = @async.now()
    let expired = pa_snapshot("pol-expired", now - 120_000L, now - 60_000L)
    match host.install_policy_announcement(pa_announcement(expired)) {
      Ok(_) => ()
      Err(message) => abort("expired snapshot install failed: " + message)
    }
    @fs.write_file(workspace + "/notes.txt", "hello") catch {
      _ => abort("cannot write the workspace file")
    }
    // Read-only fs work keeps working under a stale snapshot and is audited.
    let read = pa_dispatch(
      host,
      @contracts.METHOD_RUNTIME_FS_READ,
      pa_fs_read_params("notes.txt"),
      "expired-read",
    )
    assert_eq(pa_json_string(pa_value(read), "data"), "hello")
    // Low-risk read-only exec may proceed locally on the stale snapshot.
    let echo = pa_dispatch(
      host,
      @contracts.METHOD_RUNTIME_EXEC_START,
      pa_exec_params("run-expired-echo", ["echo", "ok"], ""),
      "expired-echo",
    )
    assert_eq(pa_decision_field(echo, "kind"), "allow")
    // High-risk and mutating work must wait, never run offline.
    let high = pa_error(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_EXEC_START,
        pa_exec_params("run-expired-sh", ["sh", "-c", "echo no >> marker.txt"], ""),
        "expired-sh",
      ),
    )
    assert_eq(high.code, @transport.ERR_POLICY_STALE)
    assert_eq(pa_error_string(high, "kind"), "policy_unverifiable")
    let write = pa_error(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_FS_WRITE,
        pa_fs_write_params("blocked.txt", "no"),
        "expired-write",
      ),
    )
    assert_eq(write.code, @transport.ERR_POLICY_STALE)
    assert_true(!@fs.exists(workspace + "/marker.txt") catch { _ => true })
    assert_true(!@fs.exists(workspace + "/blocked.txt") catch { _ => true })
    assert_true(host.audit_text().contains("policy.decision"))
    assert_true(host.audit_text().contains("\"outcome\":\"read_only\""))
  })
}

///|
async test "node risk check matches local evaluate for a command vector" {
  pa_with_override_node("mn-pa-parity", async fn(host, _base, workspace) {
    let snapshot = pa_fresh_snapshot("pol-parity")
    match host.install_policy_announcement(pa_announcement(snapshot)) {
      Ok(_) => ()
      Err(message) => abort("parity snapshot install failed: " + message)
    }
    let cases : Array[(String, Array[String])] = [
      ("echo hello", ["echo", "hello"]),
      ("git status", ["git", "status"]),
      ("rm -rf build", ["rm", "-rf", "build"]),
      ("shutdown -h now", ["shutdown", "-h", "now"]),
      ("sh -c echo hi", ["sh", "-c", "echo hi"]),
      ("curl http://example", ["curl", "http://example"]),
    ]
    let mut index = 0
    for command in cases {
      let argv = command.1
      let local = pa_local_decision(
        snapshot,
        pa_local_exec_request(workspace, argv),
      )
      let remote = pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_EXEC_START,
        pa_exec_params("parity-" + index.to_string(), argv, ""),
        "parity-crid-" + index.to_string(),
      )
      assert_eq(pa_remote_kind(remote), local.kind.label())
      assert_eq(pa_decision_field(remote, "digest"), local.digest)
      assert_eq(pa_decision_field(remote, "policy_version"), local.policy_version)
      assert_eq(pa_decision_field(remote, "policy_hash"), local.policy_hash)
      index = index + 1
    }
    // fs.write is explicitly allowed by this snapshot while it is fresh.
    let local_write = pa_local_decision(
      snapshot,
      @policy.ExecutionRequest::new(
        operation=@policy.PolicyOperation::FsWrite,
        argv=["parity.txt"],
        cwd=workspace,
        workspace_root=workspace,
      ),
    )
    let remote_write = pa_dispatch(
      host,
      @contracts.METHOD_RUNTIME_FS_WRITE,
      pa_fs_write_params("parity.txt", "content"),
      "parity-write",
    )
    assert_eq(local_write.kind.label(), "allow")
    assert_eq(pa_remote_kind(remote_write), local_write.kind.label())
    assert_eq(pa_decision_field(remote_write, "digest"), local_write.digest)
    // An env name the snapshot does not allow is denied, and the failed
    // request never runs; the secret value stays out of the audit ring.
    let deny_params = pa_exec_params(
      "parity-env",
      ["echo", "hello"],
      "",
    )
    deny_params.set(
      "env",
      @contracts.json_object([
        ("SECRET_KEY", @contracts.json_string("s3cr3t-value")),
      ]),
    )
    let denied = pa_error(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_EXEC_START,
        deny_params,
        "parity-env",
      ),
    )
    assert_eq(denied.code, @transport.ERR_POLICY_DENIED)
    assert_eq(pa_error_string(denied, "kind"), "policy_denied")
    assert_eq(pa_error_string(denied, "risk"), @contracts.RISK_HIGH)
    assert_true(!host.audit_text().contains("s3cr3t-value"))
    // Read-only calls are audited even when the policy allows them.
    let read = pa_dispatch(
      host,
      @contracts.METHOD_RUNTIME_FS_READ,
      pa_fs_read_params("parity.txt"),
      "parity-read",
    )
    assert_true(read is Ok(_))
    assert_true(host.audit_text().contains("policy.decision"))
  })
}

///|
async test "high-risk command runs once under a Decision-bound grant" {
  pa_with_override_node("mn-pa-grant", async fn(host, _base, workspace) {
    let snapshot = pa_fresh_snapshot("pol-grant")
    match host.install_policy_announcement(pa_announcement(snapshot)) {
      Ok(_) => ()
      Err(message) => abort("grant snapshot install failed: " + message)
    }
    let argv = ["sh", "-c", "echo once >> " + workspace + "/marker.txt"]
    // 1. Without a grant the node refuses and returns the binding.
    let binding = pa_binding(
      pa_error(
        pa_dispatch(
          host,
          @contracts.METHOD_RUNTIME_EXEC_START,
          pa_exec_params("run-grant", argv, ""),
          "grant-1",
        ),
      ),
    )
    assert_eq(binding.run_id, "run-grant")
    assert_eq(binding.policy_version, "pol-grant")
    assert_eq(binding.policy_hash, snapshot.content_hash)
    assert_eq(binding.risk, @contracts.RISK_HIGH)
    assert_true(!@fs.exists(workspace + "/marker.txt") catch { _ => true })
    // 2. A grant bound to this run and digest executes exactly once.
    let now = @async.now()
    let grant = pa_grant(
      binding.run_id,
      binding.digest,
      binding.policy_version,
      "nonce-grant-000001",
      now - 1_000L,
      now + 30_000L,
    )
    let approved = pa_dispatch(
      host,
      @contracts.METHOD_RUNTIME_EXEC_START,
      pa_exec_params("run-grant", argv, grant.encode()),
      "grant-1",
    )
    assert_eq(pa_decision_field(approved, "kind"), "approval_required")
    assert_true(pa_json_bool(pa_value(approved), "approval_verified"))
    let marker = @fs.read_file(workspace + "/marker.txt") catch {
      _ => abort("the approved command did not run")
    }
    let marker_text = marker.text() catch { _ => abort("cannot read the marker") }
    let occurrences = {
      let mut count = 0
      for piece in marker_text.split("once") {
        let _ = piece
        count = count + 1
      }
      count - 1
    }
    assert_eq(occurrences, 1)
    // 3. Replaying the same nonce is refused, even for the same request id;
    // the idempotency cache is consulted only after the policy gate.
    let replay = pa_error(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_EXEC_START,
        pa_exec_params("run-grant", argv, grant.encode()),
        "grant-1",
      ),
    )
    assert_eq(replay.code, @transport.ERR_APPROVAL_INVALID)
    assert_eq(pa_error_string(replay, "reason"), "replayed_nonce")
    // The cached result is not served without a fresh, valid grant.
    let ungranted = pa_error(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_EXEC_START,
        pa_exec_params("run-grant", argv, ""),
        "grant-1",
      ),
    )
    assert_eq(ungranted.code, @transport.ERR_APPROVAL_REQUIRED)
    let after = @fs.read_file(workspace + "/marker.txt") catch {
      _ => abort("the marker disappeared")
    }
    let after_text = after.text() catch { _ => abort("cannot read the marker") }
    assert_true(after_text.contains("once"))
    assert_true(host.audit_text().contains("policy.approval_used"))
    assert_true(host.audit_text().contains("policy.approval_rejected"))
  })
}

///|
async test "a grant cannot authorize another command, run, or policy version" {
  pa_with_override_node("mn-pa-mismatch", async fn(host, _base, workspace) {
    let v1 = pa_fresh_snapshot("pol-v1")
    match host.install_policy_announcement(pa_announcement(v1)) {
      Ok(_) => ()
      Err(message) => abort("v1 install failed: " + message)
    }
    let argv = ["sh", "-c", "echo bound"]
    let binding = pa_binding(
      pa_error(
        pa_dispatch(
          host,
          @contracts.METHOD_RUNTIME_EXEC_START,
          pa_exec_params("run-bound", argv, ""),
          "bound-1",
        ),
      ),
    )
    let now = @async.now()
    // Same run, different command digest.
    let other_digest = "sha256:" + pa_repeat("cd", 32)
    let wrong_digest = pa_grant(
      "run-bound",
      other_digest,
      binding.policy_version,
      "nonce-wrong-digest",
      now - 1_000L,
      now + 30_000L,
    )
    let digest_error = pa_error(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_EXEC_START,
        pa_exec_params("run-bound", argv, wrong_digest.encode()),
        "bound-2",
      ),
    )
    assert_eq(digest_error.code, @transport.ERR_APPROVAL_INVALID)
    assert_eq(pa_error_string(digest_error, "reason"), "digest_mismatch")
    // Different run, correct digest.
    let wrong_run = pa_grant(
      "run-other",
      binding.digest,
      binding.policy_version,
      "nonce-wrong-run-01",
      now - 1_000L,
      now + 30_000L,
    )
    let run_error = pa_error(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_EXEC_START,
        pa_exec_params("run-bound", argv, wrong_run.encode()),
        "bound-3",
      ),
    )
    assert_eq(run_error.code, @transport.ERR_APPROVAL_INVALID)
    assert_eq(pa_error_string(run_error, "reason"), "run_mismatch")
    // Expired and not-yet-valid grants.
    let expired = pa_grant(
      "run-bound",
      binding.digest,
      binding.policy_version,
      "nonce-expired-0001",
      now - 120_000L,
      now - 60_000L,
    )
    let expired_error = pa_error(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_EXEC_START,
        pa_exec_params("run-bound", argv, expired.encode()),
        "bound-4",
      ),
    )
    assert_eq(expired_error.code, @transport.ERR_APPROVAL_INVALID)
    assert_eq(pa_error_string(expired_error, "reason"), "expired")
    let future = pa_grant(
      "run-bound",
      binding.digest,
      binding.policy_version,
      "nonce-future-0001",
      now + 120_000L,
      now + 180_000L,
    )
    let future_error = pa_error(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_EXEC_START,
        pa_exec_params("run-bound", argv, future.encode()),
        "bound-5",
      ),
    )
    assert_eq(future_error.code, @transport.ERR_APPROVAL_INVALID)
    assert_eq(pa_error_string(future_error, "reason"), "not_yet_valid")
    // Malformed grants never reach verification.
    let malformed = pa_error(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_EXEC_START,
        pa_exec_params("run-bound", argv, "{}"),
        "bound-6",
      ),
    )
    assert_eq(malformed.code, @transport.ERR_APPROVAL_INVALID)
    assert_eq(pa_error_string(malformed, "reason"), "malformed_grant")
    // Policy rotation invalidates the outstanding binding and grant.
    let v2 = pa_fresh_snapshot("pol-v2")
    match host.install_policy_announcement(pa_announcement(v2)) {
      Ok(_) => ()
      Err(message) => abort("v2 install failed: " + message)
    }
    let v1_grant = pa_grant(
      "run-bound",
      binding.digest,
      binding.policy_version,
      "nonce-v1-outstanding",
      now - 1_000L,
      now + 30_000L,
    )
    let rotated = pa_error(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_EXEC_START,
        pa_exec_params("run-bound", argv, v1_grant.encode()),
        "bound-7",
      ),
    )
    assert_eq(rotated.code, @transport.ERR_APPROVAL_INVALID)
    assert_eq(pa_error_string(rotated, "reason"), "policy_version_mismatch")
    // A new binding under v2 can be approved and run.
    let fresh_binding = pa_binding(
      pa_error(
        pa_dispatch(
          host,
          @contracts.METHOD_RUNTIME_EXEC_START,
          pa_exec_params("run-bound-v2", ["sh", "-c", "echo rotated"], ""),
          "bound-8",
        ),
      ),
    )
    assert_eq(fresh_binding.policy_version, "pol-v2")
    assert_eq(fresh_binding.policy_hash, v2.content_hash)
  })
}
