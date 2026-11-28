///|
/// ADR-0017 Bot / Agent / Chat / AgentSession wire contracts.
///
/// These records describe the durable host objects. Runtime execution details
/// stay in `AgentSession.runtime_session_id`; an Agent is never a Chat
/// participant. Empty optional string fields mean "absent" on the wire, which
/// matches the rest of the contracts package.

// ---------------------------------------------------------------------------
// State and policy labels
// ---------------------------------------------------------------------------

///|
pub const BOT_STATE_ACTIVE : String = "active"

///|
pub const BOT_STATE_SUSPENDED : String = "suspended"

///|
pub const BOT_STATE_ARCHIVED : String = "archived"

///|
pub const AGENT_LIFECYCLE_PROVISIONING : String = "provisioning"

///|
pub const AGENT_LIFECYCLE_ACTIVE : String = "active"

///|
pub const AGENT_LIFECYCLE_SUSPENDED : String = "suspended"

///|
pub const AGENT_LIFECYCLE_RETIRED : String = "retired"

///|
pub const CHAT_STATE_ACTIVE : String = "active"

///|
pub const CHAT_STATE_ARCHIVED : String = "archived"

///|
pub const PROJECT_STATE_ACTIVE : String = "active"

///|
pub const PROJECT_STATE_ARCHIVED : String = "archived"

///|
pub const PARTICIPANT_STATE_ACTIVE : String = "active"

///|
pub const PARTICIPANT_STATE_REMOVED : String = "removed"

///|
pub const MEMBERSHIP_STATE_ACTIVE : String = "active"

///|
pub const MEMBERSHIP_STATE_REMOVED : String = "removed"

///|
pub const AGENT_SESSION_STATE_STARTING : String = "starting"

///|
pub const AGENT_SESSION_STATE_ACTIVE : String = "active"

///|
pub const AGENT_SESSION_STATE_WAITING : String = "waiting"

///|
pub const AGENT_SESSION_STATE_ENDING : String = "ending"

///|
pub const AGENT_SESSION_STATE_ENDED : String = "ended"

///|
pub const AGENT_SESSION_STATE_FAILED : String = "failed"

///|
pub const AGENT_SESSION_STATE_LOST : String = "lost"

///|
pub const BOT_CREATE_POLICY_OFF : String = "off"

///|
pub const BOT_CREATE_POLICY_ASK : String = "ask"

///|
pub const BOT_CREATE_POLICY_AUTO : String = "auto"

///|
pub const AGENT_SESSION_END_REASON_TURN_END : String = "turn_end"

///|
pub const AGENT_SESSION_END_REASON_CANCELLED : String = "cancelled"

///|
pub const AGENT_SESSION_END_REASON_ERROR : String = "error"

///|
pub const AGENT_SESSION_END_REASON_EXITED : String = "exited"

///|
pub const AGENT_SESSION_END_REASON_HOST_RESTART : String = "host_restart"

///|
/// ADR-0019: the terminal reason written when startup reconcile closes a Chat
/// AgentSession whose ACP process did not survive the host restart. The legacy
/// runtime-session reason above stays `host_restart` for backward compatibility.
pub const AGENT_SESSION_END_REASON_HOST_RESTARTED : String = "host_restarted"

///|
pub const AGENT_SESSION_END_REASON_LOST : String = "lost"

///|
pub const AGENT_SESSION_END_REASON_INTERRUPTED : String = "interrupted"

///|
pub const AGENT_SESSION_END_REASON_AGENT_SWITCH : String = "agent_switch"

///|
pub const AGENT_SESSION_END_REASON_PROJECT_ACCESS_REVOKED : String =
  "project_access_revoked"

///|
pub const AGENT_SESSION_END_REASON_CHAT_ARCHIVED : String = "chat_archived"

///|
pub const CHAT_PARTICIPANT_ROLE_BOT : String = "bot"

///|
pub const CHAT_MESSAGE_ROLE_USER : String = "user"

///|
pub const CHAT_MESSAGE_ROLE_ASSISTANT : String = "assistant"

///|
pub const CHAT_MESSAGE_ROLE_SYSTEM : String = "system"

///|
/// Visible Chat boundary written once per AgentSession interrupted by a host
/// restart. It is an ordinary ChatMessage, never hidden recovery context.
pub const CHAT_HOST_RESTART_BOUNDARY_BODY : String =
  "运行时已中断，记录已保留。可在同一 Chat 启动新的智能体会话继续。"

///|
/// Maximum inline Chat transcript body. Runtime stdout and hidden prompts are
/// never copied into a Chat message; only bounded user-visible text is stored.
pub const CHAT_MESSAGE_BODY_CAP : Int = 16_384

///|
pub const RUNTIME_LAUNCH_COMMAND : String = "command"

///|
pub const RUNTIME_LAUNCH_ACP : String = "acp"

// ---------------------------------------------------------------------------
// Runtime binding
// ---------------------------------------------------------------------------

///|
/// A fixed execution binding. It contains no secrets. `hash` is the canonical
/// fingerprint used by permission snapshots and immutable-binding checks.
pub(all) struct RuntimeBinding {
  software_id : String
  adapter_id : String
  launch_kind : String
  command : String
  args : Array[String]
  model_profile : String
  tools : Array[String]
  skills : Array[String]
  version : String
  hash : String
}

///|
pub fn RuntimeBinding::new(
  software_id~ : String,
  adapter_id~ : String,
  launch_kind~ : String,
  command~ : String,
  args~ : Array[String],
  model_profile~ : String,
  hash~ : String,
  tools~ : Array[String] = [],
  skills~ : Array[String] = [],
  version~ : String = "",
) -> RuntimeBinding {
  {
    software_id,
    adapter_id,
    launch_kind,
    command,
    args,
    model_profile,
    tools,
    skills,
    version,
    hash,
  }
}

///|
pub fn RuntimeBinding::to_json(self : RuntimeBinding) -> @json.Json {
  json_object([
    ("software_id", json_string(self.software_id)),
    ("adapter_id", json_string(self.adapter_id)),
    ("launch_kind", json_string(self.launch_kind)),
    ("command", json_string(self.command)),
    ("args", json_string_array(self.args)),
    ("model_profile", json_string(self.model_profile)),
    ("tools", json_string_array(self.tools)),
    ("skills", json_string_array(self.skills)),
    ("version", json_string(self.version)),
    ("hash", json_string(self.hash)),
  ])
}

///|
pub fn runtime_binding_from_json(
  json : @json.Json,
) -> RuntimeBinding? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  Some({
    software_id: string_field_or(object, "software_id", ""),
    adapter_id: string_field_or(object, "adapter_id", ""),
    launch_kind: string_field_or(object, "launch_kind", RUNTIME_LAUNCH_COMMAND),
    command: string_field_or(object, "command", ""),
    args: string_array_field(object, "args"),
    model_profile: string_field_or(object, "model_profile", ""),
    tools: string_array_field(object, "tools"),
    skills: string_array_field(object, "skills"),
    version: string_field_or(object, "version", ""),
    hash: string_field_or(object, "hash", ""),
  })
}

///|
/// Structural equality for the immutable binding. Array order is significant
/// because command arguments and declared capability order are part of the
/// fingerprint input.
pub fn RuntimeBinding::same_as(
  self : RuntimeBinding,
  other : RuntimeBinding,
) -> Bool {
  self.software_id == other.software_id &&
  self.adapter_id == other.adapter_id &&
  self.launch_kind == other.launch_kind &&
  self.command == other.command &&
  self.args == other.args &&
  self.model_profile == other.model_profile &&
  self.tools == other.tools &&
  self.skills == other.skills &&
  self.version == other.version &&
  self.hash == other.hash
}

///|
/// Canonical SHA-256 over the same deterministic JSON rendering used by the
/// other contract hashes. Used for immutable policy and permission snapshots.
pub fn bots_canonical_hash(value : @json.Json) -> String {
  "sha256:" + trigger_sha256_hex(trigger_canonical_json(value))
}

///|
/// Order-independent hash for an allowlist. Duplicate entries are dropped so
/// two equivalent permission sets always produce the same snapshot hash.
pub fn bots_permission_set_hash(values : Array[String]) -> String {
  let sorted = values.copy()
  sorted.sort()
  let unique : Array[String] = []
  for value in sorted {
    if unique.length() == 0 || unique[unique.length() - 1] != value {
      unique.push(value)
    }
  }
  bots_canonical_hash(json_string_array(unique))
}

///|
/// Bound an inline Chat transcript body to `CHAT_MESSAGE_BODY_CAP`.
pub fn chat_message_body_bounded(text : String) -> String {
  if text.length() > CHAT_MESSAGE_BODY_CAP {
    text.substring(start=0, end=CHAT_MESSAGE_BODY_CAP)
  } else {
    text
  }
}

///|
/// Canonical digest for a Chat message. The inline body wins when present;
/// otherwise the body reference is the stable content address.
pub fn chat_message_digest(body : String, body_ref : String) -> String {
  bots_canonical_hash(json_string(if body != "" { body } else { body_ref }))
}

// ---------------------------------------------------------------------------
// Bot
// ---------------------------------------------------------------------------

///|
pub(all) struct BotRecord {
  id : String
  org_id : String
  name : String
  persona_ref : String
  instructions_ref : String
  memory_ref : String
  home : String
  permission_ceiling : Array[String]
  create_policy : String
  agent_count_cap : Int
  agent_concurrency_cap : Int
  software_allowlist : Array[String]
  state : String
  created_at : String
  updated_at : String
}

///|
pub fn BotRecord::new(
  id~ : String,
  org_id~ : String,
  name~ : String,
  created_at~ : String,
  persona_ref~ : String = "",
  instructions_ref~ : String = "",
  memory_ref~ : String = "",
  home~ : String = "",
  permission_ceiling~ : Array[String] = [],
  create_policy~ : String = BOT_CREATE_POLICY_ASK,
  agent_count_cap~ : Int = 8,
  agent_concurrency_cap~ : Int = 1,
  software_allowlist~ : Array[String] = [],
  state~ : String = BOT_STATE_ACTIVE,
) -> BotRecord {
  {
    id,
    org_id,
    name,
    persona_ref,
    instructions_ref,
    memory_ref,
    home,
    permission_ceiling,
    create_policy,
    agent_count_cap,
    agent_concurrency_cap,
    software_allowlist,
    state,
    created_at,
    updated_at: created_at,
  }
}

///|
pub fn BotRecord::to_json(self : BotRecord) -> @json.Json {
  json_object([
    ("id", json_string(self.id)),
    ("org_id", json_string(self.org_id)),
    ("name", json_string(self.name)),
    ("persona_ref", json_string(self.persona_ref)),
    ("instructions_ref", json_string(self.instructions_ref)),
    ("memory_ref", json_string(self.memory_ref)),
    ("home", json_string(self.home)),
    ("permission_ceiling", json_string_array(self.permission_ceiling)),
    ("create_policy", json_string(self.create_policy)),
    ("agent_count_cap", json_int(self.agent_count_cap)),
    ("agent_concurrency_cap", json_int(self.agent_concurrency_cap)),
    ("software_allowlist", json_string_array(self.software_allowlist)),
    ("state", json_string(self.state)),
    ("created_at", json_string(self.created_at)),
    ("updated_at", json_string(self.updated_at)),
  ])
}

///|
pub fn bot_from_json(json : @json.Json) -> BotRecord? {
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
    org_id: string_field_or(object, "org_id", ""),
    name: string_field_or(object, "name", ""),
    persona_ref: string_field_or(object, "persona_ref", ""),
    instructions_ref: string_field_or(object, "instructions_ref", ""),
    memory_ref: string_field_or(object, "memory_ref", ""),
    home: string_field_or(object, "home", ""),
    permission_ceiling: string_array_field(object, "permission_ceiling"),
    create_policy: string_field_or(
      object,
      "create_policy",
      BOT_CREATE_POLICY_ASK,
    ),
    agent_count_cap: int_field_or(object, "agent_count_cap", 8),
    agent_concurrency_cap: int_field_or(object, "agent_concurrency_cap", 1),
    software_allowlist: string_array_field(object, "software_allowlist"),
    state: string_field_or(object, "state", BOT_STATE_ACTIVE),
    created_at: string_field_or(object, "created_at", ""),
    updated_at: string_field_or(object, "updated_at", ""),
  })
}

// ---------------------------------------------------------------------------
// Agent
// ---------------------------------------------------------------------------

///|
/// A long-lived execution worker belonging to exactly one Bot.
pub(all) struct AgentRecord {
  id : String
  org_id : String
  bot_id : String
  name : String
  specialty : String
  tags : Array[String]
  runtime_binding : RuntimeBinding
  permission_scope : Array[String]
  state : String
  created_at : String
  updated_at : String
  retired_at : String
}

///|
pub fn AgentRecord::new(
  id~ : String,
  org_id~ : String,
  bot_id~ : String,
  name~ : String,
  runtime_binding~ : RuntimeBinding,
  created_at~ : String,
  specialty~ : String = "",
  tags~ : Array[String] = [],
  permission_scope~ : Array[String] = [],
  state~ : String = AGENT_LIFECYCLE_PROVISIONING,
) -> AgentRecord {
  {
    id,
    org_id,
    bot_id,
    name,
    specialty,
    tags,
    runtime_binding,
    permission_scope,
    state,
    created_at,
    updated_at: created_at,
    retired_at: "",
  }
}

///|
pub fn AgentRecord::to_json(self : AgentRecord) -> @json.Json {
  json_object([
    ("id", json_string(self.id)),
    ("org_id", json_string(self.org_id)),
    ("bot_id", json_string(self.bot_id)),
    ("name", json_string(self.name)),
    ("specialty", json_string(self.specialty)),
    ("tags", json_string_array(self.tags)),
    ("runtime_binding", self.runtime_binding.to_json()),
    ("permission_scope", json_string_array(self.permission_scope)),
    ("state", json_string(self.state)),
    ("created_at", json_string(self.created_at)),
    ("updated_at", json_string(self.updated_at)),
    ("retired_at", json_string(self.retired_at)),
  ])
}

///|
pub fn agent_from_json(json : @json.Json) -> AgentRecord? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let id = match string_field(object, "id") {
    Some(value) => value
    None => return None
  }
  let runtime_binding = match object.get("runtime_binding") {
    Some(value) => match runtime_binding_from_json(value) {
      Some(binding) => binding
      None => return None
    }
    None => return None
  }
  Some({
    id,
    org_id: string_field_or(object, "org_id", ""),
    bot_id: string_field_or(object, "bot_id", ""),
    name: string_field_or(object, "name", ""),
    specialty: string_field_or(object, "specialty", ""),
    tags: string_array_field(object, "tags"),
    runtime_binding,
    permission_scope: string_array_field(object, "permission_scope"),
    state: string_field_or(object, "state", AGENT_LIFECYCLE_PROVISIONING),
    created_at: string_field_or(object, "created_at", ""),
    updated_at: string_field_or(object, "updated_at", ""),
    retired_at: string_field_or(object, "retired_at", ""),
  })
}

// ---------------------------------------------------------------------------
// Chat
// ---------------------------------------------------------------------------

///|
pub(all) struct ChatRecord {
  id : String
  org_id : String
  title : String
  project_id : String
  summary_ref : String
  state : String
  created_at : String
  updated_at : String
  archived_at : String
}

///|
pub fn ChatRecord::new(
  id~ : String,
  org_id~ : String,
  title~ : String,
  created_at~ : String,
  project_id~ : String = "",
  summary_ref~ : String = "",
  state~ : String = CHAT_STATE_ACTIVE,
) -> ChatRecord {
  {
    id,
    org_id,
    title,
    project_id,
    summary_ref,
    state,
    created_at,
    updated_at: created_at,
    archived_at: "",
  }
}

///|
pub fn ChatRecord::to_json(self : ChatRecord) -> @json.Json {
  json_object([
    ("id", json_string(self.id)),
    ("org_id", json_string(self.org_id)),
    ("title", json_string(self.title)),
    ("project_id", json_string(self.project_id)),
    ("summary_ref", json_string(self.summary_ref)),
    ("state", json_string(self.state)),
    ("created_at", json_string(self.created_at)),
    ("updated_at", json_string(self.updated_at)),
    ("archived_at", json_string(self.archived_at)),
  ])
}

///|
pub fn chat_from_json(json : @json.Json) -> ChatRecord? {
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
    org_id: string_field_or(object, "org_id", ""),
    title: string_field_or(object, "title", ""),
    project_id: string_field_or(object, "project_id", ""),
    summary_ref: string_field_or(object, "summary_ref", ""),
    state: string_field_or(object, "state", CHAT_STATE_ACTIVE),
    created_at: string_field_or(object, "created_at", ""),
    updated_at: string_field_or(object, "updated_at", ""),
    archived_at: string_field_or(object, "archived_at", ""),
  })
}

// ---------------------------------------------------------------------------
// Chat participant
// ---------------------------------------------------------------------------

///|
/// The only V1 Chat participant relation is `(chat_id, bot_id)`.
pub(all) struct ChatParticipant {
  chat_id : String
  bot_id : String
  role : String
  state : String
  added_at : String
  removed_at : String
}

///|
pub fn ChatParticipant::new(
  chat_id~ : String,
  bot_id~ : String,
  added_at~ : String,
  role~ : String = CHAT_PARTICIPANT_ROLE_BOT,
  state~ : String = PARTICIPANT_STATE_ACTIVE,
) -> ChatParticipant {
  {
    chat_id,
    bot_id,
    role,
    state,
    added_at,
    removed_at: "",
  }
}

///|
pub fn ChatParticipant::to_json(self : ChatParticipant) -> @json.Json {
  json_object([
    ("chat_id", json_string(self.chat_id)),
    ("bot_id", json_string(self.bot_id)),
    ("role", json_string(self.role)),
    ("state", json_string(self.state)),
    ("added_at", json_string(self.added_at)),
    ("removed_at", json_string(self.removed_at)),
  ])
}

///|
pub fn chat_participant_from_json(
  json : @json.Json,
) -> ChatParticipant? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let chat_id = match string_field(object, "chat_id") {
    Some(value) => value
    None => return None
  }
  let bot_id = match string_field(object, "bot_id") {
    Some(value) => value
    None => return None
  }
  Some({
    chat_id,
    bot_id,
    role: string_field_or(object, "role", CHAT_PARTICIPANT_ROLE_BOT),
    state: string_field_or(object, "state", PARTICIPANT_STATE_ACTIVE),
    added_at: string_field_or(object, "added_at", ""),
    removed_at: string_field_or(object, "removed_at", ""),
  })
}

// ---------------------------------------------------------------------------
// Chat transcript message
// ---------------------------------------------------------------------------

///|
/// A user-visible Chat message. `agent_session_id` is required for assistant
/// messages and empty for user/system messages.
pub(all) struct ChatMessage {
  id : String
  chat_id : String
  role : String
  agent_session_id : String
  body_ref : String
  body : String
  digest : String
  actor : String
  created_at : String
}

///|
pub fn ChatMessage::new(
  id~ : String,
  chat_id~ : String,
  role~ : String,
  body_ref~ : String,
  digest~ : String,
  created_at~ : String,
  agent_session_id~ : String = "",
  body~ : String = "",
  actor~ : String = "",
) -> ChatMessage {
  {
    id,
    chat_id,
    role,
    agent_session_id,
    body_ref,
    body,
    digest,
    actor,
    created_at,
  }
}

///|
pub fn ChatMessage::to_json(self : ChatMessage) -> @json.Json {
  json_object([
    ("id", json_string(self.id)),
    ("chat_id", json_string(self.chat_id)),
    ("role", json_string(self.role)),
    ("agent_session_id", json_string(self.agent_session_id)),
    ("body_ref", json_string(self.body_ref)),
    ("body", json_string(self.body)),
    ("digest", json_string(self.digest)),
    ("actor", json_string(self.actor)),
    ("created_at", json_string(self.created_at)),
  ])
}

///|
pub fn chat_message_from_json(json : @json.Json) -> ChatMessage? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let id = match string_field(object, "id") {
    Some(value) => value
    None => return None
  }
  let chat_id = match string_field(object, "chat_id") {
    Some(value) => value
    None => return None
  }
  Some({
    id,
    chat_id,
    role: string_field_or(object, "role", CHAT_MESSAGE_ROLE_USER),
    agent_session_id: string_field_or(object, "agent_session_id", ""),
    body_ref: string_field_or(object, "body_ref", ""),
    body: string_field_or(object, "body", ""),
    digest: string_field_or(object, "digest", ""),
    actor: string_field_or(object, "actor", ""),
    created_at: string_field_or(object, "created_at", ""),
  })
}

// ---------------------------------------------------------------------------
// AgentSession
// ---------------------------------------------------------------------------

///|
/// One execution segment in a Chat. The project/workspace fields are a frozen
/// range snapshot; the binding and permission snapshot are immutable for the
/// session lifetime.
pub(all) struct AgentSession {
  id : String
  chat_id : String
  agent_id : String
  runtime_session_id : String
  project_id : String
  workspace_id : String
  workspace_root : String
  worktree_id : String
  permission_snapshot_hash : String
  state : String
  handoff_from_session_id : String
  summary_ref : String
  started_at : String
  updated_at : String
  ended_at : String
  end_reason : String
}

///|
pub fn AgentSession::new(
  id~ : String,
  chat_id~ : String,
  agent_id~ : String,
  permission_snapshot_hash~ : String,
  started_at~ : String,
  runtime_session_id~ : String = "",
  project_id~ : String = "",
  workspace_id~ : String = "",
  workspace_root~ : String = "",
  worktree_id~ : String = "",
  state~ : String = AGENT_SESSION_STATE_STARTING,
  handoff_from_session_id~ : String = "",
) -> AgentSession {
  {
    id,
    chat_id,
    agent_id,
    runtime_session_id,
    project_id,
    workspace_id,
    workspace_root,
    worktree_id,
    permission_snapshot_hash,
    state,
    handoff_from_session_id,
    summary_ref: "",
    started_at,
    updated_at: started_at,
    ended_at: "",
    end_reason: "",
  }
}

///|
pub fn AgentSession::to_json(self : AgentSession) -> @json.Json {
  json_object([
    ("id", json_string(self.id)),
    ("chat_id", json_string(self.chat_id)),
    ("agent_id", json_string(self.agent_id)),
    ("runtime_session_id", json_string(self.runtime_session_id)),
    ("project_id", json_string(self.project_id)),
    ("workspace_id", json_string(self.workspace_id)),
    ("workspace_root", json_string(self.workspace_root)),
    ("worktree_id", json_string(self.worktree_id)),
    ("permission_snapshot_hash", json_string(self.permission_snapshot_hash)),
    ("state", json_string(self.state)),
    (
      "handoff_from_session_id",
      json_string(self.handoff_from_session_id),
    ),
    ("summary_ref", json_string(self.summary_ref)),
    ("started_at", json_string(self.started_at)),
    ("updated_at", json_string(self.updated_at)),
    ("ended_at", json_string(self.ended_at)),
    ("end_reason", json_string(self.end_reason)),
  ])
}

///|
pub fn chat_agent_session_from_json(json : @json.Json) -> AgentSession? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let id = match string_field(object, "id") {
    Some(value) => value
    None => return None
  }
  let chat_id = match string_field(object, "chat_id") {
    Some(value) => value
    None => return None
  }
  let agent_id = match string_field(object, "agent_id") {
    Some(value) => value
    None => return None
  }
  Some({
    id,
    chat_id,
    agent_id,
    runtime_session_id: string_field_or(object, "runtime_session_id", ""),
    project_id: string_field_or(object, "project_id", ""),
    workspace_id: string_field_or(object, "workspace_id", ""),
    workspace_root: string_field_or(object, "workspace_root", ""),
    worktree_id: string_field_or(object, "worktree_id", ""),
    permission_snapshot_hash: string_field_or(
      object,
      "permission_snapshot_hash",
      "",
    ),
    state: string_field_or(
      object,
      "state",
      AGENT_SESSION_STATE_STARTING,
    ),
    handoff_from_session_id: string_field_or(
      object,
      "handoff_from_session_id",
      "",
    ),
    summary_ref: string_field_or(object, "summary_ref", ""),
    started_at: string_field_or(object, "started_at", ""),
    updated_at: string_field_or(object, "updated_at", ""),
    ended_at: string_field_or(object, "ended_at", ""),
    end_reason: string_field_or(object, "end_reason", ""),
  })
}

// ---------------------------------------------------------------------------
// Project membership
// ---------------------------------------------------------------------------

///|
pub(all) struct ProjectMembership {
  project_id : String
  bot_id : String
  state : String
  access : Array[String]
  reason : String
  added_at : String
  removed_at : String
}

///|
pub fn ProjectMembership::new(
  project_id~ : String,
  bot_id~ : String,
  added_at~ : String,
  access~ : Array[String] = [],
  reason~ : String = "",
  state~ : String = MEMBERSHIP_STATE_ACTIVE,
) -> ProjectMembership {
  {
    project_id,
    bot_id,
    state,
    access,
    reason,
    added_at,
    removed_at: "",
  }
}

///|
pub fn ProjectMembership::to_json(self : ProjectMembership) -> @json.Json {
  json_object([
    ("project_id", json_string(self.project_id)),
    ("bot_id", json_string(self.bot_id)),
    ("state", json_string(self.state)),
    ("access", json_string_array(self.access)),
    ("reason", json_string(self.reason)),
    ("added_at", json_string(self.added_at)),
    ("removed_at", json_string(self.removed_at)),
  ])
}

///|
pub fn project_membership_from_json(
  json : @json.Json,
) -> ProjectMembership? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let project_id = match string_field(object, "project_id") {
    Some(value) => value
    None => return None
  }
  let bot_id = match string_field(object, "bot_id") {
    Some(value) => value
    None => return None
  }
  Some({
    project_id,
    bot_id,
    state: string_field_or(object, "state", MEMBERSHIP_STATE_ACTIVE),
    access: string_array_field(object, "access"),
    reason: string_field_or(object, "reason", ""),
    added_at: string_field_or(object, "added_at", ""),
    removed_at: string_field_or(object, "removed_at", ""),
  })
}
