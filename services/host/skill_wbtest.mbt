///|
/// A4 host skill tests (whitebox, ADR-0015 §13 items 1–7, 9–11).
///
/// Owner RPCs are driven through the real `handle_request` dispatcher so the
/// flag-off contract, idempotency and method routing are exercised. Signing
/// uses a throwaway `ssh-keygen` key per test; no key material is checked in.

///|
const SKH_KEY_ID : String = "owner-key-1"

///|
const SKH_HASH_ZERO : String =
  "sha256:0000000000000000000000000000000000000000000000000000000000000000"

///|
async fn skh_run_ok(tool : String, argv : Array[String], cwd~ : String = "") -> String raise {
  let result = if cwd == "" {
    @process.collect_output(tool, argv) catch {
      _ => fail("cannot spawn " + tool)
    }
  } else {
    @process.collect_output(tool, argv, cwd=cwd) catch {
      _ => fail("cannot spawn " + tool)
    }
  }
  let (code, stdout, stderr) = result
  if code != 0 {
    let message = stderr.text() catch { _ => "" }
    fail(tool + " exited " + code.to_string() + ": " + message)
  }
  stdout.text() catch { _ => "" }
}

///|
async fn skh_write(path : String, text : String, mode : Int32) -> Unit raise {
  @fs.write_file(path, text, permission=mode) catch {
    _ => fail("cannot write " + path)
  }
}

///|
async fn skh_read(path : String) -> String raise {
  let data = @fs.read_file(path) catch { _ => fail("cannot read " + path) }
  data.text() catch { _ => fail("cannot decode " + path) }
}

///|
async fn skh_tmp(prefix : String) -> String raise {
  @fs.tmpdir(prefix=prefix) catch { _ => fail("cannot create temp directory") }
}

///|
async fn skh_cleanup(path : String) -> Unit {
  @fs.rmdir(path, recursive=true) catch { _ => () }
}

///|
fn skh_strip_armor(text : String) -> String {
  let out = StringBuilder()
  for line in text.split("\n") {
    let trimmed = line.trim()
    if trimmed.has_prefix("-----") || trimmed.length() == 0 {
      continue
    }
    out.write_string(trimmed.to_owned())
  }
  out.to_string()
}

///|
async fn skh_generate_key(dir : String) -> (String, String) raise {
  let key_path = dir + "/id_ed25519"
  ignore(
    skh_run_ok(
      "ssh-keygen",
      ["-q", "-t", "ed25519", "-N", "", "-C", "", "-f", key_path],
    ),
  )
  let public_key = skh_run_ok("ssh-keygen", ["-y", "-f", key_path])
  (key_path, public_key.trim().to_owned())
}

///|
async fn skh_sign(key_path : String, payload_path : String) -> String raise {
  ignore(
    skh_run_ok(
      "ssh-keygen",
      [
        "-q", "-Y", "sign", "-f", key_path, "-n",
        @skills.SKILL_SIGNATURE_NAMESPACE,
        payload_path,
      ],
    ),
  )
  skh_strip_armor(skh_read(payload_path + ".sig"))
}

///|
/// A throwaway agent home plus a skill-enabled host state with a real verifier
/// and an in-memory store.
async fn skh_state(prefix : String, enabled : Bool) -> (HostState, String) raise {
  let dir = skh_tmp(prefix)
  @fs.mkdir(dir + "/state", permission=0o700, recursive=true) catch {
    _ => fail("cannot create the state directory")
  }
  let store = match @machines.MachineStore::open(":memory:") {
    Ok(value) => value
    Err(message) => fail("cannot open the store: " + message)
  }
  let verifier = @skills.probe_skill_verifier()
  if !verifier.usable {
    store.close()
    fail("the ssh-keygen verifier is not usable here: " + verifier.detail)
  }
  let options = HostOptions::new(
    state_dir=dir + "/state",
    skill_enabled=enabled,
  )
  let state = HostState::new(
    options,
    0,
    store,
    @recipes.TrustStore::empty(),
    verifier,
  )
  (state, dir)
}

///|
fn skh_ref_params(
  client_request_id : String,
  name : String,
  version : String,
  content_hash : String,
) -> Map[String, @json.Json] {
  @contracts.skill_ref_params(client_request_id, name, version, content_hash)
}

///|
async fn skh_call(
  state : HostState,
  method : String,
  params : Map[String, @json.Json],
) -> String {
  let request = @contracts.RpcRequest::new(
    "req-" + @contracts.new_id("t", @async.now()),
    method,
    params,
  )
  let sink = host_test_sink()
  handle_request(state, sink, request)
  sink.queue.get() catch { _ => "" }
}

///|
struct SkhFixture {
  dir : String
  source : String
  key_path : String
  public_key : String
  name : String
  version : String
  content_hash : String
  manifest : String
}

///|
async fn skh_fixture(
  prefix : String,
  name : String,
  version : String,
  permissions : String,
  commands : String,
  dependencies : String,
) -> SkhFixture raise {
  let dir = skh_tmp(prefix)
  let source = dir + "/source"
  @fs.mkdir(source, permission=0o700, recursive=true) catch {
    _ => fail("cannot create the bundle source")
  }
  let (key_path, public_key) = skh_generate_key(dir)
  let entry = "# " + name + "\n\nUse the declared entry.\n"
  let resource = "notes\n"
  let deps_field = if dependencies == "" {
    ""
  } else {
    ",\"dependencies\":" + dependencies
  }
  let fields = "{\"schema_version\":1," +
    "\"name\":\"" + name + "\"," +
    "\"version\":\"" + version + "\"," +
    "\"description\":\"Test skill " + name + "\"," +
    "\"permissions\":" + permissions + "," +
    "\"entry\":{\"path\":\"SKILL.md\",\"max_bytes\":4096}," +
    "\"resources\":[{\"path\":\"notes/README.md\",\"description\":\"notes\"}]," +
    "\"commands\":" + commands +
    deps_field + "," +
    "\"source\":{\"kind\":\"local_directory\",\"path\":\"/tmp/src\",\"author\":\"ops\",\"created_at\":\"2026-01-01T00:00:00Z\"}}"
  let placeholder = fields[:fields.length() - 1].to_owned() +
    ",\"content_hash\":\"" + SKH_HASH_ZERO +
    "\",\"signature\":{\"key_id\":\"" + SKH_KEY_ID +
    "\",\"alg\":\"ed25519\",\"sig\":\"U1NIU0lHAAAAdGVzdA==\"}}"
  let parsed = match @skills.parse_skill_manifest(placeholder) {
    Ok(value) => value
    Err(fault) =>
      fail(
        "fixture manifest rejected: " + fault.code + ": " + fault.detail,
      )
  }
  let body = @skills.canonical_manifest_string(parsed)
  let hash = @skills.compute_content_hash(
    body,
    [("SKILL.md", entry), ("notes/README.md", resource)],
  )
  let payload_path = dir + "/payload"
  skh_write(payload_path, @skills.skill_sig_input(hash), 0o600)
  let sig = skh_sign(key_path, payload_path)
  let manifest = fields[:fields.length() - 1].to_owned() +
    ",\"content_hash\":\"" + hash +
    "\",\"signature\":{\"key_id\":\"" + SKH_KEY_ID +
    "\",\"alg\":\"ed25519\",\"sig\":\"" + sig + "\"}}"
  skh_write(source + "/skill.json", manifest, 0o600)
  skh_write(source + "/SKILL.md", entry, 0o600)
  @fs.mkdir(source + "/notes", permission=0o700, recursive=true) catch {
    _ => fail("cannot create the notes directory")
  }
  skh_write(source + "/notes/README.md", resource, 0o600)
  {
    dir,
    source,
    key_path,
    public_key,
    name,
    version,
    content_hash: hash,
    manifest,
  }
}

///|
fn skh_read_commands() -> String {
  // Generous timeout: the full native suite runs packages concurrently, and
  // process spawn can take longer than 5 s under that load on macOS.
  "[{\"id\":\"status\",\"argv\":[\"git\",\"status\",\"--porcelain\"],\"mode\":\"read_only\",\"timeout_ms\":30000,\"max_output_bytes\":8192}]"
}

///|
fn skh_write_commands() -> String {
  // Same contention allowance as skh_read_commands.
  "[{\"id\":\"note\",\"argv\":[\"git\",\"commit\",\"--allow-empty\",\"-m\",\"release 1.0.0\"],\"mode\":\"write\",\"timeout_ms\":30000,\"max_output_bytes\":8192}]"
}

///|
fn skh_binding(
  name : String,
  version : String,
  content_hash : String,
  mode : String,
) -> @contracts.SkillBinding {
  @contracts.SkillBinding::new(
    name~,
    version~,
    content_hash~,
    mode~,
  )
}

///|
async fn skh_register_key(
  state : HostState,
  key_id : String,
  public_key : String,
) -> String {
  let cid = @contracts.new_id("cid", @async.now())
  skh_call(
    state,
    @contracts.METHOD_SKILL_KEY_REGISTER,
    @contracts.skill_key_register_params(cid, key_id, public_key),
  )
}

///|
async fn skh_import(state : HostState, source : String) -> String {
  let cid = @contracts.new_id("cid", @async.now())
  skh_call(
    state,
    @contracts.METHOD_SKILL_IMPORT,
    @contracts.skill_import_params(cid, source),
  )
}

///|
async fn skh_allow(state : HostState, fixture : SkhFixture) -> String {
  let cid = @contracts.new_id("cid", @async.now())
  skh_call(
    state,
    @contracts.METHOD_SKILL_ALLOW,
    skh_ref_params(cid, fixture.name, fixture.version, fixture.content_hash),
  )
}

///|
async fn skh_enable(
  state : HostState,
  scope : String,
  scope_ref : String,
  fixture : SkhFixture,
  mode : String,
) -> String {
  let cid = @contracts.new_id("cid", @async.now())
  skh_call(
    state,
    @contracts.METHOD_SKILL_ENABLE,
    @contracts.skill_enable_params(
      cid,
      scope,
      scope_ref,
      skh_binding(fixture.name, fixture.version, fixture.content_hash, mode),
    ),
  )
}

///|
/// Register, import, allowlist and enable one fixture for an agent scope.
async fn skh_publish(
  state : HostState,
  fixture : SkhFixture,
  agent_id : String,
  mode : String,
) -> Unit raise {
  let registered = skh_register_key(state, SKH_KEY_ID, fixture.public_key)
  if !registered.contains("\"key_id\"") {
    fail("key registration failed: " + registered)
  }
  let imported = skh_import(state, fixture.source)
  if !imported.contains("\"skill\"") {
    fail("import failed: " + imported)
  }
  let allowed = skh_allow(state, fixture)
  if !allowed.contains("\"allowed\"") {
    fail("allow failed: " + allowed)
  }
  let enabled = skh_enable(
    state,
    @contracts.SKILL_SCOPE_AGENT,
    agent_id,
    fixture,
    mode,
  )
  if !enabled.contains("\"binding\"") {
    fail("enable failed: " + enabled)
  }
}

///|
async test "flag-off host answers unsupported and resolves no skills" {
  let (state, dir) = skh_state("monexus-skill-host-off", false) catch {
    _ => fail("cannot create the test state")
  }
  defer @async.protect_from_cancel(async fn() { skh_cleanup(dir) })
  let fixture = skh_fixture(
    "monexus-skill-host-off-bundle",
    "repo-health",
    "1.0.0",
    "[\"git.read\"]",
    skh_read_commands(),
    "",
  ) catch { _ => fail("cannot build the fixture") }
  defer @async.protect_from_cancel(async fn() { skh_cleanup(fixture.dir) })
  // Every skill method is registered but answers unsupported.
  let import_text = skh_import(state, fixture.source) catch {
    _ => fail("import call failed")
  }
  assert_true(import_text.contains("unsupported"))
  assert_true(!import_text.contains("skill.import"))
  let tools_text = skh_call(
    state,
    @contracts.METHOD_SKILL_TOOLS,
    Map([
      ("client_request_id", @contracts.json_string(@contracts.new_id("cid", @async.now()))),
      ("token", @contracts.json_string("token")),
    ]),
  ) catch { _ => fail("tools call failed") }
  assert_true(tools_text.contains("unsupported"))
  let invoke_text = skh_call(
    state,
    @contracts.METHOD_SKILL_INVOKE,
    Map([
      ("client_request_id", @contracts.json_string(@contracts.new_id("cid", @async.now()))),
      ("token", @contracts.json_string("token")),
      ("entry_id", @contracts.json_string("status")),
    ]),
  ) catch { _ => fail("invoke call failed") }
  assert_true(invoke_text.contains("unsupported"))
  // Session resolution is a no-op: no token, no injection, no materialisation.
  let setup = match
    setup_skill_session(
      state,
      "agt_off",
      "agt_off_session",
      "",
      fixture.dir + "/home",
      fixture.dir,
      "ws_off",
      false,
      [],
    ) {
    Ok(value) => value
    Err(fault) => fail("setup failed: " + fault.code)
  }
  assert_eq(setup.token, "")
  assert_eq(setup.loaded, 0)
  assert_eq(setup.available, 0)
  assert_true(!(
    @fs.exists(fixture.dir + "/home/sessions/agt_off_session/skills") catch {
      _ => true
    }
  ))
  state.store.close()
}

///|
async test "owner flow imports, allowlists, enables, upgrades and uninstalls" {
  let (state, dir) = skh_state("monexus-skill-host-owner", true) catch {
    _ => fail("cannot create the test state")
  }
  defer @async.protect_from_cancel(async fn() { skh_cleanup(dir) })
  let v1 = skh_fixture(
    "monexus-skill-host-owner-v1",
    "repo-health",
    "1.0.0",
    "[\"git.read\"]",
    skh_read_commands(),
    "",
  ) catch { _ => fail("cannot build the v1 fixture") }
  defer @async.protect_from_cancel(async fn() { skh_cleanup(v1.dir) })
  let v2 = skh_fixture(
    "monexus-skill-host-owner-v2",
    "repo-health",
    "2.0.0",
    "[\"git.read\"]",
    skh_read_commands(),
    "",
  ) catch { _ => fail("cannot build the v2 fixture") }
  defer @async.protect_from_cancel(async fn() { skh_cleanup(v2.dir) })
  skh_publish(state, v1, "agt_owner", @contracts.SKILL_MODE_LOADED) catch {
    _ => fail("cannot publish v1")
  }
  // The exact tuple is visible and allowlisted.
  let listed = skh_call(
    state,
    @contracts.METHOD_SKILL_LIST,
    @contracts.skill_list_params(
      @contracts.new_id("cid", @async.now()),
    ),
  ) catch { _ => fail("list failed") }
  assert_true(listed.contains(v1.content_hash))
  assert_true(listed.contains("\"allowlist\""))
  assert_true(listed.contains("\"bindings\""))
  // A different hash is not covered by the same tuple.
  let unknown = skh_call(
    state,
    @contracts.METHOD_SKILL_GET,
    skh_ref_params(
      @contracts.new_id("cid", @async.now()),
      v1.name,
      v1.version,
      SKH_HASH_ZERO,
    ),
  ) catch { _ => fail("get failed") }
  assert_true(unknown.contains(@contracts.SKILL_ERR_NOT_ALLOWLISTED))
  // Permission ceiling round-trips through the owner API.
  let set = skh_call(
    state,
    @contracts.METHOD_SKILL_PERMISSIONS_SET,
    @contracts.skill_permissions_set_params(
      @contracts.new_id("cid", @async.now()),
      "agt_owner",
      ["git.read", "git.write", "workspace.read", "exec.readonly"],
    ),
  ) catch { _ => fail("permissions set failed") }
  assert_true(set.contains("\"permissions\""))
  let got = skh_call(
    state,
    @contracts.METHOD_SKILL_PERMISSIONS_GET,
    @contracts.skill_permissions_get_params(
      @contracts.new_id("cid", @async.now()),
      "agt_owner",
    ),
  ) catch { _ => fail("permissions get failed") }
  assert_true(got.contains("git.read"))
  // Doctor re-verifies the stored copy and reports a healthy bundle.
  let doctor = skh_call(
    state,
    @contracts.METHOD_SKILL_DOCTOR,
    skh_ref_params(
      @contracts.new_id("cid", @async.now()),
      v1.name,
      v1.version,
      v1.content_hash,
    ),
  ) catch { _ => fail("doctor failed") }
  assert_true(doctor.contains("\"ok\":true"))
  // Import v2, allow it, then upgrade only by the explicit RPC. Each fixture
  // signs with its own throwaway key, so the key registration is refreshed.
  let registered_v2 = skh_register_key(state, SKH_KEY_ID, v2.public_key) catch {
    _ => fail("v2 key registration failed")
  }
  assert_true(registered_v2.contains("\"key_id\""))
  let imported_v2 = skh_import(state, v2.source) catch { _ => fail("v2 import failed") }
  assert_true(imported_v2.contains("\"file_count\""))
  let allowed_v2 = skh_allow(state, v2) catch { _ => fail("v2 allow failed") }
  assert_true(allowed_v2.contains("\"allowed\""))
  let upgraded = skh_call(
    state,
    @contracts.METHOD_SKILL_UPGRADE,
    @contracts.skill_enable_params(
      @contracts.new_id("cid", @async.now()),
      @contracts.SKILL_SCOPE_AGENT,
      "agt_owner",
      skh_binding(v2.name, v2.version, v2.content_hash, @contracts.SKILL_MODE_LOADED),
    ),
  ) catch { _ => fail("upgrade failed") }
  assert_true(upgraded.contains("\"old_version\""))
  assert_true(upgraded.contains("1.0.0"))
  let binding_result = state.store.get_skill_binding(
    @contracts.SKILL_SCOPE_AGENT,
    "agt_owner",
    "repo-health",
  )
  let binding = match binding_result {
    Ok(value) => value
    Err(message) => fail("cannot read the binding: " + message)
  }
  match binding {
    Some(row) => assert_eq(row.version, "2.0.0")
    None => fail("upgraded binding is missing")
  }
  // Disable removes the binding but keeps the imported tuple visible.
  let disabled = skh_call(
    state,
    @contracts.METHOD_SKILL_DISABLE,
    Map([
      ("client_request_id", @contracts.json_string(@contracts.new_id("cid", @async.now()))),
      ("scope", @contracts.json_string(@contracts.SKILL_SCOPE_AGENT)),
      ("scope_ref", @contracts.json_string("agt_owner")),
      ("name", @contracts.json_string("repo-health")),
    ]),
  ) catch { _ => fail("disable failed") }
  assert_true(disabled.contains("\"disabled\""))
  assert_true(disabled.contains("active_sessions_note"))
  // Uninstall removes the store directory and the index row.
  let uninstalled = skh_call(
    state,
    @contracts.METHOD_SKILL_UNINSTALL,
    skh_ref_params(
      @contracts.new_id("cid", @async.now()),
      v1.name,
      v1.version,
      v1.content_hash,
    ),
  ) catch { _ => fail("uninstall failed") }
  assert_true(uninstalled.contains("\"pending_delete\""))
  let store_path = state.state_dir +
    "/skills/store/" + v1.name + "/" + v1.version + "/" + v1.content_hash
  assert_true(!(@fs.exists(store_path) catch { _ => true }))
  let row_result = state.store.get_skill_row(v1.name, v1.version, v1.content_hash)
  let row = match row_result {
    Ok(value) => value
    Err(message) => fail("cannot read the removed row: " + message)
  }
  assert_true(row is None)
  state.store.close()
}

///|
async test "enable rejects a permission ceiling escape and records readiness" {
  let (state, dir) = skh_state("monexus-skill-host-ceiling", true) catch {
    _ => fail("cannot create the test state")
  }
  defer @async.protect_from_cancel(async fn() { skh_cleanup(dir) })
  let writable = skh_fixture(
    "monexus-skill-host-ceiling-write",
    "release-note",
    "1.0.0",
    "[\"git.write\"]",
    skh_write_commands(),
    "",
  ) catch { _ => fail("cannot build the write fixture") }
  defer @async.protect_from_cancel(async fn() { skh_cleanup(writable.dir) })
  // Import and allowlist first, with a ceiling that excludes git.write.
  let registered = skh_register_key(state, SKH_KEY_ID, writable.public_key) catch {
    _ => fail("key registration failed")
  }
  assert_true(registered.contains("\"key_id\""))
  let imported = skh_import(state, writable.source) catch { _ => fail("import failed") }
  assert_true(imported.contains("\"skill\""))
  let allowed = skh_allow(state, writable) catch { _ => fail("allow failed") }
  assert_true(allowed.contains("\"allowed\""))
  let ceiling = skh_call(
    state,
    @contracts.METHOD_SKILL_PERMISSIONS_SET,
    @contracts.skill_permissions_set_params(
      @contracts.new_id("cid", @async.now()),
      "agt_ceiling",
      ["git.read", "workspace.read"],
    ),
  ) catch { _ => fail("permissions set failed") }
  assert_true(ceiling.contains("\"permissions\""))
  let refused = skh_enable(
    state,
    @contracts.SKILL_SCOPE_AGENT,
    "agt_ceiling",
    writable,
    @contracts.SKILL_MODE_LOADED,
  ) catch { _ => fail("enable call failed") }
  assert_true(refused.contains(@contracts.SKILL_ERR_PERMISSION_DENIED))
  assert_true(!refused.contains("\"binding\""))
  // A missing binary dependency produces a Decision instead of an enable.
  let dependent = skh_fixture(
    "monexus-skill-host-ceiling-dep",
    "dep-skill",
    "1.0.0",
    "[\"git.read\"]",
    skh_read_commands(),
    "[{\"kind\":\"binary\",\"name\":\"mn-missing-binary-a4\"}]",
  ) catch { _ => fail("cannot build the dependency fixture") }
  defer @async.protect_from_cancel(async fn() { skh_cleanup(dependent.dir) })
  let registered_dep = skh_register_key(state, SKH_KEY_ID, dependent.public_key) catch {
    _ => fail("dependency key registration failed")
  }
  assert_true(registered_dep.contains("\"key_id\""))
  let imported_dep = skh_import(state, dependent.source) catch {
    _ => fail("dependency import failed")
  }
  assert_true(imported_dep.contains("\"file_count\""))
  let allowed_dep = skh_allow(state, dependent) catch {
    _ => fail("dependency allow failed")
  }
  assert_true(allowed_dep.contains("\"allowed\""))
  let dependency_refused = skh_enable(
    state,
    @contracts.SKILL_SCOPE_AGENT,
    "agt_ceiling",
    dependent,
    @contracts.SKILL_MODE_LOADED,
  ) catch { _ => fail("dependency enable failed") }
  assert_true(dependency_refused.contains(@contracts.SKILL_ERR_DEPENDENCY_MISSING))
  let decision_result = state.store.list_decisions("", "")
  let decisions = match decision_result {
    Ok(value) => value
    Err(message) => fail("cannot list decisions: " + message)
  }
  let mut readiness = 0
  for decision in decisions {
    if decision.kind == @contracts.DECISION_KIND_READINESS {
      readiness = readiness + 1
    }
  }
  assert_true(readiness >= 1)
  state.store.close()
}

///|
async fn skh_fake_runtime(
  group : @async.TaskGroup[Unit],
  session_id : String,
  agent_id : String,
  home : String,
  token : String,
) -> AgentSessionRuntime raise {
  let spec = @agent.AgentSpec::new(
    agent_id=agent_id,
    mode=@contracts.AGENT_MODE_ACP,
    command="/bin/sleep",
    args=["30"],
    cwd="",
    env=Map([]),
  )
  let process = match
    @agent.spawn_agent(group, spec, async fn(_line) { () }) {
    Ok(value) => value
    Err(message) => fail("cannot spawn the fake agent process: " + message)
  }
  {
    id: session_id,
    agent_id,
    acp_session_id: "acp_" + session_id,
    process,
    transcript: Ref({ base: 0L, text: "" }),
    pending: Map([]),
    active_prompts: Map([]),
    turn_text: Ref(""),
    home,
    memory_before: "",
    stderr_tail: Ref(""),
    finalized: Ref(false),
    skill_token: token,
  }
}

///|
async fn skh_setup(
  state : HostState,
  agent_id : String,
  session_id : String,
  home : String,
  cwd : String,
  explicit : Array[@contracts.SkillBinding],
  task_id~ : String = "",
) -> SkillSessionSetup raise {
  match
    setup_skill_session(
      state,
      agent_id,
      session_id,
      task_id,
      home,
      cwd,
      "ws_skill",
      false,
      explicit,
    ) {
    Ok(value) => value
    Err(fault) => fail("session setup refused: " + fault.code + ": " + fault.detail)
  }
}

///|
async fn skh_snapshot_has(state : HostState, event_type : String, needle : String) -> Bool {
  state.mutex.acquire()
  let mut found = false
  for event in state.ring {
    if event.event_type == event_type &&
      event.payload.stringify().contains(needle) {
      found = true
    }
  }
  state.mutex.release()
  found
}

///|
async fn skh_ring_leaks(state : HostState, needle : String) -> Bool {
  state.mutex.acquire()
  let mut leaked = false
  for event in state.ring {
    if (event.event_type == @contracts.EVENT_SKILL_INVOKED ||
      event.event_type == @contracts.EVENT_SKILL_INVOKE_DENIED ||
      event.event_type == @contracts.EVENT_AUDIT_RECORDED) &&
      event.payload.stringify().contains(needle) {
      leaked = true
    }
  }
  state.mutex.release()
  leaked
}

///|
fn skh_invocation_count(state : HostState, session_id : String, entry_id : String) -> Int {
  let rows = match state.store.list_skill_invocations(session_id) {
    Ok(value) => value
    Err(_) => []
  }
  let mut count = 0
  for row in rows {
    if row.entry_id == entry_id {
      count = count + 1
    }
  }
  count
}

///|
async test "session resolution freezes tuples, refuses conflicts and follows disable" {
  let (state, dir) = skh_state("monexus-skill-host-session", true) catch {
    _ => fail("cannot create the test state")
  }
  defer @async.protect_from_cancel(async fn() { skh_cleanup(dir) })
  let v1 = skh_fixture(
    "monexus-skill-host-session-v1",
    "repo-health",
    "1.0.0",
    "[\"git.read\"]",
    skh_read_commands(),
    "",
  ) catch { _ => fail("cannot build the fixture") }
  defer @async.protect_from_cancel(async fn() { skh_cleanup(v1.dir) })
  let v2 = skh_fixture(
    "monexus-skill-host-session-v2",
    "repo-health",
    "2.0.0",
    "[\"git.read\"]",
    skh_read_commands(),
    "",
  ) catch { _ => fail("cannot build the second fixture") }
  defer @async.protect_from_cancel(async fn() { skh_cleanup(v2.dir) })
  skh_publish(state, v1, "agt_sess", @contracts.SKILL_MODE_LOADED) catch {
    _ => fail("cannot publish the agent binding")
  }
  let home = v1.dir + "/home"
  // An explicit session binding merges with the agent binding; loaded wins
  // and the session scope is the most specific one.
  let setup = skh_setup(
    state,
    "agt_sess",
    "agt_sess_local",
    home,
    v1.dir,
    [
      skh_binding(
        v1.name,
        v1.version,
        v1.content_hash,
        @contracts.SKILL_MODE_AVAILABLE,
      ),
    ],
  ) catch { _ => fail("explicit-session setup failed") }
  assert_eq(setup.loaded, 1)
  assert_eq(setup.available, 0)
  assert_true(setup.token != "")
  assert_eq(setup.entries.length(), 1)
  assert_eq(setup.entries[0].scope, @contracts.SKILL_SCOPE_SESSION)
  assert_eq(setup.entries[0].mode, @contracts.SKILL_MODE_LOADED)
  let root = setup.entries[0].resource_root
  assert_true(root.has_prefix(home + "/sessions/agt_sess_local/skills/"))
  assert_true(@fs.exists(root + "/SKILL.md") catch { _ => false })
  assert_true(@fs.exists(root + "/notes/README.md") catch { _ => false })
  assert_true(!(@fs.exists(root + "/skill.json") catch { _ => true }))
  assert_true(setup.injection.block.contains(v1.content_hash))
  // The capability is frozen with the token and the session is still live.
  state.mutex.acquire()
  let capability = state.skill_capabilities.get(setup.token)
  state.mutex.release()
  assert_true(capability is Some(_))
  // A second exact tuple for the same name is a conflict, never "latest".
  let conflict = setup_skill_session(
    state,
    "agt_sess",
    "agt_sess_conflict",
    "",
    home,
    v1.dir,
    "ws_skill",
    false,
    [
      skh_binding(
        v2.name,
        v2.version,
        v2.content_hash,
        @contracts.SKILL_MODE_LOADED,
      ),
    ],
  )
  match conflict {
    Ok(_) => fail("conflicting tuples were merged")
    Err(fault) => assert_eq(fault.code, @contracts.SKILL_ERR_CONFLICT)
  }
  // A wrong hash for an imported name is a conflict, not an implicit
  // substitution of the agent's frozen tuple.
  let wrong = setup_skill_session(
    state,
    "agt_sess",
    "agt_sess_wrong",
    "",
    home,
    v1.dir,
    "ws_skill",
    false,
    [
      skh_binding(
        v1.name,
        v1.version,
        SKH_HASH_ZERO,
        @contracts.SKILL_MODE_LOADED,
      ),
    ],
  )
  match wrong {
    Ok(_) => fail("an unimported tuple was accepted")
    Err(fault) => assert_eq(fault.code, @contracts.SKILL_ERR_CONFLICT)
  }
  // An unknown name is not allowlisted and is never resolved by name alone.
  let missing = setup_skill_session(
    state,
    "agt_sess",
    "agt_sess_missing",
    "",
    home,
    v1.dir,
    "ws_skill",
    false,
    [
      skh_binding(
        "not-imported",
        "1.0.0",
        SKH_HASH_ZERO,
        @contracts.SKILL_MODE_LOADED,
      ),
    ],
  )
  match missing {
    Ok(_) => fail("an unknown skill was accepted")
    Err(fault) => assert_eq(fault.code, @contracts.SKILL_ERR_NOT_ALLOWLISTED)
  }
  // Available-only is visible as a card and gets no token or materialisation.
  let card = skh_setup(
    state,
    "agt_other",
    "agt_card_local",
    v1.dir + "/home-card",
    v1.dir,
    [
      skh_binding(
        v1.name,
        v1.version,
        v1.content_hash,
        @contracts.SKILL_MODE_AVAILABLE,
      ),
    ],
  ) catch { _ => fail("available-only setup failed") }
  assert_eq(card.loaded, 0)
  assert_eq(card.available, 1)
  assert_eq(card.token, "")
  let card_dir_exists = @fs.exists(v1.dir + "/home-card/sessions/agt_card_local/skills") catch {
    _ => true
  }
  assert_true(!card_dir_exists)
  // Disabling the agent binding only affects new sessions. The frozen
  // capability remains until the session is finalized.
  let disabled = skh_call(
    state,
    @contracts.METHOD_SKILL_DISABLE,
    Map([
      ("client_request_id", @contracts.json_string(@contracts.new_id("cid", @async.now()))),
      ("scope", @contracts.json_string(@contracts.SKILL_SCOPE_AGENT)),
      ("scope_ref", @contracts.json_string("agt_sess")),
      ("name", @contracts.json_string("repo-health")),
    ]),
  ) catch { _ => fail("disable failed") }
  assert_true(disabled.contains("\"disabled\""))
  let after_disable = skh_setup(
    state,
    "agt_sess",
    "agt_sess_after_disable",
    home,
    v1.dir,
    [],
  ) catch { _ => fail("post-disable setup failed") }
  assert_eq(after_disable.loaded, 0)
  assert_eq(after_disable.token, "")
  state.mutex.acquire()
  let frozen = state.skill_capabilities.get(setup.token)
  state.mutex.release()
  assert_true(frozen is Some(_))
  // Finalizing removes the capability and the materialised copies.
  finalize_skill_session(state, setup.token, "agt_sess_local", home)
  state.mutex.acquire()
  let gone = state.skill_capabilities.get(setup.token)
  state.mutex.release()
  assert_true(gone is None)
  assert_true(!(@fs.exists(root) catch { _ => true }))
  state.store.close()
}

///|
async test "gateway lists one tool, executes reads and audits without bodies" {
  let (state, dir) = skh_state("monexus-skill-host-gateway", true) catch {
    _ => fail("cannot create the test state")
  }
  let workspace = dir + "/workspace"
  @fs.mkdir(workspace, permission=0o700, recursive=true) catch {
    _ => fail("cannot create the workspace")
  }
  ignore(skh_run_ok("git", ["init", "-q"], cwd=workspace) catch {
    _ => fail("cannot initialise git")
  })
  skh_write(workspace + "/SECRET_FILE.txt", "secret-output\n", 0o600) catch {
    _ => fail("cannot write the marker")
  }
  let fixture = skh_fixture(
    "monexus-skill-host-gateway-read",
    "repo-health",
    "1.0.0",
    "[\"git.read\"]",
    skh_read_commands(),
    "",
  ) catch { _ => fail("cannot build the fixture") }
  defer @async.protect_from_cancel(async fn() { skh_cleanup(fixture.dir) })
  @async.with_task_group(async fn(group) {
    skh_publish(state, fixture, "agt_gate", @contracts.SKILL_MODE_LOADED) catch {
      _ => fail("cannot publish the agent binding")
    }
    let home = fixture.dir + "/home"
    let setup = skh_setup(
      state,
      "agt_gate",
      "agt_gate_local",
      home,
      workspace,
      [],
    ) catch { _ => fail("gateway setup failed") }
    assert_true(setup.token != "")
    let runtime = skh_fake_runtime(
      group,
      "agt_gate_local",
      "agt_gate",
      home,
      setup.token,
    ) catch { _ => fail("cannot create the fake runtime") }
    state.mutex.acquire()
    state.agent_sessions.set("agt_gate_local", runtime)
    state.mutex.release()
    defer @async.protect_from_cancel(async fn() {
      state.mutex.acquire()
      state.agent_sessions.remove("agt_gate_local")
      state.mutex.release()
      runtime.process.interrupt()
      finalize_skill_session(state, setup.token, "agt_gate_local", home)
    })
    // The tool list exposes only the host-owned gateway and only entry_id.
    let tools = skh_call(
      state,
      @contracts.METHOD_SKILL_TOOLS,
      Map([
        ("client_request_id", @contracts.json_string(@contracts.new_id("cid", @async.now()))),
        ("token", @contracts.json_string(setup.token)),
      ]),
    ) catch { _ => fail("tools call failed") }
    assert_true(tools.contains(@contracts.SKILL_INVOKE_TOOL))
    assert_true(tools.contains("\"required\":[\"entry_id\"]"))
    assert_true(tools.contains("\"additionalProperties\":false"))
    let bogus = skh_call(
      state,
      @contracts.METHOD_SKILL_TOOLS,
      Map([
        ("client_request_id", @contracts.json_string(@contracts.new_id("cid", @async.now()))),
        ("token", @contracts.json_string("not-a-live-token")),
      ]),
    ) catch { _ => fail("bogus tools call failed") }
    assert_true(bogus.contains(@contracts.SKILL_ERR_GATEWAY_UNAVAILABLE))
    // A read-only entry executes with the manifest argv and only entry_id.
    let invoked = skh_call(
      state,
      @contracts.METHOD_SKILL_INVOKE,
      Map([
        ("client_request_id", @contracts.json_string(@contracts.new_id("cid", @async.now()))),
        ("token", @contracts.json_string(setup.token)),
        ("entry_id", @contracts.json_string("status")),
        ("argv", @contracts.json_string("ignored")),
        ("command", @contracts.json_string("ignored")),
      ]),
    ) catch { _ => fail("read invocation failed") }
    assert_true(invoked.contains("\"invocation\""))
    assert_true(invoked.contains("\"exit_code\":0"))
    // The untracked marker reaches the bounded output; secret-shaped text is
    // redacted before it is returned.
    assert_true(invoked.contains("?? [redacted]"))
    assert_true(!invoked.contains("SECRET_FILE.txt"))
    assert_true(invoked.contains("\"decision_id\":\"\""))
    assert_true(skh_snapshot_has(
      state,
      @contracts.EVENT_SKILL_INVOKED,
      "\"entry_id\":\"status\"",
    ))
    assert_true(skh_snapshot_has(state, @contracts.EVENT_SKILL_INVOKED, "\"exit_code\":0"))
    assert_true(!skh_ring_leaks(state, "secret-output"))
    // Unknown entries are refused without running anything.
    let unknown = skh_call(
      state,
      @contracts.METHOD_SKILL_INVOKE,
      Map([
        ("client_request_id", @contracts.json_string(@contracts.new_id("cid", @async.now()))),
        ("token", @contracts.json_string(setup.token)),
        ("entry_id", @contracts.json_string("not-declared")),
      ]),
    ) catch { _ => fail("unknown invocation call failed") }
    assert_true(unknown.contains(@contracts.SKILL_ERR_NOT_LOADED))
    // Disabling the binding refuses new calls while the session stays live.
    let disabled = skh_call(
      state,
      @contracts.METHOD_SKILL_DISABLE,
      Map([
        ("client_request_id", @contracts.json_string(@contracts.new_id("cid", @async.now()))),
        ("scope", @contracts.json_string(@contracts.SKILL_SCOPE_AGENT)),
        ("scope_ref", @contracts.json_string("agt_gate")),
        ("name", @contracts.json_string("repo-health")),
      ]),
    ) catch { _ => fail("disable failed") }
    assert_true(disabled.contains("\"disabled\""))
    let refused = skh_call(
      state,
      @contracts.METHOD_SKILL_INVOKE,
      Map([
        ("client_request_id", @contracts.json_string(@contracts.new_id("cid", @async.now()))),
        ("token", @contracts.json_string(setup.token)),
        ("entry_id", @contracts.json_string("status")),
      ]),
    ) catch { _ => fail("disabled invocation call failed") }
    assert_true(refused.contains(@contracts.SKILL_ERR_NOT_LOADED))
    assert_eq(skh_invocation_count(state, "agt_gate_local", "status"), 1)
  })
  state.store.close()
  skh_cleanup(dir)
}

///|
async fn skh_git_commit_count(workspace : String) -> String {
  let text = skh_run_ok("git", ["rev-list", "--count", "--all"], cwd=workspace) catch {
    _ => return "error"
  }
  text.trim().to_owned()
}

///|
/// Answer the next pending skill Decision on the real Decision RPC path.
async fn skh_answer_skill_decision(
  state : HostState,
  session_id : String,
  option_id : String,
) -> Bool {
  let started = @async.now()
  while @async.now() - started < 10_000L {
    let result = state.store.list_decisions(
      @contracts.DECISION_STATUS_PENDING,
      session_id,
    )
    let pending = match result {
      Ok(value) => value
      Err(_) => []
    }
    for record in pending {
      if record.kind == @contracts.DECISION_KIND_SKILL {
        let cid = @contracts.new_id("cid", @async.now())
        ignore(
          skh_call(
            state,
            @contracts.METHOD_DECISION_RESPOND,
            @contracts.decision_respond_params(
              cid,
              record.id,
              option_id,
              "",
              "owner",
            ),
          ),
        )
        return true
      }
    }
    @async.sleep(10)
  }
  false
}

///|
async test "write entries always wait for a Decision and deny never executes" {
  let (state, dir) = skh_state("monexus-skill-host-write", true) catch {
    _ => fail("cannot create the test state")
  }
  let workspace = dir + "/workspace"
  @fs.mkdir(workspace, permission=0o700, recursive=true) catch {
    _ => fail("cannot create the workspace")
  }
  ignore(skh_run_ok("git", ["init", "-q"], cwd=workspace) catch {
    _ => fail("cannot initialise git")
  })
  ignore(skh_run_ok("git", ["config", "user.email", "skill@example.com"], cwd=workspace) catch {
    _ => fail("cannot configure git email")
  })
  ignore(skh_run_ok("git", ["config", "user.name", "Skill Test"], cwd=workspace) catch {
    _ => fail("cannot configure git name")
  })
  let fixture = skh_fixture(
    "monexus-skill-host-write-bundle",
    "release-note",
    "1.0.0",
    "[\"git.write\"]",
    skh_write_commands(),
    "",
  ) catch { _ => fail("cannot build the fixture") }
  defer @async.protect_from_cancel(async fn() { skh_cleanup(fixture.dir) })
  @async.with_task_group(async fn(group) {
    let ceiling = skh_call(
      state,
      @contracts.METHOD_SKILL_PERMISSIONS_SET,
      @contracts.skill_permissions_set_params(
        @contracts.new_id("cid", @async.now()),
        "agt_write",
        ["git.read", "git.write"],
      ),
    ) catch { _ => fail("permissions set failed") }
    assert_true(ceiling.contains("\"permissions\""))
    skh_publish(state, fixture, "agt_write", @contracts.SKILL_MODE_LOADED) catch {
      _ => fail("cannot publish the agent binding")
    }
    let home = fixture.dir + "/home"
    let setup = skh_setup(
      state,
      "agt_write",
      "agt_write_local",
      home,
      workspace,
      [],
    ) catch { _ => fail("write setup failed") }
    let runtime = skh_fake_runtime(
      group,
      "agt_write_local",
      "agt_write",
      home,
      setup.token,
    ) catch { _ => fail("cannot create the fake runtime") }
    state.mutex.acquire()
    state.agent_sessions.set("agt_write_local", runtime)
    state.mutex.release()
    defer @async.protect_from_cancel(async fn() {
      state.mutex.acquire()
      state.agent_sessions.remove("agt_write_local")
      state.mutex.release()
      runtime.process.interrupt()
      finalize_skill_session(state, setup.token, "agt_write_local", home)
    })
    // An owner approval executes exactly once and records the decision id.
    group.spawn_bg(
      no_wait=true,
      allow_failure=true,
      async fn() {
        ignore(
          skh_answer_skill_decision(
            state,
            "agt_write_local",
            @contracts.DECISION_OPTION_APPROVE,
          ),
        )
      },
    )
    let approved = skh_call(
      state,
      @contracts.METHOD_SKILL_INVOKE,
      Map([
        ("client_request_id", @contracts.json_string(@contracts.new_id("cid", @async.now()))),
        ("token", @contracts.json_string(setup.token)),
        ("entry_id", @contracts.json_string("note")),
      ]),
    ) catch { _ => fail("approved invocation call failed") }
    assert_true(approved.contains("\"exit_code\":0"))
    assert_true(!approved.contains("\"decision_id\":\"\""))
    assert_eq(skh_git_commit_count(workspace), "1")
    // A denial never reaches the command.
    group.spawn_bg(
      no_wait=true,
      allow_failure=true,
      async fn() {
        ignore(
          skh_answer_skill_decision(
            state,
            "agt_write_local",
            @contracts.DECISION_OPTION_DENY,
          ),
        )
      },
    )
    let denied = skh_call(
      state,
      @contracts.METHOD_SKILL_INVOKE,
      Map([
        ("client_request_id", @contracts.json_string(@contracts.new_id("cid", @async.now()))),
        ("token", @contracts.json_string(setup.token)),
        ("entry_id", @contracts.json_string("note")),
      ]),
    ) catch { _ => fail("denied invocation call failed") }
    assert_true(denied.contains(@contracts.SKILL_ERR_DECISION_DENIED))
    assert_eq(skh_git_commit_count(workspace), "1")
    // Both answers are persisted Decisions; only the approved one is recorded
    // as an executed invocation.
    let decisions = match state.store.list_decisions("", "agt_write_local") {
      Ok(value) => value
      Err(message) => fail("cannot list decisions: " + message)
    }
    let mut approvals = 0
    let mut denials = 0
    for decision in decisions {
      if decision.kind == @contracts.DECISION_KIND_SKILL {
        if decision.status == @contracts.DECISION_STATUS_ANSWERED {
          if decision.option_id == @contracts.DECISION_OPTION_APPROVE {
            approvals = approvals + 1
          } else if decision.option_id == @contracts.DECISION_OPTION_DENY {
            denials = denials + 1
          }
        }
      }
    }
    assert_eq(approvals, 1)
    assert_eq(denials, 1)
    assert_eq(skh_invocation_count(state, "agt_write_local", "note"), 1)
    // Tightening the agent ceiling refuses the next write before any Decision.
    let tightened = skh_call(
      state,
      @contracts.METHOD_SKILL_PERMISSIONS_SET,
      @contracts.skill_permissions_set_params(
        @contracts.new_id("cid", @async.now()),
        "agt_write",
        ["git.read"],
      ),
    ) catch { _ => fail("permissions set failed") }
    assert_true(tightened.contains("\"permissions\""))
    let limited = skh_call(
      state,
      @contracts.METHOD_SKILL_INVOKE,
      Map([
        ("client_request_id", @contracts.json_string(@contracts.new_id("cid", @async.now()))),
        ("token", @contracts.json_string(setup.token)),
        ("entry_id", @contracts.json_string("note")),
      ]),
    ) catch { _ => fail("limited invocation call failed") }
    assert_true(limited.contains(@contracts.SKILL_ERR_PERMISSION_DENIED))
    assert_eq(skh_git_commit_count(workspace), "1")
  })
  state.store.close()
  skh_cleanup(dir)
}

///|
async test "critical commands are denied before any Decision or execution" {
  let (state, dir) = skh_state("monexus-skill-host-critical", true) catch {
    _ => fail("cannot create the test state")
  }
  let workspace = dir + "/workspace"
  @fs.mkdir(workspace, permission=0o700, recursive=true) catch {
    _ => fail("cannot create the workspace")
  }
  let fixture = skh_fixture(
    "monexus-skill-host-critical-bundle",
    "critical-check",
    "1.0.0",
    "[\"exec.readonly\"]",
    "[{\"id\":\"danger\",\"argv\":[\"sudo\",\"ls\"],\"mode\":\"read_only\",\"timeout_ms\":1000,\"max_output_bytes\":1024}]",
    "",
  ) catch { _ => fail("cannot build the fixture") }
  defer @async.protect_from_cancel(async fn() { skh_cleanup(fixture.dir) })
  @async.with_task_group(async fn(group) {
    skh_publish(state, fixture, "agt_crit", @contracts.SKILL_MODE_LOADED) catch {
      _ => fail("cannot publish the agent binding")
    }
    let home = fixture.dir + "/home"
    let setup = skh_setup(
      state,
      "agt_crit",
      "agt_crit_local",
      home,
      workspace,
      [],
    ) catch { _ => fail("critical setup failed") }
    let runtime = skh_fake_runtime(
      group,
      "agt_crit_local",
      "agt_crit",
      home,
      setup.token,
    ) catch { _ => fail("cannot create the fake runtime") }
    state.mutex.acquire()
    state.agent_sessions.set("agt_crit_local", runtime)
    state.mutex.release()
    defer @async.protect_from_cancel(async fn() {
      state.mutex.acquire()
      state.agent_sessions.remove("agt_crit_local")
      state.mutex.release()
      runtime.process.interrupt()
      finalize_skill_session(state, setup.token, "agt_crit_local", home)
    })
    let denied = skh_call(
      state,
      @contracts.METHOD_SKILL_INVOKE,
      Map([
        ("client_request_id", @contracts.json_string(@contracts.new_id("cid", @async.now()))),
        ("token", @contracts.json_string(setup.token)),
        ("entry_id", @contracts.json_string("danger")),
      ]),
    ) catch { _ => fail("critical invocation call failed") }
    assert_true(denied.contains(@contracts.SKILL_ERR_POLICY_DENIED))
    assert_eq(skh_invocation_count(state, "agt_crit_local", "danger"), 0)
    let decisions = match state.store.list_decisions("", "agt_crit_local") {
      Ok(value) => value
      Err(message) => fail("cannot list decisions: " + message)
    }
    let mut skill_decisions = 0
    for decision in decisions {
      if decision.kind == @contracts.DECISION_KIND_SKILL {
        skill_decisions = skill_decisions + 1
      }
    }
    assert_eq(skill_decisions, 0)
    assert_true(skh_snapshot_has(
      state,
      @contracts.EVENT_SKILL_INVOKE_DENIED,
      @contracts.SKILL_ERR_POLICY_DENIED,
    ))
  })
  state.store.close()
  skh_cleanup(dir)
}

///|
fn skh_result_task_id(text : String) -> String {
  let json = @json.parse(text) catch { _ => return "" }
  let reply = match @contracts.as_object(json) {
    Some(value) => value
    None => return ""
  }
  let result = match reply.get("result") {
    Some(@json.Object(value)) => value
    _ => return ""
  }
  let task = match result.get("task") {
    Some(@json.Object(value)) => value
    _ => return ""
  }
  @contracts.string_field_or(task, "id", "")
}

///|
async test "task-declared skills load only sessions created for that task" {
  let (state, dir) = skh_state("monexus-skill-host-task", true) catch {
    _ => fail("cannot create the test state")
  }
  defer @async.protect_from_cancel(async fn() { skh_cleanup(dir) })
  let fixture = skh_fixture(
    "monexus-skill-host-task-bundle",
    "repo-health",
    "1.0.0",
    "[\"git.read\"]",
    skh_read_commands(),
    "",
  ) catch { _ => fail("cannot build the fixture") }
  defer @async.protect_from_cancel(async fn() { skh_cleanup(fixture.dir) })
  skh_publish(state, fixture, "agt_task", @contracts.SKILL_MODE_AVAILABLE) catch {
    _ => fail("cannot publish the agent binding")
  }
  // The owner declares an exact task binding. The Task event carries it.
  let binding = skh_binding(
    fixture.name,
    fixture.version,
    fixture.content_hash,
    @contracts.SKILL_MODE_LOADED,
  )
  let created = skh_call(
    state,
    @contracts.METHOD_TASK_CREATE,
    Map([
      ("client_request_id", @contracts.json_string(@contracts.new_id("cid", @async.now()))),
      ("title", @contracts.json_string("task with skills")),
      ("skills", @contracts.json_array([binding.to_json()])),
    ]),
  ) catch { _ => fail("task.create failed") }
  let task_id = skh_result_task_id(created)
  if task_id == "" {
    fail("task.create did not return an id: " + created)
  }
  assert_true(created.contains("\"skills\""))
  let read_back = skh_call(
    state,
    @contracts.METHOD_TASK_GET,
    Map([
      ("client_request_id", @contracts.json_string(@contracts.new_id("cid", @async.now()))),
      ("task_id", @contracts.json_string(task_id)),
    ]),
  ) catch { _ => fail("task.get failed") }
  // A session created for the Task loads the entry even though the Agent
  // binding is only `available`.
  let task_home = fixture.dir + "/task-home"
  let task_setup = skh_setup(
    state,
    "agt_task",
    "agt_task_session",
    task_home,
    fixture.dir,
    [],
    task_id = task_id,
  ) catch { _ => fail("task session setup failed") }
  assert_eq(task_setup.loaded, 1)
  assert_true(task_setup.token != "")
  assert_true(task_setup.injection.block.contains("repo-health@1.0.0"))
  // A session without the task_id does not see the Task binding.
  let other_setup = skh_setup(
    state,
    "agt_task",
    "agt_task_other",
    fixture.dir + "/other-home",
    fixture.dir,
    [],
  ) catch { _ => fail("non-task session setup failed") }
  assert_eq(other_setup.loaded, 0)
  assert_eq(other_setup.token, "")
  // A malformed Task binding is refused at creation, not silently dropped.
  let malformed = skh_call(
    state,
    @contracts.METHOD_TASK_CREATE,
    Map([
      ("client_request_id", @contracts.json_string(@contracts.new_id("cid", @async.now()))),
      ("title", @contracts.json_string("bad task")),
      ("skills", @contracts.json_string("not-an-array")),
    ]),
  ) catch { _ => fail("malformed task.create call failed") }
  assert_true(malformed.contains("skills must be"))
  finalize_skill_session(state, task_setup.token, "agt_task_session", task_home)
  finalize_skill_session(state, other_setup.token, "agt_task_other", fixture.dir + "/other-home")
  state.store.close()
}