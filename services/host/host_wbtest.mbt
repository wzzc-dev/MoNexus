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
  HostState::new(options, 0, store)
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
  if code != 0 {
    return ""
  }
  out.text().trim().to_owned()
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
