///|
/// Agent runtime contracts (M4, ADR-0005/0006).
///
/// One agent session is owned by the host: the host keeps metadata, the
/// transcript cursor and the pending Decisions; the adapter process (ACP
/// stdio sidecar or a line-oriented CLI) owns the model conversation. The
/// desktop only observes `agent.read` and answers Decisions through the same
/// `decision.respond` channel used for approvals.

// ---------------------------------------------------------------------------
// RPC methods
// ---------------------------------------------------------------------------

///|
pub const METHOD_AGENT_PROBE : String = "agent.probe"

///|
pub const METHOD_AGENT_START : String = "agent.start"

///|
pub const METHOD_AGENT_SEND : String = "agent.send"

///|
pub const METHOD_AGENT_STOP : String = "agent.stop"

///|
pub const METHOD_AGENT_READ : String = "agent.read"

///|
pub const METHOD_AGENT_LIST : String = "agent.list"

///|
pub const METHOD_AGENT_RESUME : String = "agent.resume"

///|
pub const METHOD_AGENT_MEMORY_READ : String = "agent.memory.read"

///|
pub const METHOD_AGENT_MEMORY_WRITE : String = "agent.memory.write"

///|
pub const METHOD_DECISION_LIST : String = "decision.list"

///|
pub const METHOD_DECISION_RESPOND : String = "decision.respond"

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

///|
pub const EVENT_AGENT_READINESS_OK : String = "agent.readiness.ok"

///|
pub const EVENT_AGENT_READINESS_FAILED : String = "agent.readiness.failed"

///|
pub const EVENT_AGENT_SESSION_STARTED : String = "agent.session.started"

///|
pub const EVENT_AGENT_SESSION_RESUMED : String = "agent.session.resumed"

///|
pub const EVENT_AGENT_SESSION_OUTPUT : String = "agent.session.output"

///|
/// State-only session update (running/idle/waiting_decision). Carries the
/// full session record so projections stay current between output events.
pub const EVENT_AGENT_SESSION_UPDATED : String = "agent.session.updated"

///|
pub const EVENT_AGENT_SESSION_STOPPED : String = "agent.session.stopped"

///|
pub const EVENT_AGENT_SESSION_EXITED : String = "agent.session.exited"

///|
pub const EVENT_AGENT_ARTIFACT_CREATED : String = "agent.artifact.created"

///|
pub const EVENT_AGENT_MEMORY_UPDATED : String = "agent.memory.updated"

///|
pub const EVENT_DECISION_REQUESTED : String = "decision.requested"

///|
pub const EVENT_DECISION_RESPONDED : String = "decision.responded"

///|
pub const EVENT_DECISION_EXPIRED : String = "decision.expired"

// ---------------------------------------------------------------------------
// Errors / labels
// ---------------------------------------------------------------------------

///|
pub const AGENT_ERR_INVALID : String = "invalid"

///|
pub const AGENT_ERR_NOT_FOUND : String = "not_found"

///|
pub const AGENT_ERR_CONFLICT : String = "conflict"

///|
pub const AGENT_ERR_READINESS : String = "readiness"

///|
pub const AGENT_ERR_UNAUTHORIZED : String = "unauthorized"

///|
pub const AGENT_ERR_UNSUPPORTED : String = "unsupported"

///|
pub const AGENT_ERR_INTERNAL : String = "internal"

///|
pub fn agent_error_label(kind : String) -> String {
  match kind {
    "invalid" => "InvalidRequest"
    "not_found" => "NotFound"
    "conflict" => "Conflict"
    "readiness" => "NotReady"
    "unauthorized" => "Unauthorized"
    "unsupported" => "Unsupported"
    _ => "Internal"
  }
}

///|
pub fn agent_error(kind : String, message : String) -> RpcError {
  RpcError::new(
    ERR_HOST,
    agent_error_label(kind) + ": " + message,
    data=json_object([
      ("kind", json_string(kind)),
      ("reason", json_string(message)),
    ]),
  )
}

// ---------------------------------------------------------------------------
// States / modes
// ---------------------------------------------------------------------------

///|
pub const AGENT_MODE_ACP : String = "acp"

///|
pub const AGENT_MODE_STDOUT : String = "stdout"

///|
pub const AGENT_STATE_STARTING : String = "starting"

///|
pub const AGENT_STATE_IDLE : String = "idle"

///|
pub const AGENT_STATE_RUNNING : String = "running"

///|
pub const AGENT_STATE_WAITING : String = "waiting_decision"

///|
pub const AGENT_STATE_STOPPED : String = "stopped"

///|
pub const AGENT_STATE_EXITED : String = "exited"

///|
pub const AGENT_STATE_FAILED : String = "failed"

///|
pub fn agent_state_is_active(state : String) -> Bool {
  match state {
    "starting" | "idle" | "running" | "waiting_decision" => true
    _ => false
  }
}

///|
pub const AGENT_STOP_END_TURN : String = "end_turn"

///|
pub const AGENT_STOP_CANCELLED : String = "cancelled"

///|
pub const AGENT_STOP_ERROR : String = "error"

///|
pub const AGENT_STOP_EXITED : String = "exited"

///|
pub const AGENT_STOP_HOST_RESTART : String = "host_restarted"

// ---------------------------------------------------------------------------
// Records
// ---------------------------------------------------------------------------

///|
pub(all) struct AgentReadiness {
  ok : Bool
  agent_id : String
  mode : String
  command : String
  resolved_command : String
  acp_version : String
  agent_name : String
  agent_version : String
  load_session : Bool
  auth : String
  error : String
  detail : String
  checked_at : String
}

///|
pub fn AgentReadiness::new(
  ok~ : Bool,
  agent_id~ : String,
  mode~ : String,
  command~ : String,
) -> AgentReadiness {
  {
    ok,
    agent_id,
    mode,
    command,
    resolved_command: "",
    acp_version: "",
    agent_name: "",
    agent_version: "",
    load_session: false,
    auth: "unknown",
    error: "",
    detail: "",
    checked_at: "",
  }
}

///|
pub fn AgentReadiness::to_json(self : AgentReadiness) -> @json.Json {
  json_object([
    ("ok", json_bool(self.ok)),
    ("agent_id", json_string(self.agent_id)),
    ("mode", json_string(self.mode)),
    ("command", json_string(self.command)),
    ("resolved_command", json_string(self.resolved_command)),
    ("acp_version", json_string(self.acp_version)),
    ("agent_name", json_string(self.agent_name)),
    ("agent_version", json_string(self.agent_version)),
    ("load_session", json_bool(self.load_session)),
    ("auth", json_string(self.auth)),
    ("error", json_string(self.error)),
    ("detail", json_string(self.detail)),
    ("checked_at", json_string(self.checked_at)),
  ])
}

///|
pub fn agent_readiness_from_json(json : @json.Json) -> AgentReadiness? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  Some({
    ok: bool_field_or(object, "ok", false),
    agent_id: string_field_or(object, "agent_id", ""),
    mode: string_field_or(object, "mode", AGENT_MODE_ACP),
    command: string_field_or(object, "command", ""),
    resolved_command: string_field_or(object, "resolved_command", ""),
    acp_version: string_field_or(object, "acp_version", ""),
    agent_name: string_field_or(object, "agent_name", ""),
    agent_version: string_field_or(object, "agent_version", ""),
    load_session: bool_field_or(object, "load_session", false),
    auth: string_field_or(object, "auth", "unknown"),
    error: string_field_or(object, "error", ""),
    detail: string_field_or(object, "detail", ""),
    checked_at: string_field_or(object, "checked_at", ""),
  })
}

///|
pub(all) struct AgentSessionRecord {
  id : String
  agent_id : String
  mode : String
  workspace_id : String
  worktree_id : String
  cwd : String
  command : String
  args : Array[String]
  state : String
  acp_session_id : String
  agent_name : String
  acp_version : String
  load_session : Bool
  stop_reason : String
  last_error : String
  stderr_tail : String
  turns : Int
  chunks : Int
  decisions : Int
  memory_injected : Bool
  memory_bytes : Int
  artifacts : Array[String]
  started_at : String
  updated_at : String
  ended_at : String
}

///|
pub fn AgentSessionRecord::new(
  id~ : String,
  agent_id~ : String,
  mode~ : String,
  cwd~ : String,
  started_at~ : String,
) -> AgentSessionRecord {
  {
    id,
    agent_id,
    mode,
    workspace_id: "",
    worktree_id: "",
    cwd,
    command: "",
    args: [],
    state: AGENT_STATE_STARTING,
    acp_session_id: "",
    agent_name: "",
    acp_version: "",
    load_session: false,
    stop_reason: "",
    last_error: "",
    stderr_tail: "",
    turns: 0,
    chunks: 0,
    decisions: 0,
    memory_injected: false,
    memory_bytes: 0,
    artifacts: [],
    started_at,
    updated_at: started_at,
    ended_at: "",
  }
}

///|
pub fn AgentSessionRecord::to_json(self : AgentSessionRecord) -> @json.Json {
  let args = json_array(
    self.args.map(fn(value) { json_string(value) }),
  )
  let artifacts = json_array(
    self.artifacts.map(fn(value) { json_string(value) }),
  )
  json_object([
    ("id", json_string(self.id)),
    ("agent_id", json_string(self.agent_id)),
    ("mode", json_string(self.mode)),
    ("workspace_id", json_string(self.workspace_id)),
    ("worktree_id", json_string(self.worktree_id)),
    ("cwd", json_string(self.cwd)),
    ("command", json_string(self.command)),
    ("args", args),
    ("state", json_string(self.state)),
    ("acp_session_id", json_string(self.acp_session_id)),
    ("agent_name", json_string(self.agent_name)),
    ("acp_version", json_string(self.acp_version)),
    ("load_session", json_bool(self.load_session)),
    ("stop_reason", json_string(self.stop_reason)),
    ("last_error", json_string(self.last_error)),
    ("stderr_tail", json_string(self.stderr_tail)),
    ("turns", json_int(self.turns)),
    ("chunks", json_int(self.chunks)),
    ("decisions", json_int(self.decisions)),
    ("memory_injected", json_bool(self.memory_injected)),
    ("memory_bytes", json_int(self.memory_bytes)),
    ("artifacts", artifacts),
    ("started_at", json_string(self.started_at)),
    ("updated_at", json_string(self.updated_at)),
    ("ended_at", json_string(self.ended_at)),
  ])
}

///|
pub fn agent_session_from_json(json : @json.Json) -> AgentSessionRecord? {
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
    agent_id: string_field_or(object, "agent_id", "default"),
    mode: string_field_or(object, "mode", AGENT_MODE_ACP),
    workspace_id: string_field_or(object, "workspace_id", ""),
    worktree_id: string_field_or(object, "worktree_id", ""),
    cwd: string_field_or(object, "cwd", ""),
    command: string_field_or(object, "command", ""),
    args: string_array_field(object, "args"),
    state: string_field_or(object, "state", AGENT_STATE_EXITED),
    acp_session_id: string_field_or(object, "acp_session_id", ""),
    agent_name: string_field_or(object, "agent_name", ""),
    acp_version: string_field_or(object, "acp_version", ""),
    load_session: bool_field_or(object, "load_session", false),
    stop_reason: string_field_or(object, "stop_reason", ""),
    last_error: string_field_or(object, "last_error", ""),
    stderr_tail: string_field_or(object, "stderr_tail", ""),
    turns: int_field_or(object, "turns", 0),
    chunks: int_field_or(object, "chunks", 0),
    decisions: int_field_or(object, "decisions", 0),
    memory_injected: bool_field_or(object, "memory_injected", false),
    memory_bytes: int_field_or(object, "memory_bytes", 0),
    artifacts: string_array_field(object, "artifacts"),
    started_at: string_field_or(object, "started_at", ""),
    updated_at: string_field_or(object, "updated_at", ""),
    ended_at: string_field_or(object, "ended_at", ""),
  })
}

///|
pub(all) struct DecisionOption {
  option_id : String
  name : String
  kind : String
}

///|
pub fn DecisionOption::new(
  option_id~ : String,
  name~ : String,
  kind~ : String,
) -> DecisionOption {
  { option_id, name, kind, }
}

///|
pub fn DecisionOption::to_json(self : DecisionOption) -> @json.Json {
  json_object([
    ("option_id", json_string(self.option_id)),
    ("name", json_string(self.name)),
    ("kind", json_string(self.kind)),
  ])
}

///|
pub fn decision_option_from_json(json : @json.Json) -> DecisionOption? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let option_id = match string_field(object, "option_id") {
    Some(value) => value
    None => return None
  }
  Some({
    option_id,
    name: string_field_or(object, "name", option_id),
    kind: string_field_or(object, "kind", "allow_once"),
  })
}

///|
pub const DECISION_KIND_PERMISSION : String = "permission"

///|
pub const DECISION_KIND_READINESS : String = "readiness"

///|
pub const DECISION_KIND_QUESTION : String = "question"

///|
pub const DECISION_STATUS_PENDING : String = "pending"

///|
pub const DECISION_STATUS_ANSWERED : String = "answered"

///|
pub const DECISION_STATUS_EXPIRED : String = "expired"

///|
pub(all) struct DecisionRecord {
  id : String
  kind : String
  status : String
  title : String
  detail : String
  session_id : String
  agent_id : String
  run_id : String
  options : Array[DecisionOption]
  option_id : String
  answer_text : String
  answered_by : String
  delivery_error : String
  created_at : String
  answered_at : String
  // Derived Inbox fields. Set when the host lists decisions; empty when stored.
  inbox : String
  run_status : String
}

///|
pub fn DecisionRecord::new(
  id~ : String,
  kind~ : String,
  title~ : String,
  detail~ : String,
  session_id~ : String,
  agent_id~ : String,
  options~ : Array[DecisionOption],
  created_at~ : String,
  run_id~ : String = "",
) -> DecisionRecord {
  {
    id,
    kind,
    status: DECISION_STATUS_PENDING,
    title,
    detail,
    session_id,
    agent_id,
    run_id,
    options,
    option_id: "",
    answer_text: "",
    answered_by: "",
    delivery_error: "",
    created_at,
    answered_at: "",
    inbox: "",
    run_status: "",
  }
}

///|
pub fn DecisionRecord::to_json(self : DecisionRecord) -> @json.Json {
  let options = json_array(
    self.options.map(fn(option) { option.to_json() }),
  )
  json_object([
    ("id", json_string(self.id)),
    ("kind", json_string(self.kind)),
    ("status", json_string(self.status)),
    ("title", json_string(self.title)),
    ("detail", json_string(self.detail)),
    ("session_id", json_string(self.session_id)),
    ("agent_id", json_string(self.agent_id)),
    ("run_id", json_string(self.run_id)),
    ("options", options),
    ("option_id", json_string(self.option_id)),
    ("answer_text", json_string(self.answer_text)),
    ("answered_by", json_string(self.answered_by)),
    ("delivery_error", json_string(self.delivery_error)),
    ("created_at", json_string(self.created_at)),
    ("answered_at", json_string(self.answered_at)),
    ("inbox", json_string(self.inbox)),
    ("run_status", json_string(self.run_status)),
  ])
}

///|
pub fn decision_from_json(json : @json.Json) -> DecisionRecord? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let id = match string_field(object, "id") {
    Some(value) => value
    None => return None
  }
  let options : Array[DecisionOption] = []
  match object.get("options") {
    Some(@json.Json::Array(items)) => {
      for item in items {
        match decision_option_from_json(item) {
          Some(option) => options.push(option)
          None => ()
        }
      }
    }
    _ => ()
  }
  Some({
    id,
    kind: string_field_or(object, "kind", DECISION_KIND_QUESTION),
    status: string_field_or(object, "status", DECISION_STATUS_PENDING),
    title: string_field_or(object, "title", ""),
    detail: string_field_or(object, "detail", ""),
    session_id: string_field_or(object, "session_id", ""),
    agent_id: string_field_or(object, "agent_id", ""),
    run_id: string_field_or(object, "run_id", ""),
    options,
    option_id: string_field_or(object, "option_id", ""),
    answer_text: string_field_or(object, "answer_text", ""),
    answered_by: string_field_or(object, "answered_by", ""),
    delivery_error: string_field_or(object, "delivery_error", ""),
    created_at: string_field_or(object, "created_at", ""),
    answered_at: string_field_or(object, "answered_at", ""),
    inbox: string_field_or(object, "inbox", ""),
    run_status: string_field_or(object, "run_status", ""),
  })
}

///|
pub const ARTIFACT_KIND_MEMORY_DIFF : String = "memory_diff"

///|
pub(all) struct ArtifactRecord {
  id : String
  session_id : String
  run_id : String
  kind : String
  uri : String
  digest : String
  size : Int
  media_type : String
  created_at : String
}

///|
pub fn ArtifactRecord::new(
  id~ : String,
  session_id~ : String,
  kind~ : String,
  uri~ : String,
  digest~ : String,
  size~ : Int,
  media_type~ : String,
  created_at~ : String,
  run_id~ : String = "",
) -> ArtifactRecord {
  { id, session_id, run_id, kind, uri, digest, size, media_type, created_at, }
}

///|
pub fn ArtifactRecord::to_json(self : ArtifactRecord) -> @json.Json {
  json_object([
    ("id", json_string(self.id)),
    ("session_id", json_string(self.session_id)),
    ("run_id", json_string(self.run_id)),
    ("kind", json_string(self.kind)),
    ("uri", json_string(self.uri)),
    ("digest", json_string(self.digest)),
    ("size", json_int(self.size)),
    ("media_type", json_string(self.media_type)),
    ("created_at", json_string(self.created_at)),
  ])
}

///|
pub fn artifact_from_json(json : @json.Json) -> ArtifactRecord? {
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
    session_id: string_field_or(object, "session_id", ""),
    run_id: string_field_or(object, "run_id", ""),
    kind: string_field_or(object, "kind", ARTIFACT_KIND_MEMORY_DIFF),
    uri: string_field_or(object, "uri", ""),
    digest: string_field_or(object, "digest", ""),
    size: int_field_or(object, "size", 0),
    media_type: string_field_or(object, "media_type", "text/x-diff"),
    created_at: string_field_or(object, "created_at", ""),
  })
}

// ---------------------------------------------------------------------------
// Event payloads
// ---------------------------------------------------------------------------

///|
pub fn agent_session_payload(record : AgentSessionRecord) -> @json.Json {
  record.to_json()
}

///|
pub fn decision_payload(record : DecisionRecord) -> @json.Json {
  record.to_json()
}

///|
pub fn readiness_payload(readiness : AgentReadiness) -> @json.Json {
  readiness.to_json()
}

///|
pub fn artifact_payload(record : ArtifactRecord) -> @json.Json {
  record.to_json()
}

///|
/// Payload of `agent.session.output`: the text of one completed turn. It is
/// capped so a single event cannot bloat the log.
pub fn agent_output_payload(
  session_id : String,
  turn : Int,
  stop_reason : String,
  text : String,
) -> @json.Json {
  let cap = 8_192
  let trimmed = if text.length() > cap { text[:cap].to_owned() } else { text }
  json_object([
    ("session_id", json_string(session_id)),
    ("turn", json_int(turn)),
    ("stop_reason", json_string(stop_reason)),
    ("text", json_string(trimmed)),
    ("truncated", json_bool(text.length() > cap)),
  ])
}

// ---------------------------------------------------------------------------
// Param builders and parsers
// ---------------------------------------------------------------------------

///|
pub fn agent_env_json(env : Map[String, String]) -> @json.Json {
  let entries : Array[(String, @json.Json)] = []
  for key, value in env {
    entries.push((key, json_string(value)))
  }
  json_object(entries)
}

///|
pub fn agent_env_from_json(
  object : Map[String, @json.Json],
) -> Map[String, String] {
  let env : Map[String, String] = Map([])
  match object.get("env") {
    Some(@json.Json::Object(fields)) => {
      for key, value in fields {
        match as_string(value) {
          Some(text) => env.set(key, text)
          None => ()
        }
      }
    }
    _ => ()
  }
  env
}

///|
pub fn agent_env_from_object(
  object : Map[String, @json.Json],
  key : String,
) -> Map[String, String] {
  let env : Map[String, String] = Map([])
  match object.get(key) {
    Some(@json.Json::Object(fields)) => {
      for name, value in fields {
        match as_string(value) {
          Some(text) => env.set(name, text)
          None => ()
        }
      }
    }
    _ => ()
  }
  env
}

///|
pub fn agent_probe_params(
  client_request_id : String,
  agent_id : String,
  mode : String,
  command : String,
  args : Array[String],
  cwd : String,
  env : Map[String, String],
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("agent_id", json_string(agent_id)),
    ("mode", json_string(mode)),
    ("command", json_string(command)),
    ("args", json_array(args.map(fn(value) { json_string(value) }))),
    ("cwd", json_string(cwd)),
    ("env", agent_env_json(env)),
  ])
}

///|
pub fn agent_start_params(
  client_request_id : String,
  agent_id : String,
  mode : String,
  command : String,
  args : Array[String],
  cwd : String,
  workspace_id : String,
  worktree_id : String,
  prompt : String,
  memory_limit : Int,
  env : Map[String, String],
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("agent_id", json_string(agent_id)),
    ("mode", json_string(mode)),
    ("command", json_string(command)),
    ("args", json_array(args.map(fn(value) { json_string(value) }))),
    ("cwd", json_string(cwd)),
    ("workspace_id", json_string(workspace_id)),
    ("worktree_id", json_string(worktree_id)),
    ("prompt", json_string(prompt)),
    ("memory_limit", json_int(memory_limit)),
    ("env", agent_env_json(env)),
  ])
}

///|
pub fn agent_send_params(
  client_request_id : String,
  session_id : String,
  text : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("session_id", json_string(session_id)),
    ("text", json_string(text)),
  ])
}

///|
pub fn agent_read_params(
  client_request_id : String,
  session_id : String,
  cursor : Int64,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("session_id", json_string(session_id)),
    ("cursor", json_int64(cursor)),
  ])
}

///|
pub fn agent_stop_params(
  client_request_id : String,
  session_id : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("session_id", json_string(session_id)),
  ])
}

///|
pub fn agent_list_params(
  client_request_id : String,
  agent_id : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("agent_id", json_string(agent_id)),
  ])
}

///|
pub fn agent_resume_params(
  client_request_id : String,
  session_id : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("session_id", json_string(session_id)),
  ])
}

///|
pub fn agent_memory_read_params(
  client_request_id : String,
  agent_id : String,
  file : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("agent_id", json_string(agent_id)),
    ("file", json_string(file)),
  ])
}

///|
pub fn agent_memory_write_params(
  client_request_id : String,
  agent_id : String,
  file : String,
  content : String,
  actor : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("agent_id", json_string(agent_id)),
    ("file", json_string(file)),
    ("content", json_string(content)),
    ("actor", json_string(actor)),
  ])
}

///|
pub fn decision_list_params(
  client_request_id : String,
  status : String,
  session_id : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("status", json_string(status)),
    ("session_id", json_string(session_id)),
  ])
}

///|
pub fn decision_respond_params(
  client_request_id : String,
  decision_id : String,
  option_id : String,
  text : String,
  answered_by : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("decision_id", json_string(decision_id)),
    ("option_id", json_string(option_id)),
    ("text", json_string(text)),
    ("answered_by", json_string(answered_by)),
  ])
}

// ---------------------------------------------------------------------------
// Param parsers
// ---------------------------------------------------------------------------

///|
pub fn agent_id_param(params : Map[String, @json.Json] ) -> String {
  let value = string_field_or(params, "agent_id", "")
  if value == "" { "default" } else { value }
}

///|
pub fn agent_mode_param(params : Map[String, @json.Json] ) -> String {
  let value = string_field_or(params, "mode", "")
  match value {
    "" => AGENT_MODE_ACP
    _ => value
  }
}

///|
pub fn agent_command_param(params : Map[String, @json.Json] ) -> String {
  string_field_or(params, "command", "")
}

///|
pub fn agent_args_param(params : Map[String, @json.Json]) -> Array[String] {
  string_array_field(params, "args")
}

///|
pub fn agent_cwd_param(params : Map[String, @json.Json] ) -> String {
  string_field_or(params, "cwd", "")
}

///|
pub fn agent_workspace_param(params : Map[String, @json.Json]) -> String {
  string_field_or(params, "workspace_id", "")
}

///|
pub fn agent_worktree_param(params : Map[String, @json.Json]) -> String {
  string_field_or(params, "worktree_id", "")
}

///|
pub fn agent_prompt_param(params : Map[String, @json.Json]) -> String {
  string_field_or(params, "prompt", "")
}

///|
pub fn agent_memory_limit_param(params : Map[String, @json.Json]) -> Int {
  int_field_or(params, "memory_limit", 4_096).max(0).min(16_384)
}

///|
pub fn agent_session_id_param(
  params : Map[String, @json.Json],
) -> Result[String, String] {
  match string_field(params, "session_id") {
    Some(value) if value != "" => Ok(value)
    _ => Err("missing session_id")
  }
}

///|
pub fn agent_text_param(
  params : Map[String, @json.Json],
) -> Result[String, String] {
  match string_field(params, "text") {
    Some(value) if value != "" => Ok(value)
    _ => Err("missing text")
  }
}

///|
pub fn agent_cursor_param(params : Map[String, @json.Json] ) -> Int64 {
  int64_field_or(params, "cursor", 0L)
}

///|
pub fn agent_memory_file_param(
  params : Map[String, @json.Json],
) -> Result[String, String] {
  let file = string_field_or(params, "file", "MEMORY.md")
  match file {
    "AGENTS.md" | "MEMORY.md" => Ok(file)
    _ => Err("file must be AGENTS.md or MEMORY.md")
  }
}

///|
pub fn agent_memory_content_param(params : Map[String, @json.Json] ) -> String {
  string_field_or(params, "content", "")
}

///|
pub fn agent_actor_param(params : Map[String, @json.Json]) -> String {
  let actor = string_field_or(params, "actor", "")
  if actor == "" { "host" } else { actor }
}

///|
pub fn decision_bucket_param(params : Map[String, @json.Json]) -> String {
  string_field_or(params, "bucket", "")
}

///|
pub fn decision_status_param(params : Map[String, @json.Json]) -> String {
  string_field_or(params, "status", "")
}

///|
pub fn decision_session_param(params : Map[String, @json.Json]) -> String {
  string_field_or(params, "session_id", "")
}

///|
pub fn decision_id_param(
  params : Map[String, @json.Json],
) -> Result[String, String] {
  match string_field(params, "decision_id") {
    Some(value) if value != "" => Ok(value)
    _ => Err("missing decision_id")
  }
}

///|
pub fn decision_option_param(params : Map[String, @json.Json] ) -> String {
  string_field_or(params, "option_id", "")
}

///|
pub fn decision_text_param(params : Map[String, @json.Json]) -> String {
  string_field_or(params, "text", "")
}

///|
pub fn decision_answered_by_param(params : Map[String, @json.Json] ) -> String {
  let by = string_field_or(params, "answered_by", "")
  if by == "" { "owner" } else { by }
}

// ---------------------------------------------------------------------------
// Result decoders
// ---------------------------------------------------------------------------

///|
pub fn agent_session_result(
  record : AgentSessionRecord,
) -> @json.Json {
  json_object([("session", record.to_json())])
}

///|
pub fn agent_session_from_result(
  json : @json.Json,
) -> Result[AgentSessionRecord, String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("result is not an object")
  }
  let session = match object.get("session") {
    Some(value) => value
    None => return Err("result has no session")
  }
  match agent_session_from_json(session) {
    Some(record) => Ok(record)
    None => Err("malformed session record")
  }
}

///|
pub fn agent_readiness_from_result(
  json : @json.Json,
) -> Result[AgentReadiness, String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("result is not an object")
  }
  let readiness = match object.get("readiness") {
    Some(value) => value
    None => return Err("result has no readiness")
  }
  match agent_readiness_from_json(readiness) {
    Some(record) => Ok(record)
    None => Err("malformed readiness record")
  }
}

///|
pub fn agent_sessions_result(
  records : Array[AgentSessionRecord],
) -> @json.Json {
  json_object([
    ("sessions", json_array(records.map(fn(record) { record.to_json() }))),
  ])
}

///|
pub fn agent_sessions_from_result(
  json : @json.Json,
) -> Result[Array[AgentSessionRecord], String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("result is not an object")
  }
  let items = match object.get("sessions") {
    Some(@json.Json::Array(values)) => values
    _ => return Err("result has no sessions")
  }
  let out : Array[AgentSessionRecord] = []
  for item in items {
    match agent_session_from_json(item) {
      Some(record) => out.push(record)
      None => ()
    }
  }
  Ok(out)
}

///|
pub fn agent_read_result(
  session : AgentSessionRecord,
  cursor : Int64,
  text : String,
  pending_decision : String,
) -> @json.Json {
  json_object([
    ("session_id", json_string(session.id)),
    ("cursor", json_int64(cursor)),
    ("text", json_string(text)),
    ("state", json_string(session.state)),
    ("stop_reason", json_string(session.stop_reason)),
    ("pending_decision", json_string(pending_decision)),
    ("last_error", json_string(session.last_error)),
  ])
}

///|
pub(all) struct AgentReadResult {
  session_id : String
  cursor : Int64
  text : String
  state : String
  stop_reason : String
  pending_decision : String
  last_error : String
}

///|
pub fn agent_read_from_json(json : @json.Json) -> AgentReadResult? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let session_id = match string_field(object, "session_id") {
    Some(value) => value
    None => return None
  }
  Some({
    session_id,
    cursor: int64_field_or(object, "cursor", 0L),
    text: string_field_or(object, "text", ""),
    state: string_field_or(object, "state", ""),
    stop_reason: string_field_or(object, "stop_reason", ""),
    pending_decision: string_field_or(object, "pending_decision", ""),
    last_error: string_field_or(object, "last_error", ""),
  })
}

///|
pub fn decision_list_result(records : Array[DecisionRecord]) -> @json.Json {
  json_object([
    ("decisions", json_array(records.map(fn(record) { record.to_json() }))),
  ])
}

///|
pub fn decision_list_from_result(
  json : @json.Json,
) -> Result[Array[DecisionRecord], String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("result is not an object")
  }
  let items = match object.get("decisions") {
    Some(@json.Json::Array(values)) => values
    _ => return Err("result has no decisions")
  }
  let out : Array[DecisionRecord] = []
  for item in items {
    match decision_from_json(item) {
      Some(record) => out.push(record)
      None => ()
    }
  }
  Ok(out)
}

///|
pub fn decision_result(record : DecisionRecord) -> @json.Json {
  json_object([("decision", record.to_json())])
}

///|
pub fn decision_from_result(
  json : @json.Json,
) -> Result[DecisionRecord, String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("result is not an object")
  }
  let decision = match object.get("decision") {
    Some(value) => value
    None => return Err("result has no decision")
  }
  match decision_from_json(decision) {
    Some(record) => Ok(record)
    None => Err("malformed decision record")
  }
}

///|
pub fn agent_memory_read_result(
  agent_id : String,
  file : String,
  content : String,
) -> @json.Json {
  json_object([
    ("agent_id", json_string(agent_id)),
    ("file", json_string(file)),
    ("content", json_string(content)),
    ("bytes", json_int(content.length())),
  ])
}

///|
pub fn agent_memory_write_result(
  agent_id : String,
  file : String,
  bytes : Int,
  digest : String,
) -> @json.Json {
  json_object([
    ("ok", json_bool(true)),
    ("agent_id", json_string(agent_id)),
    ("file", json_string(file)),
    ("bytes", json_int(bytes)),
    ("digest", json_string(digest)),
  ])
}

///|
pub fn agent_ack_result(session_id : String) -> @json.Json {
  json_object([
    ("ok", json_bool(true)),
    ("session_id", json_string(session_id)),
  ])
}

///|
pub fn string_array_field(
  object : Map[String, @json.Json],
  key : String,
) -> Array[String] {
  let out : Array[String] = []
  match object.get(key) {
    Some(@json.Json::Array(items)) => {
      for item in items {
        match as_string(item) {
          Some(value) => out.push(value)
          None => ()
        }
      }
    }
    _ => ()
  }
  out
}
