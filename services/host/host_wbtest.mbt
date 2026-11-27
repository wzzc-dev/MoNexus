///|
/// A3.1 host tests (whitebox): the flag-off contract, the `/hooks` vs `/ws`
/// path split, and the webhook secret file permissions. HTTP tests use a real
/// loopback server on port 0 and the async HTTP client.

///|
const HOST_TEST_TRIGGER_ID : String = "trg_01HZZZZZZZZZZZZZZZZZZZZZZZ"

///|
fn host_test_webhook_record() -> @contracts.TriggerRecord {
  let source = @contracts.TriggerSource::new(payload_fields=["title"])
  let target = @contracts.TriggerTarget::new(
    title_template="Webhook {{title}}",
    goal_template="webhook run",
  )
  @contracts.TriggerRecord::new(
    id=HOST_TEST_TRIGGER_ID,
    org_id=@contracts.ORG_LOCAL,
    name="host-webhook",
    kind=@contracts.TRIGGER_TYPE_WEBHOOK,
    target~,
    source~,
    config_hash="host-hash",
    created_by="owner",
    created_at="2026-01-01T00:00:00.000Z",
    active_from_seq=0L,
  )
}

///|
async fn host_test_state(
  state_dir : String,
  trigger_enabled : Bool,
) -> HostState raise {
  @fs.mkdir(state_dir, permission=0o700, recursive=true, allow_exist=true) catch {
    error => fail("cannot create state dir: " + error.to_string())
  }
  let store = match @machines.MachineStore::open(":memory:") {
    Ok(value) => value
    Err(message) => fail("cannot open store: " + message)
  }
  let options = HostOptions::new(
    state_dir=state_dir,
    trigger_enabled=trigger_enabled,
  )
  let verifier : @recipes.VerifierProbe = {
    tool: "",
    found: false,
    version: "",
    supports_signatures: false,
    usable: false,
    detail: "not probed in unit test",
  }
  HostState::new(options, 0, store, @recipes.TrustStore::empty(), verifier)
}

///|
fn host_test_create_webhook_trigger(state : HostState) -> Unit raise {
  let record = host_test_webhook_record()
  let event = @contracts.EventEnvelope::new(
    id="evt_1",
    org_id=@contracts.ORG_LOCAL,
    event_type=@contracts.EVENT_TRIGGER_CREATED,
    ts="2026-01-01T00:00:00.000Z",
    subject="trigger/" + record.id,
    seq=1L,
    payload=@contracts.trigger_created_payload(record),
    idempotency_key="trigger/" + record.id + "/created",
  )
  match state.store.record_trigger_event(event, record) {
    Ok(_) => ()
    Err(message) => fail("cannot create trigger: " + message)
  }
}

///|
async fn host_test_mode(path : String) -> String {
  let (code, out, _) = @process.collect_output("stat", ["-c", "%a", path]) catch {
    _ => return ""
  }
  if code == 0 {
    return out.text().trim().to_owned()
  }
  // BSD/macOS stat spelling; GNU stat exits non-zero above.
  let (fallback_code, fallback_out, _) = @process.collect_output("stat", [
    "-f", "%Lp", path,
  ]) catch {
    _ => return ""
  }
  if fallback_code != 0 {
    return ""
  }
  fallback_out.text().trim().to_owned()
}

///|
fn host_test_sink() -> Sink {
  let queue : @aqueue.Queue[String] = @aqueue.Queue(kind=Unbounded)
  { queue, subscribed: Ref(false), closed: Ref(false) }
}

///|
fn host_test_response_body(body : &@io.Data) -> String {
  body.text() catch { _ => "" }
}

///|
async test "flag-off trigger RPC answers unsupported and creates nothing" {
  let state = host_test_state("/tmp/monexus-host-flag-off-test", false) catch {
    error => fail(error.to_string())
  }
  let sink = host_test_sink()
  let request = @contracts.RpcRequest::new(
    "req_1",
    @contracts.METHOD_TRIGGER_CREATE,
    Map([]),
  )
  handle_trigger_rpc(state, sink, request, "cid_1")
  let text = sink.queue.get() catch { _ => fail("no RPC response") }
  assert_true(text.contains("\"unsupported\""))
  let triggers = match state.store.list_triggers() {
    Ok(value) => value
    Err(message) => fail(message)
  }
  assert_eq(triggers.length(), 0)
}

///|
async test "terminal.resize validates dimensions and queues a provider resize" {
  let state = host_test_state("/tmp/monexus-host-terminal-resize-test", false)
    catch {
      error => fail(error.to_string())
    }
  @async.with_task_group(async fn(group) {
    let input : @aqueue.Queue[@workspace.TerminalInput] = @aqueue.Queue(
      kind=Unbounded,
    )
    let output : @aqueue.Queue[@workspace.TerminalEvent] = @aqueue.Queue(
      kind=Unbounded,
    )
    let task = group.spawn(fn() { () })
    let session : TerminalSession = {
      id: "term_resize",
      workspace_id: "wsp_resize",
      input,
      output,
      transcript: Ref(""),
      cursor: Ref(0),
      eof: Ref(false),
      task,
    }
    state.mutex.acquire()
    state.terminals.set(session.id, session)
    state.mutex.release()

    let sink = host_test_sink()
    let valid = @contracts.RpcRequest::new(
      "req_resize",
      @contracts.METHOD_TERMINAL_RESIZE,
      @contracts.terminal_resize_params("cid_resize", "term_resize", 40, 120),
    )
    handle_terminal_resize(state, sink, valid, "cid_resize")
    let response = sink.queue.get() catch { _ => fail("no resize response") }
    assert_true(response.contains("\"rows\":40"))
    assert_true(response.contains("\"cols\":120"))
    match input.get() {
      @workspace.TerminalInput::Resize(rows, cols) => {
        assert_eq(rows, 40)
        assert_eq(cols, 120)
      }
      _ => fail("expected TerminalInput::Resize")
    }

    let invalid_sink = host_test_sink()
    let invalid = @contracts.RpcRequest::new(
      "req_resize_bad",
      @contracts.METHOD_TERMINAL_RESIZE,
      @contracts.terminal_resize_params("cid_resize_bad", "term_resize", 0, 120),
    )
    handle_terminal_resize(state, invalid_sink, invalid, "cid_resize_bad")
    let invalid_response = invalid_sink.queue.get() catch {
      _ => fail("no invalid resize response")
    }
    assert_true(invalid_response.contains("\"invalid\""))

    let missing_sink = host_test_sink()
    let missing = @contracts.RpcRequest::new(
      "req_resize_missing",
      @contracts.METHOD_TERMINAL_RESIZE,
      @contracts.terminal_resize_params("cid_missing", "term_missing", 24, 80),
    )
    handle_terminal_resize(state, missing_sink, missing, "cid_missing")
    let missing_response = missing_sink.queue.get() catch {
      _ => fail("no missing-session response")
    }
    assert_true(missing_response.contains("\"not_found\""))
  })
}

///|
async test "webhook secret file is 0600 inside a 0700 directory and returned once" {
  let dir = "/tmp/monexus-host-secret-test"
  let state = host_test_state(dir, true) catch {
    error => fail(error.to_string())
  }
  host_test_create_webhook_trigger(state) catch {
    error => fail(error.to_string())
  }
  let params = Map([
    ("trigger_id", @contracts.json_string(HOST_TEST_TRIGGER_ID)),
    ("name", @contracts.json_string("ci")),
  ])
  let first = match trigger_webhook_key_add(state, params) {
    Ok(value) => value
    Err(error) => fail("key add failed: " + error.message)
  }
  let object = match @contracts.as_object(first) {
    Some(value) => value
    None => fail("key add response is not an object")
  }
  let key_id = match object.get("key_id") {
    Some(@json.Json::String(value)) => value
    _ => fail("key add response has no key_id")
  }
  let secret = match object.get("secret") {
    Some(@json.Json::String(value)) => value
    _ => fail("key add response has no secret")
  }
  assert_eq(secret.length(), 64)
  assert_true(@contracts.webhook_is_hex(secret, 64))
  let path = dir + "/" + @contracts.webhook_secret_relative_path(key_id)
  let secret_data = @fs.read_file(path) catch {
    error => fail("cannot read secret file: " + error.to_string())
  }
  let on_disk = secret_data.text() catch {
    _ => fail("secret file is not UTF-8")
  }
  assert_eq(on_disk, secret)
  let dir_mode = host_test_mode(dir + "/secrets/webhook")
  assert_eq(dir_mode, "700")
  let file_mode = host_test_mode(path)
  assert_eq(file_mode, "600")
  // The database stores only the relative path, and the secret never reaches
  // the trigger record or the event log.
  let stored = match state.store.get_webhook_key(key_id) {
    Ok(Some(value)) => value
    Err(message) => fail(message)
    Ok(None) => fail("key was not stored")
  }
  assert_eq(
    stored.secret_path,
    @contracts.webhook_secret_relative_path(key_id),
  )
  assert_true(!stored.secret_path.contains(secret))
  let events = match state.store.load_events_since(0L, 100) {
    Ok(value) => value
    Err(message) => fail(message)
  }
  for event in events {
    assert_true(!event.payload.stringify().contains(secret))
    assert_true(!event.idempotency_key.contains(secret))
  }
  // A second add returns a fresh secret; the first is never re-issued.
  let second = match trigger_webhook_key_add(state, params) {
    Ok(value) => value
    Err(error) => fail("second key add failed: " + error.message)
  }
  let second_object = match @contracts.as_object(second) {
    Some(value) => value
    None => fail("second key add response is not an object")
  }
  let second_secret = match second_object.get("secret") {
    Some(@json.Json::String(value)) => value
    _ => fail("second key add response has no secret")
  }
  assert_true(second_secret != secret)
  // Revocation is immediate and removes the secret file best-effort.
  let revoke_params = Map([
    ("key_id", @contracts.json_string(key_id)),
  ])
  match trigger_webhook_key_revoke(state, revoke_params) {
    Ok(_) => ()
    Err(error) => fail("revoke failed: " + error.message)
  }
  let revoked = match state.store.get_webhook_key(key_id) {
    Ok(Some(value)) => value
    Err(message) => fail(message)
    Ok(None) => fail("key disappeared")
  }
  assert_true(revoked.revoked_at != "")
  let still_there = @fs.exists(path)
  assert_true(!still_there)
  match trigger_webhook_key_revoke(state, revoke_params) {
    Ok(_) => ()
    Err(error) => fail("idempotent revoke failed: " + error.message)
  }
}

///|
async test "flag-off HTTP split: /hooks is 401, /ws needs bearer, others 404" {
  let state = host_test_state("/tmp/monexus-host-http-test", false) catch {
    error => fail(error.to_string())
  }
  let addr = @socket.Addr::parse("127.0.0.1:0") catch {
    error => fail("cannot parse address: " + error.to_string())
  }
  let server = @http.Server::Server(addr, reuse_addr=false)
  let port = server.addr.port()
  @async.with_task_group(async fn(group) {
    group.spawn_bg(
      no_wait=true,
      allow_failure=true,
      async fn() {
        server.run_forever(allow_failure=true, max_connections=8) <|
        ((request, _body, conn) => {
          handle_connection(state, request, conn)
        })
      },
    )
    @async.sleep(100)
    let base = "http://127.0.0.1:" + port.to_string()
    let hook_headers : Map[@http.CaseInsensitiveString, String] = Map([
      (@http.CaseInsensitiveString("Content-Type"), "application/json"),
    ])
    let (hook_response, hook_body) = @http.post(
      base + "/hooks/" + HOST_TEST_TRIGGER_ID,
      "{\"title\":\"x\"}",
      headers=hook_headers,
    )
    assert_eq(hook_response.code, 401)
    let hook_text = host_test_response_body(hook_body)
    assert_eq(hook_text, "{\"accepted\":false,\"error\":\"unauthorized\"}")
    // The owner's WS bearer token is not accepted on the hooks path; the
    // split happens before the `/ws` bearer check.
    let owner_headers : Map[@http.CaseInsensitiveString, String] = Map([
      (@http.CaseInsensitiveString("Content-Type"), "application/json"),
      (
        @http.CaseInsensitiveString("Authorization"),
        "Bearer " + state.token,
      ),
    ])
    let (owner_response, owner_body) = @http.post(
      base + "/hooks/" + HOST_TEST_TRIGGER_ID,
      "{\"title\":\"x\"}",
      headers=owner_headers,
    )
    assert_eq(owner_response.code, 401)
    ignore(host_test_response_body(owner_body))
    // `/ws` without a bearer token is rejected by the existing check.
    let (ws_response, ws_body) = @http.get(base + "/ws")
    assert_eq(ws_response.code, 401)
    ignore(host_test_response_body(ws_body))
    let (other_response, other_body) = @http.get(base + "/unknown")
    assert_eq(other_response.code, 404)
    ignore(host_test_response_body(other_body))
    server.close()
  })
}

// ---------------------------------------------------------------------------
// A3.2 start_run catch-up regression tests.
// ---------------------------------------------------------------------------

///|
const HOST_TEST_RUN_WS : String = "ws_01HZZZZZZZZZZZZZZZZZZZZZZY"

///|
const HOST_TEST_RUN_TRIGGER : String = "trg_01HZZZZZZZZZZZZZZZZZZZZZZY"

///|
fn host_test_run_trigger(
  id : String,
  start_run : Bool,
) -> @contracts.TriggerRecord {
  let target = @contracts.TriggerTarget::new(
    title_template="Batch {{event_id}}",
    goal_template="run for {{event_id}}",
    agent_id="mock",
    workspace_id=HOST_TEST_RUN_WS,
    start_run~,
  )
  let source = @contracts.TriggerSource::new(event_type="task.created")
  @contracts.TriggerRecord::new(
    id~,
    org_id=@contracts.ORG_LOCAL,
    name="host-run-" + id,
    kind=@contracts.TRIGGER_TYPE_EVENT,
    target~,
    source~,
    config_hash="hash-" + id,
    created_by="owner",
    created_at="2026-01-01T00:00:00.000Z",
    active_from_seq=0L,
  )
}

///|
fn host_test_put_run_workspace(state : HostState) -> Unit raise {
  let workspace : @contracts.WorkspaceRecord = {
    id: HOST_TEST_RUN_WS,
    machine_id: "",
    kind: @contracts.WORKSPACE_KIND_LOCAL,
    root: "/tmp/monexus-host-run-workspace",
    name: "run-workspace",
    git_root: "",
    is_git: false,
    state: @contracts.WORKSPACE_STATE_AVAILABLE,
    created_at: "2026-01-01T00:00:00.000Z",
    updated_at: "2026-01-01T00:00:00.000Z",
  }
  match state.store.put_workspace(workspace) {
    Ok(_) => ()
    Err(message) => fail("cannot put workspace: " + message)
  }
}

///|
fn host_test_install_run_trigger(
  state : HostState,
  record : @contracts.TriggerRecord,
) -> Unit raise {
  let event = @contracts.EventEnvelope::new(
    id="evt_" + record.id + "_created",
    org_id=@contracts.ORG_LOCAL,
    event_type=@contracts.EVENT_TRIGGER_CREATED,
    ts="2026-01-01T00:00:00.000Z",
    subject="trigger/" + record.id,
    seq=1L,
    payload=@contracts.trigger_created_payload(record),
    idempotency_key="trigger/" + record.id + "/created",
  )
  match state.store.record_trigger_event(event, record) {
    Ok(_) => ()
    Err(message) => fail("cannot install trigger: " + message)
  }
  state.next_seq = 100L
}

///|
fn host_test_seed_event(index : Int) -> @contracts.EventEnvelope {
  let n = index.to_string()
  @contracts.EventEnvelope::new(
    id="evt_batch_" + n,
    org_id=@contracts.ORG_LOCAL,
    event_type=@contracts.EVENT_TASK_CREATED,
    ts="2026-01-01T00:00:01.000Z",
    subject="task/seeded_" + n,
    seq=10L + index.to_int64(),
    payload=@contracts.json_object([
      ("seed", @contracts.json_string(n)),
    ]),
    idempotency_key="seed/" + n,
  )
}

///|
async test "start_run catch-up drains seven fires from one event batch" {
  let state = host_test_state("/tmp/monexus-host-run-batch-test", true) catch {
    error => fail(error.to_string())
  }
  host_test_put_run_workspace(state) catch {
    error => fail(error.to_string())
  }
  let record = host_test_run_trigger(HOST_TEST_RUN_TRIGGER, true)
  host_test_install_run_trigger(state, record) catch {
    error => fail(error.to_string())
  }
  // One dispatcher batch creates seven ready Tasks and seven fire-ledger rows.
  for i in 0..<7 {
    let created = match trigger_process_event(state, host_test_seed_event(i), 1_700_000_000_000L) {
      Ok(value) => value
      Err(message) => fail("cannot process event: " + message)
    }
    assert_true(created)
  }
  let pending = match state.store.get_trigger_fires_missing_run(record.id, 100) {
    Ok(value) => value
    Err(message) => fail("cannot read pending fires: " + message)
  }
  assert_eq(pending.length(), 7)
  trigger_start_pending_runs_for_trigger(state, record.id)
  let fires = match state.store.get_trigger_fires(record.id, 100) {
    Ok(value) => value
    Err(message) => fail("cannot read fire ledger: " + message)
  }
  assert_eq(fires.length(), 7)
  for fire in fires {
    assert_true(fire.run_id != "")
    match state.store.find_run_by_idempotency(
      @contracts.trigger_run_idempotency(record.id, fire.fire_key),
    ) {
      Ok(Some(run)) => assert_eq(run.id, fire.run_id)
      Ok(None) => fail("fire has no idempotent Run: " + fire.fire_key)
      Err(message) => fail("cannot look up Run: " + message)
    }
  }
  let runs = match state.store.list_runs("", "") {
    Ok(value) => value
    Err(message) => fail("cannot list Runs: " + message)
  }
  assert_eq(runs.length(), 7)
}

///|
async test "enabling start_run does not backfill Runs for historical fires" {
  let state = host_test_state("/tmp/monexus-host-run-old-test", true) catch {
    error => fail(error.to_string())
  }
  host_test_put_run_workspace(state) catch {
    error => fail(error.to_string())
  }
  let record = host_test_run_trigger(HOST_TEST_RUN_TRIGGER, false)
  host_test_install_run_trigger(state, record) catch {
    error => fail(error.to_string())
  }
  for i in 0..<3 {
    let created = match trigger_process_event(state, host_test_seed_event(i), 1_700_000_000_000L) {
      Ok(value) => value
      Err(message) => fail("cannot process event: " + message)
    }
    assert_true(created)
  }
  let fires_before = match state.store.get_trigger_fires(record.id, 100) {
    Ok(value) => value
    Err(message) => fail("cannot read fire ledger: " + message)
  }
  assert_eq(fires_before.length(), 3)
  for fire in fires_before {
    assert_true(!fire.run_intent)
    assert_eq(fire.run_id, "")
  }
  // Flip start_run on through the same optimistic update path the owner uses.
  let current = match state.store.get_trigger(record.id) {
    Ok(Some(value)) => value
    Ok(None) => fail("trigger disappeared")
    Err(message) => fail("cannot read trigger: " + message)
  }
  let updated = {
    ..current,
    target: { ..current.target, start_run: true },
    version: current.version + 1,
    updated_at: "2026-01-01T00:00:02.000Z",
  }
  let update_event = @contracts.EventEnvelope::new(
    id="evt_" + record.id + "_updated",
    org_id=@contracts.ORG_LOCAL,
    event_type=@contracts.EVENT_TRIGGER_UPDATED,
    ts=updated.updated_at,
    subject="trigger/" + record.id,
    seq=200L,
    payload=@contracts.trigger_updated_payload(updated, ["target"], "owner"),
    idempotency_key="trigger/" + record.id + "/updated/2",
  )
  match state.store.record_trigger_update_event(update_event, updated, current.version) {
    Ok(@contracts.TriggerApplied) => ()
    Ok(_) => fail("trigger update was not applied")
    Err(message) => fail("trigger update failed: " + message)
  }
  trigger_start_pending_runs_for_trigger(state, record.id)
  let runs = match state.store.list_runs("", "") {
    Ok(value) => value
    Err(message) => fail("cannot list Runs: " + message)
  }
  assert_eq(runs.length(), 0)
  let fires_after = match state.store.get_trigger_fires(record.id, 100) {
    Ok(value) => value
    Err(message) => fail("cannot re-read fire ledger: " + message)
  }
  for fire in fires_after {
    assert_eq(fire.run_id, "")
  }
  // A direct start attempt for an old fire is a no-op too.
  let old_fire = fires_after[0]
  match trigger_start_run_for_fire(state, record.id, old_fire.fire_key) {
    Ok(value) => assert_eq(value, "")
    Err(message) => fail("old fire tried to start a Run: " + message)
  }
  let runs_after_direct = match state.store.list_runs("", "") {
    Ok(value) => value
    Err(message) => fail("cannot list Runs after direct attempt: " + message)
  }
  assert_eq(runs_after_direct.length(), 0)
}

// ---------------------------------------------------------------------------
// A1.4 runtime agent launcher registration.
// ---------------------------------------------------------------------------

///|
fn host_test_runtime_machine(id : String) -> @contracts.MachineRecord {
  {
    id,
    kind: @contracts.MACHINE_KIND_RUNTIME,
    name: "runtime-" + id,
    host: id,
    port: 0,
    user: "",
    identity: "",
    use_ssh_config: false,
    host_key_policy: @contracts.MACHINE_HOST_KEY_POLICY_ACCEPT_NEW,
    known_hosts_file: "",
    status: "online",
    profile: None,
    ssh_effective: Map([]),
    ssh_effective_error: "",
    last_seen: "2026-01-01T00:00:00.000Z",
    last_error: "",
    created_at: "2026-01-01T00:00:00.000Z",
    updated_at: "2026-01-01T00:00:00.000Z",
  }
}

///|
async test "runtime machine requires a registered paired launcher, never SSH" {
  let state = host_test_state("/tmp/monexus-host-runtime-agent-test", false) catch {
    error => fail(error.to_string())
  }
  let machine_id = "mch_runtime_agent_test"
  match state.store.put_machine(host_test_runtime_machine(machine_id)) {
    Ok(_) => ()
    Err(message) => fail("cannot put machine: " + message)
  }
  // No launcher yet: honest unsupported, not a local or SSH fallback.
  match agent_launcher_for_machine(state, machine_id) {
    Ok(_) => fail("runtime machine must not resolve without a paired channel")
    Err(error) =>
      assert_true(error.message.contains("paired transport"))
  }
  let launcher = @agent.RemoteLauncher::new(start=async fn(_spec) {
    Err("unused in registry test")
  })
  state.register_runtime_agent_launcher(machine_id, launcher)
  match agent_launcher_for_machine(state, machine_id) {
    Ok(@agent.ProcessLauncher::Runtime(_)) => ()
    Ok(_) => fail("runtime machine resolved to the wrong launcher kind")
    Err(error) => fail("registered launcher was not used: " + error.message)
  }
  // A missing machine is still a clear not-found error.
  match agent_launcher_for_machine(state, "mch_missing") {
    Ok(_) => fail("missing machine resolved")
    Err(error) => assert_true(error.message.contains("machine not found"))
  }
}

///|
test "runtime approval decisions are not ACP deliveries" {
  let base = @contracts.DecisionRecord::new(
    id="dec_runtime_test",
    kind=@contracts.DECISION_KIND_PERMISSION,
    title="Runtime approval needed: runtime.process.start",
    detail="",
    session_id="",
    agent_id="",
    options=[],
    created_at="2026-01-01T00:00:00.000Z",
  )
  let runtime = {
    ..base,
    action: "runtime.process.start",
    machine_id: "mch_runtime_test",
  }
  assert_true(is_runtime_approval_decision(runtime))
  let agent = { ..base, action: "fs.write", machine_id: "" }
  assert_false(is_runtime_approval_decision(agent))
}
