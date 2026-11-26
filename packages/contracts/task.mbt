///|
/// Task / Run / Project / Evidence contracts (M5).
///
/// Task is the durable work item; Run is one execution attempt bound to a
/// task, an agent, a machine and (optionally) a worktree. State transitions
/// are pure functions here so the host and the tests share one definition.

// ---------------------------------------------------------------------------
// Task state machine
// ---------------------------------------------------------------------------

pub const TASK_STATUS_DRAFT : String = "draft"

pub const TASK_STATUS_PLANNED : String = "planned"

pub const TASK_STATUS_READY : String = "ready"

pub const TASK_STATUS_RUNNING : String = "running"

pub const TASK_STATUS_WAITING_APPROVAL : String = "waiting_approval"

pub const TASK_STATUS_WAITING_OWNER : String = "waiting_owner"

pub const TASK_STATUS_BLOCKED : String = "blocked"

pub const TASK_STATUS_FAILED : String = "failed"

pub const TASK_STATUS_SUCCEEDED : String = "succeeded"

pub const TASK_STATUS_CANCELLED : String = "cancelled"

///|
pub fn task_status_is_known(status : String) -> Bool {
  match status {
    "draft" | "planned" | "ready" | "running" | "waiting_approval" |
    "waiting_owner" | "blocked" | "failed" | "succeeded" | "cancelled" =>
      true
    _ => false
  }
}

///|
pub fn task_status_is_terminal(status : String) -> Bool {
  status == TASK_STATUS_FAILED ||
  status == TASK_STATUS_SUCCEEDED ||
  status == TASK_STATUS_CANCELLED
}

///|
pub fn task_status_is_active(status : String) -> Bool {
  status == TASK_STATUS_PLANNED ||
  status == TASK_STATUS_READY ||
  status == TASK_STATUS_RUNNING ||
  status == TASK_STATUS_WAITING_APPROVAL ||
  status == TASK_STATUS_WAITING_OWNER ||
  status == TASK_STATUS_BLOCKED
}

///|
/// Allowed Task transitions. `cancelled` and `failed` are reachable from any
/// non-terminal state; `succeeded` only from `running`/`waiting_*` (i.e. after
/// all runs settled). Terminal states never move again.
pub fn task_transition_allowed(from : String, to : String) -> Bool {
  if from == to {
    return false
  }
  if task_status_is_terminal(from) {
    return false
  }
  if to == TASK_STATUS_CANCELLED || to == TASK_STATUS_FAILED {
    return true
  }
  match from {
    "draft" =>
      to == TASK_STATUS_PLANNED || to == TASK_STATUS_READY
    "planned" => to == TASK_STATUS_READY || to == TASK_STATUS_RUNNING
    "ready" => to == TASK_STATUS_RUNNING
    "running" =>
      to == TASK_STATUS_WAITING_APPROVAL ||
      to == TASK_STATUS_WAITING_OWNER ||
      to == TASK_STATUS_BLOCKED ||
      to == TASK_STATUS_SUCCEEDED ||
      to == TASK_STATUS_READY
    "waiting_approval" | "waiting_owner" =>
      to == TASK_STATUS_RUNNING || to == TASK_STATUS_SUCCEEDED
    "blocked" => to == TASK_STATUS_RUNNING || to == TASK_STATUS_READY
    _ => false
  }
}

// ---------------------------------------------------------------------------
// Run state machine
// ---------------------------------------------------------------------------

pub const RUN_STATUS_QUEUED : String = "queued"

pub const RUN_STATUS_RUNNING : String = "running"

pub const RUN_STATUS_WAITING_APPROVAL : String = "waiting_approval"

pub const RUN_STATUS_WAITING_INPUT : String = "waiting_input"

pub const RUN_STATUS_VERIFYING : String = "verifying"

pub const RUN_STATUS_SUCCEEDED : String = "succeeded"

pub const RUN_STATUS_FAILED : String = "failed"

pub const RUN_STATUS_CANCELLED : String = "cancelled"

pub const RUN_STATUS_LOST : String = "lost"

///|
pub fn run_status_is_known(status : String) -> Bool {
  match status {
    "queued" | "running" | "waiting_approval" | "waiting_input" | "verifying" |
    "succeeded" | "failed" | "cancelled" | "lost" =>
      true
    _ => false
  }
}

///|
pub fn run_status_is_terminal(status : String) -> Bool {
  status == RUN_STATUS_SUCCEEDED ||
  status == RUN_STATUS_FAILED ||
  status == RUN_STATUS_CANCELLED
}

///|
/// `lost` is not terminal: reconcile decides between retry and failure.
pub fn run_status_is_active(status : String) -> Bool {
  status == RUN_STATUS_QUEUED ||
  status == RUN_STATUS_RUNNING ||
  status == RUN_STATUS_WAITING_APPROVAL ||
  status == RUN_STATUS_WAITING_INPUT ||
  status == RUN_STATUS_VERIFYING ||
  status == RUN_STATUS_LOST
}

///|
/// Runs that occupy a machine slot for scheduling.
pub fn run_status_occupies_slot(status : String) -> Bool {
  status == RUN_STATUS_RUNNING ||
  status == RUN_STATUS_VERIFYING ||
  status == RUN_STATUS_WAITING_APPROVAL ||
  status == RUN_STATUS_WAITING_INPUT
}

///|
pub fn run_transition_allowed(from : String, to : String) -> Bool {
  if from == to {
    return false
  }
  if run_status_is_terminal(from) {
    return false
  }
  if to == RUN_STATUS_CANCELLED {
    return true
  }
  match from {
    "queued" => to == RUN_STATUS_RUNNING || to == RUN_STATUS_LOST
    "running" =>
      to == RUN_STATUS_VERIFYING ||
      to == RUN_STATUS_WAITING_APPROVAL ||
      to == RUN_STATUS_WAITING_INPUT ||
      to == RUN_STATUS_FAILED ||
      to == RUN_STATUS_LOST
    "waiting_approval" =>
      to == RUN_STATUS_QUEUED ||
      to == RUN_STATUS_RUNNING ||
      to == RUN_STATUS_VERIFYING ||
      to == RUN_STATUS_SUCCEEDED ||
      to == RUN_STATUS_FAILED
    "waiting_input" =>
      to == RUN_STATUS_RUNNING || to == RUN_STATUS_FAILED
    "verifying" =>
      to == RUN_STATUS_SUCCEEDED ||
      to == RUN_STATUS_FAILED ||
      to == RUN_STATUS_WAITING_APPROVAL ||
      to == RUN_STATUS_LOST
    "lost" => to == RUN_STATUS_RUNNING || to == RUN_STATUS_FAILED
    _ => false
  }
}

// ---------------------------------------------------------------------------
// Records
// ---------------------------------------------------------------------------

///|
pub(all) struct ProjectRecord {
  id : String
  name : String
  repo_url : String
  default_branch : String
  verify : Array[String]
  created_at : String
}

///|
pub fn ProjectRecord::new(
  id~ : String,
  name~ : String,
  repo_url~ : String,
  default_branch~ : String,
  verify~ : Array[String],
  created_at~ : String,
) -> ProjectRecord {
  { id, name, repo_url, default_branch, verify, created_at }
}

///|
pub fn ProjectRecord::to_json(self : ProjectRecord) -> @json.Json {
  json_object([
    ("id", json_string(self.id)),
    ("name", json_string(self.name)),
    ("repo_url", json_string(self.repo_url)),
    ("default_branch", json_string(self.default_branch)),
    ("verify", json_string_array(self.verify)),
    ("created_at", json_string(self.created_at)),
  ])
}

///|
pub fn project_from_json(json : @json.Json) -> ProjectRecord? {
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
    repo_url: string_field_or(object, "repo_url", ""),
    default_branch: string_field_or(object, "default_branch", "main"),
    verify: string_array_field(object, "verify"),
    created_at: string_field_or(object, "created_at", ""),
  })
}

///|
pub(all) struct TaskRecord {
  id : String
  title : String
  goal : String
  status : String
  parent_id : String
  project_id : String
  agent_id : String
  workspace_id : String
  verify : Array[String]
  result_summary : String
  cancel_reason : String
  created_at : String
  updated_at : String
  /// Present only for Tasks created by a trigger (ADR-0014 §2.4). Ordinary
  /// Tasks keep `None`, so their events stay byte-identical to pre-A3 hosts.
  origin : TriggerOrigin?
}

///|
pub fn TaskRecord::new(
  id~ : String,
  title~ : String,
  goal~ : String,
  parent_id~ : String,
  project_id~ : String,
  agent_id~ : String,
  workspace_id~ : String,
  verify~ : Array[String],
  created_at~ : String,
  status~ : String = TASK_STATUS_DRAFT,
  origin~ : TriggerOrigin? = None,
) -> TaskRecord {
  {
    id,
    title,
    goal,
    status,
    parent_id,
    project_id,
    agent_id,
    workspace_id,
    verify,
    result_summary: "",
    cancel_reason: "",
    created_at,
    updated_at: created_at,
    origin,
  }
}

///|
pub fn TaskRecord::to_json(self : TaskRecord) -> @json.Json {
  let entries : Array[(String, @json.Json)] = [
    ("id", json_string(self.id)),
    ("title", json_string(self.title)),
    ("goal", json_string(self.goal)),
    ("status", json_string(self.status)),
    ("parent_id", json_string(self.parent_id)),
    ("project_id", json_string(self.project_id)),
    ("agent_id", json_string(self.agent_id)),
    ("workspace_id", json_string(self.workspace_id)),
    ("verify", json_string_array(self.verify)),
    ("result_summary", json_string(self.result_summary)),
    ("cancel_reason", json_string(self.cancel_reason)),
    ("created_at", json_string(self.created_at)),
    ("updated_at", json_string(self.updated_at)),
  ]
  match self.origin {
    Some(origin) => entries.push(("origin", origin.to_json()))
    None => ()
  }
  json_object(entries)
}

///|
pub fn task_from_json(json : @json.Json) -> TaskRecord? {
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
    title: string_field_or(object, "title", ""),
    goal: string_field_or(object, "goal", ""),
    status: string_field_or(object, "status", TASK_STATUS_DRAFT),
    parent_id: string_field_or(object, "parent_id", ""),
    project_id: string_field_or(object, "project_id", ""),
    agent_id: string_field_or(object, "agent_id", ""),
    workspace_id: string_field_or(object, "workspace_id", ""),
    verify: string_array_field(object, "verify"),
    result_summary: string_field_or(object, "result_summary", ""),
    cancel_reason: string_field_or(object, "cancel_reason", ""),
    created_at: string_field_or(object, "created_at", ""),
    updated_at: string_field_or(object, "updated_at", ""),
    origin: match object.get("origin") {
      Some(value) => trigger_origin_from_json(value)
      None => None
    },
  })
}

///|
pub(all) struct RunRecord {
  id : String
  task_id : String
  agent_id : String
  machine_id : String
  workspace_id : String
  worktree_id : String
  environment_id : String
  session_id : String
  mode : String
  command : String
  prompt : String
  agent_command : String
  agent_args : Array[String]
  agent_env : Map[String, String]
  status : String
  stop_reason : String
  idempotency_key : String
  attempt : Int
  tmux_session : String
  log_path : String
  exit_path : String
  durable : String
  exit_code : Int
  retried_from : String
  output_summary : String
  last_error : String
  created_at : String
  started_at : String
  finished_at : String
  updated_at : String
}

///|
pub fn RunRecord::new(
  id~ : String,
  task_id~ : String,
  agent_id~ : String,
  machine_id~ : String,
  workspace_id~ : String,
  worktree_id~ : String,
  mode~ : String,
  command~ : String,
  prompt~ : String,
  idempotency_key~ : String,
  created_at~ : String,
  agent_command~ : String = "",
  agent_args~ : Array[String] = [],
  agent_env~ : Map[String, String] = Map([]),
  environment_id~ : String = "",
) -> RunRecord {
  {
    id,
    task_id,
    agent_id,
    machine_id,
    workspace_id,
    worktree_id,
    environment_id,
    session_id: "",
    mode,
    command,
    prompt,
    agent_command,
    agent_args,
    agent_env,
    status: RUN_STATUS_QUEUED,
    stop_reason: "",
    idempotency_key,
    attempt: 1,
    tmux_session: "",
    log_path: "",
    exit_path: "",
    durable: "",
    exit_code: -1,
    retried_from: "",
    output_summary: "",
    last_error: "",
    created_at,
    started_at: "",
    finished_at: "",
    updated_at: created_at,
  }
}

///|
pub fn RunRecord::to_json(self : RunRecord) -> @json.Json {
  json_object([
    ("id", json_string(self.id)),
    ("task_id", json_string(self.task_id)),
    ("agent_id", json_string(self.agent_id)),
    ("machine_id", json_string(self.machine_id)),
    ("workspace_id", json_string(self.workspace_id)),
    ("worktree_id", json_string(self.worktree_id)),
    ("environment_id", json_string(self.environment_id)),
    ("session_id", json_string(self.session_id)),
    ("mode", json_string(self.mode)),
    ("command", json_string(self.command)),
    ("prompt", json_string(self.prompt)),
    ("agent_command", json_string(self.agent_command)),
    ("agent_args", json_string_array(self.agent_args)),
    ("agent_env", agent_env_json(self.agent_env)),
    ("status", json_string(self.status)),
    ("stop_reason", json_string(self.stop_reason)),
    ("idempotency_key", json_string(self.idempotency_key)),
    ("attempt", json_int(self.attempt)),
    ("tmux_session", json_string(self.tmux_session)),
    ("log_path", json_string(self.log_path)),
    ("exit_path", json_string(self.exit_path)),
    ("durable", json_string(self.durable)),
    ("exit_code", json_int(self.exit_code)),
    ("retried_from", json_string(self.retried_from)),
    ("output_summary", json_string(self.output_summary)),
    ("last_error", json_string(self.last_error)),
    ("created_at", json_string(self.created_at)),
    ("started_at", json_string(self.started_at)),
    ("finished_at", json_string(self.finished_at)),
    ("updated_at", json_string(self.updated_at)),
  ])
}

///|
pub fn run_from_json(json : @json.Json) -> RunRecord? {
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
    task_id: string_field_or(object, "task_id", ""),
    agent_id: string_field_or(object, "agent_id", ""),
    machine_id: string_field_or(object, "machine_id", ""),
    workspace_id: string_field_or(object, "workspace_id", ""),
    worktree_id: string_field_or(object, "worktree_id", ""),
    environment_id: string_field_or(object, "environment_id", ""),
    session_id: string_field_or(object, "session_id", ""),
    mode: string_field_or(object, "mode", RUN_MODE_COMMAND),
    command: string_field_or(object, "command", ""),
    prompt: string_field_or(object, "prompt", ""),
    agent_command: string_field_or(object, "agent_command", ""),
    agent_args: string_array_field(object, "agent_args"),
    agent_env: agent_env_from_object(object, "agent_env"),
    status: string_field_or(object, "status", RUN_STATUS_QUEUED),
    stop_reason: string_field_or(object, "stop_reason", ""),
    idempotency_key: string_field_or(object, "idempotency_key", ""),
    attempt: int_field_or(object, "attempt", 1),
    tmux_session: string_field_or(object, "tmux_session", ""),
    log_path: string_field_or(object, "log_path", ""),
    exit_path: string_field_or(object, "exit_path", ""),
    durable: string_field_or(object, "durable", ""),
    exit_code: int_field_or(object, "exit_code", -1),
    retried_from: string_field_or(object, "retried_from", ""),
    output_summary: string_field_or(object, "output_summary", ""),
    last_error: string_field_or(object, "last_error", ""),
    created_at: string_field_or(object, "created_at", ""),
    started_at: string_field_or(object, "started_at", ""),
    finished_at: string_field_or(object, "finished_at", ""),
    updated_at: string_field_or(object, "updated_at", ""),
  })
}

///|
pub const RUN_MODE_COMMAND : String = "command"

///|
pub const RUN_MODE_AGENT : String = "agent"

///|
/// Stop reasons shared by recovery and the evidence gate (architecture §13).
/// `lost` = the durable session is gone and the exit is unknowable; the host
/// retries once. `exited` = the process exited and its code is known; retry
/// once. `unverifiable` = the host cannot observe the process at all; never
/// retried automatically, always escalated to an owner Decision.
pub const STOP_REASON_EXITED : String = "exited"

///|
pub const STOP_REASON_LOST : String = "lost"

///|
pub const STOP_REASON_UNVERIFIABLE : String = "unverifiable"

///|
pub const STOP_REASON_HOST_RESTARTED : String = "host_restarted"

///|
pub const STOP_REASON_VERIFIED : String = "verified"

///|
pub const STOP_REASON_POLICY_DENIED : String = "policy_denied"

///|
pub const STOP_REASON_APPROVAL_DENIED : String = "approval_denied"

///|
pub(all) struct EvidenceRecord {
  id : String
  run_id : String
  name : String
  kind : String
  command : String
  exit_code : Int
  passed : Bool
  waived : Bool
  timed_out : Bool
  artifact_id : String
  excerpt : String
  started_at : String
  finished_at : String
}

///|
pub fn EvidenceRecord::new(
  id~ : String,
  run_id~ : String,
  name~ : String,
  kind~ : String,
  command~ : String,
  started_at~ : String,
) -> EvidenceRecord {
  {
    id,
    run_id,
    name,
    kind,
    command,
    exit_code: 0,
    passed: false,
    waived: false,
    timed_out: false,
    artifact_id: "",
    excerpt: "",
    started_at,
    finished_at: "",
  }
}

///|
pub fn EvidenceRecord::to_json(self : EvidenceRecord) -> @json.Json {
  json_object([
    ("id", json_string(self.id)),
    ("run_id", json_string(self.run_id)),
    ("name", json_string(self.name)),
    ("kind", json_string(self.kind)),
    ("command", json_string(self.command)),
    ("exit_code", json_int(self.exit_code)),
    ("passed", json_bool(self.passed)),
    ("waived", json_bool(self.waived)),
    ("timed_out", json_bool(self.timed_out)),
    ("artifact_id", json_string(self.artifact_id)),
    ("excerpt", json_string(self.excerpt)),
    ("started_at", json_string(self.started_at)),
    ("finished_at", json_string(self.finished_at)),
  ])
}

///|
pub fn evidence_from_json(json : @json.Json) -> EvidenceRecord? {
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
    run_id: string_field_or(object, "run_id", ""),
    name: string_field_or(object, "name", ""),
    kind: string_field_or(object, "kind", "test"),
    command: string_field_or(object, "command", ""),
    exit_code: int_field_or(object, "exit_code", 0),
    passed: bool_field_or(object, "passed", false),
    waived: bool_field_or(object, "waived", false),
    timed_out: bool_field_or(object, "timed_out", false),
    artifact_id: string_field_or(object, "artifact_id", ""),
    excerpt: string_field_or(object, "excerpt", ""),
    started_at: string_field_or(object, "started_at", ""),
    finished_at: string_field_or(object, "finished_at", ""),
  })
}

///|
pub(all) struct RunDetail {
  run : RunRecord
  evidence : Array[EvidenceRecord]
  artifacts : Array[ArtifactRecord]
  diff : String
}

///|
pub fn RunDetail::to_json(self : RunDetail) -> @json.Json {
  json_object([
    ("run", self.run.to_json()),
    ("evidence", json_array(self.evidence.map(fn(e) { e.to_json() }))),
    ("artifacts", json_array(self.artifacts.map(fn(a) { a.to_json() }))),
    ("diff", json_string(self.diff)),
  ])
}

// ---------------------------------------------------------------------------
// RPC methods
// ---------------------------------------------------------------------------

pub const METHOD_PROJECT_CREATE : String = "project.create"

pub const METHOD_PROJECT_LIST : String = "project.list"

pub const METHOD_TASK_CREATE : String = "task.create"

pub const METHOD_TASK_LIST : String = "task.list"

pub const METHOD_TASK_GET : String = "task.get"

pub const METHOD_TASK_CANCEL : String = "task.cancel"

pub const METHOD_RUN_CREATE : String = "run.create"

pub const METHOD_RUN_LIST : String = "run.list"

pub const METHOD_RUN_GET : String = "run.get"

pub const METHOD_RUN_CANCEL : String = "run.cancel"

pub const METHOD_ARTIFACT_READ : String = "artifact.read"

pub const METHOD_EVENTS_LIST : String = "events.list"

pub const METHOD_SEARCH_SESSIONS : String = "search.sessions"

// ---------------------------------------------------------------------------
// Event types (architecture §5.2)
// ---------------------------------------------------------------------------

pub const EVENT_PROJECT_CREATED : String = "project.created"

pub const EVENT_TASK_CREATED : String = "task.created"

pub const EVENT_TASK_ASSIGNED : String = "task.assigned"

pub const EVENT_TASK_STATUS_CHANGED : String = "task.status.changed"

pub const EVENT_TASK_CANCELLED : String = "task.cancelled"

pub const EVENT_RUN_QUEUED : String = "run.queued"

pub const EVENT_RUN_STARTED : String = "run.started"

pub const EVENT_RUN_PROGRESS : String = "run.progress"

pub const EVENT_RUN_HEARTBEAT : String = "run.heartbeat"

pub const EVENT_RUN_VERIFYING : String = "run.verifying"

pub const EVENT_RUN_EVIDENCE : String = "run.evidence"

pub const EVENT_RUN_SUCCEEDED : String = "run.succeeded"

pub const EVENT_RUN_FAILED : String = "run.failed"

pub const EVENT_RUN_CANCELLED : String = "run.cancelled"

pub const EVENT_RUN_LOST : String = "run.lost"

///|
/// A recovery action ran for a Run (reattach, retry, escalated to a Decision,
/// failed). The audit payload carries the detail; this event wakes the UI.
pub const EVENT_RUN_RECOVERED : String = "run.recovered"

pub const EVENT_RUN_WAITING_APPROVAL : String = "run.waiting_approval"

pub const EVENT_ARTIFACT_CREATED : String = "artifact.created"

pub const DECISION_KIND_VERIFY : String = "verify"

///|
/// Policy approval: a high-risk command waits for an owner Decision before it
/// is queued (same queue as verify, permission and recovery Decisions).
pub const DECISION_KIND_APPROVAL : String = "approval"

///|
/// Recovery: a run stopped in a state the host cannot settle alone. Options
/// are `retry` (explicit owner retry), `fail` and `waive` for partial
/// artifacts where applicable.
pub const DECISION_KIND_RECOVERY : String = "recovery"

///|
pub const DECISION_OPTION_APPROVE : String = "approve"

///|
pub const DECISION_OPTION_DENY : String = "deny"

pub const DECISION_OPTION_WAIVE : String = "waive"

pub const DECISION_OPTION_FAIL : String = "fail"

pub const DECISION_OPTION_RETRY : String = "retry"

// ---------------------------------------------------------------------------
// Param / result helpers
// ---------------------------------------------------------------------------

///|
pub fn task_id_param(
  params : Map[String, @json.Json],
) -> Result[String, String] {
  match string_field(params, "task_id") {
    Some(value) if value.trim() != "" => Ok(value)
    _ => Err("missing task_id")
  }
}

///|
pub fn run_id_param(
  params : Map[String, @json.Json],
) -> Result[String, String] {
  match string_field(params, "run_id") {
    Some(value) if value.trim() != "" => Ok(value)
    _ => Err("missing run_id")
  }
}

///|
pub fn artifact_id_param(
  params : Map[String, @json.Json],
) -> Result[String, String] {
  match string_field(params, "artifact_id") {
    Some(value) if value.trim() != "" => Ok(value)
    _ => Err("missing artifact_id")
  }
}

///|
/// Parse a project verify list. Accepts either a JSON array of strings or a
/// single string with one command per line.
pub fn verify_list_param(
  params : Map[String, @json.Json],
  key : String,
) -> Array[String] {
  match params.get(key) {
    Some(@json.Json::Array(items)) => {
      let out : Array[String] = []
      for item in items {
        match item {
          @json.Json::String(value) =>
            if value.trim() != "" {
              out.push(value)
            }
          _ => ()
        }
      }
      out
    }
    Some(@json.Json::String(value)) => {
      let out : Array[String] = []
      for piece in value.split("\n") {
        let line = piece.to_string()
        if line.trim() != "" {
          out.push(line)
        }
      }
      out
    }
    _ => []
  }
}

///|
pub fn task_result(record : TaskRecord) -> @json.Json {
  json_object([("task", record.to_json())])
}

///|
pub fn tasks_result(records : Array[TaskRecord]) -> @json.Json {
  json_object([
    ("tasks", json_array(records.map(fn(r) { r.to_json() }))),
  ])
}

///|
pub fn run_result(record : RunRecord) -> @json.Json {
  json_object([("run", record.to_json())])
}

///|
pub fn runs_result(records : Array[RunRecord]) -> @json.Json {
  json_object([("runs", json_array(records.map(fn(r) { r.to_json() })))])
}

///|
pub fn parse_task_list(json : @json.Json) -> Result[Array[TaskRecord], String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("task.list result is not an object")
  }
  let items = match object.get("tasks") {
    Some(@json.Json::Array(values)) => values
    _ => return Err("task.list result has no tasks array")
  }
  let out : Array[TaskRecord] = []
  for item in items {
    match task_from_json(item) {
      Some(record) => out.push(record)
      None => return Err("corrupt task record")
    }
  }
  Ok(out)
}

///|
pub fn parse_run_list(json : @json.Json) -> Result[Array[RunRecord], String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("run.list result is not an object")
  }
  let items = match object.get("runs") {
    Some(@json.Json::Array(values)) => values
    _ => return Err("run.list result has no runs array")
  }
  let out : Array[RunRecord] = []
  for item in items {
    match run_from_json(item) {
      Some(record) => out.push(record)
      None => return Err("corrupt run record")
    }
  }
  Ok(out)
}

///|
pub fn parse_run_detail(json : @json.Json) -> Result[RunDetail, String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("run.get result is not an object")
  }
  let run = match object.get("run") {
    Some(value) =>
      match run_from_json(value) {
        Some(record) => record
        None => return Err("corrupt run record")
      }
    None => return Err("run.get result has no run")
  }
  let evidence : Array[EvidenceRecord] = []
  match object.get("evidence") {
    Some(@json.Json::Array(items)) =>
      for item in items {
        match evidence_from_json(item) {
          Some(record) => evidence.push(record)
          None => ()
        }
      }
    _ => ()
  }
  let artifacts : Array[ArtifactRecord] = []
  match object.get("artifacts") {
    Some(@json.Json::Array(items)) =>
      for item in items {
        match artifact_from_json(item) {
          Some(record) => artifacts.push(record)
          None => ()
        }
      }
    _ => ()
  }
  let diff = string_field_or(object, "diff", "")
  Ok({ run, evidence, artifacts, diff })
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

///|
pub(all) struct SearchHit {
  kind : String
  ref_id : String
  title : String
  snippet : String
  ts : String
}

///|
pub fn SearchHit::to_json(self : SearchHit) -> @json.Json {
  json_object([
    ("kind", json_string(self.kind)),
    ("ref_id", json_string(self.ref_id)),
    ("title", json_string(self.title)),
    ("snippet", json_string(self.snippet)),
    ("ts", json_string(self.ts)),
  ])
}

///|
pub fn search_hits_result(hits : Array[SearchHit]) -> @json.Json {
  json_object([
    ("hits", json_array(hits.map(fn(h) { h.to_json() }))),
  ])
}

///|
pub fn parse_search_hits(json : @json.Json) -> Result[Array[SearchHit], String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("search result is not an object")
  }
  let items = match object.get("hits") {
    Some(@json.Json::Array(values)) => values
    _ => return Err("search result has no hits array")
  }
  let out : Array[SearchHit] = []
  for item in items {
    let fields = match as_object(item) {
      Some(value) => value
      None => continue
    }
    out.push({
      kind: string_field_or(fields, "kind", ""),
      ref_id: string_field_or(fields, "ref_id", ""),
      title: string_field_or(fields, "title", ""),
      snippet: string_field_or(fields, "snippet", ""),
      ts: string_field_or(fields, "ts", ""),
    })
  }
  Ok(out)
}
