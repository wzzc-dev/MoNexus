///|
/// A5 host-side credential tests (whitebox): flag-off regression, enroll /
/// bind / reuse / machine rules, secret-free events, local proxy swap,
/// rotation and revocation, node-local mirror + lease, readiness dedup, and
/// restart fail-closed.

///|
const CREDENTIAL_TEST_AGENT : String = "agent-credential-test"

///|
async fn credential_test_cleanup(root : String) -> Unit {
  @fs.rmdir(root, recursive=true) catch {
    _ => ()
  }
}

///|
fn credential_test_memory_store() -> @machines.MachineStore {
  match @machines.MachineStore::open(":memory:") {
    Ok(value) => value
    Err(message) => abort("cannot open the credential test store: " + message)
  }
}

///|
async fn credential_test_make_state(
  state_dir : String,
  store : @machines.MachineStore,
  enabled : Bool,
  ttl_ms : Int64,
  cooldown_ms : Int64,
) -> HostState {
  @fs.mkdir(state_dir, permission=0o700, recursive=true, allow_exist=true) catch {
    error => fail("cannot create credential state dir: " + error.to_string())
  }
  let options = HostOptions::new(
    state_dir~,
    credential_enabled=enabled,
    credential_storage="file",
    credential_lease_ttl_ms=ttl_ms,
    credential_cooldown_ms=cooldown_ms,
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
async fn credential_test_state(state_dir : String, enabled : Bool) -> HostState {
  credential_test_make_state(
    state_dir,
    credential_test_memory_store(),
    enabled,
    @contracts.CREDENTIAL_DEFAULT_LEASE_TTL_MS,
    @contracts.CREDENTIAL_DEFAULT_COOLDOWN_MS,
  )
}

///|
async fn credential_test_prepare(
  state : HostState,
  machine_id : String,
  agent_id : String,
  profile : String,
) -> Result[PreparedAgentCredential?, @credentials.CredentialFailure] {
  let outcome : Ref[
    Result[PreparedAgentCredential?, @credentials.CredentialFailure]?,
  ] = Ref(None)
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    outcome.val = Some(
      prepare_agent_credential(state, group, machine_id, agent_id, profile),
    )
  })
  match outcome.val {
    Some(value) => value
    None => fail("credential preparation did not run")
  }
}

///|
async fn credential_test_rpc(
  state : HostState,
  method : String,
  params : Map[String, @json.Json],
  client_request_id : String,
) -> String {
  let sink = host_test_sink()
  let request = @contracts.RpcRequest::new(
    "req_" + client_request_id,
    method,
    params,
  )
  handle_credential_rpc(state, sink, request, client_request_id)
  sink.queue.get() catch {
    _ => fail("no credential RPC response")
  }
}

///|
fn credential_test_result(text : String) -> Map[String, @json.Json] raise {
  let parsed = @json.parse(text) catch {
    _ => fail("credential RPC response is not JSON: " + text)
  }
  let response = match @contracts.as_object(parsed) {
    Some(value) => value
    None => fail("credential RPC response is not an object: " + text)
  }
  let result = match response.get("result") {
    Some(value) => value
    None => fail("credential RPC response has no result: " + text)
  }
  match @contracts.as_object(result) {
    Some(value) => value
    None => fail("credential RPC result is not an object: " + text)
  }
}

///|
fn credential_test_nested(
  object : Map[String, @json.Json],
  key : String,
) -> Map[String, @json.Json] raise {
  let value = match object.get(key) {
    Some(value) => value
    None => fail("credential response has no " + key)
  }
  match @contracts.as_object(value) {
    Some(value) => value
    None => fail("credential field " + key + " is not an object")
  }
}

///|
fn credential_test_credential_id(text : String) -> String raise {
  let result = credential_test_result(text)
  let credential = credential_test_nested(result, "credential")
  let id = @contracts.string_field_or(credential, "id", "")
  if id == "" {
    fail("credential response has no credential id: " + text)
  }
  id
}

///|
fn credential_test_binding_id(text : String) -> String raise {
  let result = credential_test_result(text)
  let binding = credential_test_nested(result, "binding")
  let id = @contracts.string_field_or(binding, "id", "")
  if id == "" {
    fail("binding response has no binding id: " + text)
  }
  id
}

///|
fn credential_test_enroll_params(
  secret : String,
  machine_id : String,
) -> Map[String, @json.Json] {
  let params : Map[String, @json.Json] = Map([])
  params.set("secret", @contracts.json_string(secret))
  if machine_id != "" {
    params.set("machine_id", @contracts.json_string(machine_id))
  }
  params
}

///|
fn credential_test_bind_params(
  credential_id : String,
  machine_id : String,
  agent_id : String,
  profile : String,
) -> Map[String, @json.Json] {
  let params : Map[String, @json.Json] = Map([])
  params.set("credential_id", @contracts.json_string(credential_id))
  params.set("machine_id", @contracts.json_string(machine_id))
  params.set("agent_id", @contracts.json_string(agent_id))
  params.set("profile", @contracts.json_string(profile))
  params
}

///|
fn credential_test_machine_record(
  id : String,
  kind : String,
) -> @contracts.MachineRecord {
  {
    id,
    kind,
    name: "credential-" + id,
    host: "127.0.0.1",
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
fn credential_test_put_machine(
  state : HostState,
  id : String,
  kind : String,
) -> Unit raise {
  match state.store.put_machine(credential_test_machine_record(id, kind)) {
    Ok(_) => ()
    Err(message) => fail("cannot put credential machine: " + message)
  }
}

///|
fn credential_test_events(
  state : HostState,
) -> Array[@contracts.EventEnvelope] raise {
  match state.store.load_recent_events(1000) {
    Ok(value) => value
    Err(message) => fail("cannot load credential events: " + message)
  }
}

///|
fn credential_test_event_text(state : HostState) -> String raise {
  let text : Ref[String] = Ref("")
  for event in credential_test_events(state) {
    text.val = text.val +
      event.event_type +
      " " +
      event.subject +
      " " +
      event.payload.stringify() +
      "\n"
  }
  text.val
}

///|
fn credential_test_count_events(
  state : HostState,
  event_type : String,
) -> Int32 raise {
  let mut count = 0
  for event in credential_test_events(state) {
    if event.event_type == event_type {
      count = count + 1
    }
  }
  count
}

///|
async test "flag-off credential RPC is unsupported and changes nothing" {
  let root = @fs.tmpdir(prefix="monexus-host-cred-off") catch {
    _ => fail("cannot create the flag-off test root")
  }
  defer credential_test_cleanup(root)
  let state = credential_test_state(root + "/state", false)
  let text = credential_test_rpc(
    state,
    @contracts.METHOD_CREDENTIAL_ENROLL,
    credential_test_enroll_params("sk-flag-off-secret", ""),
    "flag-off-1",
  )
  assert_true(text.contains(@contracts.CREDENTIAL_REASON_DISABLED))
  assert_true(!(@fs.exists(root + "/state/credentials") catch { _ => false }))
  assert_eq(
    credential_test_count_events(state, @contracts.EVENT_CREDENTIAL_ENROLLED),
    0,
  )
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    match
      prepare_agent_credential(state, group, "", CREDENTIAL_TEST_AGENT, "") {
      Ok(None) => ()
      Ok(Some(_)) => fail("flag-off must not prepare a credential")
      Err(error) => fail("flag-off prepare failed: " + error.message())
    }
  })
  let credentials = match state.store.list_credentials() {
    Ok(value) => value
    Err(message) => fail(message)
  }
  assert_eq(credentials.length(), 0)
}

///|
async test "enroll, bind, uniqueness and machine custody rules" {
  let root = @fs.tmpdir(prefix="monexus-host-cred-rules") catch {
    _ => fail("cannot create the credential rules root")
  }
  defer credential_test_cleanup(root)
  let state = credential_test_state(root + "/state", true)
  credential_test_put_machine(
    state,
    "mch_local_cred",
    @contracts.MACHINE_KIND_LOCAL,
  ) catch {
    error => fail(error.to_string())
  }
  credential_test_put_machine(
    state,
    "mch_runtime_cred",
    @contracts.MACHINE_KIND_RUNTIME,
  ) catch {
    error => fail(error.to_string())
  }
  credential_test_put_machine(
    state,
    "mch_ssh_cred",
    @contracts.MACHINE_KIND_SSH,
  ) catch {
    error => fail(error.to_string())
  }
  let secret = "sk-host-secret-rules-123"
  let enroll_text = credential_test_rpc(
    state,
    @contracts.METHOD_CREDENTIAL_ENROLL,
    credential_test_enroll_params(secret, "mch_local_cred"),
    "rules-enroll-1",
  )
  let credential_id = credential_test_credential_id(enroll_text)
  // Durable idempotency: the retry returns the same record and adds no
  // second enrollment.
  let retry_text = credential_test_rpc(
    state,
    @contracts.METHOD_CREDENTIAL_ENROLL,
    credential_test_enroll_params(secret, "mch_local_cred"),
    "rules-enroll-1",
  )
  assert_eq(credential_test_credential_id(retry_text), credential_id)
  let credentials = match state.store.list_credentials() {
    Ok(value) => value
    Err(message) => fail(message)
  }
  assert_eq(credentials.length(), 1)
  // A remote machine may never receive a primary-held secret.
  let remote_enroll = credential_test_rpc(
    state,
    @contracts.METHOD_CREDENTIAL_ENROLL,
    credential_test_enroll_params("sk-remote-enroll", "mch_runtime_cred"),
    "rules-enroll-remote",
  )
  assert_true(
    remote_enroll.contains(@contracts.CREDENTIAL_REASON_MACHINE_MISMATCH),
  )
  let ssh_enroll = credential_test_rpc(
    state,
    @contracts.METHOD_CREDENTIAL_ENROLL,
    credential_test_enroll_params("sk-ssh-enroll", "mch_ssh_cred"),
    "rules-enroll-ssh",
  )
  assert_true(
    ssh_enroll.contains(@contracts.CREDENTIAL_REASON_MACHINE_MISMATCH),
  )
  // A binding request never accepts a secret.
  let secret_binding_params = credential_test_bind_params(
    credential_id,
    "",
    CREDENTIAL_TEST_AGENT,
    "anthropic",
  )
  secret_binding_params.set(
    "secret",
    @contracts.json_string("sk-should-not-bind"),
  )
  let secret_binding = credential_test_rpc(
    state,
    @contracts.METHOD_CREDENTIAL_BINDING_CREATE,
    secret_binding_params,
    "rules-bind-secret",
  )
  assert_true(
    secret_binding.contains(@contracts.CREDENTIAL_REASON_SECRET_INVALID),
  )
  let bind_text = credential_test_rpc(
    state,
    @contracts.METHOD_CREDENTIAL_BINDING_CREATE,
    credential_test_bind_params(
      credential_id,
      "",
      CREDENTIAL_TEST_AGENT,
      "anthropic",
    ),
    "rules-bind-1",
  )
  let binding_id = credential_test_binding_id(bind_text)
  // The same tuple is one active binding, not two.
  let conflict = credential_test_rpc(
    state,
    @contracts.METHOD_CREDENTIAL_BINDING_CREATE,
    credential_test_bind_params(
      credential_id,
      "",
      CREDENTIAL_TEST_AGENT,
      "anthropic",
    ),
    "rules-bind-conflict",
  )
  assert_true(conflict.contains(@contracts.CREDENTIAL_REASON_BINDING_CONFLICT))
  // One credential has exactly one live binding: a second agent/profile is
  // refused instead of splitting the secret across two bindings.
  let reused = credential_test_rpc(
    state,
    @contracts.METHOD_CREDENTIAL_BINDING_CREATE,
    credential_test_bind_params(
      credential_id, "", "agent-credential-other", "anthropic",
    ),
    "rules-bind-reused",
  )
  assert_true(reused.contains(@contracts.CREDENTIAL_REASON_REUSED))
  // A fresh host-owned credential cannot be bound to a remote machine: the
  // primary must never become the custodian of a node's secret.
  let cross_enroll = credential_test_rpc(
    state,
    @contracts.METHOD_CREDENTIAL_ENROLL,
    credential_test_enroll_params("sk-cross-machine-secret", ""),
    "rules-enroll-cross",
  )
  let cross_credential_id = credential_test_credential_id(cross_enroll)
  let cross_machine = credential_test_rpc(
    state,
    @contracts.METHOD_CREDENTIAL_BINDING_CREATE,
    credential_test_bind_params(
      cross_credential_id,
      "mch_runtime_cred",
      CREDENTIAL_TEST_AGENT,
      "anthropic",
    ),
    "rules-bind-runtime",
  )
  assert_true(
    cross_machine.contains(@contracts.CREDENTIAL_REASON_MACHINE_MISMATCH),
  )
  // A fresh credential may not be bound to an SSH machine at all.
  let ssh_enroll_ok = credential_test_rpc(
    state,
    @contracts.METHOD_CREDENTIAL_ENROLL,
    credential_test_enroll_params("sk-ssh-bound-secret", ""),
    "rules-enroll-ssh-bound",
  )
  let ssh_credential_id = credential_test_credential_id(ssh_enroll_ok)
  let ssh_binding = credential_test_rpc(
    state,
    @contracts.METHOD_CREDENTIAL_BINDING_CREATE,
    credential_test_bind_params(
      ssh_credential_id,
      "mch_ssh_cred",
      CREDENTIAL_TEST_AGENT,
      "anthropic",
    ),
    "rules-bind-ssh",
  )
  assert_true(
    ssh_binding.contains(@contracts.CREDENTIAL_REASON_PROXY_UNSUPPORTED),
  )
  // Status and doctor are metadata only.
  let status_text = credential_test_rpc(
    state,
    @contracts.METHOD_CREDENTIAL_STATUS,
    Map([]),
    "rules-status",
  )
  assert_true(status_text.contains(@contracts.CREDENTIAL_STATE_ACTIVE))
  assert_true(!status_text.contains(secret))
  let doctor_text = credential_test_rpc(
    state,
    @contracts.METHOD_CREDENTIAL_DOCTOR,
    Map([]),
    "rules-doctor",
  )
  assert_true(!doctor_text.contains(secret))
  // Persisted audit surfaces never carry the secret.
  let event_text = credential_test_event_text(state)
  assert_true(!event_text.contains(secret))
  assert_true(event_text.contains(binding_id))
  let binding_list = match state.store.list_credential_bindings() {
    Ok(value) => value
    Err(message) => fail(message)
  }
  for binding in binding_list {
    assert_true(!binding.to_json().stringify().contains(secret))
  }
}

///|
async fn credential_test_upstream_handler(
  request : @http.Request,
  _body : &@io.Reader,
  conn : @http.ServerConnection,
  seen_auth : Ref[String],
  hits : Ref[Int32],
) -> Unit {
  hits.val = hits.val + 1
  seen_auth.val = match
    request.headers.get(@http.CaseInsensitiveString("authorization")) {
    Some(value) => value
    None => ""
  }
  let headers : @http.Headers = Map([])
  headers.set(@http.CaseInsensitiveString("content-type"), "application/json")
  conn.send_response(200, "OK", extra_headers=headers)
  conn.write_string("{\"ok\":true}")
  conn.end_response()
}

///|
fn credential_test_proxy_headers(token : String) -> @http.Headers {
  let headers : @http.Headers = Map([])
  headers.set(@http.CaseInsensitiveString("authorization"), "Bearer " + token)
  headers.set(@http.CaseInsensitiveString("content-type"), "application/json")
  headers
}

///|
async test "local proxy swaps the token, rotation and revocation fail closed" {
  let root = @fs.tmpdir(prefix="monexus-host-cred-local") catch {
    _ => fail("cannot create the local credential root")
  }
  defer credential_test_cleanup(root)
  let state = credential_test_state(root + "/state", true)
  let upstream_addr = @socket.Addr::parse("127.0.0.1:0") catch {
    _ => fail("cannot parse the upstream bind address")
  }
  let upstream = @http.Server::Server(upstream_addr, reuse_addr=false)
  let upstream_port = upstream.addr().port()
  let seen_auth : Ref[String] = Ref("")
  let hits : Ref[Int32] = Ref(0)
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    group.spawn_bg(no_wait=true, allow_failure=true, async fn() {
      upstream.run_forever(allow_failure=true, max_connections=8) <| ((
        request,
        body,
        conn,
      ) => {
        credential_test_upstream_handler(request, body, conn, seen_auth, hits)
      })
    })
    let profile = @contracts.CredentialProfile::new(
      name="local-test",
      upstream_scheme="http",
      upstream_host="127.0.0.1:" + upstream_port.to_string(),
      upstream_base_path="/v1",
      auth_header="authorization",
      auth_scheme="Bearer",
    )
    match state.store.put_credential_profile(profile) {
      Ok(_) => ()
      Err(message) => fail("cannot store the test profile: " + message)
    }
    let secret_one = "sk-local-secret-one"
    let secret_two = "sk-local-secret-two"
    let enroll_text = credential_test_rpc(
      state,
      @contracts.METHOD_CREDENTIAL_ENROLL,
      credential_test_enroll_params(secret_one, ""),
      "local-enroll",
    )
    let credential_id = credential_test_credential_id(enroll_text)
    let bind_text = credential_test_rpc(
      state,
      @contracts.METHOD_CREDENTIAL_BINDING_CREATE,
      credential_test_bind_params(
        credential_id,
        "",
        CREDENTIAL_TEST_AGENT,
        "local-test",
      ),
      "local-bind",
    )
    let binding_id = credential_test_binding_id(bind_text)
    let prepared_one = match
      prepare_agent_credential(
        state,
        group,
        "",
        CREDENTIAL_TEST_AGENT,
        "local-test",
      ) {
      Ok(Some(value)) => value
      Ok(None) => fail("the local binding was not prepared")
      Err(error) => fail("local prepare failed: " + error.message())
    }
    assert_true(!prepared_one.is_remote())
    let env_one = prepared_one.env()
    let token_one = match env_one.get(@contracts.CREDENTIAL_ENV_PROXY_TOKEN) {
      Some(value) => value
      None => fail("local prepare did not inject a proxy token")
    }
    let url_one = match env_one.get(@contracts.CREDENTIAL_ENV_PROXY_URL) {
      Some(value) => value
      None => fail("local prepare did not inject a proxy URL")
    }
    assert_true(token_one.has_prefix(@contracts.CREDENTIAL_TOKEN_PREFIX))
    let mut env_has_secret = false
    for _name, value in env_one {
      if value == secret_one {
        env_has_secret = true
      }
    }
    assert_true(!env_has_secret)
    let (response_one, body_one) = @http.post(
      url_one + "/v1/messages",
      "{}",
      headers=credential_test_proxy_headers(token_one),
    )
    assert_eq(response_one.code, 200)
    ignore(body_one.text() catch { _ => "" })
    assert_eq(seen_auth.val, "Bearer " + secret_one)
    assert_eq(hits.val, 1)
    // Rotation: the stored secret and binding version advance together.
    let rotate_params : Map[String, @json.Json] = Map([])
    rotate_params.set("credential_id", @contracts.json_string(credential_id))
    rotate_params.set("secret", @contracts.json_string(secret_two))
    let rotate_text = credential_test_rpc(
      state,
      @contracts.METHOD_CREDENTIAL_ROTATE,
      rotate_params,
      "local-rotate",
    )
    assert_true(rotate_text.contains("\"version\":2"))
    // The old proxy is denied immediately (version mismatch), without a new
    // upstream call.
    let (old_response, old_body) = @http.post(
      url_one + "/v1/messages",
      "{}",
      headers=credential_test_proxy_headers(token_one),
    )
    assert_eq(old_response.code, 401)
    ignore(old_body.text() catch { _ => "" })
    assert_eq(hits.val, 1)
    let prepared_two = match
      prepare_agent_credential(
        state,
        group,
        "",
        CREDENTIAL_TEST_AGENT,
        "local-test",
      ) {
      Ok(Some(value)) => value
      Ok(None) => fail("the rotated binding was not prepared")
      Err(error) =>
        fail("local prepare after rotate failed: " + error.message())
    }
    assert_eq(prepared_two.binding().id, binding_id)
    assert_eq(prepared_two.binding().version, 2)
    let env_two = prepared_two.env()
    let token_two = match env_two.get(@contracts.CREDENTIAL_ENV_PROXY_TOKEN) {
      Some(value) => value
      None => fail("rotated prepare did not inject a proxy token")
    }
    let url_two = match env_two.get(@contracts.CREDENTIAL_ENV_PROXY_URL) {
      Some(value) => value
      None => fail("rotated prepare did not inject a proxy URL")
    }
    let proxy_two = match prepared_two.proxy {
      Some(value) => value
      None => fail("rotated prepare did not start a proxy")
    }
    state.credential_proxies.set("session-credential-test", proxy_two)
    let (response_two, body_two) = @http.post(
      url_two + "/v1/messages",
      "{}",
      headers=credential_test_proxy_headers(token_two),
    )
    assert_eq(response_two.code, 200)
    ignore(body_two.text() catch { _ => "" })
    assert_eq(seen_auth.val, "Bearer " + secret_two)
    assert_eq(hits.val, 2)
    // Revocation destroys the secret, stops the in-flight proxy and makes the
    // next start fail closed.
    let revoke_params : Map[String, @json.Json] = Map([])
    revoke_params.set("credential_id", @contracts.json_string(credential_id))
    let revoke_text = credential_test_rpc(
      state,
      @contracts.METHOD_CREDENTIAL_REVOKE,
      revoke_params,
      "local-revoke",
    )
    assert_true(revoke_text.contains(@contracts.CREDENTIAL_STATE_REVOKED))
    match state.credential_proxies.get("session-credential-test") {
      Some(_) => fail("revoke left a live proxy registered")
      None => ()
    }
    assert_true(proxy_two.closed.val)
    match
      prepare_agent_credential(
        state,
        group,
        "",
        CREDENTIAL_TEST_AGENT,
        "local-test",
      ) {
      Ok(_) => fail("a revoked binding must not prepare")
      Err(error) =>
        assert_eq(error.reason, @contracts.CREDENTIAL_REASON_REVOKED)
    }
    let stored = state.credential_store.get(credential_id)
    match stored {
      Ok(_) => fail("revoke left the secret in the platform store")
      Err(_) => ()
    }
    // Every persisted audit surface is secret-free, including the proxy
    // capability tokens.
    let event_text = credential_test_event_text(state)
    assert_true(!event_text.contains(secret_one))
    assert_true(!event_text.contains(secret_two))
    assert_true(!event_text.contains(token_one))
    assert_true(!event_text.contains(token_two))
    assert_true(event_text.contains(binding_id))
    upstream.close()
  })
}

///|
fn credential_test_remote_bind_params(
  credential_id : String,
  machine_id : String,
  agent_id : String,
  profile : String,
  version : Int32,
  fingerprint : String,
  node_enrolled : Bool,
) -> Map[String, @json.Json] {
  let params = credential_test_bind_params(
    credential_id, machine_id, agent_id, profile,
  )
  params.set("node_enrolled", @contracts.json_bool(node_enrolled))
  params.set("version", @contracts.json_int(version))
  params.set("fingerprint", @contracts.json_string(fingerprint))
  params
}

///|
async test "remote binding mirrors metadata, leases, and revokes without a secret" {
  let root = @fs.tmpdir(prefix="monexus-host-cred-remote") catch {
    _ => fail("cannot create the remote credential root")
  }
  defer credential_test_cleanup(root)
  let state = credential_test_state(root + "/state", true)
  credential_test_put_machine(
    state,
    "mch_runtime_remote",
    @contracts.MACHINE_KIND_RUNTIME,
  ) catch {
    error => fail(error.to_string())
  }
  let credential_id = "crd_node_remote_1"
  let fingerprint = "sha256-node-fingerprint-1"
  let bind_text = credential_test_rpc(
    state,
    @contracts.METHOD_CREDENTIAL_BINDING_CREATE,
    credential_test_remote_bind_params(
      credential_id,
      "mch_runtime_remote",
      CREDENTIAL_TEST_AGENT,
      "anthropic",
      1,
      fingerprint,
      true,
    ),
    "remote-bind",
  )
  let binding_id = credential_test_binding_id(bind_text)
  assert_true(bind_text.contains(@contracts.CREDENTIAL_OWNER_NODE))
  assert_true(!bind_text.contains("secret"))
  // Without a live node channel a fresh lease cannot be requested; the
  // primary refuses the start instead of shipping a secret.
  let delivery = credential_test_prepare(
    state,
    "mch_runtime_remote",
    CREDENTIAL_TEST_AGENT,
    "anthropic",
  )
  match delivery {
    Ok(_) => fail("a remote binding without a live channel must not prepare")
    Err(error) =>
      assert_eq(error.reason, @contracts.CREDENTIAL_REASON_DELIVERY_FAILED)
  }
  // A metadata-only lease signal renews the mirror.
  let lease_calls : Array[@credentials.RemoteCredentialSignal] = []
  let revoke_calls : Array[@credentials.RemoteCredentialSignal] = []
  let port = @credentials.RemoteCredentialPort::new(
    lease=async fn(signal) {
      lease_calls.push(signal)
      Ok(())
    },
    revoke=async fn(signal) {
      revoke_calls.push(signal)
      Ok(())
    },
  )
  state.register_remote_credential_port("mch_runtime_remote", port)
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let prepared = match
      prepare_agent_credential(
        state,
        group,
        "mch_runtime_remote",
        CREDENTIAL_TEST_AGENT,
        "anthropic",
      ) {
      Ok(Some(value)) => value
      Ok(None) => fail("the remote binding was not prepared")
      Err(error) => fail("remote prepare failed: " + error.message())
    }
    assert_true(prepared.is_remote())
    assert_true(prepared.env().is_empty())
    assert_eq(lease_calls.length(), 1)
    let signal = lease_calls[0]
    assert_eq(signal.binding_id, binding_id)
    assert_eq(signal.credential_id, credential_id)
    assert_eq(signal.version, 1)
    assert_eq(signal.fingerprint, fingerprint)
    assert_true(!signal.profile.contains("sk-"))
    assert_true(prepared.binding().lease_expires_at != "")
  })
  // Primary-side revoke is a signal only; the metadata mirror becomes revoked
  // once the node acknowledges.
  let revoke_params : Map[String, @json.Json] = Map([])
  revoke_params.set("credential_id", @contracts.json_string(credential_id))
  let revoke_text = credential_test_rpc(
    state,
    @contracts.METHOD_CREDENTIAL_REVOKE,
    revoke_params,
    "remote-revoke",
  )
  assert_eq(revoke_calls.length(), 1)
  assert_eq(revoke_calls[0].profile, "anthropic")
  assert_true(revoke_text.contains(@contracts.CREDENTIAL_STATE_REVOKED))
  let delivery = credential_test_prepare(
    state,
    "mch_runtime_remote",
    CREDENTIAL_TEST_AGENT,
    "anthropic",
  )
  match delivery {
    Ok(_) => fail("a revoked remote binding must not prepare")
    Err(error) => assert_eq(error.reason, @contracts.CREDENTIAL_REASON_REVOKED)
  }
  let event_text = credential_test_event_text(state)
  assert_true(!event_text.contains("secret"))
}

///|
async test "remote lease expiry fails closed while the node is offline" {
  let root = @fs.tmpdir(prefix="monexus-host-cred-lease") catch {
    _ => fail("cannot create the lease credential root")
  }
  defer credential_test_cleanup(root)
  let state = credential_test_make_state(
    root + "/state",
    credential_test_memory_store(),
    true,
    100L,
    @contracts.CREDENTIAL_DEFAULT_COOLDOWN_MS,
  )
  credential_test_put_machine(
    state,
    "mch_runtime_lease",
    @contracts.MACHINE_KIND_RUNTIME,
  ) catch {
    error => fail(error.to_string())
  }
  let bind_text = credential_test_rpc(
    state,
    @contracts.METHOD_CREDENTIAL_BINDING_CREATE,
    credential_test_remote_bind_params(
      "crd_node_lease",
      "mch_runtime_lease",
      CREDENTIAL_TEST_AGENT,
      "anthropic",
      1,
      "sha256-node-lease",
      true,
    ),
    "lease-bind",
  )
  ignore(bind_text)
  @async.sleep(300)
  let delivery = credential_test_prepare(
    state,
    "mch_runtime_lease",
    CREDENTIAL_TEST_AGENT,
    "anthropic",
  )
  match delivery {
    Ok(_) => fail("an expired offline lease must fail closed")
    Err(error) =>
      assert_eq(error.reason, @contracts.CREDENTIAL_REASON_LEASE_EXPIRED)
  }
}

///|
async test "readiness failures create one Decision per tuple and suppress retries" {
  let root = @fs.tmpdir(prefix="monexus-host-cred-readiness") catch {
    _ => fail("cannot create the readiness credential root")
  }
  defer credential_test_cleanup(root)
  let state = credential_test_state(root + "/state", true)
  let reason = @contracts.CREDENTIAL_REASON_MISSING
  record_credential_readiness_failure(
    state,
    "mch_readiness",
    CREDENTIAL_TEST_AGENT,
    "anthropic",
    reason,
  )
  record_credential_readiness_failure(
    state,
    "mch_readiness",
    CREDENTIAL_TEST_AGENT,
    "anthropic",
    reason,
  )
  state.credential_cooldowns.clear()
  record_credential_readiness_failure(
    state,
    "mch_readiness",
    CREDENTIAL_TEST_AGENT,
    "anthropic",
    reason,
  )
  assert_eq(
    credential_test_count_events(
      state,
      @contracts.EVENT_CREDENTIAL_READINESS_FAILED,
    ),
    1,
  )
  assert_eq(
    credential_test_count_events(
      state,
      @contracts.EVENT_CREDENTIAL_READINESS_SUPPRESSED,
    ),
    2,
  )
  let decisions = match
    state.store.list_decisions(@contracts.DECISION_STATUS_PENDING, "") {
    Ok(value) => value
    Err(message) => fail(message)
  }
  let mut readiness = 0
  for decision in decisions {
    if decision.kind == @contracts.DECISION_KIND_READINESS {
      readiness = readiness + 1
      assert_true(decision.detail.contains(reason))
    }
  }
  assert_eq(readiness, 1)
}

///|
async test "revocation survives a restart and replay stays idempotent" {
  let root = @fs.tmpdir(prefix="monexus-host-cred-restart") catch {
    _ => fail("cannot create the restart credential root")
  }
  defer credential_test_cleanup(root)
  let db_path = root + "/host.db"
  let store_one = match @machines.MachineStore::open(db_path) {
    Ok(value) => value
    Err(message) => fail("cannot open the restart store: " + message)
  }
  let state_one = credential_test_make_state(
    root + "/state",
    store_one,
    true,
    @contracts.CREDENTIAL_DEFAULT_LEASE_TTL_MS,
    @contracts.CREDENTIAL_DEFAULT_COOLDOWN_MS,
  )
  let secret = "sk-restart-secret"
  let enroll_text = credential_test_rpc(
    state_one,
    @contracts.METHOD_CREDENTIAL_ENROLL,
    credential_test_enroll_params(secret, ""),
    "restart-enroll",
  )
  let credential_id = credential_test_credential_id(enroll_text)
  let bind_text = credential_test_rpc(
    state_one,
    @contracts.METHOD_CREDENTIAL_BINDING_CREATE,
    credential_test_bind_params(
      credential_id,
      "",
      CREDENTIAL_TEST_AGENT,
      "anthropic",
    ),
    "restart-bind",
  )
  ignore(credential_test_binding_id(bind_text))
  let revoke_params : Map[String, @json.Json] = Map([])
  revoke_params.set("credential_id", @contracts.json_string(credential_id))
  ignore(
    credential_test_rpc(
      state_one,
      @contracts.METHOD_CREDENTIAL_REVOKE,
      revoke_params,
      "restart-revoke",
    ),
  )
  assert_true(
    !(@fs.exists(root + "/state/credentials/" + credential_id + ".json") catch {
      _ => false
    }),
  )
  store_one.close()
  // A fresh host process sees the same durable idempotency record and the
  // revoked metadata; the secret is already gone.
  let store_two = match @machines.MachineStore::open(db_path) {
    Ok(value) => value
    Err(message) => fail("cannot reopen the restart store: " + message)
  }
  let state_two = credential_test_make_state(
    root + "/state",
    store_two,
    true,
    @contracts.CREDENTIAL_DEFAULT_LEASE_TTL_MS,
    @contracts.CREDENTIAL_DEFAULT_COOLDOWN_MS,
  )
  let replay_text = credential_test_rpc(
    state_two,
    @contracts.METHOD_CREDENTIAL_ENROLL,
    credential_test_enroll_params(secret, ""),
    "restart-enroll",
  )
  assert_eq(credential_test_credential_id(replay_text), credential_id)
  let credentials = match state_two.store.list_credentials() {
    Ok(value) => value
    Err(message) => fail(message)
  }
  assert_eq(credentials.length(), 1)
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    match
      prepare_agent_credential(
        state_two,
        group,
        "",
        CREDENTIAL_TEST_AGENT,
        "anthropic",
      ) {
      Ok(_) => fail("a revoked binding must fail closed after a restart")
      Err(error) =>
        assert_eq(error.reason, @contracts.CREDENTIAL_REASON_REVOKED)
    }
  })
  let event_text = credential_test_event_text(state_two)
  assert_true(!event_text.contains(secret))
  store_two.close()
}

///|
/// Exact byte search used by the live e2e scan; the persisted SQLite file is
/// binary, so a UTF-8 string search is not sufficient.
fn credential_live_bytes_contains(data : Bytes, needle : String) -> Bool {
  let target = @utf8.encode(needle)
  if target.length() == 0 || data.length() < target.length() {
    return false
  }
  let limit = data.length() - target.length()
  let mut start = 0
  while start <= limit {
    let mut matched = true
    let mut offset = 0
    while offset < target.length() {
      if data[start + offset] != target[offset] {
        matched = false
        break
      }
      offset = offset + 1
    }
    if matched {
      return true
    }
    start = start + 1
  }
  false
}

///|
/// Scan a directory tree for a secret or capability token, skipping the one
/// node/host store file where the secret is allowed to live.
async fn credential_live_scan_dir(
  root : String,
  skip : String,
  needle : String,
) -> Unit {
  let names = @fs.readdir(root, include_hidden=true, sort=false) catch {
    _ => []
  }
  for name in names {
    let path = root + "/" + name
    if path == skip {
      continue
    }
    let kind = @fs.kind(path, follow_symlink=false) catch {
      _ => @fs.FileKind::Unknown
    }
    match kind {
      @fs.FileKind::Directory => credential_live_scan_dir(path, skip, needle)
      @fs.FileKind::Regular => {
        let data = @fs.read_file(path) catch { _ => continue }
        if credential_live_bytes_contains(data.binary(), needle) {
          fail("a credential value leaked into " + path)
        }
      }
      _ => ()
    }
  }
}

///|
/// Optional live-e2e tuning knob. Empty when unset, which keeps every default
/// (built-in preset, CI, offline runs) byte-identical.
fn credential_live_env(name : String) -> String {
  match @env.get_env_var(name) {
    Some(value) => value.trim().to_owned()
    None => ""
  }
}

///|
/// Resolve the live e2e profile name. Without any upstream override the name
/// is used as-is, so the built-in `anthropic` preset (or an already stored
/// profile) keeps working exactly as before. With an override, persist a
/// profile that points the loopback proxy at the override target; each empty
/// override field keeps the known preset's value (or the contract default for
/// a brand-new profile name).
fn credential_live_profile(
  state : HostState,
  name : String,
  scheme : String,
  host : String,
  base_path : String,
  auth_header : String,
  auth_scheme : String,
) -> String raise {
  let overridden = scheme != "" ||
    host != "" ||
    base_path != "" ||
    auth_header != "" ||
    auth_scheme != ""
  if !overridden {
    return name
  }
  let base = match @contracts.CredentialProfile::builtin(name) {
    Some(value) => value
    None =>
      match state.store.get_credential_profile(name) {
        Ok(Some(value)) => value
        // A fresh override-only profile starts from the contract defaults
        // (https, authorization/Bearer); the caller supplies what it needs.
        _ => @contracts.CredentialProfile::new(name~, upstream_host="")
      }
  }
  let profile = @contracts.CredentialProfile::new(
    name~,
    upstream_scheme=if scheme == "" { base.upstream_scheme } else { scheme },
    upstream_host=if host == "" { base.upstream_host } else { host },
    upstream_base_path=if base_path == "" {
      base.upstream_base_path
    } else {
      base_path
    },
    auth_header=if auth_header == "" { base.auth_header } else { auth_header },
    auth_scheme=if auth_scheme == "" { base.auth_scheme } else { auth_scheme },
  )
  match state.store.put_credential_profile(profile) {
    Ok(_) => ()
    Err(message) => fail("cannot store the live credential profile: " + message)
  }
  name
}

///|
/// A5.1 live model-call end to end. The test uses an explicitly supplied model
/// key (`MONEXUS_E2E_CREDENTIAL_KEY`); without one it skips and says so, so CI
/// stays offline and deterministic. With a key it proves the loopback proxy
/// really swaps the capability token for the upstream credential, that the
/// secret/token never land in persisted host surfaces, and that the same call
/// fails closed after revocation. The upstream profile can be steered with
/// the optional `MONEXUS_E2E_CREDENTIAL_*` overrides so the same test can run
/// against a local Anthropic-compatible gateway.
async test "live managed model call and revocation fail closed" {
  let key = match @env.get_env_var("MONEXUS_E2E_CREDENTIAL_KEY") {
    Some(value) => value.trim().to_owned()
    None => ""
  }
  if key == "" {
    println(
      "host credential live e2e skipped: MONEXUS_E2E_CREDENTIAL_KEY is not set",
    )
    return
  }
  let model = match @env.get_env_var("MONEXUS_E2E_CREDENTIAL_MODEL") {
    Some(value) => value.trim().to_owned()
    None => "claude-haiku-4-5"
  }
  let profile_name = match
    credential_live_env("MONEXUS_E2E_CREDENTIAL_PROFILE") {
    "" => "anthropic"
    value => value
  }
  let root = @fs.tmpdir(prefix="monexus-host-cred-live") catch {
    _ => fail("cannot create the live credential root")
  }
  defer credential_test_cleanup(root)
  let db_path = root + "/host.db"
  let store = match @machines.MachineStore::open(db_path) {
    Ok(value) => value
    Err(message) => fail("cannot open the live credential store: " + message)
  }
  let state = credential_test_make_state(
    root + "/state",
    store,
    true,
    @contracts.CREDENTIAL_DEFAULT_LEASE_TTL_MS,
    @contracts.CREDENTIAL_DEFAULT_COOLDOWN_MS,
  )
  let live_profile = credential_live_profile(
    state,
    profile_name,
    credential_live_env("MONEXUS_E2E_CREDENTIAL_UPSTREAM_SCHEME"),
    credential_live_env("MONEXUS_E2E_CREDENTIAL_UPSTREAM_HOST"),
    credential_live_env("MONEXUS_E2E_CREDENTIAL_UPSTREAM_BASE_PATH"),
    credential_live_env("MONEXUS_E2E_CREDENTIAL_AUTH_HEADER"),
    credential_live_env("MONEXUS_E2E_CREDENTIAL_AUTH_SCHEME"),
  )
  let enroll_text = credential_test_rpc(
    state,
    @contracts.METHOD_CREDENTIAL_ENROLL,
    credential_test_enroll_params(key, ""),
    "live-enroll",
  )
  let credential_id = credential_test_credential_id(enroll_text)
  let bind_text = credential_test_rpc(
    state,
    @contracts.METHOD_CREDENTIAL_BINDING_CREATE,
    credential_test_bind_params(
      credential_id,
      "",
      CREDENTIAL_TEST_AGENT,
      live_profile,
    ),
    "live-bind",
  )
  ignore(credential_test_binding_id(bind_text))
  // The loopback proxy's accept loop is a child of the task group that
  // prepared it, and `with_task_group` cancels children when its body
  // returns. Hold one group open across prepare, the model call, the secret
  // scan, revocation and the post-revoke call so the proxy really serves
  // them; the previous short-lived helper group left a listener that
  // accepted TCP but never answered.
  @async.with_task_group(async fn(group : @async.TaskGroup[Unit]) -> Unit {
    let prepared = match
      prepare_agent_credential(
        state,
        group,
        "",
        CREDENTIAL_TEST_AGENT,
        live_profile,
      ) {
      Ok(Some(value)) => value
      Ok(None) => fail("the live credential binding was not prepared")
      Err(error) =>
        fail("cannot prepare the live credential: " + error.message())
    }
    assert_true(!prepared.is_remote())
    let env = prepared.env()
    let proxy_url = match env.get(@contracts.CREDENTIAL_ENV_PROXY_URL) {
      Some(value) => value
      None => fail("the prepared environment has no proxy URL")
    }
    let token = match env.get(@contracts.CREDENTIAL_ENV_PROXY_TOKEN) {
      Some(value) => value
      None => fail("the prepared environment has no proxy token")
    }
    assert_true(token.has_prefix(@contracts.CREDENTIAL_TOKEN_PREFIX))
    let body = "{\"model\":\"" +
      model +
      "\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}"
    let headers : @http.Headers = Map([])
    headers.set(
      @http.CaseInsensitiveString("authorization"),
      "Bearer " + token,
    )
    headers.set(@http.CaseInsensitiveString("content-type"), "application/json")
    let (response, response_body) = @http.post(
      proxy_url + "/v1/messages",
      body,
      headers~,
    )
    let response_text = response_body.text() catch { _ => "" }
    if response.code != 200 {
      fail(
        "live managed model call failed: HTTP " +
        response.code.to_string() +
        " " +
        response_text,
      )
    }
    // A 200 alone would also pass for an empty or error-shaped body, so
    // require a message-shaped response with at least one content block
    // (or the assistant role). The body never carries the key or the
    // capability token, so it is safe to surface in the failure text.
    let response_json = @json.parse(response_text) catch {
      _ => fail("the live model response is not JSON: " + response_text)
    }
    let response_object = match @contracts.as_object(response_json) {
      Some(value) => value
      None =>
        fail("the live model response is not a JSON object: " + response_text)
    }
    let content_blocks = match response_object.get("content") {
      Some(@json.Json::Array(items)) => items.length()
      _ => 0
    }
    let assistant_role = @contracts.string_field_or(response_object, "role", "")
    if content_blocks == 0 && assistant_role != "assistant" {
      fail("the live model response has no assistant content: " + response_text)
    }
    println(
      "live managed model call: HTTP 200 model=" +
      @contracts.string_field_or(response_object, "model", model) +
      " content_blocks=" +
      content_blocks.to_string(),
    )
    // Persisted surfaces, including SQLite and any WAL files, must not
    // contain the real key or the capability token. The one credential file
    // is the store's legitimate 0600 envelope and is skipped by exact path.
    let secret_path = root + "/state/credentials/" + credential_id + ".json"
    credential_live_scan_dir(root, secret_path, key)
    credential_live_scan_dir(root, secret_path, token)
    let event_text = credential_test_event_text(state)
    assert_true(!event_text.contains(key))
    assert_true(!event_text.contains(token))
    let revoke_params : Map[String, @json.Json] = Map([])
    revoke_params.set("credential_id", @contracts.json_string(credential_id))
    let revoke_text = credential_test_rpc(
      state,
      @contracts.METHOD_CREDENTIAL_REVOKE,
      revoke_params,
      "live-revoke",
    )
    assert_true(revoke_text.contains(@contracts.CREDENTIAL_STATE_REVOKED))
    // The secret is gone from disk and the same call now fails closed.
    credential_live_scan_dir(root, "", key)
    assert_true(
      !(@fs.exists(root + "/state/credentials/" + credential_id + ".json") catch {
        _ => false
      }),
    )
    let second_code = @async.with_timeout_opt(3_000, async fn() -> Int32 {
      let (second, second_body) = @http.post(
        proxy_url + "/v1/messages",
        body,
        headers~,
      ) catch {
        _ => return -1
      }
      ignore(second_body.text() catch { _ => "" })
      second.code
    })
    match second_code {
      Some(code) => {
        println("live post-revoke model call: code=" + code.to_string())
        assert_true(code != 200)
      }
      None => println("live post-revoke model call: timed out (no 200)")
    }
    match
      prepare_agent_credential(
        state,
        group,
        "",
        CREDENTIAL_TEST_AGENT,
        live_profile,
      ) {
      Ok(_) => fail("a revoked credential must not prepare again")
      Err(error) =>
        assert_eq(error.reason, @contracts.CREDENTIAL_REASON_REVOKED)
    }
  })
  store.close()
}
