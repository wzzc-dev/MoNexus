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
fn environment_test_runner(
  home : String,
  removed : Ref[Array[String]],
  remove_fails : Bool,
) -> @environment.DockerRunner {
  let invoke : @environment.DockerInvoke = async fn(argv, timeout_s) {
    ignore(argv)
    ignore(timeout_s)
    Ok({ exit_code: 0, stdout: "", stderr: "" })
  }
  let make_dir : @environment.PathOp = async fn(path) {
    ignore(path)
    Ok(())
  }
  let write_secret : @environment.WriteSecretOp = async fn(dir, variables) {
    ignore(dir)
    ignore(variables)
    Ok(())
  }
  let remove_file : @environment.PathOp = async fn(path) {
    removed.val.push(path)
    if remove_fails {
      return Err(
        @environment.EnvFailure::new(
          @contracts.ENVIRONMENT_ERR_CLEANUP_FAILED,
          "cannot remove env file",
        ),
      )
    }
    Ok(())
  }
  let remove_dir : @environment.PathOp = async fn(path) {
    ignore(path)
    Ok(())
  }
  {
    machine_id: "",
    remote: false,
    home,
    target: None,
    invoke,
    make_dir,
    write_secret,
    remove_file,
    remove_dir,
  }
}

///|
async fn environment_test_audit_outcomes(
  state : HostState,
  action : String,
) -> Array[String] {
  state.mutex.acquire()
  let events = match state.store.load_recent_events(1_000) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      abort("cannot read events: " + message)
    }
  }
  state.mutex.release()
  let out : Array[String] = []
  for event in events {
    if event.event_type == @contracts.EVENT_AUDIT_RECORDED {
      match @contracts.audit_from_json(event.payload) {
        Some(record) =>
          if record.action == action {
            out.push(record.outcome)
          }
        None => ()
      }
    }
  }
  out
}

///|
fn environment_test_intent(
  id : String,
  workspace_id : String,
) -> @contracts.EnvironmentRecord {
  let now = @async.now()
  {
    ..environment_test_record(id, workspace_id, ""),
    state: @contracts.ENVIRONMENT_STATE_CREATING,
    created_at: @contracts.format_rfc3339(now),
    updated_at: @contracts.format_rfc3339(now),
    started_at: "",
  }
}

///|
async test "approval is not burned when the target conflict or lease wins" {
  let store = environment_test_open_store()
  let state = environment_test_state(store)
  // An active environment already owns the target: the newcomer must lose
  // before the approval is touched.
  let active = environment_test_record(
    "env_ACTIVE000000000000001",
    "wsp_01ARYZ6S41",
    "",
  )
  match store.put_environment(active) {
    Ok(_) => ()
    Err(message) => abort("cannot store active environment: " + message)
  }
  let conflict_approval = environment_test_approval(
    "dec_gate_conflict00000001",
    @contracts.DECISION_OPTION_APPROVE,
    "2030-01-01T00:00:00Z",
  )
  environment_test_persist_decision(state, conflict_approval)
  let conflict_intent = environment_test_intent(
    "env_01ARYZ6S42",
    "wsp_01ARYZ6S41",
  )
  match
    reserve_environment_creation(
      state,
      conflict_intent,
      "workspace",
      "wsp_01ARYZ6S41",
      Some(conflict_approval),
    ) {
    Ok(_) => fail("a target conflict must be refused")
    Err(error) =>
      assert_true(
        error.message.has_prefix(@contracts.ENVIRONMENT_ERR_CONFLICT),
      )
  }
  assert_true(!environment_test_decision_consumed(state, conflict_approval.id))
  assert_eq(environment_test_audit_outcomes(state, "environment.approval.consume").length(), 0)
  match store.find_lease("workspace", "wsp_01ARYZ6S41") {
    Ok(None) => ()
    _ => fail("a losing create must not leave a lease")
  }
  match store.get_environment(conflict_intent.id) {
    Ok(None) => ()
    _ => fail("a losing create must not persist an intent")
  }
  // An active lease without an active record must also stop the create before
  // the approval is burned.
  match acquire_environment_lease(state, "env_OTHER00000000000001", "workspace", "wsp_01ARYZ6S43") {
    Ok(_) => ()
    Err(error) => fail("cannot seed the lease: " + error.message)
  }
  let lease_approval = environment_test_approval(
    "dec_gate_lease0000000001",
    @contracts.DECISION_OPTION_APPROVE,
    "2030-01-01T00:00:00Z",
  )
  environment_test_persist_decision(state, lease_approval)
  let lease_intent = environment_test_intent("env_01ARYZ6S44", "wsp_01ARYZ6S43")
  match
    reserve_environment_creation(
      state,
      lease_intent,
      "workspace",
      "wsp_01ARYZ6S43",
      Some(lease_approval),
    ) {
    Ok(_) => fail("a leased target must be refused")
    Err(error) =>
      assert_true(
        error.message.has_prefix(@contracts.ENVIRONMENT_ERR_CONFLICT),
      )
  }
  assert_true(!environment_test_decision_consumed(state, lease_approval.id))
  store.close()
}

///|
async test "approval consumption append failure fails closed before any create" {
  let store = environment_test_open_store()
  let state = environment_test_state(store)
  let approval = environment_test_approval(
    "dec_gate_append000000001",
    @contracts.DECISION_OPTION_APPROVE,
    "2030-01-01T00:00:00Z",
  )
  environment_test_persist_decision(state, approval)
  let intent = environment_test_intent("env_01ARYZ6S45", "wsp_01ARYZ6S41")
  state.test_fail_approval_consumption.val = true
  match
    reserve_environment_creation(
      state,
      intent,
      "workspace",
      "wsp_01ARYZ6S41",
      Some(approval),
    ) {
    Ok(_) => fail("an unpersisted approval burn must stop the create")
    Err(error) =>
      assert_true(
        error.message.has_prefix(@contracts.ENVIRONMENT_ERR_INTERNAL),
      )
  }
  state.test_fail_approval_consumption.val = false
  // Durable state is all-or-nothing: no consumed flag, no lease, no intent,
  // and the rejection is audited as failed rather than consumed. Docker is
  // only reached after this gate returns Ok, so no container call can happen.
  assert_true(!environment_test_decision_consumed(state, approval.id))
  let consume_outcomes = environment_test_audit_outcomes(
    state,
    "environment.approval.consume",
  )
  assert_eq(consume_outcomes.length(), 1)
  assert_eq(consume_outcomes[0], "failed")
  match store.find_lease("workspace", "wsp_01ARYZ6S41") {
    Ok(None) => ()
    _ => fail("a failed approval burn must release the lease")
  }
  match store.get_environment(intent.id) {
    Ok(None) => ()
    _ => fail("a failed approval burn must leave no create intent")
  }
  assert_true(state.env_create_started.get(intent.id).is_none())
  store.close()
}

///|
async test "reserve burns the approval after the gates and blocks a second environment" {
  let store = environment_test_open_store()
  let state = environment_test_state(store)
  let approval = environment_test_approval(
    "dec_gate_success000000001",
    @contracts.DECISION_OPTION_APPROVE,
    "2030-01-01T00:00:00Z",
  )
  environment_test_persist_decision(state, approval)
  let intent = environment_test_intent("env_01ARYZ6S46", "wsp_01ARYZ6S41")
  assert_true(!environment_test_decision_consumed(state, approval.id))
  match
    reserve_environment_creation(
      state,
      intent,
      "workspace",
      "wsp_01ARYZ6S41",
      Some(approval),
    ) {
    Ok(value) => assert_eq(value.id, intent.id)
    Err(error) => fail("reserve failed: " + error.message)
  }
  assert_true(environment_test_decision_consumed(state, approval.id))
  match store.find_lease("workspace", "wsp_01ARYZ6S41") {
    Ok(Some(lease)) => assert_eq(lease.holder, "environment:" + intent.id)
    _ => fail("a successful reserve must hold the target lease")
  }
  // The in-process marker exists in the same mutex section as the intent, so
  // reconcile cannot classify this live create as stale.
  assert_true(state.env_create_started.get(intent.id).is_some())
  match store.get_environment(intent.id) {
    Ok(Some(record)) =>
      assert_eq(record.state, @contracts.ENVIRONMENT_STATE_CREATING)
    _ => fail("a successful reserve must persist the create intent")
  }
  // A second create for the same target loses without spending its own grant.
  let second_approval = environment_test_approval(
    "dec_gate_second0000000001",
    @contracts.DECISION_OPTION_APPROVE,
    "2030-01-01T00:00:00Z",
  )
  environment_test_persist_decision(state, second_approval)
  let second_intent = environment_test_intent("env_01ARYZ6S47", "wsp_01ARYZ6S41")
  match
    reserve_environment_creation(
      state,
      second_intent,
      "workspace",
      "wsp_01ARYZ6S41",
      Some(second_approval),
    ) {
    Ok(_) => fail("a second environment for one target must be refused")
    Err(error) =>
      assert_true(
        error.message.has_prefix(@contracts.ENVIRONMENT_ERR_CONFLICT),
      )
  }
  assert_true(!environment_test_decision_consumed(state, second_approval.id))
  store.close()
}

///|
test "create intent timeout uses the recorded age" {
  let created_ms = match @contracts.parse_rfc3339_ms("2026-02-01T00:00:00Z") {
    Some(value) => value
    None => fail("fixture timestamp did not parse")
  }
  let old = environment_test_record("env_01ARYZ6S48", "wsp_01ARYZ6S41", "")
  assert_true(
    create_intent_age_timed_out(
      old,
      created_ms + @environment.CREATE_INTENT_TIMEOUT_MS,
    ),
  )
  assert_true(!create_intent_age_timed_out(old, created_ms + 1_000L))
  assert_true(
    !create_intent_age_timed_out(
      { ..old, created_at: "not-a-timestamp" },
      created_ms + @environment.CREATE_INTENT_TIMEOUT_MS,
    ),
  )
}

///|
async test "reconcile adoption removes a leftover env-file and records the outcome" {
  let store = environment_test_open_store()
  let state = environment_test_state(store)
  let removed : Ref[Array[String]] = Ref([])
  let runner = environment_test_runner(
    "/tmp/monexus-environment-wbtest/home",
    removed,
    false,
  )
  let record = {
    ..environment_test_record("env_01ARYZ6S41", "wsp_01ARYZ6S41", ""),
    state: @contracts.ENVIRONMENT_STATE_CREATING,
  }
  adopt_environment(state, record, true, runner)
  assert_eq(removed.val.length(), 1)
  assert_true(
    removed.val[0].has_suffix(
      "/.monexus/environments/env_01ARYZ6S41/env",
    ),
  )
  let stored = match store.get_environment(record.id) {
    Ok(Some(value)) => value
    _ => fail("adoption did not persist the record")
  }
  assert_eq(stored.state, @contracts.ENVIRONMENT_STATE_RUNNING)
  assert_true(stored.cleanup_ok)
  assert_eq(stored.cleanup_detail, "")
  store.close()
}

///|
async test "drift settlement removes the env-file and never reports clean when it remains" {
  let store = environment_test_open_store()
  let state = environment_test_state(store)
  let removed : Ref[Array[String]] = Ref([])
  let runner = environment_test_runner(
    "/tmp/monexus-environment-wbtest/home",
    removed,
    false,
  )
  let record = {
    ..environment_test_record("env_01ARYZ6S49", "wsp_01ARYZ6S41", ""),
    state: @contracts.ENVIRONMENT_STATE_CREATING,
  }
  match acquire_environment_lease(state, record.id, "workspace", "wsp_01ARYZ6S41") {
    Ok(_) => ()
    Err(error) => fail("cannot seed lease: " + error.message)
  }
  settle_drifted_create_intent(
    state,
    record,
    runner,
    "container does not match the recorded plan; container left untouched",
  )
  assert_eq(removed.val.length(), 1)
  assert_true(removed.val[0].has_suffix("/env"))
  match store.find_lease("workspace", "wsp_01ARYZ6S41") {
    Ok(None) => ()
    _ => fail("settling a drift intent must release its lease")
  }
  let settled = match store.get_environment(record.id) {
    Ok(Some(value)) => value
    _ => fail("drift settlement did not persist the record")
  }
  assert_eq(settled.state, @contracts.ENVIRONMENT_STATE_FAILED)
  assert_true(settled.cleanup_ok)
  // A removal that cannot be confirmed is recorded as failed, with a cleanup
  // artifact; cleanup_ok is never set while the secret could remain.
  let failing_store = environment_test_open_store()
  let failing_state = environment_test_state(failing_store)
  let failing_removed : Ref[Array[String]] = Ref([])
  let failing_runner = environment_test_runner(
    "/tmp/monexus-environment-wbtest/home",
    failing_removed,
    true,
  )
  let failing_record = {
    ..environment_test_record("env_01ARYZ6S50", "wsp_01ARYZ6S43", ""),
    state: @contracts.ENVIRONMENT_STATE_CREATING,
  }
  settle_drifted_create_intent(
    failing_state,
    failing_record,
    failing_runner,
    "container is missing",
  )
  assert_eq(failing_removed.val.length(), 1)
  let failed = match failing_store.get_environment(failing_record.id) {
    Ok(Some(value)) => value
    _ => fail("drift settlement did not persist the failing record")
  }
  assert_eq(failed.state, @contracts.ENVIRONMENT_STATE_FAILED)
  assert_true(!failed.cleanup_ok)
  assert_true(failed.cleanup_detail != "")
  store.close()
  failing_store.close()
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
