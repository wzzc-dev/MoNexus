///|
/// Whitebox host tests for the two durable safety rules around environment
/// creation: a repeated `client_request_id` returns the stored record instead
/// of creating again, and an environment approval is single-use and bound to
/// one exact plan, machine and recipe.

///|
fn environment_test_state(store : @machines.MachineStore) -> HostState {
  let options = HostOptions::new(state_dir="/tmp/monexus-environment-wbtest")
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
fn environment_test_open_store() -> @machines.MachineStore {
  match @machines.MachineStore::open(":memory:") {
    Ok(value) => value
    Err(message) => abort("cannot open in-memory store: " + message)
  }
}

///|
fn environment_test_record(
  id : String,
  workspace_id : String,
  client_request_id : String,
) -> @contracts.EnvironmentRecord {
  {
    id,
    workspace_id,
    worktree_id: "",
    machine_id: "",
    backend: @contracts.ENVIRONMENT_BACKEND_DOCKER,
    recipe: "tiny@0.1.0",
    recipe_hash: "sha256:" +
      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    container_name: "monexus-env-" + id,
    state: @contracts.ENVIRONMENT_STATE_RUNNING,
    plan_digest: "sha256:" +
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    workdir: "/workspace/project",
    user: "1000:1000",
    network: "none",
    mounts: [],
    env_names: [],
    risk: @contracts.RISK_MEDIUM,
    approval_id: "",
    ephemeral: false,
    ttl_s: 0,
    client_request_id,
    created_at: "2026-02-01T00:00:00Z",
    updated_at: "2026-02-01T00:00:00Z",
    started_at: "2026-02-01T00:00:00Z",
    stopped_at: "",
    last_error: "",
    cleanup_ok: true,
    cleanup_detail: "",
  }
}

///|
fn environment_create_params(
  workspace_id : String,
  environment_id : String,
  client_request_id : String,
) -> Map[String, @json.Json] {
  let params : Map[String, @json.Json] = Map([])
  params.set("workspace_id", @contracts.json_string(workspace_id))
  params.set("recipe", @contracts.json_string("tiny@0.1.0"))
  if environment_id != "" {
    params.set("environment_id", @contracts.json_string(environment_id))
  }
  if client_request_id != "" {
    params.set("client_request_id", @contracts.json_string(client_request_id))
  }
  params
}

///|
async test "repeated client_request_id returns the same record without a create" {
  let store = environment_test_open_store()
  let record = environment_test_record(
    "env_01ARYZ6S41",
    "wsp_01ARYZ6S41",
    "creq_01ARYZ6S41",
  )
  match store.put_environment(record) {
    Ok(_) => ()
    Err(message) => abort("cannot store environment: " + message)
  }
  let state = environment_test_state(store)
  let params = environment_create_params(
    "wsp_01ARYZ6S41",
    "",
    "creq_01ARYZ6S41",
  )
  let request = @contracts.RpcRequest::new(
    "req-1",
    "environment.create",
    params,
  )
  let first = match create_environment_locked(state, request) {
    Ok(value) => value
    Err(error) => fail("first create retry failed: " + error.message)
  }
  let second = match create_environment_locked(state, request) {
    Ok(value) => value
    Err(error) => fail("second create retry failed: " + error.message)
  }
  assert_eq(first.id, record.id)
  assert_eq(second.id, record.id)
  assert_eq(second.client_request_id, "creq_01ARYZ6S41")
  let stored = match store.find_environment_by_request("creq_01ARYZ6S41") {
    Ok(Some(value)) => value
    Ok(None) => fail("stored environment disappeared")
    Err(message) => abort("cannot read environment: " + message)
  }
  assert_eq(stored.id, record.id)
  store.close()
}

///|
async test "an explicit environment id is idempotent but refuses mismatch" {
  let store = environment_test_open_store()
  let record = environment_test_record(
    "env_01ARYZ6S42",
    "wsp_01ARYZ6S41",
    "",
  )
  match store.put_environment(record) {
    Ok(_) => ()
    Err(message) => abort("cannot store environment: " + message)
  }
  let state = environment_test_state(store)
  let same = @contracts.RpcRequest::new(
    "req-2",
    "environment.create",
    environment_create_params("wsp_01ARYZ6S41", "env_01ARYZ6S42", ""),
  )
  let returned = match create_environment_locked(state, same) {
    Ok(value) => value
    Err(error) => fail("explicit id retry failed: " + error.message)
  }
  assert_eq(returned.id, record.id)
  // The same id bound to a different workspace is a conflict, never a
  // second container or a silent re-bind.
  let mismatch = @contracts.RpcRequest::new(
    "req-3",
    "environment.create",
    environment_create_params("wsp_OTHER", "env_01ARYZ6S42", ""),
  )
  match create_environment_locked(state, mismatch) {
    Ok(_) => fail("a mismatched explicit id must be refused")
    Err(_) => ()
  }
  store.close()
}

///|
fn environment_test_approval(
  id : String,
  option_id : String,
  expires_at : String,
) -> @contracts.DecisionRecord {
  let base = @contracts.DecisionRecord::new(
    id=id,
    kind=@contracts.DECISION_KIND_ENVIRONMENT_APPROVAL,
    title="Approval needed: tiny@0.1.0",
    detail="test decision",
    session_id="",
    agent_id="",
    options=[
      @contracts.DecisionOption::new(
        option_id=@contracts.DECISION_OPTION_APPROVE,
        name="Approve once",
        kind="allow_once",
      ),
      @contracts.DecisionOption::new(
        option_id=@contracts.DECISION_OPTION_DENY,
        name="Deny",
        kind="reject_once",
      ),
    ],
    created_at="2026-01-01T00:00:00Z",
  )
  let bound = base.with_environment_approval(
    action=@contracts.ENVIRONMENT_APPROVAL_ACTION_CREATE,
    plan_digest="sha256:" +
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    machine_id="mch_01ARYZ6S41",
    recipe_hash="sha256:" +
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    nonce="nonce-one",
    expires_at=expires_at,
  )
  {
    ..bound,
    status: @contracts.DECISION_STATUS_ANSWERED,
    option_id,
    answered_by: "owner",
    answered_at: "2026-01-01T00:01:00Z",
  }
}

///|
async fn environment_test_persist_decision(
  state : HostState,
  decision : @contracts.DecisionRecord,
) -> Unit {
  state.mutex.acquire()
  let appended = state.append_decision_event(
    @contracts.EVENT_DECISION_RESPONDED,
    decision.id,
    @contracts.decision_payload(decision),
    decision,
  )
  state.mutex.release()
  match appended {
    Ok(_) => ()
    Err(message) => abort("cannot persist decision: " + message)
  }
}

///|
async fn environment_test_decision_consumed(
  state : HostState,
  decision_id : String,
) -> Bool {
  state.mutex.acquire()
  let loaded = state.store.get_decision(decision_id)
  state.mutex.release()
  match loaded {
    Ok(Some(value)) => value.consumed_at != ""
    Ok(None) => false
    Err(message) => abort("cannot read decision: " + message)
  }
}

///|
async test "environment approval denies, expires and is consumed once" {
  let store = environment_test_open_store()
  let state = environment_test_state(store)
  let action = @contracts.ENVIRONMENT_APPROVAL_ACTION_CREATE
  let digest = "sha256:" +
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  let machine = "mch_01ARYZ6S41"
  let recipe_hash = "sha256:" +
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  // Denied: answered but not approved, so it can never pull or create.
  let denied = environment_test_approval(
    "dec_denied00000000000000001",
    @contracts.DECISION_OPTION_DENY,
    "2030-01-01T00:00:00Z",
  )
  environment_test_persist_decision(state, denied)
  match
    validate_and_consume_approval(
      state,
      denied.id,
      action,
      digest,
      machine,
      recipe_hash,
    ) {
    Ok(_) => fail("a denied approval must be rejected")
    Err(_) => ()
  }
  assert_true(!environment_test_decision_consumed(state, denied.id))
  // Expired: approved but the deadline has passed.
  let expired = environment_test_approval(
    "dec_expired0000000000000001",
    @contracts.DECISION_OPTION_APPROVE,
    "2000-01-01T00:00:00Z",
  )
  environment_test_persist_decision(state, expired)
  match
    validate_and_consume_approval(
      state,
      expired.id,
      action,
      digest,
      machine,
      recipe_hash,
    ) {
    Ok(_) => fail("an expired approval must be rejected")
    Err(_) => ()
  }
  assert_true(!environment_test_decision_consumed(state, expired.id))
  // Binding mismatch: a valid grant for another machine does not transfer.
  let valid = environment_test_approval(
    "dec_valid0000000000000000001",
    @contracts.DECISION_OPTION_APPROVE,
    "2030-01-01T00:00:00Z",
  )
  environment_test_persist_decision(state, valid)
  match
    validate_and_consume_approval(
      state,
      valid.id,
      action,
      digest,
      "mch_OTHER",
      recipe_hash,
    ) {
    Ok(_) => fail("an approval bound to another machine must be rejected")
    Err(_) => ()
  }
  assert_true(!environment_test_decision_consumed(state, valid.id))
  // The matching retry consumes the grant exactly once.
  let first = match
    validate_and_consume_approval(
      state,
      valid.id,
      action,
      digest,
      machine,
      recipe_hash,
    ) {
    Ok(value) => value
    Err(error) => fail("valid approval was rejected: " + error.message)
  }
  assert_eq(first.id, valid.id)
  assert_true(environment_test_decision_consumed(state, valid.id))
  // Replay of the same approval id fails closed.
  match
    validate_and_consume_approval(
      state,
      valid.id,
      action,
      digest,
      machine,
      recipe_hash,
    ) {
    Ok(_) => fail("a consumed approval must not be reusable")
    Err(_) => ()
  }
  assert_true(environment_test_decision_consumed(state, valid.id))
  store.close()
}

///|
async test "environment approval rejects a missing or unbound decision" {
  let store = environment_test_open_store()
  let state = environment_test_state(store)
  // No decision was ever stored.
  match
    validate_and_consume_approval(
      state,
      "dec_missing0000000000000001",
      @contracts.ENVIRONMENT_APPROVAL_ACTION_CREATE,
      "sha256:" +
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "mch_01ARYZ6S41",
      "sha256:" +
      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    ) {
    Ok(_) => fail("a missing decision must be rejected")
    Err(_) => ()
  }
  store.close()
}
