///|
/// Node-side skill mirror and invocation tests (ADR-0015 A4.2).
///
/// The first group drives `NodeHost::dispatch` directly with real policy
/// snapshots, so mirror verification, lease expiry, policy tightening and
/// bounded output run without TLS. The last test uses the paired primary/node
/// harness from `host_e2e_test.mbt` and the primary-side Decision port from
/// `approval_e2e_test.mbt`, so mirror, invoke, owner approve/deny, GC and
/// re-mirror all run over the real pinned-TLS transport.

///|
const SKE_HASH_ZERO : String =
  "sha256:0000000000000000000000000000000000000000000000000000000000000000"

///|
struct SkeBundle {
  name : String
  version : String
  content_hash : String
  manifest_text : String
  files : Array[(String, String)]
}

///|
fn ske_bundle(
  name : String,
  version : String,
  permissions : String,
  commands : String,
) -> SkeBundle {
  let entry = "# " + name + "\n\nEntry for the node mirror tests.\n"
  let resource = "notes\n"
  let fields = "{\"schema_version\":1," +
    "\"name\":\"" + name + "\"," +
    "\"version\":\"" + version + "\"," +
    "\"description\":\"Node mirror test skill\"," +
    "\"permissions\":" + permissions + "," +
    "\"entry\":{\"path\":\"SKILL.md\",\"max_bytes\":4096}," +
    "\"resources\":[{\"path\":\"notes/README.md\",\"description\":\"notes\"}]," +
    "\"commands\":" + commands + "," +
    "\"source\":{\"kind\":\"local_directory\",\"path\":\"/tmp/src\",\"author\":\"ops\",\"created_at\":\"2026-01-01T00:00:00Z\"}}"
  let prefix = fields[:fields.length() - 1].to_owned()
  let placeholder = prefix +
    ",\"content_hash\":\"" + SKE_HASH_ZERO +
    "\",\"signature\":{\"key_id\":\"node-test-key\",\"alg\":\"ed25519\",\"sig\":\"U1NIU0lHAAAAdGVzdA==\"}}"
  let parsed = match @skills.parse_skill_manifest(placeholder) {
    Ok(value) => value
    Err(fault) =>
      abort(
        "node fixture manifest rejected: " + fault.code + ": " + fault.detail,
      )
  }
  let body = @skills.canonical_manifest_string(parsed)
  let hash = @skills.compute_content_hash(
    body,
    [("SKILL.md", entry), ("notes/README.md", resource)],
  )
  let manifest_text = prefix +
    ",\"content_hash\":\"" + hash +
    "\",\"signature\":{\"key_id\":\"node-test-key\",\"alg\":\"ed25519\",\"sig\":\"U1NIU0lHAAAAdGVzdA==\"}}"
  {
    name,
    version,
    content_hash: hash,
    manifest_text,
    files: [
      ("skill.json", manifest_text),
      ("SKILL.md", entry),
      ("notes/README.md", resource),
    ],
  }
}

///|
fn ske_read_commands(max_output_bytes : Int) -> String {
  "[{\"id\":\"status\",\"argv\":[\"git\",\"status\",\"--porcelain\"],\"mode\":\"read_only\",\"timeout_ms\":10000,\"max_output_bytes\":" +
  max_output_bytes.to_string() + "}]"
}

///|
fn ske_write_commands() -> String {
  "[{\"id\":\"note\",\"argv\":[\"git\",\"commit\",\"--allow-empty\",\"-m\",\"release 1.0.0\"],\"mode\":\"write\",\"timeout_ms\":10000,\"max_output_bytes\":8192}]"
}

///|
fn ske_files_json(files : Array[(String, String)]) -> Array[@json.Json] {
  let out : Array[@json.Json] = []
  for file in files {
    out.push(
      @contracts.json_object([
        ("path", @contracts.json_string(file.0)),
        ("content", @contracts.json_string(file.1)),
      ]),
    )
  }
  out
}

///|
fn ske_mirror_params(
  session_id : String,
  name : String,
  version : String,
  content_hash : String,
  manifest_text : String,
  files : Array[(String, String)],
  lease_ms : Int64,
) -> Map[String, @json.Json] {
  let params : Map[String, @json.Json] = Map([])
  params.set("session_id", @contracts.json_string(session_id))
  params.set("name", @contracts.json_string(name))
  params.set("version", @contracts.json_string(version))
  params.set("content_hash", @contracts.json_string(content_hash))
  params.set("manifest", @contracts.json_string(manifest_text))
  params.set("files", @contracts.json_array(ske_files_json(files)))
  params.set("lease_ms", @contracts.json_int64(lease_ms))
  params
}

///|
fn ske_mirror_params_for(
  session_id : String,
  bundle : SkeBundle,
  lease_ms : Int64,
) -> Map[String, @json.Json] {
  ske_mirror_params(
    session_id,
    bundle.name,
    bundle.version,
    bundle.content_hash,
    bundle.manifest_text,
    bundle.files,
    lease_ms,
  )
}

///|
fn ske_invoke_params(
  session_id : String,
  bundle : SkeBundle,
  entry_id : String,
  run_id : String,
) -> Map[String, @json.Json] {
  let params : Map[String, @json.Json] = Map([])
  params.set("session_id", @contracts.json_string(session_id))
  params.set("name", @contracts.json_string(bundle.name))
  params.set("version", @contracts.json_string(bundle.version))
  params.set("content_hash", @contracts.json_string(bundle.content_hash))
  params.set("entry_id", @contracts.json_string(entry_id))
  params.set("run_id", @contracts.json_string(run_id))
  params
}

///|
fn ske_json_int(json : @json.Json, key : String) -> Int {
  match @contracts.as_object(json) {
    Some(object) => @contracts.int_field_or(object, key, -1)
    None => -1
  }
}

///|
fn ske_snapshot(
  version : String,
  issued_at_ms : Int64,
  allow_read_only : Bool,
  allowed_operations : Array[String],
  denied_operations : Array[String],
) -> @policy.PolicySnapshot {
  let rules = @policy.PolicyRules::new(
    allow_read_only~,
    allowed_operations~,
    denied_operations~,
    env_allowlist=["PATH", "HOME"],
  )
  match
    @policy.PolicySnapshot::new(
      version~,
      issued_at_ms~,
      expires_at_ms=@async.now() + 3_600_000L,
      rules~,
    ) {
    Ok(value) => value
    Err(message) => abort("cannot build the skill test snapshot: " + message)
  }
}

///|
async fn ske_lease_items(host : NodeHost) -> Array[@json.Json] {
  let text = pa_read_text(
    host.state_dir() + "/" + NODE_SKILL_LEASES_FILE_NAME,
  )
  let root = @json.parse(text) catch {
    _ => abort("skill lease file is not valid JSON")
  }
  let object = match @contracts.as_object(root) {
    Some(value) => value
    None => abort("skill lease file is not an object")
  }
  assert_eq(@contracts.int_field_or(object, "schema", -1), 1)
  match object.get("leases") {
    Some(@json.Json::Array(items)) => items
    _ => abort("skill lease file has no leases array")
  }
}

///|
async fn ske_git_commit_text(workspace : String) -> String {
  let collected = @process.collect_output(
    "git",
    ["rev-list", "--count", "HEAD"],
    cwd=workspace,
  ) catch {
    _ => abort("cannot run git rev-list")
  }
  let (code, stdout, stderr) = collected
  if code != 0 {
    let message = stderr.text() catch { _ => "git failed" }
    abort("git rev-list failed: " + message)
  }
  let text = stdout.text() catch { _ => "0" }
  text.trim().to_owned()
}

///|
async fn ske_init_repo(workspace : String) -> Unit {
  host_sh(
    workspace,
    "set -e\n" +
    "git init -q\n" +
    "git config user.email node-test@example.com\n" +
    "git config user.name NodeTester\n" +
    "touch base.txt\n" +
    "git add base.txt\n" +
    "git commit -q -m base\n",
  )
}

///|
async test "node mirror verifies the hash, materialises and persists a lease" {
  pa_with_override_node("mn-skill-mirror", async fn(host, _base, _workspace) {
    let bundle = ske_bundle(
      "repo-health",
      "1.0.0",
      "[\"git.read\"]",
      ske_read_commands(8192),
    )
    let session_id = "skill-session-mirror"
    let first = pa_value(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_SKILL_MIRROR,
        ske_mirror_params_for(session_id, bundle, 120_000L),
        "skm-first",
      ),
    )
    assert_eq(pa_json_bool(first, "existing"), false)
    let lease_path = host.state_dir() + "/" + NODE_SKILL_LEASES_FILE_NAME
    assert_eq(pa_mode(lease_path), 0o600)
    let leases = ske_lease_items(host)
    assert_eq(leases.length(), 1)
    assert_eq(pa_json_string(leases[0], "session_id"), session_id)
    assert_eq(pa_json_string(leases[0], "content_hash"), bundle.content_hash)
    assert_eq(pa_json_bool(leases[0], "expired"), false)
    let store_path = host.state_dir() + "/skills/store/" + bundle.name + "/" +
      bundle.version + "/" + bundle.content_hash
    let store_exists = @fs.exists(store_path) catch { _ => false }
    assert_true(store_exists)
    let copy_path = host.state_dir() + "/skills/sessions/" + session_id + "/" +
      bundle.name + "-" + bundle.version
    let copy_exists = @fs.exists(copy_path) catch { _ => false }
    assert_true(copy_exists)
    let entry_text = pa_read_text(copy_path + "/SKILL.md")
    assert_true(entry_text.contains(bundle.name))
    assert_true(host.audit_text().contains("skill.mirror"))
    // Re-mirroring the exact tuple reuses the immutable store entry.
    let second = pa_value(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_SKILL_MIRROR,
        ske_mirror_params_for(session_id, bundle, 120_000L),
        "skm-second",
      ),
    )
    assert_eq(pa_json_bool(second, "existing"), true)
    // A modified entry no longer matches the signed hash.
    let tampered : Array[(String, String)] = [
      ("skill.json", bundle.manifest_text),
      ("SKILL.md", "changed body"),
      ("notes/README.md", "notes\n"),
    ]
    let tampered_error = pa_error(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_SKILL_MIRROR,
        ske_mirror_params(
          session_id,
          bundle.name,
          bundle.version,
          bundle.content_hash,
          bundle.manifest_text,
          tampered,
          120_000L,
        ),
        "skm-tampered",
      ),
    )
    assert_eq(tampered_error.code, @contracts.ERR_INVALID_PARAMS)
    assert_eq(
      pa_error_string(tampered_error, "reason"),
      @contracts.SKILL_ERR_HASH_MISMATCH,
    )
    // A truncated transfer misses a declared file.
    let truncated : Array[(String, String)] = [
      ("skill.json", bundle.manifest_text),
      ("SKILL.md", "# repo-health\n\nEntry for the node mirror tests.\n"),
    ]
    let truncated_error = pa_error(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_SKILL_MIRROR,
        ske_mirror_params(
          session_id,
          bundle.name,
          bundle.version,
          bundle.content_hash,
          bundle.manifest_text,
          truncated,
          120_000L,
        ),
        "skm-truncated",
      ),
    )
    assert_eq(truncated_error.code, @contracts.ERR_INVALID_PARAMS)
    assert_eq(
      pa_error_string(truncated_error, "reason"),
      @contracts.SKILL_ERR_INVALID_PATH,
    )
    // An undeclared extra file is refused as well.
    let extra = bundle.files.copy()
    extra.push(("evil.sh", "echo nope\n"))
    let extra_error = pa_error(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_SKILL_MIRROR,
        ske_mirror_params(
          session_id,
          bundle.name,
          bundle.version,
          bundle.content_hash,
          bundle.manifest_text,
          extra,
          120_000L,
        ),
        "skm-extra",
      ),
    )
    assert_eq(extra_error.code, @contracts.ERR_INVALID_PARAMS)
    assert_eq(
      pa_error_string(extra_error, "reason"),
      @contracts.SKILL_ERR_INVALID_PATH,
    )
    // A valid bundle addressed as a different exact tuple is refused.
    let tuple_error = pa_error(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_SKILL_MIRROR,
        ske_mirror_params(
          session_id,
          bundle.name,
          "2.0.0",
          bundle.content_hash,
          bundle.manifest_text,
          bundle.files,
          120_000L,
        ),
        "skm-tuple",
      ),
    )
    assert_eq(tuple_error.code, @contracts.ERR_INVALID_PARAMS)
    assert_eq(
      pa_error_string(tuple_error, "reason"),
      @contracts.SKILL_ERR_HASH_MISMATCH,
    )
    // Listing reports the live lease without any file bodies.
    let listed = pa_value(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_SKILL_LIST,
        Map([("session_id", @contracts.json_string(session_id))]),
        "skm-list",
      ),
    )
    match @contracts.as_object(listed) {
      Some(object) =>
        match object.get("leases") {
          Some(@json.Json::Array(items)) => assert_eq(items.length(), 1)
          _ => abort("skill.list has no leases array")
        }
      None => abort("skill.list result is not an object")
    }
  })
}

///|
async test "stored skill leases must be a 0600 schema-1 file" {
  let dir = @fs.tmpdir(prefix="mn-skill-leases-")
  defer @fs.rmdir(dir, recursive=true)
  let path = dir + "/skill_leases.json"
  @fs.write_file(path, "{\"schema\":1,\"leases\":[]}", permission=0o600) catch {
    _ => abort("cannot write the lease fixture")
  }
  match load_node_skill_leases(path) {
    Ok(leases) => assert_eq(leases.length(), 0)
    Err(message) => abort("valid lease file was refused: " + message)
  }
  @fs.chmod(path, 0o644) catch { _ => abort("cannot chmod the lease fixture") }
  let mode_error = match load_node_skill_leases(path) {
    Ok(_) => abort("0644 lease file was accepted")
    Err(message) => message
  }
  assert_true(mode_error.contains("0600"))
  @fs.chmod(path, 0o600) catch { _ => abort("cannot restore the lease mode") }
  @fs.write_file(
    path,
    "{\"schema\":2,\"leases\":[]}",
    permission=0o600,
  ) catch {
    _ => abort("cannot write the schema fixture")
  }
  let schema_error = match load_node_skill_leases(path) {
    Ok(_) => abort("schema 2 lease file was accepted")
    Err(message) => message
  }
  assert_true(schema_error.contains("schema"))
  let invalid_lease = "{\"schema\":1,\"leases\":[{\"session_id\":\"s\",\"name\":\"repo-health\",\"version\":\"1.0.0\",\"content_hash\":\"" +
    SKE_HASH_ZERO +
    "\",\"entry_ids\":[],\"mirrored_at_ms\":1,\"expires_at_ms\":0}]}"
  @fs.write_file(path, invalid_lease, permission=0o600) catch {
    _ => abort("cannot write the invalid lease fixture")
  }
  let lease_error = match load_node_skill_leases(path) {
    Ok(_) => abort("a non-expiring lease was accepted")
    Err(message) => message
  }
  assert_true(lease_error.contains("invalid lease"))
}

///|
async test "mirrored invocation fails closed without policy or a live lease" {
  pa_with_override_node("mn-skill-invoke", async fn(host, _base, workspace) {
    ske_init_repo(workspace)
    let read_bundle = ske_bundle(
      "repo-health",
      "1.0.0",
      "[\"git.read\"]",
      ske_read_commands(8192),
    )
    let session_id = "skill-session-invoke"
    let _ = pa_value(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_SKILL_MIRROR,
        ske_mirror_params_for(session_id, read_bundle, 120_000L),
        "ski-mirror-1",
      ),
    )
    // Without a verified snapshot, invocation fails closed before any lease
    // or mirror is trusted.
    let stale = pa_error(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_SKILL_INVOKE,
        ske_invoke_params(session_id, read_bundle, "status", "ski-run-none"),
        "ski-none",
      ),
    )
    assert_eq(stale.code, @transport.ERR_POLICY_STALE)
    assert_eq(pa_error_string(stale, "reason"), "policy_unverifiable")
    let base = @async.now()
    let v1 = ske_snapshot(
      "pol-skill-v1",
      base - 10_000L,
      true,
      [],
      [],
    )
    match host.install_policy_announcement(pa_announcement(v1)) {
      Ok(_) => ()
      Err(message) => abort("v1 snapshot install failed: " + message)
    }
    let allowed = pa_value(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_SKILL_INVOKE,
        ske_invoke_params(session_id, read_bundle, "status", "ski-run-read"),
        "ski-read",
      ),
    )
    assert_eq(ske_json_int(allowed, "exit_code"), 0)
    assert_eq(pa_json_bool(allowed, "truncated"), false)
    let _ = pa_value(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_SKILL_MIRROR,
        ske_mirror_params_for(session_id, read_bundle, 1L),
        "ski-mirror-2",
      ),
    )
    @async.sleep(10)
    let expired = pa_error(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_SKILL_INVOKE,
        ske_invoke_params(
          session_id,
          read_bundle,
          "status",
          "ski-run-expired",
        ),
        "ski-expired",
      ),
    )
    assert_eq(expired.code, @transport.ERR_POLICY_STALE)
    assert_eq(
      pa_error_string(expired, "reason"),
      "lease_expired_or_missing",
    )
    let _ = pa_value(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_SKILL_MIRROR,
        ske_mirror_params_for(session_id, read_bundle, 120_000L),
        "ski-mirror-3",
      ),
    )
    let write_bundle = ske_bundle(
      "release-note",
      "1.0.0",
      "[\"git.write\"]",
      ske_write_commands(),
    )
    let _ = pa_value(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_SKILL_MIRROR,
        ske_mirror_params_for(session_id, write_bundle, 120_000L),
        "ski-mirror-4",
      ),
    )
    // Tightening the snapshot denies the exec operation: the mirrored write
    // entry is refused and no commit runs.
    let v2 = ske_snapshot(
      "pol-skill-v2",
      base - 5_000L,
      true,
      [],
      ["exec"],
    )
    match host.install_policy_announcement(pa_announcement(v2)) {
      Ok(_) => ()
      Err(message) => abort("v2 snapshot install failed: " + message)
    }
    let denied = pa_error(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_SKILL_INVOKE,
        ske_invoke_params(session_id, write_bundle, "note", "ski-run-write"),
        "ski-write-denied",
      ),
    )
    assert_eq(denied.code, @transport.ERR_POLICY_DENIED)
    assert_eq(ske_git_commit_text(workspace), "1")
    // Read output is bounded even when the manifest asks for more than the
    // node's transport limit.
    let bounded_bundle = ske_bundle(
      "repo-scan",
      "1.0.0",
      "[\"git.read\"]",
      ske_read_commands(1_048_576),
    )
    let _ = pa_value(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_SKILL_MIRROR,
        ske_mirror_params_for(session_id, bounded_bundle, 120_000L),
        "ski-mirror-5",
      ),
    )
    for index in 0..<600 {
      @fs.write_file(
        workspace + "/untracked-very-long-file-name-" +
        index.to_string() + ".txt",
        "x",
      ) catch {
        _ => abort("cannot create an untracked file")
      }
    }
    let v3 = ske_snapshot(
      "pol-skill-v3",
      base - 1_000L,
      true,
      [],
      [],
    )
    match host.install_policy_announcement(pa_announcement(v3)) {
      Ok(_) => ()
      Err(message) => abort("v3 snapshot install failed: " + message)
    }
    let bounded = pa_value(
      pa_dispatch(
        host,
        @contracts.METHOD_RUNTIME_SKILL_INVOKE,
        ske_invoke_params(
          session_id,
          bounded_bundle,
          "status",
          "ski-run-bounded",
        ),
        "ski-bounded",
      ),
    )
    assert_eq(pa_json_bool(bounded, "truncated"), true)
    let output = pa_json_string(bounded, "output")
    assert_true(output.contains("[output truncated]"))
    assert_true(output.length() <= NODE_SKILL_MAX_OUTPUT_BYTES + 64)
    assert_eq(ske_git_commit_text(workspace), "1")
  })
}

///|
async test "paired node serves skills only through owner Decisions and GC" {
  host_run_scenario(
    "mn-skill-paired",
    "rt-skill-paired",
    5_000L,
    3,
    5_000L,
    100L,
    8,
    None,
    async fn(h) {
      ske_init_repo(h.workspace)
      let read_bundle = ske_bundle(
        "repo-health",
        "1.0.0",
        "[\"git.read\"]",
        ske_read_commands(8192),
      )
      let write_bundle = ske_bundle(
        "release-note",
        "1.0.0",
        "[\"git.write\"]",
        ske_write_commands(),
      )
      let session_id = "skill-paired"
      let first_mirror = match
        h.machine.skill_mirror(
          session_id=session_id,
          name=read_bundle.name,
          version=read_bundle.version,
          content_hash=read_bundle.content_hash,
          manifest=read_bundle.manifest_text,
          files=read_bundle.files,
          lease_ms=120_000L,
          client_request_id="skp-mirror-read",
        ) {
        Ok(value) => value
        Err(error) => abort("paired mirror failed: " + error.message)
      }
      assert_eq(pa_json_bool(first_mirror, "existing"), false)
      assert_eq(
        host_mode(h.host.state_dir() + "/" + NODE_SKILL_LEASES_FILE_NAME),
        0o600,
      )
      // A read-only entry executes directly under the current policy; the
      // owner port must never be asked to decide it.
      let abort_port : @provider_runtime.ApprovalPort = async fn(_request) {
        abort("a read-only skill invocation must not create a Decision")
      }
      let read_approval = @provider_runtime.ApprovalContext::new(
        port=abort_port,
        ttl_ms=30_000L,
        wait_ms=2_000L,
      )
      let read_result = match
        h.machine.skill_invoke_approved(
          session_id=session_id,
          name=read_bundle.name,
          version=read_bundle.version,
          content_hash=read_bundle.content_hash,
          entry_id="status",
          run_id="skp-read-run",
          client_request_id="skp-read-1",
          approval=read_approval,
        ) {
        Ok(value) => value
        Err(failure) =>
          abort("paired read invocation failed: " + failure.error_text())
      }
      assert_eq(ske_json_int(read_result, "exit_code"), 0)
      assert_eq(pa_json_bool(read_result, "truncated"), false)
      // A gated snapshot allows read-only work but requires a Decision for
      // the write entry.
      let gated = ske_snapshot(
        "pol-skill-paired-gated",
        @async.now(),
        true,
        [],
        [],
      )
      ae_publish_snapshot(h, gated)
      let _ = match
        h.machine.skill_mirror(
          session_id=session_id,
          name=write_bundle.name,
          version=write_bundle.version,
          content_hash=write_bundle.content_hash,
          manifest=write_bundle.manifest_text,
          files=write_bundle.files,
          lease_ms=120_000L,
          client_request_id="skp-mirror-write",
        ) {
        Ok(value) => value
        Err(error) => abort("paired write mirror failed: " + error.message)
      }
      let seen : Ref[Array[@provider_runtime.ApprovalRequest]] = Ref([])
      let approve_port : @provider_runtime.ApprovalPort = async fn(request) {
        seen.val.push(request)
        @provider_runtime.ApprovalOutcome::Approved("dec-skill-approve")
      }
      let approve = @provider_runtime.ApprovalContext::new(
        port=approve_port,
        ttl_ms=30_000L,
        wait_ms=10_000L,
      )
      let write_result = match
        h.machine.skill_invoke_approved(
          session_id=session_id,
          name=write_bundle.name,
          version=write_bundle.version,
          content_hash=write_bundle.content_hash,
          entry_id="note",
          run_id="skp-write-run",
          client_request_id="skp-write-1",
          approval=approve,
        ) {
        Ok(value) => value
        Err(failure) =>
          abort("approved write invocation failed: " + failure.error_text())
      }
      assert_eq(ske_json_int(write_result, "exit_code"), 0)
      assert_eq(ske_git_commit_text(h.workspace), "2")
      assert_eq(seen.val.length(), 1)
      let request = seen.val[0]
      assert_eq(
        request.rpc_method,
        @contracts.METHOD_RUNTIME_SKILL_INVOKE,
      )
      assert_eq(request.risk, @contracts.RISK_MEDIUM)
      assert_eq(request.policy_version, gated.version)
      assert_true(request.detail().contains("skill.invoke"))
      assert_true(!request.detail().contains("release 1.0.0"))
      assert_true(!h.host.audit_text().contains("release 1.0.0"))
      assert_eq(host_audit_count(h.state, "policy.approval_used"), 1)
      // A denied Decision never executes the mirrored write entry.
      let deny_port : @provider_runtime.ApprovalPort = async fn(request) {
        let _ = request
        @provider_runtime.ApprovalOutcome::Denied("dec-skill-deny")
      }
      let deny = @provider_runtime.ApprovalContext::new(
        port=deny_port,
        ttl_ms=30_000L,
        wait_ms=10_000L,
      )
      match
        h.machine.skill_invoke_approved(
          session_id=session_id,
          name=write_bundle.name,
          version=write_bundle.version,
          content_hash=write_bundle.content_hash,
          entry_id="note",
          run_id="skp-write-denied-run",
          client_request_id="skp-write-denied",
          approval=deny,
        ) {
        Ok(_) => abort("denied skill invocation executed")
        Err(@provider_runtime.ApprovalFailure::Denied(decision_id)) =>
          assert_eq(decision_id, "dec-skill-deny")
        Err(_) => abort("denied skill invocation did not report a denial")
      }
      assert_eq(ske_git_commit_text(h.workspace), "2")
      assert_eq(host_audit_count(h.state, "policy.approval_denied"), 1)
      // GC drops the leases, the session copies and unreferenced stores.
      let gc = match
        h.machine.skill_gc(
          session_id=session_id,
          force=true,
          client_request_id="skp-gc",
        ) {
        Ok(value) => value
        Err(error) => abort("paired skill GC failed: " + error.message)
      }
      assert_eq(ske_json_int(gc, "remaining"), 0)
      let read_copy_exists = @fs.exists(
        h.host.state_dir() + "/skills/sessions/" + session_id + "/" +
        read_bundle.name + "-" + read_bundle.version,
      ) catch {
        _ => true
      }
      assert_true(!read_copy_exists)
      let read_store_exists = @fs.exists(
        h.host.state_dir() + "/skills/store/" + read_bundle.name + "/" +
        read_bundle.version + "/" + read_bundle.content_hash,
      ) catch {
        _ => true
      }
      assert_true(!read_store_exists)
      assert_eq(
        host_mode(h.host.state_dir() + "/" + NODE_SKILL_LEASES_FILE_NAME),
        0o600,
      )
      // Without a live lease the same call fails closed rather than falling
      // back to the store or to a fresh execution.
      match
        h.machine.skill_invoke_approved(
          session_id=session_id,
          name=read_bundle.name,
          version=read_bundle.version,
          content_hash=read_bundle.content_hash,
          entry_id="status",
          run_id="skp-after-gc-run",
          client_request_id="skp-after-gc",
          approval=read_approval,
        ) {
        Ok(_) => abort("invocation after GC executed")
        Err(@provider_runtime.ApprovalFailure::Unavailable(reason)) =>
          assert_true(reason.contains("fails closed"))
        Err(_) => abort("post-GC invocation did not fail unavailable")
      }
      // Re-mirroring converges: the store and session copy return, and the
      // exact entry executes again.
      let remirror = match
        h.machine.skill_mirror(
          session_id=session_id,
          name=read_bundle.name,
          version=read_bundle.version,
          content_hash=read_bundle.content_hash,
          manifest=read_bundle.manifest_text,
          files=read_bundle.files,
          lease_ms=120_000L,
          client_request_id="skp-mirror-read-2",
        ) {
        Ok(value) => value
        Err(error) => abort("paired re-mirror failed: " + error.message)
      }
      assert_eq(pa_json_bool(remirror, "existing"), false)
      let replayed = match
        h.machine.skill_invoke_approved(
          session_id=session_id,
          name=read_bundle.name,
          version=read_bundle.version,
          content_hash=read_bundle.content_hash,
          entry_id="status",
          run_id="skp-read-run-2",
          client_request_id="skp-read-2",
          approval=read_approval,
        ) {
        Ok(value) => value
        Err(failure) =>
          abort("re-mirrored read invocation failed: " + failure.error_text())
      }
      assert_eq(ske_json_int(replayed, "exit_code"), 0)
      assert_eq(ske_git_commit_text(h.workspace), "2")
    },
  )
}
