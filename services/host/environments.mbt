///|
/// Docker environment lifecycle at the host (ADR-0013, A2.1).
///
/// The host is the only authority: every mutation runs under
/// `environment_mutex`, writes the durable intent event before Docker changes,
/// and touches only the deterministic `monexus-env-<id>` container. Recipe
/// signatures are re-verified before every use, and environment values never
/// leave the env-file hand-off.

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

///|
const ENVIRONMENT_EXEC_TIMEOUT_S : Int = 600

///|
const ENVIRONMENT_EXEC_STREAM_CAP : Int = 65_536

///|
const ENVIRONMENT_GIT_OUTPUT_CAP : Int = 131_072

///|
const ENVIRONMENT_RECONCILE_INTERVAL_MS : Int = 60_000

// ---------------------------------------------------------------------------
// Errors, feature switch, runner
// ---------------------------------------------------------------------------

///|
fn environment_rpc_error(
  kind : String,
  message : String,
  detail~ : String = "",
) -> @contracts.RpcError {
  @contracts.RpcError::new(
    @contracts.ERR_HOST,
    kind + ": " + message,
    data=@contracts.environment_error(kind, message, detail~),
  )
}

///|
fn environment_failure_error(
  failure : @environment.EnvFailure,
) -> @contracts.RpcError {
  environment_rpc_error(failure.code, failure.message, detail=failure.detail)
}

///|
fn environment_feature_enabled() -> Bool {
  match @env.get_env_var("MONEXUS_ENVIRONMENT_ENABLED") {
    Some(value) => {
      let text = value.trim().to_lower()
      !(text == "false" || text == "0" || text == "off" || text == "no")
    }
    None => true
  }
}

///|
fn environment_disabled_error() -> @contracts.RpcError {
  environment_rpc_error(
    @contracts.ENVIRONMENT_ERR_UNSUPPORTED,
    "environment feature is disabled (MONEXUS_ENVIRONMENT_ENABLED=false)",
  )
}

///|
async fn environment_local_home(state : HostState) -> String {
  match @env.get_env_var("HOME") {
    Some(value) if @recipes.is_valid_host_path(value) => value
    _ => state.state_dir
  }
}

///|
async fn environment_runner_for_machine(
  state : HostState,
  machine_id : String,
) -> Result[@environment.DockerRunner, @contracts.RpcError] {
  if machine_id == "" {
    return Ok(
      @environment.local_runner(
        machine_id="",
        home=environment_local_home(state),
      ),
    )
  }
  state.mutex.acquire()
  let loaded = state.store.get_machine(machine_id)
  state.mutex.release()
  let record = match loaded {
    Ok(Some(value)) => value
    Ok(None) =>
      return Err(
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_NOT_FOUND,
          "machine not found",
        ),
      )
    Err(message) =>
      return Err(
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_INVALID,
          "cannot read machine",
          detail=message,
        ),
      )
  }
  if record.kind == @contracts.MACHINE_KIND_LOCAL {
    return Ok(
      @environment.local_runner(
        machine_id=record.id,
        home=environment_local_home(state),
      ),
    )
  }
  match
    @environment.ssh_runner(machine_id=record.id, machine_target(record)) {
    Ok(value) => Ok(value)
    Err(error) => Err(environment_failure_error(error))
  }
}

///|
fn environment_identity_of_record(
  record : @contracts.EnvironmentRecord,
) -> Result[@docker.EnvironmentIdentity, @contracts.RpcError] {
  match
    @docker.EnvironmentIdentity::new(
      environment_id=record.id,
      primary_id=@contracts.ORG_LOCAL,
      workspace_id=record.workspace_id,
      recipe_hash=record.recipe_hash,
    ) {
    Ok(value) => Ok(value)
    Err(error) =>
      Err(
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_INVALID,
          "environment record is not a valid identity",
          detail=error.reason(),
        ),
      )
  }
}

///|
/// `~/.monexus/environments/<environment_id>/` on the executing machine.
/// Derived only from the id, never from caller input.
fn environment_dir(
  runner : @environment.DockerRunner,
  environment_id : String,
) -> String {
  runner.home + "/.monexus/environments/" + environment_id
}

///|
/// The derived scratch directory: workspace root + suffix + environment id.
/// Recovered from the recorded workspace mount so a destroy after a restart
/// removes exactly what create made.
fn environment_scratch_dir(record : @contracts.EnvironmentRecord) -> String {
  let mut workspace_root = ""
  for mount in record.mounts {
    if mount.source == "workspace" {
      workspace_root = mount.host_path
    }
  }
  if workspace_root == "" {
    return ""
  }
  workspace_root + @environment.DEFAULT_SCRATCH_SUFFIX + record.id
}

///|
fn environment_payload(record : @contracts.EnvironmentRecord) -> @json.Json {
  @contracts.json_object([("environment", record.to_json())])
}

///|
fn environment_destroyed_payload(
  record : @contracts.EnvironmentRecord,
) -> @json.Json {
  @contracts.json_object([
    ("environment_id", @contracts.json_string(record.id)),
    ("environment", record.to_json()),
  ])
}

///|
fn recipe_payload(record : @contracts.RecipeRecord) -> @json.Json {
  @contracts.json_object([("recipe", record.to_json())])
}

// ---------------------------------------------------------------------------
// Recipe loading and re-verification
// ---------------------------------------------------------------------------

///|
async fn find_recipe_record(
  state : HostState,
  recipe_ref : String,
) -> Result[Option[@contracts.RecipeRecord], @contracts.RpcError] {
  let (name, version) = match @recipes.parse_recipe_identity(recipe_ref) {
    Some(value) => value
    None =>
      return Err(
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_INVALID,
          "recipe reference must be name@version",
          detail=recipe_ref,
        ),
      )
  }
  state.mutex.acquire()
  let loaded = state.store.get_recipe_by_identity(name, version)
  state.mutex.release()
  match loaded {
    Ok(value) => Ok(value)
    Err(message) =>
      Err(
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_INVALID,
          "cannot read recipe",
          detail=message,
        ),
      )
  }
}

///|
async fn load_recipe_stored(
  state : HostState,
  recipe_ref : String,
) -> Result[@contracts.RecipeRecord, @contracts.RpcError] {
  let record = match find_recipe_record(state, recipe_ref) {
    Ok(Some(value)) => value
    Ok(None) =>
      return Err(
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_UNTRUSTED_RECIPE,
          "recipe is not imported or trusted",
          detail=recipe_ref,
        ),
      )
    Err(error) => return Err(error)
  }
  if record.state != @contracts.RECIPE_STATE_TRUSTED || record.revoked_at != "" {
    return Err(
      environment_rpc_error(
        @contracts.ENVIRONMENT_ERR_UNTRUSTED_RECIPE,
        "recipe is revoked",
        detail=recipe_ref,
      ),
    )
  }
  Ok(record)
}

///|
/// Re-verify canonical bytes, stored hash and signature against the owner
/// trust store before any use (ADR-0013 §2.3, "用前复验"). No TOFU.
async fn verify_recipe_record(
  state : HostState,
  record : @contracts.RecipeRecord,
) -> Result[@recipes.Recipe, @contracts.RpcError] {
  let verified = match
    @recipes.reverify_stored(
      record.canonical,
      record.content_hash,
      record.key_id,
      record.signature,
      state.trust,
      state.verifier,
    ) {
    Ok(value) => value
    Err(error) =>
      return Err(
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_UNTRUSTED_RECIPE,
          "recipe signature re-verification failed",
          detail=error.to_string(),
        ),
      )
  }
  let recipe = match
    @recipes.parse_stored_recipe(
      verified.canonical,
      record.key_id,
      record.signature,
    ) {
    Ok(value) => value
    Err(error) =>
      return Err(
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_UNTRUSTED_RECIPE,
          "stored recipe canonical bytes are invalid",
          detail=error.to_string(),
        ),
      )
  }
  Ok(recipe)
}

// ---------------------------------------------------------------------------
// Approval decisions
// ---------------------------------------------------------------------------

///|
fn environment_approval_options() -> Array[@contracts.DecisionOption] {
  [
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
  ]
}

///|
fn approval_required_error(
  decision_id : String,
  expires_at : String,
  plan_digest : String,
  environment_id : String,
) -> @contracts.RpcError {
  @contracts.RpcError::new(
    @contracts.ERR_HOST,
    @contracts.ENVIRONMENT_ERR_APPROVAL_REQUIRED +
    ": owner approval is required (decision " + decision_id + ")",
    data=@contracts.json_object([
      (
        "kind",
        @contracts.json_string(@contracts.ENVIRONMENT_ERR_APPROVAL_REQUIRED),
      ),
      ("decision_id", @contracts.json_string(decision_id)),
      ("expires_at", @contracts.json_string(expires_at)),
      ("plan_digest", @contracts.json_string(plan_digest)),
      ("environment_id", @contracts.json_string(environment_id)),
    ]),
  )
}

///|
async fn find_pending_environment_approval(
  state : HostState,
  action : String,
  plan_digest : String,
  machine_id : String,
  recipe_hash : String,
) -> Option[@contracts.DecisionRecord] {
  state.mutex.acquire()
  let decisions = match
    state.store.list_decisions(@contracts.DECISION_STATUS_PENDING, "") {
    Ok(value) => value
    Err(_) => []
  }
  state.mutex.release()
  for decision in decisions {
    if decision.kind == @contracts.DECISION_KIND_ENVIRONMENT_APPROVAL &&
      decision.action == action &&
      decision.plan_digest == plan_digest &&
      decision.machine_id == machine_id &&
      decision.recipe_hash == recipe_hash {
      return Some(decision)
    }
  }
  None
}

///|
async fn request_environment_approval(
  state : HostState,
  action : String,
  plan_digest : String,
  machine_id : String,
  recipe_hash : String,
  recipe_ref : String,
  risk : String,
  detail : String,
) -> Result[@contracts.DecisionRecord, @contracts.RpcError] {
  match
    find_pending_environment_approval(
      state,
      action,
      plan_digest,
      machine_id,
      recipe_hash,
    ) {
    Some(existing) => return Ok(existing)
    None => ()
  }
  let now = @async.now()
  let expires_at = @contracts.format_rfc3339(
    now + @contracts.ENVIRONMENT_APPROVAL_TTL_S.to_int64() * 1_000L,
  )
  let nonce = random_token()
  let created_at = @contracts.format_rfc3339(now)
  let base = @contracts.DecisionRecord::new(
    id=@contracts.new_id("dec", now),
    kind=@contracts.DECISION_KIND_ENVIRONMENT_APPROVAL,
    title="Approval needed: environment " + recipe_ref,
    detail="Action: " + action + "\nMachine: " + machine_id +
    "\nRecipe: " + recipe_ref + "\nRecipe hash: " + recipe_hash +
    "\nPlan digest: " + plan_digest + "\nRisk: " + risk +
    "\nNonce: " + nonce + "\nExpires: " + expires_at + "\n" + detail,
    session_id="",
    agent_id="",
    options=environment_approval_options(),
    created_at~,
  )
  let record = base.with_environment_approval(
    action~,
    plan_digest~,
    machine_id~,
    recipe_hash~,
    nonce~,
    expires_at~,
  )
  state.mutex.acquire()
  let appended = state.append_decision_event(
    @contracts.EVENT_DECISION_REQUESTED,
    record.id,
    @contracts.decision_payload(record),
    record,
  )
  state.mutex.release()
  match appended {
    Ok(_) => ()
    Err(message) =>
      return Err(
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_INTERNAL,
          "cannot persist the environment approval decision",
          detail=message,
        ),
      )
  }
  audit(
    state,
    "environment.approval",
    "host",
    "environment/pending",
    "ask",
    policy=@contracts.POLICY_ASK,
    risk~,
    detail="decision " + record.id + ": " + action + " " + plan_digest,
    decision_id=record.id,
  )
  Ok(record)
}

///|
/// Record the one-time consumption of a grant. This is a durable transition:
/// if the append fails, the caller must stop before any pull/create. A
/// consumption that could not be persisted is audited as `failed`, never as
/// `consumed`, and the approval is not silently treated as burned.
async fn consume_environment_approval(
  state : HostState,
  decision : @contracts.DecisionRecord,
) -> Result[Unit, @contracts.RpcError] {
  let timestamp = @contracts.format_rfc3339(@async.now())
  let updated = { ..decision, consumed_at: timestamp }
  let appended = if state.test_fail_approval_consumption.val {
    Err("simulated approval consumption append failure")
  } else {
    state.mutex.acquire()
    let result = state.append_decision_event(
      @contracts.EVENT_DECISION_CONSUMED,
      decision.id,
      @contracts.decision_payload(updated),
      updated,
    )
    state.mutex.release()
    result
  }
  match appended {
    Ok(_) => {
      audit(
        state,
        "environment.approval.consume",
        "host",
        "decision/" + decision.id,
        "consumed",
        policy=@contracts.POLICY_ASK,
        detail=decision.action + " " + decision.plan_digest,
        decision_id=decision.id,
      )
      Ok(())
    }
    Err(message) => {
      audit(
        state,
        "environment.approval.consume",
        "host",
        "decision/" + decision.id,
        "failed",
        policy=@contracts.POLICY_ASK,
        detail="cannot persist approval consumption: " + message,
        decision_id=decision.id,
      )
      Err(
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_INTERNAL,
          "cannot persist approval consumption; no docker action was attempted",
          detail=message,
        ),
      )
    }
  }
}

///|
/// Load and validate an approval without consuming it. The grant is burned
/// only after the target-conflict check and lease acquisition succeed, so a
/// losing create can never spend the owner's approval.
async fn validate_environment_approval(
  state : HostState,
  approval_id : String,
  action : String,
  plan_digest : String,
  machine_id : String,
  recipe_hash : String,
) -> Result[@contracts.DecisionRecord, @contracts.RpcError] {
  state.mutex.acquire()
  let loaded = state.store.get_decision(approval_id)
  state.mutex.release()
  let decision = match loaded {
    Ok(Some(value)) => value
    Ok(None) =>
      return Err(
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_APPROVAL_REQUIRED,
          "approval decision not found",
          detail=approval_id,
        ),
      )
    Err(message) =>
      return Err(
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_INVALID,
          "cannot read approval decision",
          detail=message,
        ),
      )
  }
  let now_text = @contracts.format_rfc3339(@async.now())
  match
    @contracts.environment_approval_check(
      decision,
      action,
      plan_digest,
      machine_id,
      recipe_hash,
      now_text,
    ) {
    Ok(_) => ()
    Err(message) => {
      audit(
        state,
        "environment.approval.reject",
        "host",
        "decision/" + decision.id,
        "denied",
        policy=@contracts.POLICY_ASK,
        detail=message,
        decision_id=decision.id,
      )
      return Err(
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_APPROVAL_REQUIRED,
          "approval rejected: " + message,
          detail=decision.id,
        ),
      )
    }
  }
  Ok(decision)
}

///|
async fn validate_and_consume_approval(
  state : HostState,
  approval_id : String,
  action : String,
  plan_digest : String,
  machine_id : String,
  recipe_hash : String,
) -> Result[@contracts.DecisionRecord, @contracts.RpcError] {
  let decision = match
    validate_environment_approval(
      state,
      approval_id,
      action,
      plan_digest,
      machine_id,
      recipe_hash,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match consume_environment_approval(state, decision) {
    Ok(_) => Ok(decision)
    Err(error) => Err(error)
  }
}

// ---------------------------------------------------------------------------
// Leases
// ---------------------------------------------------------------------------

///|
fn environment_lease_holder(environment_id : String) -> String {
  "environment:" + environment_id
}

///|
async fn acquire_environment_lease(
  state : HostState,
  environment_id : String,
  target_kind : String,
  target_id : String,
) -> Result[Unit, @contracts.RpcError] {
  state.mutex.acquire()
  let existing = state.store.find_lease(target_kind, target_id)
  state.mutex.release()
  match existing {
    Ok(Some(_)) =>
      return Err(
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_CONFLICT,
          "target already has an active lease",
        ),
      )
    Err(message) =>
      return Err(
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_INVALID,
          "cannot read lease",
          detail=message,
        ),
      )
    Ok(None) => ()
  }
  let now = @async.now()
  let lease : @contracts.LeaseRecord = {
    id: @contracts.new_id("lse", now),
    target_kind,
    target_id,
    holder: environment_lease_holder(environment_id),
    created_at: @contracts.format_rfc3339(now),
  }
  state.mutex.acquire()
  let appended = state.append_lease_event(
    @contracts.EVENT_LEASE_ACQUIRED,
    lease.id,
    @contracts.lease_event_payload(lease),
    Some(lease),
    None,
  )
  state.mutex.release()
  match appended {
    Ok(_) => Ok(())
    Err(message) =>
      Err(
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_INTERNAL,
          "cannot record environment lease",
          detail=message,
        ),
      )
  }
}

///|
async fn release_environment_lease(
  state : HostState,
  environment_id : String,
) -> Unit {
  state.mutex.acquire()
  let leases = match state.store.list_leases() {
    Ok(value) => value
    Err(_) => []
  }
  let holder = environment_lease_holder(environment_id)
  let owned : Array[String] = []
  for lease in leases {
    if lease.holder == holder {
      owned.push(lease.id)
    }
  }
  for lease_id in owned {
    let _ = state.append_lease_event(
      @contracts.EVENT_LEASE_RELEASED,
      lease_id,
      @contracts.lease_released_payload(lease_id),
      None,
      Some(lease_id),
    )
  }
  state.mutex.release()
}

// ---------------------------------------------------------------------------
// Cleanup artifact
// ---------------------------------------------------------------------------

///|
async fn write_environment_cleanup_artifact(
  state : HostState,
  environment_id : String,
  log : String,
) -> String {
  let dir = state.state_dir + "/artifacts"
  @fs.mkdir(dir, permission=0o700, recursive=true, allow_exist=true) catch {
    _ => ()
  }
  let path = dir + "/environment-" + environment_id + "-cleanup.log"
  let text = @contracts.redact_secrets(log)
  @fs.write_file(path, text, permission=0o600) catch {
    error => {
      println("monexus-host: cannot write cleanup log: " + error.to_string())
      return ""
    }
  }
  let now = @async.now()
  let artifact = @contracts.ArtifactRecord::new(
    id=@contracts.new_id("art", now),
    session_id="",
    kind=@contracts.ENVIRONMENT_ARTIFACT_CLEANUP_LOG,
    uri=path,
    digest=content_digest(text),
    size=text.length(),
    media_type="text/plain",
    created_at=@contracts.format_rfc3339(now),
  )
  state.mutex.acquire()
  let recorded = state.append_artifact_event(
    @contracts.EVENT_ARTIFACT_CREATED,
    artifact.id,
    @contracts.artifact_payload(artifact),
    artifact,
  )
  state.mutex.release()
  match recorded {
    Ok(_) => path
    Err(message) => {
      println("monexus-host: cannot record cleanup artifact: " + message)
      path
    }
  }
}

// ---------------------------------------------------------------------------
// Lookup helpers
// ---------------------------------------------------------------------------

///|
async fn environment_record_by_id(
  state : HostState,
  environment_id : String,
) -> Result[Option[@contracts.EnvironmentRecord], @contracts.RpcError] {
  state.mutex.acquire()
  let loaded = state.store.get_environment_any(environment_id)
  state.mutex.release()
  match loaded {
    Ok(value) => Ok(value)
    Err(message) =>
      Err(
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_INVALID,
          "cannot read environment",
          detail=message,
        ),
      )
  }
}

///|
/// The active environment for one exact workspace/worktree target. Only a
/// `running` environment redirects execution.
async fn active_environment_for_target(
  state : HostState,
  workspace_id : String,
  worktree_id : String,
) -> Option[@contracts.EnvironmentRecord] {
  state.mutex.acquire()
  let found = state.store.find_environment_for_target(workspace_id, worktree_id)
  state.mutex.release()
  match found {
    Ok(Some(record)) =>
      if record.state == @contracts.ENVIRONMENT_STATE_RUNNING {
        Some(record)
      } else {
        None
      }
    _ => None
  }
}

///|
async fn active_environment_for_workspace_root(
  state : HostState,
  workspace_id : String,
) -> Option[@contracts.EnvironmentRecord] {
  active_environment_for_target(state, workspace_id, "")
}

///|
async fn environment_target_root(
  state : HostState,
  workspace : @contracts.WorkspaceRecord,
  worktree_id : String,
) -> Result[String, @contracts.RpcError] {
  if worktree_id == "" {
    return Ok(workspace.root)
  }
  let worktree = match lookup_worktree(state, worktree_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if worktree.workspace_id != workspace.id {
    return Err(
      environment_rpc_error(
        @contracts.ENVIRONMENT_ERR_INVALID,
        "worktree does not belong to the workspace",
      ),
    )
  }
  Ok(worktree.path)
}

///|
/// Secrets only ever enter through the env-file. A top-level secret-looking
/// field is refused instead of being recorded or logged.
async fn reject_inline_secret_fields(
  params : Map[String, @json.Json],
) -> Result[Unit, @contracts.RpcError] {
  for name, _ in params {
    if @contracts.is_secret_key_name(name) {
      return Err(
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_SECRET_REJECTED,
          "inline secret fields are not accepted; use environment values",
          detail=name,
        ),
      )
    }
  }
  Ok(())
}

// ---------------------------------------------------------------------------
// Create
// ---------------------------------------------------------------------------

///|
/// Persist the terminal failure of a create attempt. The caller decides
/// `cleanup_ok`; a false value (or an unreachable daemon) keeps the target
/// lease and reports `orphan_suspected`, never a fake success.
async fn settle_create_failure(
  state : HostState,
  intent : @contracts.EnvironmentRecord,
  failure : @environment.EnvFailure,
  cleanup_ok : Bool,
  cleanup_log : String,
  target_id : String,
) -> @contracts.RpcError {
  let cleanup_ref = write_environment_cleanup_artifact(
    state,
    intent.id,
    cleanup_log,
  )
  let daemon_unreachable = failure.code ==
    @contracts.ENVIRONMENT_ERR_DOCKER_UNAVAILABLE ||
    failure.code == @contracts.ENVIRONMENT_ERR_UNREACHABLE ||
    failure.code == @contracts.ENVIRONMENT_ERR_ORPHAN_SUSPECTED
  let orphan = daemon_unreachable || !cleanup_ok
  let finished = @contracts.format_rfc3339(@async.now())
  let failed : @contracts.EnvironmentRecord = {
    ..intent,
    state: if orphan {
      @contracts.ENVIRONMENT_STATE_ORPHAN_SUSPECTED
    } else {
      @contracts.ENVIRONMENT_STATE_FAILED
    },
    updated_at: finished,
    last_error: failure.to_string(),
    cleanup_ok,
    cleanup_detail: cleanup_ref,
  }
  state.mutex.acquire()
  let recorded = state.append_environment_event(
    if orphan {
      @contracts.EVENT_ENVIRONMENT_ORPHAN_SUSPECTED
    } else {
      @contracts.EVENT_ENVIRONMENT_FAILED
    },
    intent.id,
    environment_payload(failed),
    Some(failed),
    None,
  )
  state.mutex.release()
  match recorded {
    Ok(_) => ()
    Err(message) =>
      println("monexus-host: cannot record environment failure: " + message)
  }
  if !orphan {
    release_environment_lease(state, intent.id)
  }
  audit(
    state,
    "environment.create",
    "host",
    "environment/" + intent.id,
    if orphan { "orphan_suspected" } else { "failed" },
    target=target_id,
    policy=@contracts.POLICY_ALLOW,
    risk=intent.risk,
    detail=failure.to_string() + "\ncleanup: " + cleanup_ref,
  )
  environment_rpc_error(
    if orphan {
      @contracts.ENVIRONMENT_ERR_ORPHAN_SUSPECTED
    } else {
      failure.code
    },
    if orphan {
      "create did not complete cleanly; container " + running_name(intent.id) +
      " may still exist (run environment.doctor; never run docker system prune)"
    } else {
      failure.message
    },
    detail=if cleanup_ref == "" { cleanup_log } else { cleanup_ref },
  )
}

///|
/// Adopt a same-named container only when the observed labels, mounts,
/// network, user, environment names and reported limits all match the plan.
/// The env file is removed before returning because it has served its purpose.
async fn adopt_existing_environment(
  state : HostState,
  intent : @contracts.EnvironmentRecord,
  runner : @environment.DockerRunner,
  plan : @environment.EnvironmentPlan,
  existing : @docker.ContainerInspect,
  recipe_record : @contracts.RecipeRecord,
  target_id : String,
) -> Result[@contracts.EnvironmentRecord, @contracts.RpcError] {
  match (runner.remove_file)(plan.env_dir + "/env") {
    Ok(_) => ()
    Err(error) => {
      return Err(
        settle_create_failure(
          state,
          intent,
          @environment.EnvFailure::new(
            @contracts.ENVIRONMENT_ERR_CLEANUP_FAILED,
            "cannot remove the env file after adopting the container",
          ).with_detail(error.to_string()),
          false,
          error.to_string(),
          target_id,
        ),
      )
    }
  }
  let timestamp = @contracts.format_rfc3339(@async.now())
  let adopted : @contracts.EnvironmentRecord = {
    ..intent,
    state: if existing.running {
      @contracts.ENVIRONMENT_STATE_RUNNING
    } else {
      @contracts.ENVIRONMENT_STATE_STOPPED
    },
    started_at: if existing.running { timestamp } else { intent.started_at },
    stopped_at: if existing.running { intent.stopped_at } else { timestamp },
    updated_at: timestamp,
    cleanup_ok: true,
    cleanup_detail: "",
  }
  state.mutex.acquire()
  let recorded = state.append_environment_event(
    @contracts.EVENT_ENVIRONMENT_CREATED,
    intent.id,
    environment_payload(adopted),
    Some(adopted),
    None,
  )
  let used = state.append_recipe_event(
    @contracts.EVENT_RECIPE_USED,
    recipe_record.id,
    recipe_payload(recipe_record),
    Some(recipe_record),
    false,
  )
  state.mutex.release()
  match recorded {
    Ok(_) => ()
    Err(message) =>
      println("monexus-host: cannot record environment adoption: " + message)
  }
  match used {
    Ok(_) => ()
    Err(message) => println("monexus-host: cannot record recipe.used: " + message)
  }
  audit(
    state,
    "environment.create",
    "host",
    "environment/" + intent.id,
    "adopted",
    target=target_id,
    policy=@contracts.POLICY_ALLOW,
    risk=plan.risk,
    detail="labels and plan matched; container " + adopted.container_name +
    " was adopted",
  )
  let report = @environment.doctor_container(
    runner,
    adopted,
    plan.identity,
    Some(plan.recipe),
    timestamp,
  )
  audit(
    state,
    "environment.create",
    "host",
    "environment/" + intent.id,
    if report.healthy { "adopted_healthy" } else { "adopted_unhealthy" },
    target=target_id,
    policy=@contracts.POLICY_ALLOW,
    risk=plan.risk,
    detail=report.guidance,
  )
  Ok(adopted)
}

///|
/// Serialize the part of create that has no docker side effects: one active
/// environment per target, the target lease, the one-time approval burn, and
/// the durable `creating` intent. The approval is consumed only after the
/// conflict check and lease succeed, so a losing request never spends it. On
/// any failure after the lease is taken, the lease is released and no intent
/// remains. The in-process-create marker is written in the same mutex section
/// as the intent event, so reconcile never sees a live create as a stale one.
async fn reserve_environment_creation(
  state : HostState,
  intent : @contracts.EnvironmentRecord,
  target_kind : String,
  target_id : String,
  approval : @contracts.DecisionRecord?,
) -> Result[@contracts.EnvironmentRecord, @contracts.RpcError] {
  state.mutex.acquire()
  let active = state.store.find_environment_for_target(
    intent.workspace_id,
    intent.worktree_id,
  )
  state.mutex.release()
  match active {
    Ok(Some(record)) =>
      if record.state == @contracts.ENVIRONMENT_STATE_CREATING ||
        record.state == @contracts.ENVIRONMENT_STATE_RUNNING ||
        record.state == @contracts.ENVIRONMENT_STATE_STOPPED ||
        record.state == @contracts.ENVIRONMENT_STATE_ORPHAN_SUSPECTED {
        return Err(
          environment_rpc_error(
            @contracts.ENVIRONMENT_ERR_CONFLICT,
            "target already has an active environment",
            detail=record.id,
          ),
        )
      }
    _ => ()
  }
  match
    acquire_environment_lease(state, intent.id, target_kind, target_id) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  match approval {
    Some(decision) =>
      match consume_environment_approval(state, decision) {
        Ok(_) => ()
        Err(error) => {
          // Fail closed before any docker action, and do not leave a lease
          // that would block a correctly-ordered retry.
          release_environment_lease(state, intent.id)
          return Err(error)
        }
      }
    None => ()
  }
  // The `creating` intent is durable BEFORE any docker change. A crash after
  // this point is repaired by reconcile, never by guessing.
  state.mutex.acquire()
  let appended = state.append_environment_event(
    @contracts.EVENT_ENVIRONMENT_CREATING,
    intent.id,
    environment_payload(intent),
    Some(intent),
    None,
  )
  match appended {
    Ok(_) => state.env_create_started.set(intent.id, @async.now())
    Err(_) => state.env_create_started.remove(intent.id)
  }
  state.mutex.release()
  match appended {
    Ok(_) => Ok(intent)
    Err(message) => {
      release_environment_lease(state, intent.id)
      Err(
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_INTERNAL,
          "cannot persist the create intent",
          detail=message,
        ),
      )
    }
  }
}

///|
async fn create_environment_locked(
  state : HostState,
  request : @contracts.RpcRequest,
) -> Result[@contracts.EnvironmentRecord, @contracts.RpcError] {
  if !environment_feature_enabled() {
    return Err(environment_disabled_error())
  }
  match reject_inline_secret_fields(request.params) {
    Ok(_) => ()
    Err(error) => return Err(error)
  }
  let spec = match @contracts.environment_spec_from_params(request.params) {
    Ok(value) => value
    Err(message) =>
      return Err(
        environment_rpc_error(@contracts.ENVIRONMENT_ERR_INVALID, message),
      )
  }
  // Repeated `client_request_id` returns the same record and never creates a
  // second container.
  if spec.client_request_id != "" {
    state.mutex.acquire()
    let existing = state.store.find_environment_by_request(spec.client_request_id)
    state.mutex.release()
    match existing {
      Ok(Some(record)) => return Ok(record)
      _ => ()
    }
  }
  // An explicit id returned with an approval request (or echoed by a retry
  // after a lost response) is never created twice. The id is part of the plan
  // digest, so the approval grant only matches the same id.
  if spec.environment_id != "" {
    if !@docker.is_valid_runtime_id(spec.environment_id) {
      return Err(
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_INVALID,
          "environment_id is not a valid runtime id",
        ),
      )
    }
    let existing = match environment_record_by_id(state, spec.environment_id) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    match existing {
      Some(record) => {
        let mismatch = record.workspace_id != spec.workspace_id ||
          record.worktree_id != spec.worktree_id ||
          record.recipe != spec.recipe ||
          (spec.machine_id != "" && record.machine_id != spec.machine_id)
        if mismatch {
          return Err(
            environment_rpc_error(
              @contracts.ENVIRONMENT_ERR_CONFLICT,
              "environment id is already bound to a different request",
              detail=record.id,
            ),
          )
        }
        return Ok(record)
      }
      None => ()
    }
  }
  let workspace = match lookup_workspace(state, spec.workspace_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let machine_id = if spec.machine_id == "" {
    workspace.machine_id
  } else {
    spec.machine_id
  }
  if workspace.machine_id != "" && machine_id != workspace.machine_id {
    return Err(
      environment_rpc_error(
        @contracts.ENVIRONMENT_ERR_CONFLICT,
        "environment machine must match the workspace machine",
        detail="workspace machine " + workspace.machine_id,
      ),
    )
  }
  let target_root = match
    environment_target_root(state, workspace, spec.worktree_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let recipe_record = match load_recipe_stored(state, spec.recipe) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let recipe = match verify_recipe_record(state, recipe_record) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let runner = match environment_runner_for_machine(state, machine_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let now = @async.now()
  let environment_id = if spec.environment_id == "" {
    @contracts.new_id("env", now)
  } else {
    spec.environment_id
  }
  let timestamp = @contracts.format_rfc3339(now)
  let inputs : @environment.PlanInputs = {
    environment_id,
    workspace_id: spec.workspace_id,
    worktree_id: spec.worktree_id,
    machine_id,
    primary_id: @contracts.ORG_LOCAL,
    workspace_root: target_root,
    scratch_root: target_root + @environment.DEFAULT_SCRATCH_SUFFIX +
    environment_id,
    env_values: spec.env_values,
    extra_mounts: spec.extra_mounts,
  }
  let plan = match
    @environment.compute_environment_plan(
      recipe,
      recipe_record.content_hash,
      inputs,
      runner.home,
    ) {
    Ok(value) => value
    Err(error) => return Err(environment_failure_error(error))
  }
  // Approval: a required plan cannot pull or create until an answered,
  // unexpired, unconsumed Decision matches this exact plan. The plan digest
  // carries the environment id, so the retry must echo the same id. The grant
  // is validated here but not burned: `reserve_environment_creation` consumes
  // it only after the conflict check and lease acquisition succeed.
  let mut approval_id = spec.approval_id
  let mut approval_decision : @contracts.DecisionRecord? = None
  if plan.requires_approval || spec.approval_id != "" {
    if spec.approval_id == "" {
      let mut mounts_text = ""
      for mount in plan.mounts {
        mounts_text = mounts_text + "\n" + mount.source + " " +
          mount.host_path + " -> " + mount.container_path + " (" +
          mount.mode + ")"
      }
      let detail = "Env names: " + plan.env_names.join(",") +
        "\nWorkdir: " + plan.workdir + "\nNetwork: " + plan.network +
        "\nMounts:" + mounts_text
      let decision = match
        request_environment_approval(
          state,
          @contracts.ENVIRONMENT_APPROVAL_ACTION_CREATE,
          plan.plan_digest,
          machine_id,
          recipe_record.content_hash,
          spec.recipe,
          plan.risk,
          detail,
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      return Err(
        approval_required_error(
          decision.id,
          decision.expires_at,
          plan.plan_digest,
          environment_id,
        ),
      )
    }
    let decision = match
      validate_environment_approval(
        state,
        spec.approval_id,
        @contracts.ENVIRONMENT_APPROVAL_ACTION_CREATE,
        plan.plan_digest,
        machine_id,
        recipe_record.content_hash,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    approval_id = decision.id
    approval_decision = Some(decision)
  }
  let target_kind = if spec.worktree_id == "" { "workspace" } else { "worktree" }
  let target_id = if spec.worktree_id == "" {
    spec.workspace_id
  } else {
    spec.worktree_id
  }
  let intent : @contracts.EnvironmentRecord = {
    id: environment_id,
    workspace_id: spec.workspace_id,
    worktree_id: spec.worktree_id,
    machine_id,
    backend: @contracts.ENVIRONMENT_BACKEND_DOCKER,
    recipe: spec.recipe,
    recipe_hash: recipe_record.content_hash,
    container_name: @docker.container_name(plan.identity),
    state: @contracts.ENVIRONMENT_STATE_CREATING,
    plan_digest: plan.plan_digest,
    workdir: plan.workdir,
    user: plan.user,
    network: plan.network,
    mounts: plan.mounts,
    env_names: plan.env_names,
    risk: plan.risk,
    approval_id,
    ephemeral: spec.ephemeral,
    ttl_s: spec.ttl_s,
    client_request_id: spec.client_request_id,
    created_at: timestamp,
    updated_at: timestamp,
    started_at: "",
    stopped_at: "",
    last_error: "",
    cleanup_ok: true,
    cleanup_detail: "",
  }
  // The conflict check, the lease, the one-time approval burn and the durable
  // `creating` intent all happen before any docker call. The intent append and
  // the in-process-create marker are set under one mutex so reconcile can
  // never observe one without the other.
  let reserved = match
    reserve_environment_creation(
      state,
      intent,
      target_kind,
      target_id,
      approval_decision,
    ) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  ignore(reserved)
  audit(
    state,
    "environment.create",
    "host",
    "environment/" + environment_id,
    "started",
    target=target_id,
    policy=@contracts.POLICY_ALLOW,
    risk=plan.risk,
    detail="recipe " + spec.recipe + " plan " + plan.plan_digest,
  )
  // A same-named container may exist from a crash. Inspect before any docker
  // mutation: adopt only an exact plan match; otherwise report `conflict` and
  // leave the unowned container untouched. An inspect failure must not lead to
  // reverse cleanup, because the container's ownership cannot be proven.
  match @environment.inspect_container(runner, plan.identity) {
    Ok(Some(existing)) => {
      state.mutex.acquire()
      state.env_create_started.remove(environment_id)
      state.mutex.release()
      if @environment.plan_matches_inspect(plan, existing) {
        return adopt_existing_environment(
          state,
          intent,
          runner,
          plan,
          existing,
          recipe_record,
          target_id,
        )
      }
      let conflict = @environment.EnvFailure::new(
        @contracts.ENVIRONMENT_ERR_CONFLICT,
        "container name is held by a container that does not match the plan; left untouched",
      ).with_detail(running_name(environment_id))
      return Err(
        settle_create_failure(
          state,
          intent,
          conflict,
          true,
          "container labels or plan do not match; left untouched",
          target_id,
        ),
      )
    }
    Ok(None) => ()
    Err(error) => {
      state.mutex.acquire()
      state.env_create_started.remove(environment_id)
      state.mutex.release()
      return Err(
        settle_create_failure(
          state,
          intent,
          error,
          false,
          "container ownership could not be verified; no container mutation attempted",
          target_id,
        ),
      )
    }
  }
  let created = @environment.create_container(runner, plan)
  match created {
    Ok(_) => {
      let finished = @contracts.format_rfc3339(@async.now())
      let running : @contracts.EnvironmentRecord = {
        ..intent,
        state: @contracts.ENVIRONMENT_STATE_RUNNING,
        started_at: finished,
        updated_at: finished,
        approval_id,
        cleanup_ok: true,
        cleanup_detail: "",
      }
      state.mutex.acquire()
      let recorded = state.append_environment_event(
        @contracts.EVENT_ENVIRONMENT_CREATED,
        environment_id,
        environment_payload(running),
        Some(running),
        None,
      )
      let used = state.append_recipe_event(
        @contracts.EVENT_RECIPE_USED,
        recipe_record.id,
        recipe_payload(recipe_record),
        Some(recipe_record),
        false,
      )
      // Keep the in-process marker until the terminal event exists, so a
      // concurrent reconcile can never settle a live create as failed or
      // release its lease early.
      state.env_create_started.remove(environment_id)
      state.mutex.release()
      match recorded {
        Ok(_) => ()
        Err(message) =>
          println("monexus-host: cannot record environment.created: " + message)
      }
      match used {
        Ok(_) => ()
        Err(message) =>
          println("monexus-host: cannot record recipe.used: " + message)
      }
      audit(
        state,
        "environment.create",
        "host",
        "environment/" + environment_id,
        "created",
        target=target_id,
        policy=@contracts.POLICY_ALLOW,
        risk=plan.risk,
        detail="container " + running.container_name,
      )
      Ok(running)
    }
    Err(failure) => {
      let settled = settle_create_failure(
        state,
        intent,
        failure.failure,
        failure.cleanup_ok,
        failure.cleanup_log,
        target_id,
      )
      state.mutex.acquire()
      state.env_create_started.remove(environment_id)
      state.mutex.release()
      Err(settled)
    }
  }
}

///|
fn running_name(environment_id : String) -> String {
  "monexus-env-" + environment_id
}

// ---------------------------------------------------------------------------
// Start / stop / destroy
// ---------------------------------------------------------------------------

///|
fn recipe_start_needs_approval(recipe : @recipes.Recipe) -> Bool {
  let hook = match recipe.lifecycle.start.command {
    @recipes.HookArgv(argv) => !argv.is_empty()
    @recipes.HookScript(script) => script.trim() != ""
  }
  hook || recipe.effective_network() is @recipes.NetworkBridge
}

///|
async fn start_environment_locked(
  state : HostState,
  record : @contracts.EnvironmentRecord,
  approval_id : String,
) -> Result[@contracts.EnvironmentRecord, @contracts.RpcError] {
  if !environment_feature_enabled() {
    return Err(environment_disabled_error())
  }
  if record.state == @contracts.ENVIRONMENT_STATE_DESTROYED {
    return Err(
      environment_rpc_error(
        @contracts.ENVIRONMENT_ERR_NOT_FOUND,
        "environment is destroyed",
      ),
    )
  }
  if record.state == @contracts.ENVIRONMENT_STATE_RUNNING {
    return Ok(record)
  }
  if record.state == @contracts.ENVIRONMENT_STATE_CREATING {
    return Err(
      environment_rpc_error(
        @contracts.ENVIRONMENT_ERR_CONFLICT,
        "environment is still being created",
      ),
    )
  }
  let stored = match load_recipe_stored(state, record.recipe) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let recipe = match verify_recipe_record(state, stored) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let identity = match environment_identity_of_record(record) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut used_approval = record.approval_id
  if recipe_start_needs_approval(recipe) || approval_id != "" {
    if approval_id == "" {
      let decision = match
        request_environment_approval(
          state,
          @contracts.ENVIRONMENT_APPROVAL_ACTION_START,
          record.plan_digest,
          record.machine_id,
          record.recipe_hash,
          record.recipe,
          @contracts.RISK_HIGH,
          "Start of " + record.id + " needs a one-time approval",
        ) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      return Err(
        approval_required_error(
          decision.id,
          decision.expires_at,
          record.plan_digest,
          record.id,
        ),
      )
    }
    let decision = match
      validate_and_consume_approval(
        state,
        approval_id,
        @contracts.ENVIRONMENT_APPROVAL_ACTION_START,
        record.plan_digest,
        record.machine_id,
        record.recipe_hash,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    used_approval = decision.id
  }
  let runner = match environment_runner_for_machine(state, record.machine_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match @environment.start_container(runner, record, recipe, identity) {
    Ok(_) => ()
    Err(error) => {
      let timestamp = @contracts.format_rfc3339(@async.now())
      let failed = {
        ..record,
        updated_at: timestamp,
        last_error: error.to_string(),
      }
      state.mutex.acquire()
      let _ = state.append_environment_event(
        @contracts.EVENT_ENVIRONMENT_FAILED,
        record.id,
        environment_payload(failed),
        Some(failed),
        None,
      )
      state.mutex.release()
      audit(
        state,
        "environment.start",
        "host",
        "environment/" + record.id,
        "failed",
        policy=@contracts.POLICY_ALLOW,
        risk=@contracts.RISK_HIGH,
        detail=error.to_string(),
      )
      return Err(environment_failure_error(error))
    }
  }
  let timestamp = @contracts.format_rfc3339(@async.now())
  let started : @contracts.EnvironmentRecord = {
    ..record,
    state: @contracts.ENVIRONMENT_STATE_RUNNING,
    started_at: timestamp,
    updated_at: timestamp,
    last_error: "",
    approval_id: used_approval,
  }
  state.mutex.acquire()
  let recorded = state.append_environment_event(
    @contracts.EVENT_ENVIRONMENT_STARTED,
    record.id,
    environment_payload(started),
    Some(started),
    None,
  )
  state.mutex.release()
  match recorded {
    Ok(_) => ()
    Err(message) =>
      println("monexus-host: cannot record environment.started: " + message)
  }
  audit(
    state,
    "environment.start",
    "host",
    "environment/" + record.id,
    "started",
    policy=@contracts.POLICY_ALLOW,
    risk=@contracts.RISK_HIGH,
    detail=started.container_name,
  )
  Ok(started)
}

///|
/// Cancel every in-flight exec on one environment. A cancelled exec is cached
/// as `cancelled=true`, `exit_code=-1`, so a repeated `exec_id` can never look
/// like a success.
async fn cancel_environment_execs(
  state : HostState,
  environment_id : String,
) -> Unit {
  state.mutex.acquire()
  let keys : Array[String] = []
  for key, entry in state.env_exec_tasks {
    if entry.environment_id == environment_id {
      keys.push(key)
    }
  }
  let tasks : Array[@async.Task[Unit]] = []
  let exec_ids : Array[String] = []
  for key in keys {
    match state.env_exec_tasks.get(key) {
      Some(entry) => {
        tasks.push(entry.task)
        exec_ids.push(entry.exec_id)
      }
      None => exec_ids.push("")
    }
    state.env_exec_tasks.remove(key)
  }
  state.mutex.release()
  for task in tasks {
    task.cancel()
  }
  state.mutex.acquire()
  let mut index = 0
  while index < keys.length() {
    let key = keys[index]
    let exec_id = exec_ids[index]
    if state.env_exec_cache.get(key).is_none() {
      state.env_exec_cache.set(key, cancelled_exec_json(exec_id))
    }
    index = index + 1
  }
  state.mutex.release()
}

///|
async fn stop_environment_locked(
  state : HostState,
  record : @contracts.EnvironmentRecord,
) -> Result[@contracts.EnvironmentRecord, @contracts.RpcError] {
  if record.state == @contracts.ENVIRONMENT_STATE_DESTROYED {
    return Err(
      environment_rpc_error(
        @contracts.ENVIRONMENT_ERR_NOT_FOUND,
        "environment is destroyed",
      ),
    )
  }
  cancel_environment_execs(state, record.id)
  let identity = match environment_identity_of_record(record) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let runner = match environment_runner_for_machine(state, record.machine_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  match @environment.stop_container(runner, identity) {
    Ok(_) => ()
    Err(error) => {
      let timestamp = @contracts.format_rfc3339(@async.now())
      let failed = {
        ..record,
        updated_at: timestamp,
        last_error: error.to_string(),
      }
      state.mutex.acquire()
      let _ = state.append_environment_event(
        @contracts.EVENT_ENVIRONMENT_FAILED,
        record.id,
        environment_payload(failed),
        Some(failed),
        None,
      )
      state.mutex.release()
      audit(
        state,
        "environment.stop",
        "host",
        "environment/" + record.id,
        "failed",
        policy=@contracts.POLICY_ALLOW,
        risk=@contracts.RISK_MEDIUM,
        detail=error.to_string(),
      )
      return Err(environment_failure_error(error))
    }
  }
  let timestamp = @contracts.format_rfc3339(@async.now())
  let stopped : @contracts.EnvironmentRecord = {
    ..record,
    state: @contracts.ENVIRONMENT_STATE_STOPPED,
    stopped_at: timestamp,
    updated_at: timestamp,
    last_error: "",
  }
  state.mutex.acquire()
  let recorded = state.append_environment_event(
    @contracts.EVENT_ENVIRONMENT_STOPPED,
    record.id,
    environment_payload(stopped),
    Some(stopped),
    None,
  )
  state.mutex.release()
  match recorded {
    Ok(_) => ()
    Err(message) =>
      println("monexus-host: cannot record environment.stopped: " + message)
  }
  audit(
    state,
    "environment.stop",
    "host",
    "environment/" + record.id,
    "stopped",
    policy=@contracts.POLICY_ALLOW,
    risk=@contracts.RISK_MEDIUM,
    detail=stopped.container_name,
  )
  Ok(stopped)
}

///|
fn environment_destroy_ack(
  environment_id : String,
  cleanup_ok : Bool,
  detail : String,
) -> @json.Json {
  @contracts.json_object([
    ("environment_id", @contracts.json_string(environment_id)),
    ("state", @contracts.json_string(@contracts.ENVIRONMENT_STATE_DESTROYED)),
    ("cleanup_ok", @contracts.json_bool(cleanup_ok)),
    ("detail", @contracts.json_string(detail)),
  ])
}

///|
/// Remove the container, env-file, env directory, derived scratch directory,
/// and release the target lease. Idempotent when the container is already
/// gone. A cleanup failure surfaces `cleanup_failed` and keeps the record.
async fn destroy_environment_locked(
  state : HostState,
  record : @contracts.EnvironmentRecord,
) -> Result[@json.Json, @contracts.RpcError] {
  if record.state == @contracts.ENVIRONMENT_STATE_DESTROYED {
    return Ok(environment_destroy_ack(record.id, true, ""))
  }
  cancel_environment_execs(state, record.id)
  let identity = match environment_identity_of_record(record) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let runner = match environment_runner_for_machine(state, record.machine_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let outcome = @environment.destroy_container(
    runner,
    identity,
    environment_dir(runner, record.id),
    environment_scratch_dir(record),
  )
  let timestamp = @contracts.format_rfc3339(@async.now())
  if outcome.ok {
    let destroyed : @contracts.EnvironmentRecord = {
      ..record,
      state: @contracts.ENVIRONMENT_STATE_DESTROYED,
      updated_at: timestamp,
      cleanup_ok: true,
      cleanup_detail: "",
      last_error: "",
    }
    state.mutex.acquire()
    let recorded = state.append_environment_event(
      @contracts.EVENT_ENVIRONMENT_DESTROYED,
      record.id,
      environment_destroyed_payload(destroyed),
      Some(destroyed),
      Some(record.id),
    )
    state.mutex.release()
    match recorded {
      Ok(_) => ()
      Err(message) =>
        println("monexus-host: cannot record environment.destroyed: " + message)
    }
    release_environment_lease(state, record.id)
    audit(
      state,
      "environment.destroy",
      "host",
      "environment/" + record.id,
      "destroyed",
      policy=@contracts.POLICY_ALLOW,
      risk=record.risk,
      detail=record.container_name,
    )
    Ok(environment_destroy_ack(record.id, true, ""))
  } else {
    let cleanup_ref = write_environment_cleanup_artifact(
      state,
      record.id,
      outcome.log,
    )
    let failed : @contracts.EnvironmentRecord = {
      ..record,
      state: @contracts.ENVIRONMENT_STATE_ORPHAN_SUSPECTED,
      updated_at: timestamp,
      cleanup_ok: false,
      cleanup_detail: cleanup_ref,
      last_error: "cleanup failed: " + outcome.log,
    }
    state.mutex.acquire()
    let recorded = state.append_environment_event(
      @contracts.EVENT_ENVIRONMENT_ORPHAN_SUSPECTED,
      record.id,
      environment_payload(failed),
      Some(failed),
      None,
    )
    state.mutex.release()
    match recorded {
      Ok(_) => ()
      Err(message) =>
        println("monexus-host: cannot record cleanup failure: " + message)
    }
    audit(
      state,
      "environment.destroy",
      "host",
      "environment/" + record.id,
      "cleanup_failed",
      policy=@contracts.POLICY_ALLOW,
      risk=record.risk,
      detail=outcome.log,
    )
    Err(
      environment_rpc_error(
        @contracts.ENVIRONMENT_ERR_CLEANUP_FAILED,
        "environment cleanup did not complete; run environment.doctor",
        detail=cleanup_ref,
      ),
    )
  }
}

// ---------------------------------------------------------------------------
// Exec
// ---------------------------------------------------------------------------

///|
fn cancelled_exec_json(exec_id : String) -> @json.Json {
  @contracts.environment_exec_result(
    exec_id,
    -1,
    "",
    "cancelled",
    false,
    true,
    false,
  )
}

///|
fn exec_error_json(error : @environment.EnvFailure) -> @json.Json {
  @contracts.json_object([
    (
      "__exec_error",
      @contracts.environment_error(
        error.code,
        error.message,
        detail=error.detail,
      ),
    ),
  ])
}

///|
async fn run_exec_task(
  state : HostState,
  key : String,
  exec_id : String,
  runner : @environment.DockerRunner,
  identity : @docker.EnvironmentIdentity,
  argv : Array[String],
  workdir : String,
  timeout_s : Int,
) -> Unit {
  let result = match
    @environment.exec_in_container(
      runner,
      identity,
      argv,
      workdir,
      timeout_s,
      exec_id~,
    ) {
    Ok(output) => {
      let raw_stdout = @contracts.redact_secrets(output.stdout)
      let raw_stderr = @contracts.redact_secrets(output.stderr)
      let truncated = raw_stdout.length() > ENVIRONMENT_EXEC_STREAM_CAP ||
        raw_stderr.length() > ENVIRONMENT_EXEC_STREAM_CAP
      @contracts.environment_exec_result(
        exec_id,
        output.exit_code,
        truncate_output(raw_stdout, ENVIRONMENT_EXEC_STREAM_CAP),
        truncate_output(raw_stderr, ENVIRONMENT_EXEC_STREAM_CAP),
        output.timed_out,
        false,
        truncated,
      )
    }
    Err(error) => exec_error_json(error)
  }
  state.mutex.acquire()
  // Cancellation may have already recorded a non-success result. Never let a
  // late completion overwrite it; a cancelled exec must never report success.
  if state.env_exec_cache.get(key).is_none() {
    state.env_exec_cache.set(key, result)
  }
  state.env_exec_tasks.remove(key)
  state.mutex.release()
}

///|
enum EnvironmentExecSetup {
  ExecCached(@json.Json)
  ExecPending(@async.Task[Unit], String, String)
}

///|
async fn environment_exec_setup_locked(
  state : HostState,
  params : Map[String, @json.Json],
) -> Result[EnvironmentExecSetup, @contracts.RpcError] {
  if !environment_feature_enabled() {
    return Err(environment_disabled_error())
  }
  let environment_id = match @contracts.environment_id_param(params) {
    Ok(value) => value
    Err(message) =>
      return Err(
        environment_rpc_error(@contracts.ENVIRONMENT_ERR_INVALID, message),
      )
  }
  let exec_id = match @contracts.environment_exec_id_param(params) {
    Ok(value) => value
    Err(message) =>
      return Err(
        environment_rpc_error(@contracts.ENVIRONMENT_ERR_INVALID, message),
      )
  }
  let argv = match @contracts.environment_exec_argv_param(params) {
    Ok(value) => value
    Err(message) =>
      return Err(
        environment_rpc_error(@contracts.ENVIRONMENT_ERR_INVALID, message),
      )
  }
  let timeout_s = @contracts.int_field_or(
    params,
    "timeout_s",
    ENVIRONMENT_EXEC_TIMEOUT_S,
  )
  let timeout_s = if timeout_s <= 0 {
    ENVIRONMENT_EXEC_TIMEOUT_S
  } else {
    timeout_s.min(3_600)
  }
  let record = match environment_record_by_id(state, environment_id) {
    Ok(Some(value)) => value
    Ok(None) =>
      return Err(
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_NOT_FOUND,
          "environment not found",
        ),
      )
    Err(error) => return Err(error)
  }
  if record.state != @contracts.ENVIRONMENT_STATE_RUNNING {
    return Err(
      environment_rpc_error(
        @contracts.ENVIRONMENT_ERR_CONFLICT,
        "environment is not running",
        detail=record.state,
      ),
    )
  }
  let identity = match environment_identity_of_record(record) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let key = environment_id + ":" + exec_id
  state.mutex.acquire()
  let cached = state.env_exec_cache.get(key)
  let existing = state.env_exec_tasks.get(key)
  state.mutex.release()
  match cached {
    Some(value) => return Ok(ExecCached(value))
    None => ()
  }
  match existing {
    Some(entry) => return Ok(ExecPending(entry.task, key, exec_id))
    None => ()
  }
  let runner = match environment_runner_for_machine(state, record.machine_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let group = state.group.val
  let task = match group {
    Some(value) =>
      value.spawn(
        allow_failure=true,
        () =>
          run_exec_task(
            state,
            key,
            exec_id,
            runner,
            identity,
            argv,
            record.workdir,
            timeout_s,
          ),
      )
    None =>
      return Err(
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_INTERNAL,
          "host task group is not running",
        ),
      )
  }
  state.mutex.acquire()
  state.env_exec_tasks.set(key, {
    environment_id,
    exec_id,
    task,
  })
  // A very fast exec may finish before this registration; drop the stale
  // entry so the map only tracks in-flight work.
  let finished = task.try_wait() catch { _ => Some(()) }
  if finished.is_some() {
    state.env_exec_tasks.remove(key)
  }
  state.mutex.release()
  Ok(ExecPending(task, key, exec_id))
}

///|
fn exec_result_is_error(result : @json.Json) -> Bool {
  match result {
    @json.Json::Object(object) => object.get("__exec_error").is_some()
    _ => false
  }
}

///|
fn exec_result_error(result : @json.Json) -> @contracts.RpcError {
  match result {
    @json.Json::Object(object) =>
      match object.get("__exec_error") {
        Some(@json.Json::Object(error)) => {
          let kind = @contracts.string_field_or(error, "kind", "internal")
          let message = @contracts.string_field_or(
            error,
            "message",
            "environment exec failed",
          )
          let detail = @contracts.string_field_or(error, "detail", "")
          environment_rpc_error(kind, message, detail~)
        }
        _ =>
          environment_rpc_error(
            @contracts.ENVIRONMENT_ERR_INTERNAL,
            "environment exec failed",
          )
      }
    _ =>
      environment_rpc_error(
        @contracts.ENVIRONMENT_ERR_INTERNAL,
        "environment exec failed",
      )
  }
}

///|
async fn send_exec_value(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
  value : @json.Json,
) -> Unit {
  if exec_result_is_error(value) {
    env_send_error(
      state,
      sink,
      request,
      client_request_id,
      exec_result_error(value),
    )
  } else {
    send_machine_result(state, sink, request, client_request_id, value)
  }
}

// ---------------------------------------------------------------------------
// Doctor
// ---------------------------------------------------------------------------

///|
async fn environment_doctor_report(
  state : HostState,
  record : @contracts.EnvironmentRecord,
) -> Result[@json.Json, @contracts.RpcError] {
  let identity = match environment_identity_of_record(record) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let runner = match environment_runner_for_machine(state, record.machine_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let stored = load_recipe_stored(state, record.recipe)
  let recipe_option : @recipes.Recipe? = match stored {
    Ok(stored_record) =>
      match verify_recipe_record(state, stored_record) {
        Ok(value) => Some(value)
        Err(_) => None
      }
    Err(_) => None
  }
  let report = @environment.doctor_container(
    runner,
    record,
    identity,
    recipe_option,
    @contracts.format_rfc3339(@async.now()),
  )
  Ok(report.to_json())
}

// ---------------------------------------------------------------------------
// Trust store + verifier (host startup)
// ---------------------------------------------------------------------------

///|
/// Load the owner trust store. A missing or invalid file means "no trusted
/// keys": the host still starts and serves reads, but imports are refused.
pub async fn load_host_trust(state_dir : String) -> @recipes.TrustStore {
  let path = match @env.get_env_var("MONEXUS_RECIPE_TRUST") {
    Some(value) if value.trim() != "" => value
    _ => state_dir + "/recipe_trust.json"
  }
  let exists = @fs.exists(path) catch { _ => false }
  if !exists {
    println(
      "monexus-host: recipe trust store not found at " + path +
      "; recipe imports will be refused until one is provided",
    )
    return @recipes.TrustStore::empty()
  }
  match @recipes.load_trust_store(path) {
    Ok(value) => value
    Err(error) => {
      println(
        "monexus-host: recipe trust store at " + path + " is unusable (" +
        error.to_string() + "); recipe imports will be refused",
      )
      @recipes.TrustStore::empty()
    }
  }
}

///|
/// Mirror the owner trust file into `recipe_trust` rows for inspection. The
/// file remains the authority; trust keys are never accepted from recipes.
pub async fn persist_trust_rows(
  store : @machines.MachineStore,
  trust : @recipes.TrustStore,
) -> Unit {
  for key_id, key in trust.keys {
    let row : @machines.TrustKeyRow = {
      key_id,
      public_key: key.public_key,
      added_at: key.added_at,
      revoked_at: match key.revoked_at {
        Some(value) => value
        None => ""
      },
    }
    match store.put_trust_key(row) {
      Ok(_) => ()
      Err(message) =>
        println(
          "monexus-host: cannot persist trust key " + key_id + ": " + message,
        )
    }
  }
}

// ---------------------------------------------------------------------------
// Reconcile
// ---------------------------------------------------------------------------

///|
async fn mark_environment_drift(
  state : HostState,
  record : @contracts.EnvironmentRecord,
  message : String,
) -> Unit {
  if record.last_error == message {
    return
  }
  let updated = { ..record, last_error: message }
  state.mutex.acquire()
  let appended = state.append_environment_event(
    @contracts.EVENT_ENVIRONMENT_ORPHAN_SUSPECTED,
    record.id,
    environment_payload(updated),
    Some(updated),
    None,
  )
  state.mutex.release()
  match appended {
    Ok(_) => ()
    Err(error) =>
      println("monexus-host: cannot record environment drift: " + error)
  }
  audit(
    state,
    "environment.reconcile",
    "host",
    "environment/" + record.id,
    "drift",
    policy=@contracts.POLICY_ALLOW,
    risk=record.risk,
    detail=message,
  )
}

///|
/// Remove a leftover env-file from a reconciled intent and report whether the
/// secret is actually gone. `cleanup_ok` is never true while the file remains.
async fn reconcile_remove_env_file(
  state : HostState,
  runner : @environment.DockerRunner,
  record : @contracts.EnvironmentRecord,
) -> (Bool, String) {
  let path = environment_dir(runner, record.id) + "/env"
  match (runner.remove_file)(path) {
    Ok(_) => (true, "")
    Err(error) => {
      let detail = write_environment_cleanup_artifact(
        state,
        record.id,
        "env file: " + error.to_string(),
      )
      (false, detail)
    }
  }
}

///|
async fn adopt_environment(
  state : HostState,
  record : @contracts.EnvironmentRecord,
  running : Bool,
  runner : @environment.DockerRunner,
) -> Unit {
  let timestamp = @contracts.format_rfc3339(@async.now())
  // A crash after `docker start` but before `environment.created` leaves the
  // secret env-file behind. Reconcile removes it best-effort and records the
  // real outcome; adoption is not reported clean while the file remains.
  let (cleanup_ok, cleanup_detail) = reconcile_remove_env_file(
    state,
    runner,
    record,
  )
  let adopted : @contracts.EnvironmentRecord = {
    ..record,
    state: if running {
      @contracts.ENVIRONMENT_STATE_RUNNING
    } else {
      @contracts.ENVIRONMENT_STATE_STOPPED
    },
    started_at: if running && record.started_at == "" {
      timestamp
    } else {
      record.started_at
    },
    updated_at: timestamp,
    last_error: "",
    cleanup_ok,
    cleanup_detail,
  }
  state.mutex.acquire()
  let appended = state.append_environment_event(
    @contracts.EVENT_ENVIRONMENT_CREATED,
    record.id,
    environment_payload(adopted),
    Some(adopted),
    None,
  )
  state.mutex.release()
  match appended {
    Ok(_) => ()
    Err(message) =>
      println("monexus-host: cannot record environment adoption: " + message)
  }
  audit(
    state,
    "environment.reconcile",
    "host",
    "environment/" + record.id,
    "adopted",
    policy=@contracts.POLICY_ALLOW,
    risk=record.risk,
    detail="plan matched; container " + record.container_name,
  )
}

///|
/// Settle a `creating` intent whose container is absent or drifted. The
/// env-file written before `docker create` may still exist, so it is removed
/// best-effort and the cleanup result is recorded rather than assumed.
async fn settle_drifted_create_intent(
  state : HostState,
  record : @contracts.EnvironmentRecord,
  runner : @environment.DockerRunner,
  message : String,
) -> Unit {
  let timestamp = @contracts.format_rfc3339(@async.now())
  let (cleanup_ok, cleanup_detail) = reconcile_remove_env_file(
    state,
    runner,
    record,
  )
  let failed : @contracts.EnvironmentRecord = {
    ..record,
    state: @contracts.ENVIRONMENT_STATE_FAILED,
    updated_at: timestamp,
    last_error: message,
    cleanup_ok,
    cleanup_detail,
  }
  state.mutex.acquire()
  let appended = state.append_environment_event(
    @contracts.EVENT_ENVIRONMENT_FAILED,
    record.id,
    environment_payload(failed),
    Some(failed),
    None,
  )
  state.mutex.release()
  match appended {
    Ok(_) => ()
    Err(error) => println("monexus-host: cannot settle create intent: " + error)
  }
  release_environment_lease(state, record.id)
  audit(
    state,
    "environment.reconcile",
    "host",
    "environment/" + record.id,
    "failed",
    policy=@contracts.POLICY_ALLOW,
    risk=record.risk,
    detail=message,
  )
}

///|
async fn destroy_timed_out_intent(
  state : HostState,
  record : @contracts.EnvironmentRecord,
  runner : @environment.DockerRunner,
  identity : @docker.EnvironmentIdentity,
) -> Unit {
  let outcome = @environment.destroy_container(
    runner,
    identity,
    environment_dir(runner, record.id),
    environment_scratch_dir(record),
  )
  let timestamp = @contracts.format_rfc3339(@async.now())
  if outcome.ok {
    let failed : @contracts.EnvironmentRecord = {
      ..record,
      state: @contracts.ENVIRONMENT_STATE_FAILED,
      updated_at: timestamp,
      last_error: "timed-out create intent reconciled",
      cleanup_ok: true,
      cleanup_detail: "",
    }
    state.mutex.acquire()
    let appended = state.append_environment_event(
      @contracts.EVENT_ENVIRONMENT_FAILED,
      record.id,
      environment_payload(failed),
      Some(failed),
      None,
    )
    state.mutex.release()
    match appended {
      Ok(_) => ()
      Err(message) =>
        println("monexus-host: cannot record intent cleanup: " + message)
    }
    release_environment_lease(state, record.id)
  } else {
    let cleanup_ref = write_environment_cleanup_artifact(
      state,
      record.id,
      outcome.log,
    )
    let failed : @contracts.EnvironmentRecord = {
      ..record,
      state: @contracts.ENVIRONMENT_STATE_ORPHAN_SUSPECTED,
      updated_at: timestamp,
      last_error: "timed-out create intent cleanup failed",
      cleanup_ok: false,
      cleanup_detail: cleanup_ref,
    }
    state.mutex.acquire()
    let appended = state.append_environment_event(
      @contracts.EVENT_ENVIRONMENT_ORPHAN_SUSPECTED,
      record.id,
      environment_payload(failed),
      Some(failed),
      None,
    )
    state.mutex.release()
    match appended {
      Ok(_) => ()
      Err(message) =>
        println(
          "monexus-host: cannot record intent cleanup failure: " + message,
        )
    }
  }
  audit(
    state,
    "environment.reconcile",
    "host",
    "environment/" + record.id,
    "destroy_intent",
    policy=@contracts.POLICY_ALLOW,
    risk=record.risk,
    detail=outcome.log,
  )
}

///|
/// True only when a recorded create intent is older than the ADR bound. The
/// age comes from the record, never from `state == creating` alone: a live
/// create in this process is excluded by the in-process marker, and a very
/// recent intent is left untouched even before that marker is visible.
fn create_intent_age_timed_out(
  record : @contracts.EnvironmentRecord,
  now_ms : Int64,
) -> Bool {
  match @contracts.parse_rfc3339_ms(record.created_at) {
    Some(created_ms) => @environment.create_intent_timed_out(now_ms - created_ms)
    // An unparseable timestamp is not evidence of a timed-out intent.
    None => false
  }
}

///|
/// Read-only scan + convergence (ADR-0013 §3.5). It never creates an
/// environment: it adopts a complete labelled container, removes an incomplete
/// timed-out create intent, or records drift without touching an unowned
/// container.
pub async fn reconcile_environments(state : HostState) -> Unit {
  state.mutex.acquire()
  let records = match state.store.list_environments() {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      println("monexus-host: cannot list environments for reconcile: " + message)
      return
    }
  }
  let in_process_creates : Array[String] = []
  for environment_id, _ in state.env_create_started {
    in_process_creates.push(environment_id)
  }
  state.mutex.release()
  for record in records {
    if record.state == @contracts.ENVIRONMENT_STATE_DESTROYED ||
      record.state == @contracts.ENVIRONMENT_STATE_FAILED {
      continue
    }
    let mut creating_here = false
    for environment_id in in_process_creates {
      if environment_id == record.id {
        creating_here = true
      }
    }
    if creating_here {
      // The create coroutine is still running in this host process.
      continue
    }
    let identity = match environment_identity_of_record(record) {
      Ok(value) => value
      Err(_) => continue
    }
    let runner = match environment_runner_for_machine(state, record.machine_id) {
      Ok(value) => value
      Err(error) => {
        println(
          "monexus-host: environment reconcile skipped " + record.id + ": " +
          error.message,
        )
        continue
      }
    }
    let inspect = match @environment.inspect_container(runner, identity) {
      Ok(Some(value)) => Some(value)
      Ok(None) => None
      Err(_) => continue
    }
    // Adoption requires the full recorded plan, not just managed labels: the
    // identity labels are necessary but not sufficient. The recipe is loaded
    // and re-verified so limits can be checked; without it nothing is
    // adopted (fail closed).
    let plan_matches = match inspect {
      Some(value) => {
        let recipe_record = match load_recipe_stored(state, record.recipe) {
          Ok(loaded) => Some(loaded)
          Err(_) => None
        }
        let verified = match recipe_record {
          Some(stored) =>
            match verify_recipe_record(state, stored) {
              Ok(recipe) => Some(recipe)
              Err(_) => None
            }
          None => None
        }
        @environment.record_matches_inspect(record, identity, value, verified)
      }
      None => false
    }
    // Any create intent left over in the projection belongs to a previous
    // execution; its coroutine cannot be alive after a restart. A live create
    // in this process is excluded by the marker above, and a recent intent is
    // not treated as timed out merely because its state is `creating`.
    let create_timed_out = record.state ==
      @contracts.ENVIRONMENT_STATE_CREATING &&
      create_intent_age_timed_out(record, @async.now())
    let action = @environment.reconcile_decision(
      record,
      inspect,
      plan_matches,
      create_timed_out,
    )
    match action {
      @environment.Adopt => {
        let some_inspect = match inspect {
          Some(value) => value
          None => continue
        }
        if record.state == @contracts.ENVIRONMENT_STATE_CREATING {
          adopt_environment(state, record, some_inspect.running, runner)
        } else if record.state == @contracts.ENVIRONMENT_STATE_RUNNING &&
          !some_inspect.running {
          mark_environment_drift(
            state,
            record,
            "container is not running but the environment is recorded as running",
          )
        } else if record.state == @contracts.ENVIRONMENT_STATE_STOPPED &&
          some_inspect.running {
          mark_environment_drift(
            state,
            record,
            "container is running but the environment is recorded as stopped",
          )
        }
      }
      @environment.DestroyIntent =>
        destroy_timed_out_intent(state, record, runner, identity)
      @environment.MarkDrift(message) =>
        if record.state == @contracts.ENVIRONMENT_STATE_CREATING {
          settle_drifted_create_intent(state, record, runner, message)
        } else {
          mark_environment_drift(state, record, message)
        }
      @environment.Ignore => ()
    }
  }
}

///|
pub async fn environment_reconcile_loop(state : HostState) -> Unit {
  for ;; {
    @async.sleep(ENVIRONMENT_RECONCILE_INTERVAL_MS)
    reconcile_environments(state)
  }
}

// ---------------------------------------------------------------------------
// Run / terminal / git dispatch through an active environment
// ---------------------------------------------------------------------------

///|
/// Execute one Run command inside the Run's environment container. The command
/// is an owner/Run shell string (A1 semantics), executed as `sh -c`; only
/// `environment.exec` is argv-only.
async fn run_exec_in_environment(
  state : HostState,
  run : @contracts.RunRecord,
  command : String,
  timeout_s : Int,
) -> Result[@environment.ExecOutput, String] {
  let environment = match environment_record_by_id(state, run.environment_id) {
    Ok(Some(value)) => value
    Ok(None) => return Err("environment not found: " + run.environment_id)
    Err(error) => return Err(error.message)
  }
  if environment.state != @contracts.ENVIRONMENT_STATE_RUNNING {
    return Err("environment is not running: " + environment.state)
  }
  let identity = match environment_identity_of_record(environment) {
    Ok(value) => value
    Err(error) => return Err(error.message)
  }
  let runner = match environment_runner_for_machine(state, environment.machine_id) {
    Ok(value) => value
    Err(error) => return Err(error.message)
  }
  match
    @environment.shell_in_container(
      runner,
      identity,
      command,
      environment.workdir,
      timeout_s,
    ) {
    Ok(output) => Ok(output)
    Err(error) => Err(error.to_string())
  }
}

///|
/// Uniform exec path for command steps and diffs: the environment container
/// when the Run carries one, otherwise the workspace machine provider.
async fn run_exec_checked(
  state : HostState,
  run : @contracts.RunRecord,
  command : String,
  cwd : String,
  timeout_s : Int,
) -> Result[@environment.ExecOutput, String] {
  if run.environment_id != "" {
    return run_exec_in_environment(state, run, command, timeout_s)
  }
  let workspace = match state.load_workspace(run.workspace_id) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let provider = match open_provider(state, workspace.machine_id, workspace.root) {
    Ok(value) => value
    Err(error) => return Err(error.message)
  }
  match provider.exec(command, cwd~, timeout_seconds=timeout_s) {
    Ok(result) =>
      Ok({
        exit_code: result.exit_code,
        stdout: result.stdout,
        stderr: result.stderr,
        timed_out: result.timed_out,
      })
    Err(error) => Err(error.to_string())
  }
}

///|
/// Destroy an ephemeral environment when its Run reaches a terminal state.
/// Idempotent and safe to call from every terminal transition.
async fn finalize_run_environment(
  state : HostState,
  run : @contracts.RunRecord,
) -> Unit {
  if run.environment_id == "" {
    return
  }
  let loaded = match environment_record_by_id(state, run.environment_id) {
    Ok(value) => value
    Err(_) => return
  }
  let record = match loaded {
    Some(value) => value
    None => return
  }
  if !record.ephemeral ||
    record.state == @contracts.ENVIRONMENT_STATE_DESTROYED {
    return
  }
  state.environment_mutex.acquire()
  let _ = destroy_environment_locked(state, record)
  state.environment_mutex.release()
}

///|
/// Git status through the active environment's container. Read-only.
async fn environment_git_status(
  state : HostState,
  workspace : @contracts.WorkspaceRecord,
  environment : @contracts.EnvironmentRecord,
) -> Result[@contracts.GitStatus, @contracts.RpcError] {
  if !workspace.is_git {
    return Ok({
      is_git: false,
      branch: "",
      upstream: "",
      ahead: 0,
      behind: 0,
      changes: [],
    })
  }
  let identity = match environment_identity_of_record(environment) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let runner = match environment_runner_for_machine(state, environment.machine_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let output = match
    @environment.shell_in_container(
      runner,
      identity,
      "git --no-pager status --porcelain=v1 --branch",
      environment.workdir,
      60,
    ) {
    Ok(value) => value
    Err(error) => return Err(environment_failure_error(error))
  }
  if output.timed_out {
    return Err(
      environment_rpc_error(
        @contracts.ENVIRONMENT_ERR_TIMEOUT,
        "git status timed out",
      ),
    )
  }
  if output.exit_code != 0 {
    return Err(
      environment_rpc_error(
        @contracts.ENVIRONMENT_ERR_INTERNAL,
        "git status failed",
        detail=@contracts.redact_secrets(output.stderr),
      ),
    )
  }
  let parsed = @workspace.parse_git_status(output.stdout, true)
  let changes : Array[@contracts.GitChange] = []
  for change in parsed.changes {
    changes.push({
      path: change.path,
      status: change.status,
      index_status: change.index_status,
      worktree_status: change.worktree_status,
    })
  }
  Ok({
    is_git: parsed.is_git,
    branch: parsed.branch,
    upstream: parsed.upstream,
    ahead: parsed.ahead,
    behind: parsed.behind,
    changes,
  })
}

///|
fn truncate_diff(text : String) -> (String, Bool) {
  if text.length() <= ENVIRONMENT_GIT_OUTPUT_CAP {
    (text, false)
  } else {
    (text[:ENVIRONMENT_GIT_OUTPUT_CAP].to_owned() + "\n...[truncated]", true)
  }
}

///|
/// Git diff through the active environment's container. The argv is built
/// element by element; no shell interpolation and no environment values.
async fn environment_git_diff(
  state : HostState,
  environment : @contracts.EnvironmentRecord,
  path : String,
  cached : Bool,
  range : String,
) -> Result[@contracts.GitDiff, @contracts.RpcError] {
  let identity = match environment_identity_of_record(environment) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let runner = match environment_runner_for_machine(state, environment.machine_id) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let argv : Array[String] = ["git", "--no-pager", "diff", "--no-color"]
  if cached {
    argv.push("--cached")
  }
  if range != "" {
    argv.push(range)
  }
  argv.push("--")
  if path != "" {
    argv.push(path)
  }
  let output = match
    @environment.exec_in_container(
      runner,
      identity,
      argv,
      environment.workdir,
      60,
    ) {
    Ok(value) => value
    Err(error) => return Err(environment_failure_error(error))
  }
  if output.timed_out {
    return Err(
      environment_rpc_error(
        @contracts.ENVIRONMENT_ERR_TIMEOUT,
        "git diff timed out",
      ),
    )
  }
  if output.exit_code != 0 {
    return Err(
      environment_rpc_error(
        @contracts.ENVIRONMENT_ERR_INTERNAL,
        "git diff failed",
        detail=@contracts.redact_secrets(output.stderr),
      ),
    )
  }
  let (text, truncated) = truncate_diff(@contracts.redact_secrets(output.stdout))
  Ok({ path, cached, range, text, truncated })
}

// ---------------------------------------------------------------------------
// Environment RPC handlers
// ---------------------------------------------------------------------------

///|
async fn env_send_error(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
  error : @contracts.RpcError,
) -> Unit {
  send_machine_error(state, sink, request, client_request_id, error)
}

///|
async fn handle_environment_create(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  state.environment_mutex.acquire()
  let result = create_environment_locked(state, request)
  state.environment_mutex.release()
  match result {
    Ok(record) =>
      send_machine_result(
        state,
        sink,
        request,
        client_request_id,
        environment_payload(record),
      )
    Err(error) => env_send_error(state, sink, request, client_request_id, error)
  }
}

///|
async fn handle_environment_start(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let environment_id = match @contracts.environment_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      env_send_error(
        state,
        sink,
        request,
        client_request_id,
        environment_rpc_error(@contracts.ENVIRONMENT_ERR_INVALID, message),
      )
      return
    }
  }
  let approval_id = @contracts.string_field_or(request.params, "approval_id", "")
  state.environment_mutex.acquire()
  let loaded = environment_record_by_id(state, environment_id)
  let result = match loaded {
    Ok(Some(record)) => start_environment_locked(state, record, approval_id)
    Ok(None) =>
      Err(
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_NOT_FOUND,
          "environment not found",
        ),
      )
    Err(error) => Err(error)
  }
  state.environment_mutex.release()
  match result {
    Ok(record) =>
      send_machine_result(
        state,
        sink,
        request,
        client_request_id,
        environment_payload(record),
      )
    Err(error) => env_send_error(state, sink, request, client_request_id, error)
  }
}

///|
async fn handle_environment_stop(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let environment_id = match @contracts.environment_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      env_send_error(
        state,
        sink,
        request,
        client_request_id,
        environment_rpc_error(@contracts.ENVIRONMENT_ERR_INVALID, message),
      )
      return
    }
  }
  state.environment_mutex.acquire()
  let loaded = environment_record_by_id(state, environment_id)
  let result = match loaded {
    Ok(Some(record)) => stop_environment_locked(state, record)
    Ok(None) =>
      Err(
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_NOT_FOUND,
          "environment not found",
        ),
      )
    Err(error) => Err(error)
  }
  state.environment_mutex.release()
  match result {
    Ok(record) =>
      send_machine_result(
        state,
        sink,
        request,
        client_request_id,
        environment_payload(record),
      )
    Err(error) => env_send_error(state, sink, request, client_request_id, error)
  }
}

///|
async fn handle_environment_destroy(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let environment_id = match @contracts.environment_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      env_send_error(
        state,
        sink,
        request,
        client_request_id,
        environment_rpc_error(@contracts.ENVIRONMENT_ERR_INVALID, message),
      )
      return
    }
  }
  state.environment_mutex.acquire()
  let loaded = environment_record_by_id(state, environment_id)
  let result = match loaded {
    Ok(Some(record)) => destroy_environment_locked(state, record)
    Ok(None) => Ok(environment_destroy_ack(environment_id, true, ""))
    Err(error) => Err(error)
  }
  state.environment_mutex.release()
  match result {
    Ok(value) =>
      send_machine_result(state, sink, request, client_request_id, value)
    Err(error) => env_send_error(state, sink, request, client_request_id, error)
  }
}

///|
async fn handle_environment_exec(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  // Setup is serialized with lifecycle mutations, but the wait is not: stop
  // and destroy must be able to cancel a running exec through the task map.
  state.environment_mutex.acquire()
  let setup = environment_exec_setup_locked(state, request.params)
  state.environment_mutex.release()
  match setup {
    Ok(EnvironmentExecSetup::ExecCached(value)) =>
      send_exec_value(state, sink, request, client_request_id, value)
    Ok(EnvironmentExecSetup::ExecPending(task, key, exec_id)) => {
      let _ = task.wait() catch { _ => () }
      state.mutex.acquire()
      let result = state.env_exec_cache.get(key)
      state.mutex.release()
      match result {
        Some(value) =>
          send_exec_value(state, sink, request, client_request_id, value)
        None =>
          send_exec_value(
            state,
            sink,
            request,
            client_request_id,
            cancelled_exec_json(exec_id),
          )
      }
    }
    Err(error) => env_send_error(state, sink, request, client_request_id, error)
  }
}

///|
async fn handle_environment_doctor(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let environment_id = match @contracts.environment_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      env_send_error(
        state,
        sink,
        request,
        client_request_id,
        environment_rpc_error(@contracts.ENVIRONMENT_ERR_INVALID, message),
      )
      return
    }
  }
  let loaded = environment_record_by_id(state, environment_id)
  let result = match loaded {
    Ok(Some(record)) => environment_doctor_report(state, record)
    Ok(None) =>
      Err(
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_NOT_FOUND,
          "environment not found",
        ),
      )
    Err(error) => Err(error)
  }
  match result {
    Ok(value) =>
      send_machine_result(state, sink, request, client_request_id, value)
    Err(error) => env_send_error(state, sink, request, client_request_id, error)
  }
}

///|
async fn handle_environment_list(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let workspace_id = @contracts.string_field_or(request.params, "workspace_id", "")
  state.mutex.acquire()
  let records = match state.store.list_environments() {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      env_send_error(
        state,
        sink,
        request,
        client_request_id,
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_INVALID,
          "cannot list environments",
          detail=message,
        ),
      )
      return
    }
  }
  state.mutex.release()
  let items : Array[@json.Json] = []
  for record in records {
    if workspace_id == "" || record.workspace_id == workspace_id {
      items.push(record.to_json())
    }
  }
  send_machine_result(
    state,
    sink,
    request,
    client_request_id,
    @contracts.json_object([("environments", @contracts.json_array(items))]),
  )
}

///|
async fn handle_environment_get(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let environment_id = match @contracts.environment_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      env_send_error(
        state,
        sink,
        request,
        client_request_id,
        environment_rpc_error(@contracts.ENVIRONMENT_ERR_INVALID, message),
      )
      return
    }
  }
  match environment_record_by_id(state, environment_id) {
    Ok(Some(record)) =>
      send_machine_result(
        state,
        sink,
        request,
        client_request_id,
        environment_payload(record),
      )
    Ok(None) =>
      env_send_error(
        state,
        sink,
        request,
        client_request_id,
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_NOT_FOUND,
          "environment not found",
        ),
      )
    Err(error) => env_send_error(state, sink, request, client_request_id, error)
  }
}

// ---------------------------------------------------------------------------
// Recipe RPC handlers
// ---------------------------------------------------------------------------

///|
async fn recipe_import_refused(
  state : HostState,
  source : String,
  reason : String,
) -> Unit {
  let payload = @contracts.json_object([
    ("reason", @contracts.json_string(@contracts.redact_secrets(reason))),
    ("source", @contracts.json_string(@contracts.redact_secrets(source))),
  ])
  state.mutex.acquire()
  let appended = state.append_recipe_event(
    @contracts.EVENT_RECIPE_REFUSED,
    "recipe/refused",
    payload,
    None,
    true,
  )
  state.mutex.release()
  match appended {
    Ok(_) => ()
    Err(message) =>
      println("monexus-host: cannot record recipe.refused: " + message)
  }
  audit(
    state,
    "recipe.import",
    "host",
    "recipe/refused",
    "refused",
    policy=@contracts.POLICY_DENY,
    risk=@contracts.RISK_HIGH,
    detail=@contracts.redact_secrets(reason),
  )
}

///|
async fn handle_recipe_import(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let text = @contracts.string_field_or(request.params, "recipe", "")
  let source = @contracts.string_field_or(request.params, "source", "inline")
  if text.trim() == "" {
    agent_io_error(
      state,
      sink,
      request,
      client_request_id,
      environment_rpc_error(
        @contracts.ENVIRONMENT_ERR_INVALID,
        "recipe text is required",
      ),
    )
    return
  }
  let verified = match
    @recipes.import_recipe(text, state.trust, state.verifier) {
    Ok(value) => value
    Err(error) => {
      let reason = error.to_string()
      recipe_import_refused(state, source, reason)
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_UNTRUSTED_RECIPE,
          "recipe refused: " + reason,
        ),
      )
      return
    }
  }
  let ref = verified.recipe.identity()
  let existing = match find_recipe_record(state, ref) {
    Ok(value) => value
    Err(error) => {
      agent_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  match existing {
    Some(record) => {
      if record.state == @contracts.RECIPE_STATE_REVOKED ||
        record.revoked_at != "" {
        agent_io_error(
          state,
          sink,
          request,
          client_request_id,
          environment_rpc_error(
            @contracts.ENVIRONMENT_ERR_UNTRUSTED_RECIPE,
            "recipe is revoked and cannot be re-imported",
            detail=ref,
          ),
        )
        return
      }
      if record.content_hash != verified.content_hash {
        let reason = "recipe " + ref +
          " is already imported with different content"
        recipe_import_refused(state, source, reason)
        agent_io_error(
          state,
          sink,
          request,
          client_request_id,
          environment_rpc_error(
            @contracts.ENVIRONMENT_ERR_CONFLICT,
            reason,
          ),
        )
        return
      }
      send_machine_result(
        state,
        sink,
        request,
        client_request_id,
        recipe_payload(record),
      )
      return
    }
    None => ()
  }
  let now = @async.now()
  let record : @contracts.RecipeRecord = {
    id: @contracts.new_id("rcp", now),
    name: verified.recipe.name,
    version: verified.recipe.version,
    content_hash: verified.content_hash,
    key_id: verified.key_id,
    state: @contracts.RECIPE_STATE_TRUSTED,
    canonical: verified.canonical,
    signature: verified.recipe.signature.sig,
    source,
    imported_at: @contracts.format_rfc3339(now),
    revoked_at: "",
    refusal_reason: "",
  }
  state.mutex.acquire()
  let appended = state.append_recipe_event(
    @contracts.EVENT_RECIPE_IMPORTED,
    record.id,
    recipe_payload(record),
    Some(record),
    false,
  )
  state.mutex.release()
  match appended {
    Ok(_) => ()
    Err(message) => {
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_INTERNAL,
          "cannot persist recipe import",
          detail=message,
        ),
      )
      return
    }
  }
  audit(
    state,
    "recipe.import",
    "host",
    "recipe/" + ref,
    "imported",
    policy=@contracts.POLICY_ASK,
    risk=@contracts.RISK_HIGH,
    detail=ref + " " + verified.content_hash,
  )
  send_machine_result(
    state,
    sink,
    request,
    client_request_id,
    recipe_payload(record),
  )
}

///|
async fn handle_recipe_list(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  state.mutex.acquire()
  let records = match state.store.list_recipes() {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_INVALID,
          "cannot list recipes",
          detail=message,
        ),
      )
      return
    }
  }
  state.mutex.release()
  let items : Array[@json.Json] = []
  for record in records {
    items.push(record.to_json())
  }
  send_machine_result(
    state,
    sink,
    request,
    client_request_id,
    @contracts.json_object([("recipes", @contracts.json_array(items))]),
  )
}

///|
async fn handle_recipe_show(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let ref = @contracts.string_field_or(request.params, "recipe", "")
  let found = match find_recipe_record(state, ref) {
    Ok(value) => value
    Err(error) => {
      agent_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  match found {
    Some(record) =>
      send_machine_result(
        state,
        sink,
        request,
        client_request_id,
        recipe_payload(record),
      )
    None =>
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_NOT_FOUND,
          "recipe not found",
          detail=ref,
        ),
      )
  }
}

///|
async fn handle_recipe_revoke(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let ref = @contracts.string_field_or(request.params, "recipe", "")
  let found = match find_recipe_record(state, ref) {
    Ok(value) => value
    Err(error) => {
      agent_io_error(state, sink, request, client_request_id, error)
      return
    }
  }
  let record = match found {
    Some(value) => value
    None => {
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_NOT_FOUND,
          "recipe not found",
          detail=ref,
        ),
      )
      return
    }
  }
  if record.state == @contracts.RECIPE_STATE_REVOKED || record.revoked_at != "" {
    send_machine_result(
      state,
      sink,
      request,
      client_request_id,
      recipe_payload(record),
    )
    return
  }
  let revoked : @contracts.RecipeRecord = {
    ..record,
    state: @contracts.RECIPE_STATE_REVOKED,
    revoked_at: @contracts.format_rfc3339(@async.now()),
  }
  state.mutex.acquire()
  let appended = state.append_recipe_event(
    @contracts.EVENT_RECIPE_REVOKED,
    revoked.id,
    recipe_payload(revoked),
    Some(revoked),
    false,
  )
  state.mutex.release()
  match appended {
    Ok(_) => ()
    Err(message) => {
      agent_io_error(
        state,
        sink,
        request,
        client_request_id,
        environment_rpc_error(
          @contracts.ENVIRONMENT_ERR_INTERNAL,
          "cannot persist recipe revocation",
          detail=message,
        ),
      )
      return
    }
  }
  audit(
    state,
    "recipe.revoke",
    "host",
    "recipe/" + revoked.id,
    "revoked",
    policy=@contracts.POLICY_ALLOW,
    risk=@contracts.RISK_HIGH,
    detail=revoked.name + "@" + revoked.version,
  )
  send_machine_result(
    state,
    sink,
    request,
    client_request_id,
    recipe_payload(revoked),
  )
}
