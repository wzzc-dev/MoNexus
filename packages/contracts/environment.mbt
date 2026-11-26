///|
/// Environment / recipe contracts (ADR-0013, V0.2 A2.1).
///
/// An environment is a WorkspaceProvider capability, not a second workspace
/// record: the record below is the only environment identity, and a workspace
/// keeps its original `kind` (`local` or `ssh`) while an active environment
/// redirects git/terminal/Run execution into the container.
///
/// Environment values are *never* part of `EnvironmentRecord`, events,
/// Artifacts, doctor reports or logs. Only names are retained.

// ---------------------------------------------------------------------------
// RPC methods
// ---------------------------------------------------------------------------

///|
pub const METHOD_ENVIRONMENT_CREATE : String = "environment.create"

///|
pub const METHOD_ENVIRONMENT_START : String = "environment.start"

///|
pub const METHOD_ENVIRONMENT_STOP : String = "environment.stop"

///|
pub const METHOD_ENVIRONMENT_DESTROY : String = "environment.destroy"

///|
pub const METHOD_ENVIRONMENT_EXEC : String = "environment.exec"

///|
pub const METHOD_ENVIRONMENT_DOCTOR : String = "environment.doctor"

///|
pub const METHOD_ENVIRONMENT_LIST : String = "environment.list"

///|
pub const METHOD_ENVIRONMENT_GET : String = "environment.get"

///|
pub const METHOD_RECIPE_IMPORT : String = "recipe.import"

///|
pub const METHOD_RECIPE_LIST : String = "recipe.list"

///|
pub const METHOD_RECIPE_SHOW : String = "recipe.show"

///|
pub const METHOD_RECIPE_REVOKE : String = "recipe.revoke"

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

///|
pub const EVENT_RECIPE_IMPORTED : String = "recipe.imported"

///|
pub const EVENT_RECIPE_REFUSED : String = "recipe.refused"

///|
pub const EVENT_RECIPE_REVOKED : String = "recipe.revoked"

///|
pub const EVENT_RECIPE_USED : String = "recipe.used"

///|
/// Durable create intent, written before any Docker change so reconcile can
/// tell an in-flight create from an unowned container after a crash. It is the
/// only lifecycle event written before a terminal outcome.
pub const EVENT_ENVIRONMENT_CREATING : String = "environment.creating"

///|
pub const EVENT_ENVIRONMENT_CREATED : String = "environment.created"

///|
pub const EVENT_ENVIRONMENT_STARTED : String = "environment.started"

///|
pub const EVENT_ENVIRONMENT_STOPPED : String = "environment.stopped"

///|
pub const EVENT_ENVIRONMENT_DESTROYED : String = "environment.destroyed"

///|
pub const EVENT_ENVIRONMENT_FAILED : String = "environment.failed"

///|
pub const EVENT_ENVIRONMENT_ORPHAN_SUSPECTED : String = "environment.orphan_suspected"

// ---------------------------------------------------------------------------
// Backend / state / error constants
// ---------------------------------------------------------------------------

///|
pub const ENVIRONMENT_BACKEND_DOCKER : String = "docker"

///|
pub const ENVIRONMENT_STATE_CREATING : String = "creating"

///|
pub const ENVIRONMENT_STATE_RUNNING : String = "running"

///|
pub const ENVIRONMENT_STATE_STOPPED : String = "stopped"

///|
pub const ENVIRONMENT_STATE_FAILED : String = "failed"

///|
pub const ENVIRONMENT_STATE_DESTROYED : String = "destroyed"

///|
pub const ENVIRONMENT_STATE_ORPHAN_SUSPECTED : String = "orphan_suspected"

///|
pub const ENVIRONMENT_ERR_INVALID : String = "invalid"

///|
pub const ENVIRONMENT_ERR_UNTRUSTED_RECIPE : String = "untrusted_recipe"

///|
pub const ENVIRONMENT_ERR_UNSUPPORTED : String = "unsupported"

///|
pub const ENVIRONMENT_ERR_DOCKER_UNAVAILABLE : String = "docker_unavailable"

///|
pub const ENVIRONMENT_ERR_CLEANUP_FAILED : String = "cleanup_failed"

///|
pub const ENVIRONMENT_ERR_ORPHAN_SUSPECTED : String = "orphan_suspected"

///|
pub const ENVIRONMENT_ERR_APPROVAL_REQUIRED : String = "approval_required"

///|
pub const ENVIRONMENT_ERR_NOT_FOUND : String = "not_found"

///|
pub const ENVIRONMENT_ERR_CONFLICT : String = "conflict"

///|
pub const ENVIRONMENT_ERR_TIMEOUT : String = "timeout"

///|
pub const ENVIRONMENT_ERR_UNREACHABLE : String = "unreachable"

///|
pub const ENVIRONMENT_ERR_INTERNAL : String = "internal"

///|
pub const ENVIRONMENT_ERR_SECRET_REJECTED : String = "secret_rejected"

///|
pub const ENVIRONMENT_ARTIFACT_RECIPE_BUNDLE : String = "recipe_bundle"

///|
pub const ENVIRONMENT_ARTIFACT_RECIPE_SCRIPT : String = "recipe_script"

///|
pub const ENVIRONMENT_ARTIFACT_CLEANUP_LOG : String = "environment_cleanup_log"

// ---------------------------------------------------------------------------
// Environment approval binding (ADR-0013 §4.2, §6)
// ---------------------------------------------------------------------------

///|
/// One-time approval Decision kind. It is deliberately separate from the
/// task/agent approval flows: answering it never sends an ACP message, it only
/// records a grant bound to one plan digest, machine and recipe hash.
pub const DECISION_KIND_ENVIRONMENT_APPROVAL : String = "environment_approval"

///|
pub const ENVIRONMENT_APPROVAL_ACTION_CREATE : String = "environment.create"

///|
pub const ENVIRONMENT_APPROVAL_ACTION_START : String = "environment.start"

///|
/// Default approval lifetime. The caller may ask for a shorter TTL; a longer
/// request is clamped to this value. Expired grants can never create.
pub const ENVIRONMENT_APPROVAL_TTL_S : Int = 900

///|
pub const ENVIRONMENT_APPROVAL_MAX_TTL_S : Int = 3_600

///|
/// The binding a Decision must carry for one environment plan. `nonce` makes a
/// grant single-use even if the same plan is retried identically.
pub(all) struct EnvironmentApprovalBinding {
  action : String
  plan_digest : String
  machine_id : String
  recipe_hash : String
  nonce : String
  expires_at : String
}

// ---------------------------------------------------------------------------
// Records
// ---------------------------------------------------------------------------

///|
pub(all) struct EnvironmentMount {
  source : String
  host_path : String
  container_path : String
  mode : String
}

///|
pub fn EnvironmentMount::to_json(self : EnvironmentMount) -> @json.Json {
  json_object([
    ("source", json_string(self.source)),
    ("host_path", json_string(self.host_path)),
    ("container_path", json_string(self.container_path)),
    ("mode", json_string(self.mode)),
  ])
}

///|
pub fn environment_mount_from_json(json : @json.Json) -> EnvironmentMount? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  Some({
    source: string_field_or(object, "source", ""),
    host_path: string_field_or(object, "host_path", ""),
    container_path: string_field_or(object, "container_path", ""),
    mode: string_field_or(object, "mode", "ro"),
  })
}

///|
pub(all) struct EnvironmentRecord {
  id : String
  workspace_id : String
  worktree_id : String
  machine_id : String
  backend : String
  recipe : String
  recipe_hash : String
  container_name : String
  state : String
  plan_digest : String
  workdir : String
  user : String
  network : String
  mounts : Array[EnvironmentMount]
  env_names : Array[String]
  risk : String
  approval_id : String
  ephemeral : Bool
  ttl_s : Int
  client_request_id : String
  created_at : String
  updated_at : String
  started_at : String
  stopped_at : String
  last_error : String
  cleanup_ok : Bool
  cleanup_detail : String
}

///|
pub fn EnvironmentRecord::to_json(self : EnvironmentRecord) -> @json.Json {
  json_object([
    ("id", json_string(self.id)),
    ("workspace_id", json_string(self.workspace_id)),
    ("worktree_id", json_string(self.worktree_id)),
    ("machine_id", json_string(self.machine_id)),
    ("backend", json_string(self.backend)),
    ("recipe", json_string(self.recipe)),
    ("recipe_hash", json_string(self.recipe_hash)),
    ("container_name", json_string(self.container_name)),
    ("state", json_string(self.state)),
    ("plan_digest", json_string(self.plan_digest)),
    ("workdir", json_string(self.workdir)),
    ("user", json_string(self.user)),
    ("network", json_string(self.network)),
    (
      "mounts",
      json_array(self.mounts.map(fn(mount) { mount.to_json() })),
    ),
    ("env_names", json_string_array(self.env_names)),
    ("risk", json_string(self.risk)),
    ("approval_id", json_string(self.approval_id)),
    ("ephemeral", json_bool(self.ephemeral)),
    ("ttl_s", json_int(self.ttl_s)),
    ("client_request_id", json_string(self.client_request_id)),
    ("created_at", json_string(self.created_at)),
    ("updated_at", json_string(self.updated_at)),
    ("started_at", json_string(self.started_at)),
    ("stopped_at", json_string(self.stopped_at)),
    ("last_error", json_string(self.last_error)),
    ("cleanup_ok", json_bool(self.cleanup_ok)),
    ("cleanup_detail", json_string(self.cleanup_detail)),
  ])
}

///|
pub fn environment_record_from_json(json : @json.Json) -> EnvironmentRecord? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let id = match string_field(object, "id") {
    Some(value) => value
    None => return None
  }
  let mounts : Array[EnvironmentMount] = []
  match object.get("mounts") {
    Some(@json.Json::Array(items)) => {
      for item in items {
        match environment_mount_from_json(item) {
          Some(mount) => mounts.push(mount)
          None => ()
        }
      }
    }
    _ => ()
  }
  let env_names : Array[String] = []
  match object.get("env_names") {
    Some(@json.Json::Array(items)) => {
      for item in items {
        match as_string(item) {
          Some(value) => env_names.push(value)
          None => ()
        }
      }
    }
    _ => ()
  }
  Some({
    id,
    workspace_id: string_field_or(object, "workspace_id", ""),
    worktree_id: string_field_or(object, "worktree_id", ""),
    machine_id: string_field_or(object, "machine_id", ""),
    backend: string_field_or(object, "backend", ENVIRONMENT_BACKEND_DOCKER),
    recipe: string_field_or(object, "recipe", ""),
    recipe_hash: string_field_or(object, "recipe_hash", ""),
    container_name: string_field_or(object, "container_name", ""),
    state: string_field_or(object, "state", ENVIRONMENT_STATE_CREATING),
    plan_digest: string_field_or(object, "plan_digest", ""),
    workdir: string_field_or(object, "workdir", ""),
    user: string_field_or(object, "user", ""),
    network: string_field_or(object, "network", ""),
    mounts,
    env_names,
    risk: string_field_or(object, "risk", ""),
    approval_id: string_field_or(object, "approval_id", ""),
    ephemeral: bool_field_or(object, "ephemeral", false),
    ttl_s: int_field_or(object, "ttl_s", 0),
    client_request_id: string_field_or(object, "client_request_id", ""),
    created_at: string_field_or(object, "created_at", ""),
    updated_at: string_field_or(object, "updated_at", ""),
    started_at: string_field_or(object, "started_at", ""),
    stopped_at: string_field_or(object, "stopped_at", ""),
    last_error: string_field_or(object, "last_error", ""),
    cleanup_ok: bool_field_or(object, "cleanup_ok", true),
    cleanup_detail: string_field_or(object, "cleanup_detail", ""),
  })
}

///|
pub fn environment_event_record(
  event : EventEnvelope,
) -> EnvironmentRecord? {
  match event.payload {
    @json.Json::Object(object) =>
      match object.get("environment") {
        Some(value) => environment_record_from_json(value)
        None => None
      }
    _ => None
  }
}

///|
pub fn environment_destroyed_id(
  event : EventEnvelope,
) -> String? {
  match event.payload {
    @json.Json::Object(object) =>
      match object.get("environment_id") {
        Some(@json.Json::String(value)) => Some(value)
        _ => None
      }
    _ => None
  }
}

///|
pub(all) struct EnvironmentHandle {
  environment_id : String
  container_name : String
  workspace_id : String
  worktree_id : String
  machine_id : String
  backend : String
  recipe : String
  recipe_hash : String
  state : String
  workdir : String
}

///|
pub fn EnvironmentHandle::from_record(
  record : EnvironmentRecord,
) -> EnvironmentHandle {
  {
    environment_id: record.id,
    container_name: record.container_name,
    workspace_id: record.workspace_id,
    worktree_id: record.worktree_id,
    machine_id: record.machine_id,
    backend: record.backend,
    recipe: record.recipe,
    recipe_hash: record.recipe_hash,
    state: record.state,
    workdir: record.workdir,
  }
}

///|
pub fn EnvironmentHandle::to_json(self : EnvironmentHandle) -> @json.Json {
  json_object([
    ("environment_id", json_string(self.environment_id)),
    ("container_name", json_string(self.container_name)),
    ("workspace_id", json_string(self.workspace_id)),
    ("worktree_id", json_string(self.worktree_id)),
    ("machine_id", json_string(self.machine_id)),
    ("backend", json_string(self.backend)),
    ("recipe", json_string(self.recipe)),
    ("recipe_hash", json_string(self.recipe_hash)),
    ("state", json_string(self.state)),
    ("workdir", json_string(self.workdir)),
  ])
}

///|
pub(all) struct EnvironmentEnvValue {
  name : String
  value : String
}

///|
/// Create request. `environment_id` is optional: an approval-required
/// response returns the proposed id, and the retry echoes it so the plan
/// digest (which includes the id) matches the grant. It also makes a
/// lost-response create idempotent.
pub(all) struct EnvironmentSpec {
  workspace_id : String
  worktree_id : String
  machine_id : String
  recipe : String
  environment_id : String
  env_values : Array[EnvironmentEnvValue]
  extra_mounts : Array[EnvironmentMount]
  ephemeral : Bool
  ttl_s : Int
  approval_id : String
  client_request_id : String
}

///|
pub fn environment_spec_from_params(
  params : Map[String, @json.Json],
) -> Result[EnvironmentSpec, String] {
  let workspace_id = match string_field(params, "workspace_id") {
    Some(value) if value != "" => value
    _ => return Err("workspace_id is required")
  }
  let recipe = match string_field(params, "recipe") {
    Some(value) if value != "" => value
    _ => return Err("recipe is required")
  }
  let env_values : Array[EnvironmentEnvValue] = []
  match params.get("env") {
    Some(@json.Json::Array(items)) => {
      for item in items {
        let object = match as_object(item) {
          Some(value) => value
          None => return Err("env entries must be objects with name and value")
        }
        let name = match string_field(object, "name") {
          Some(value) if value != "" => value
          _ => return Err("env entry name is required")
        }
        let value = match string_field(object, "value") {
          Some(value) => value
          None => return Err("env entry value is required")
        }
        env_values.push({ name, value })
      }
    }
    Some(_) => return Err("env must be an array")
    None => ()
  }
  let extra_mounts : Array[EnvironmentMount] = []
  match params.get("mounts") {
    Some(@json.Json::Array(items)) => {
      for item in items {
        let object = match as_object(item) {
          Some(value) => value
          None => return Err("mount entries must be objects")
        }
        let source = match string_field(object, "source") {
          Some(value) if value != "" => value
          _ => return Err("mount source is required")
        }
        let target = match string_field(object, "target") {
          Some(value) if value != "" => value
          _ => return Err("mount target is required")
        }
        let mode = match string_field(object, "mode") {
          Some("rw") => "rw"
          Some("ro") => "ro"
          Some(_) => return Err("mount mode must be ro or rw")
          None => "ro"
        }
        extra_mounts.push({
          source,
          host_path: "",
          container_path: target,
          mode,
        })
      }
    }
    Some(_) => return Err("mounts must be an array")
    None => ()
  }
  let ephemeral = bool_field_or(params, "ephemeral", false)
  let ttl_s = int_field_or(params, "ttl_s", 0)
  Ok({
    workspace_id,
    worktree_id: string_field_or(params, "worktree_id", ""),
    machine_id: string_field_or(params, "machine_id", ""),
    recipe,
    environment_id: string_field_or(params, "environment_id", ""),
    env_values,
    extra_mounts,
    ephemeral,
    ttl_s,
    approval_id: string_field_or(params, "approval_id", ""),
    client_request_id: string_field_or(params, "client_request_id", ""),
  })
}

// ---------------------------------------------------------------------------
// Doctor report
// ---------------------------------------------------------------------------

///|
pub(all) struct EnvironmentDoctorCheck {
  name : String
  ok : Bool
  detail : String
}

///|
pub fn EnvironmentDoctorCheck::to_json(
  self : EnvironmentDoctorCheck,
) -> @json.Json {
  json_object([
    ("name", json_string(self.name)),
    ("ok", json_bool(self.ok)),
    ("detail", json_string(self.detail)),
  ])
}

///|
pub(all) struct EnvironmentDoctorReport {
  environment_id : String
  container_name : String
  machine_id : String
  backend : String
  state : String
  healthy : Bool
  checks : Array[EnvironmentDoctorCheck]
  guidance : String
  observed_at : String
}

///|
pub fn EnvironmentDoctorReport::to_json(
  self : EnvironmentDoctorReport,
) -> @json.Json {
  json_object([
    ("environment_id", json_string(self.environment_id)),
    ("container_name", json_string(self.container_name)),
    ("machine_id", json_string(self.machine_id)),
    ("backend", json_string(self.backend)),
    ("state", json_string(self.state)),
    ("healthy", json_bool(self.healthy)),
    (
      "checks",
      json_array(self.checks.map(fn(check) { check.to_json() })),
    ),
    ("guidance", json_string(self.guidance)),
    ("observed_at", json_string(self.observed_at)),
  ])
}

// ---------------------------------------------------------------------------
// Recipe records
// ---------------------------------------------------------------------------

///|
pub const RECIPE_STATE_TRUSTED : String = "trusted"

///|
pub const RECIPE_STATE_REVOKED : String = "revoked"

///|
pub(all) struct RecipeRecord {
  id : String
  name : String
  version : String
  content_hash : String
  key_id : String
  state : String
  canonical : String
  signature : String
  source : String
  imported_at : String
  revoked_at : String
  refusal_reason : String
}

///|
pub fn RecipeRecord::to_json(self : RecipeRecord) -> @json.Json {
  json_object([
    ("id", json_string(self.id)),
    ("name", json_string(self.name)),
    ("version", json_string(self.version)),
    ("content_hash", json_string(self.content_hash)),
    ("key_id", json_string(self.key_id)),
    ("state", json_string(self.state)),
    ("canonical", json_string(self.canonical)),
    ("signature", json_string(self.signature)),
    ("source", json_string(self.source)),
    ("imported_at", json_string(self.imported_at)),
    ("revoked_at", json_string(self.revoked_at)),
    ("refusal_reason", json_string(self.refusal_reason)),
  ])
}

///|
pub fn recipe_record_from_json(json : @json.Json) -> RecipeRecord? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let id = match string_field(object, "id") {
    Some(value) => value
    None => return None
  }
  Some({
    id,
    name: string_field_or(object, "name", ""),
    version: string_field_or(object, "version", ""),
    content_hash: string_field_or(object, "content_hash", ""),
    key_id: string_field_or(object, "key_id", ""),
    state: string_field_or(object, "state", RECIPE_STATE_TRUSTED),
    canonical: string_field_or(object, "canonical", ""),
    signature: string_field_or(object, "signature", ""),
    source: string_field_or(object, "source", ""),
    imported_at: string_field_or(object, "imported_at", ""),
    revoked_at: string_field_or(object, "revoked_at", ""),
    refusal_reason: string_field_or(object, "refusal_reason", ""),
  })
}

///|
pub fn recipe_event_record(
  event : EventEnvelope,
) -> RecipeRecord? {
  match event.payload {
    @json.Json::Object(object) =>
      match object.get("recipe") {
        Some(value) => recipe_record_from_json(value)
        None => None
      }
    _ => None
  }
}

// ---------------------------------------------------------------------------
// Error / result shapes
// ---------------------------------------------------------------------------

///|
pub fn environment_error(
  kind : String,
  message : String,
  detail~ : String = "",
) -> @json.Json {
  if detail == "" {
    json_object([("kind", json_string(kind)), ("message", json_string(message))])
  } else {
    json_object([
      ("kind", json_string(kind)),
      ("message", json_string(message)),
      ("detail", json_string(detail)),
    ])
  }
}

///|
/// Structured `environment.exec` result. `cancelled` is always false for a
/// successful exec; a cancelled exec reports `exit_code = -1` and can never be
/// mistaken for success.
pub fn environment_exec_result(
  exec_id : String,
  exit_code : Int,
  stdout : String,
  stderr : String,
  timed_out : Bool,
  cancelled : Bool,
  truncated : Bool,
) -> @json.Json {
  json_object([
    ("exec_id", json_string(exec_id)),
    ("exit_code", json_int(exit_code)),
    ("stdout", json_string(stdout)),
    ("stderr", json_string(stderr)),
    ("timed_out", json_bool(timed_out)),
    ("cancelled", json_bool(cancelled)),
    ("truncated", json_bool(truncated)),
  ])
}

// ---------------------------------------------------------------------------
// One-time approval check (ADR-0013 §4.2)
// ---------------------------------------------------------------------------

///|
/// Validate an answered environment approval against one concrete plan.
/// A denial, expiry, reused grant or any binding mismatch fails closed; the
/// caller must not pull or create anything in that case.
pub fn environment_approval_check(
  decision : DecisionRecord,
  action : String,
  plan_digest : String,
  machine_id : String,
  recipe_hash : String,
  now_text : String,
) -> Result[Unit, String] {
  if decision.kind != DECISION_KIND_ENVIRONMENT_APPROVAL {
    return Err("decision is not an environment approval")
  }
  if decision.status != DECISION_STATUS_ANSWERED {
    return Err("approval has not been answered")
  }
  if decision.option_id != DECISION_OPTION_APPROVE {
    return Err("approval was denied")
  }
  if decision.action != action {
    return Err("approval action does not match")
  }
  if decision.plan_digest != plan_digest {
    return Err("approval plan digest does not match")
  }
  if decision.machine_id != machine_id {
    return Err("approval machine does not match")
  }
  if decision.recipe_hash != recipe_hash {
    return Err("approval recipe hash does not match")
  }
  if decision.nonce == "" {
    return Err("approval has no nonce")
  }
  if decision.consumed_at != "" {
    return Err("approval was already consumed")
  }
  let now_ms = match parse_rfc3339_ms(now_text) {
    Some(value) => value
    None => return Err("approval clock is not valid")
  }
  let expires_ms = match parse_rfc3339_ms(decision.expires_at) {
    Some(value) => value
    None => return Err("approval has expired")
  }
  if now_ms >= expires_ms {
    return Err("approval has expired")
  }
  Ok(())
}

// ---------------------------------------------------------------------------
// Param helpers (thin; the host validates every field again)
// ---------------------------------------------------------------------------

///|
pub fn environment_id_param(
  params : Map[String, @json.Json],
) -> Result[String, String] {
  match string_field(params, "environment_id") {
    Some(value) if value != "" => Ok(value)
    _ => Err("environment_id is required")
  }
}

///|
pub fn environment_create_params(
  client_request_id : String,
  workspace_id : String,
  recipe : String,
  worktree_id : String,
) -> Map[String, @json.Json] {
  let params : Map[String, @json.Json] = Map([])
  params.set("client_request_id", json_string(client_request_id))
  params.set("workspace_id", json_string(workspace_id))
  params.set("recipe", json_string(recipe))
  if worktree_id != "" {
    params.set("worktree_id", json_string(worktree_id))
  }
  params
}

///|
pub fn environment_exec_params(
  client_request_id : String,
  environment_id : String,
  exec_id : String,
  argv : Array[String],
) -> Map[String, @json.Json] {
  let params : Map[String, @json.Json] = Map([])
  params.set("client_request_id", json_string(client_request_id))
  params.set("environment_id", json_string(environment_id))
  params.set("exec_id", json_string(exec_id))
  params.set(
    "argv",
    json_array(argv.map(fn(arg) { json_string(arg) })),
  )
  params
}

///|
pub fn environment_exec_id_param(
  params : Map[String, @json.Json],
) -> Result[String, String] {
  match string_field(params, "exec_id") {
    Some(value) if value != "" && value.length() <= 128 => Ok(value)
    _ => Err("exec_id is required (bounded to 128 bytes)")
  }
}

///|
pub fn environment_exec_argv_param(
  params : Map[String, @json.Json],
) -> Result[Array[String], String] {
  match params.get("argv") {
    Some(@json.Json::Array(items)) => {
      let argv : Array[String] = []
      for item in items {
        match as_string(item) {
          Some(value) => argv.push(value)
          None => return Err("argv entries must be strings")
        }
      }
      if argv.is_empty() {
        return Err("argv is required and may not be empty")
      }
      Ok(argv)
    }
    _ => Err("argv must be a non-empty array of strings")
  }
}

///|
pub fn recipe_import_params(
  client_request_id : String,
  recipe : String,
  source : String,
) -> Map[String, @json.Json] {
  let params : Map[String, @json.Json] = Map([])
  params.set("client_request_id", json_string(client_request_id))
  params.set("recipe", json_string(recipe))
  if source != "" {
    params.set("source", json_string(source))
  }
  params
}
