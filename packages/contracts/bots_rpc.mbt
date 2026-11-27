///|
/// ADR-0017 P0.3 Bot / Chat RPC surface.
///
/// Method names are additive. Every request carries `client_request_id`; the
/// host's existing response cache is the idempotency authority for retries.

// ---------------------------------------------------------------------------
// Methods
// ---------------------------------------------------------------------------

///|
pub const METHOD_BOT_LIST : String = "bot.list"

///|
pub const METHOD_BOT_GET : String = "bot.get"

///|
pub const METHOD_BOT_CREATE : String = "bot.create"

///|
pub const METHOD_BOT_UPDATE : String = "bot.update"

///|
pub const METHOD_BOT_ARCHIVE : String = "bot.archive"

///|
pub const METHOD_BOT_AGENT_LIST : String = "bot.agent.list"

///|
pub const METHOD_BOT_AGENT_CREATE : String = "bot.agent.create"

///|
pub const METHOD_BOT_AGENT_SUSPEND : String = "bot.agent.suspend"

///|
pub const METHOD_BOT_AGENT_RETIRE : String = "bot.agent.retire"

///|
pub const METHOD_CHAT_LIST : String = "chat.list"

///|
pub const METHOD_CHAT_GET : String = "chat.get"

///|
pub const METHOD_CHAT_CREATE : String = "chat.create"

///|
pub const METHOD_CHAT_AGENT_SESSION_START : String = "chat.agent_session.start"

///|
pub const METHOD_CHAT_AGENT_SESSION_END : String = "chat.agent_session.end"

///|
pub const METHOD_CHAT_SEND : String = "chat.send"

///|
pub const METHOD_CHAT_READ : String = "chat.read"

///|
pub const METHOD_CHAT_STOP : String = "chat.stop"

///|
pub const METHOD_CHAT_MESSAGES : String = "chat.messages"

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

///|
pub const BOTS_ERR_INVALID : String = "invalid"

///|
pub const BOTS_ERR_NOT_FOUND : String = "not_found"

///|
pub const BOTS_ERR_CONFLICT : String = "conflict"

///|
pub const BOTS_ERR_UNAUTHORIZED : String = "unauthorized"

///|
pub const BOTS_ERR_UNSUPPORTED : String = "unsupported"

///|
pub const BOTS_ERR_INTERNAL : String = "internal"

///|
pub fn bots_error_label(kind : String) -> String {
  match kind {
    "invalid" => "InvalidRequest"
    "not_found" => "NotFound"
    "conflict" => "Conflict"
    "unauthorized" => "Unauthorized"
    "unsupported" => "Unsupported"
    _ => "Internal"
  }
}

///|
pub fn bots_error(kind : String, message : String) -> RpcError {
  RpcError::new(
    ERR_HOST,
    bots_error_label(kind) + ": " + message,
    data=json_object([
      ("kind", json_string(kind)),
      ("reason", json_string(message)),
    ]),
  )
}

///|
/// Map a domain/store rejection to the canonical Bot/Chat error kinds.
pub fn bots_error_from_message(message : String) -> RpcError {
  let lower = message.to_lower()
  if lower.contains("not found") {
    return bots_error(BOTS_ERR_NOT_FOUND, message)
  }
  if lower.contains("membership") || lower.contains("not an active") {
    return bots_error(BOTS_ERR_UNAUTHORIZED, message)
  }
  if lower.contains("already exists") ||
    lower.contains("read-only") ||
    lower.contains("cap reached") ||
    lower.contains("at most one") ||
    lower.contains("concurrency") ||
    lower.contains("cannot transition") ||
    lower.contains("cannot be") ||
    lower.contains("immutable") ||
    lower.contains("different") ||
    lower.contains("is not active") {
    return bots_error(BOTS_ERR_CONFLICT, message)
  }
  if lower.contains("required") ||
    lower.contains("not canonical") ||
    lower.contains("unknown") ||
    lower.contains("invalid") ||
    lower.contains("incomplete") ||
    lower.contains("exceeds") ||
    lower.contains("allowlist") ||
    lower.contains("no changed fields") {
    return bots_error(BOTS_ERR_INVALID, message)
  }
  bots_error(BOTS_ERR_INTERNAL, message)
}

// ---------------------------------------------------------------------------
// Result records
// ---------------------------------------------------------------------------

///|
/// `chat.get` / `chat.list` entry: the durable Chat, its participant
/// relations, the active AgentSession (or none) and the bound Agent summary.
pub(all) struct ChatDetail {
  chat : ChatRecord
  participants : Array[ChatParticipant]
  active_agent_session : AgentSession?
  agent : AgentRecord?
}

///|
pub fn ChatDetail::new(
  chat~ : ChatRecord,
  participants~ : Array[ChatParticipant],
  active_agent_session~ : AgentSession? = None,
  agent~ : AgentRecord? = None,
) -> ChatDetail {
  { chat, participants, active_agent_session, agent, }
}

///|
pub fn ChatDetail::to_json(self : ChatDetail) -> @json.Json {
  let participants : Array[@json.Json] = []
  for participant in self.participants {
    participants.push(participant.to_json())
  }
  json_object([
    ("chat", self.chat.to_json()),
    ("participants", json_array(participants)),
    (
      "active_agent_session",
      match self.active_agent_session {
        Some(session) => session.to_json()
        None => json_null()
      },
    ),
    (
      "agent",
      match self.agent {
        Some(agent) => agent.to_json()
        None => json_null()
      },
    ),
  ])
}

///|
pub fn chat_detail_from_json(json : @json.Json) -> ChatDetail? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let chat = match object.get("chat") {
    Some(value) =>
      match chat_from_json(value) {
        Some(record) => record
        None => return None
      }
    None => return None
  }
  let participants : Array[ChatParticipant] = []
  match object.get("participants") {
    Some(@json.Json::Array(items)) =>
      for item in items {
        match chat_participant_from_json(item) {
          Some(participant) => participants.push(participant)
          None => ()
        }
      }
    _ => ()
  }
  let active_agent_session = match object.get("active_agent_session") {
    Some(@json.Json::Null) => None
    Some(value) => chat_agent_session_from_json(value)
    None => None
  }
  let agent = match object.get("agent") {
    Some(@json.Json::Null) => None
    Some(value) => agent_from_json(value)
    None => None
  }
  Some({ chat, participants, active_agent_session, agent, })
}

///|
pub(all) struct ChatReadResult {
  session_id : String
  runtime_session_id : String
  cursor : Int64
  text : String
  state : String
  pending_decision : String
}

///|
pub fn ChatReadResult::new(
  session_id~ : String,
  runtime_session_id~ : String,
  cursor~ : Int64,
  text~ : String,
  state~ : String,
  pending_decision~ : String = "",
) -> ChatReadResult {
  { session_id, runtime_session_id, cursor, text, state, pending_decision, }
}

///|
pub fn ChatReadResult::to_json(self : ChatReadResult) -> @json.Json {
  json_object([
    ("session_id", json_string(self.session_id)),
    ("runtime_session_id", json_string(self.runtime_session_id)),
    ("cursor", json_int64(self.cursor)),
    ("text", json_string(self.text)),
    ("state", json_string(self.state)),
    ("pending_decision", json_string(self.pending_decision)),
  ])
}

///|
pub fn chat_read_result_from_json(json : @json.Json) -> ChatReadResult? {
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
    runtime_session_id: string_field_or(object, "runtime_session_id", ""),
    cursor: int64_field_or(object, "cursor", 0L),
    text: string_field_or(object, "text", ""),
    state: string_field_or(object, "state", ""),
    pending_decision: string_field_or(object, "pending_decision", ""),
  })
}

///|
pub(all) struct ChatSendResult {
  message : ChatMessage
  session : AgentSession
}

///|
pub fn ChatSendResult::to_json(self : ChatSendResult) -> @json.Json {
  json_object([
    ("message", self.message.to_json()),
    ("session", self.session.to_json()),
  ])
}

///|
pub fn chat_send_result_from_json(json : @json.Json) -> ChatSendResult? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let message = match object.get("message") {
    Some(value) =>
      match chat_message_from_json(value) {
        Some(record) => record
        None => return None
      }
    None => return None
  }
  let session = match object.get("session") {
    Some(value) =>
      match chat_agent_session_from_json(value) {
        Some(record) => record
        None => return None
      }
    None => return None
  }
  Some({ message, session, })
}

///|
pub(all) struct ChatStopResult {
  session : AgentSession
  stopped : Bool
}

///|
pub fn ChatStopResult::to_json(self : ChatStopResult) -> @json.Json {
  json_object([
    ("session", self.session.to_json()),
    ("stopped", json_bool(self.stopped)),
  ])
}

///|
pub fn chat_stop_result_from_json(json : @json.Json) -> ChatStopResult? {
  let object = match as_object(json) {
    Some(value) => value
    None => return None
  }
  let session = match object.get("session") {
    Some(value) =>
      match chat_agent_session_from_json(value) {
        Some(record) => record
        None => return None
      }
    None => return None
  }
  Some({ session, stopped: bool_field_or(object, "stopped", false), })
}

// ---------------------------------------------------------------------------
// Params
// ---------------------------------------------------------------------------

///|
pub fn bot_list_params(client_request_id : String) -> Map[String, @json.Json] {
  Map([("client_request_id", json_string(client_request_id))])
}

///|
pub fn bot_get_params(
  client_request_id : String,
  bot_id : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("bot_id", json_string(bot_id)),
  ])
}

///|
pub fn bot_create_params(
  client_request_id : String,
  bot : BotRecord,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("bot", bot.to_json()),
  ])
}

///|
pub fn bot_update_params(
  client_request_id : String,
  bot : BotRecord,
  changed_fields : Array[String],
  version : Int32,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("bot", bot.to_json()),
    ("changed_fields", json_string_array(changed_fields)),
    ("version", json_int(version)),
  ])
}

///|
pub fn bot_archive_params(
  client_request_id : String,
  bot_id : String,
  reason : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("bot_id", json_string(bot_id)),
    ("reason", json_string(reason)),
  ])
}

///|
pub fn bot_agent_list_params(
  client_request_id : String,
  bot_id : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("bot_id", json_string(bot_id)),
  ])
}

///|
pub fn bot_agent_create_params(
  client_request_id : String,
  bot_id : String,
  agent : AgentRecord,
  decision_id~ : String = "",
  source~ : String = "manual",
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("bot_id", json_string(bot_id)),
    ("agent", agent.to_json()),
    ("decision_id", json_string(decision_id)),
    ("source", json_string(source)),
  ])
}

///|
pub fn bot_agent_suspend_params(
  client_request_id : String,
  agent_id : String,
  reason : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("agent_id", json_string(agent_id)),
    ("reason", json_string(reason)),
  ])
}

///|
pub fn bot_agent_retire_params(
  client_request_id : String,
  agent_id : String,
  reason : String,
) -> Map[String, @json.Json] {
  bot_agent_suspend_params(client_request_id, agent_id, reason)
}

///|
pub fn chat_list_params(
  client_request_id : String,
  project_id : String,
  bot_id : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("project_id", json_string(project_id)),
    ("bot_id", json_string(bot_id)),
  ])
}

///|
pub fn chat_get_params(
  client_request_id : String,
  chat_id : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("chat_id", json_string(chat_id)),
  ])
}

///|
pub fn chat_create_params(
  client_request_id : String,
  chat : ChatRecord,
  bot_id : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("chat", chat.to_json()),
    ("bot_id", json_string(bot_id)),
    ("participant_bot_ids", json_string_array([bot_id])),
  ])
}

///|
pub fn chat_agent_session_start_params(
  client_request_id : String,
  chat_id : String,
  agent_id : String,
  workspace_id : String,
  workspace_root : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("chat_id", json_string(chat_id)),
    ("agent_id", json_string(agent_id)),
    ("workspace_id", json_string(workspace_id)),
    ("workspace_root", json_string(workspace_root)),
  ])
}

///|
pub fn chat_agent_session_end_params(
  client_request_id : String,
  session_id : String,
  end_reason : String,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("session_id", json_string(session_id)),
    ("end_reason", json_string(end_reason)),
  ])
}

///|
pub fn chat_send_params(
  client_request_id : String,
  chat_id : String,
  text : String,
  actor~ : String = "owner",
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("chat_id", json_string(chat_id)),
    ("text", json_string(text)),
    ("actor", json_string(actor)),
  ])
}

///|
pub fn chat_read_params(
  client_request_id : String,
  chat_id : String,
  cursor : Int64,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("chat_id", json_string(chat_id)),
    ("cursor", json_int64(cursor)),
  ])
}

///|
pub fn chat_stop_params(
  client_request_id : String,
  chat_id : String,
  end_reason~ : String = AGENT_SESSION_END_REASON_CANCELLED,
  session_id~ : String = "",
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("chat_id", json_string(chat_id)),
    ("session_id", json_string(session_id)),
    ("end_reason", json_string(end_reason)),
  ])
}

///|
pub fn chat_messages_params(
  client_request_id : String,
  chat_id : String,
  after~ : String = "",
  limit~ : Int32 = 50,
) -> Map[String, @json.Json] {
  Map([
    ("client_request_id", json_string(client_request_id)),
    ("chat_id", json_string(chat_id)),
    ("after", json_string(after)),
    ("limit", json_int(limit)),
  ])
}

// ---------------------------------------------------------------------------
// Param parsers
// ---------------------------------------------------------------------------

///|
pub fn bot_id_param(params : Map[String, @json.Json]) -> Result[String, String] {
  match string_field(params, "bot_id") {
    Some(value) if value != "" => Ok(value)
    _ => Err("missing bot_id")
  }
}

///|
pub fn chat_id_param(
  params : Map[String, @json.Json],
) -> Result[String, String] {
  match string_field(params, "chat_id") {
    Some(value) if value != "" => Ok(value)
    _ => Err("missing chat_id")
  }
}

///|
pub fn bot_agent_id_param(
  params : Map[String, @json.Json],
) -> Result[String, String] {
  match string_field(params, "agent_id") {
    Some(value) if value != "" => Ok(value)
    _ => Err("missing agent_id")
  }
}

///|
pub fn chat_agent_session_id_param(
  params : Map[String, @json.Json],
) -> Result[String, String] {
  match string_field(params, "session_id") {
    Some(value) if value != "" => Ok(value)
    _ => Err("missing session_id")
  }
}

///|
pub fn bot_record_param(
  params : Map[String, @json.Json],
) -> Result[BotRecord, String] {
  match params.get("bot") {
    Some(value) =>
      match bot_from_json(value) {
        Some(record) => Ok(record)
        None => Err("malformed bot record")
      }
    None => Err("missing bot")
  }
}

///|
pub fn agent_record_param(
  params : Map[String, @json.Json],
) -> Result[AgentRecord, String] {
  match params.get("agent") {
    Some(value) =>
      match agent_from_json(value) {
        Some(record) => Ok(record)
        None => Err("malformed agent record")
      }
    None => Err("missing agent")
  }
}

///|
pub fn chat_record_param(
  params : Map[String, @json.Json],
) -> Result[ChatRecord, String] {
  match params.get("chat") {
    Some(value) =>
      match chat_from_json(value) {
        Some(record) => Ok(record)
        None => Err("malformed chat record")
      }
    None => Err("missing chat")
  }
}

///|
pub fn bot_changed_fields_param(
  params : Map[String, @json.Json],
) -> Array[String] {
  string_array_field(params, "changed_fields")
}

///|
pub fn bot_version_param(params : Map[String, @json.Json]) -> Int32 {
  int_field_or(params, "version", 1)
}

///|
pub fn bot_reason_param(params : Map[String, @json.Json]) -> String {
  string_field_or(params, "reason", "")
}

///|
pub fn bot_source_param(params : Map[String, @json.Json]) -> String {
  let value = string_field_or(params, "source", "")
  if value == "" {
    "manual"
  } else {
    value
  }
}

///|
pub fn bot_actor_param(params : Map[String, @json.Json]) -> String {
  let value = string_field_or(params, "actor", "")
  if value == "" {
    "owner"
  } else {
    value
  }
}

///|
pub fn bot_decision_id_param(params : Map[String, @json.Json]) -> String {
  string_field_or(params, "decision_id", "")
}

///|
pub fn chat_project_param(params : Map[String, @json.Json]) -> String {
  string_field_or(params, "project_id", "")
}

///|
pub fn chat_filter_by_bot(params : Map[String, @json.Json]) -> String {
  string_field_or(params, "bot_id", "")
}

///|
pub fn chat_filter_runtime(params : Map[String, @json.Json]) -> String {
  string_field_or(params, "agent_id", "")
}

///|
pub fn chat_scope_param(params : Map[String, @json.Json]) -> String {
  string_field_or(params, "workspace_id", "")
}

///|
pub fn chat_workspace_root_param(params : Map[String, @json.Json]) -> String {
  string_field_or(params, "workspace_root", "")
}

///|
pub fn chat_text_param(
  params : Map[String, @json.Json],
) -> Result[String, String] {
  match string_field(params, "text") {
    Some(value) if value.trim() != "" => Ok(value)
    _ => Err("missing text")
  }
}

///|
pub fn chat_cursor_param(params : Map[String, @json.Json]) -> Int64 {
  int64_field_or(params, "cursor", 0L).max(0L)
}

///|
pub fn chat_after_param(params : Map[String, @json.Json]) -> String {
  string_field_or(params, "after", "")
}

///|
pub fn chat_limit_param(params : Map[String, @json.Json]) -> Int32 {
  int_field_or(params, "limit", 50).max(1).min(200)
}

///|
pub fn chat_end_reason_param(params : Map[String, @json.Json]) -> String {
  let value = string_field_or(params, "end_reason", "")
  if value == "" {
    AGENT_SESSION_END_REASON_CANCELLED
  } else {
    value
  }
}

///|
pub fn chat_session_id_param(params : Map[String, @json.Json]) -> String {
  string_field_or(params, "session_id", "")
}

// ---------------------------------------------------------------------------
// Result builders / decoders
// ---------------------------------------------------------------------------

///|
fn bots_records_result(key : String, records : Array[@json.Json]) -> @json.Json {
  json_object([(key, json_array(records))])
}

///|
pub fn bots_list_result(bots : Array[BotRecord]) -> @json.Json {
  let records : Array[@json.Json] = []
  for bot in bots {
    records.push(bot.to_json())
  }
  bots_records_result("bots", records)
}

///|
pub fn bots_from_result(json : @json.Json) -> Result[Array[BotRecord], String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("result is not an object")
  }
  let items = match object.get("bots") {
    Some(@json.Json::Array(values)) => values
    _ => return Err("result has no bots")
  }
  let out : Array[BotRecord] = []
  for item in items {
    match bot_from_json(item) {
      Some(record) => out.push(record)
      None => return Err("malformed Bot record")
    }
  }
  Ok(out)
}

///|
pub fn bot_result(bot : BotRecord) -> @json.Json {
  json_object([("bot", bot.to_json())])
}

///|
pub fn bot_from_result(json : @json.Json) -> Result[BotRecord, String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("result is not an object")
  }
  match object.get("bot") {
    Some(value) =>
      match bot_from_json(value) {
        Some(record) => Ok(record)
        None => Err("malformed Bot record")
      }
    None => Err("result has no bot")
  }
}

///|
pub fn agents_list_result(agents : Array[AgentRecord]) -> @json.Json {
  let records : Array[@json.Json] = []
  for agent in agents {
    records.push(agent.to_json())
  }
  bots_records_result("agents", records)
}

///|
pub fn agents_from_result(
  json : @json.Json,
) -> Result[Array[AgentRecord], String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("result is not an object")
  }
  let items = match object.get("agents") {
    Some(@json.Json::Array(values)) => values
    _ => return Err("result has no agents")
  }
  let out : Array[AgentRecord] = []
  for item in items {
    match agent_from_json(item) {
      Some(record) => out.push(record)
      None => return Err("malformed Agent record")
    }
  }
  Ok(out)
}

///|
pub fn agent_result(agent : AgentRecord) -> @json.Json {
  json_object([("agent", agent.to_json())])
}

///|
pub fn agent_from_result(json : @json.Json) -> Result[AgentRecord, String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("result is not an object")
  }
  match object.get("agent") {
    Some(value) =>
      match agent_from_json(value) {
        Some(record) => Ok(record)
        None => Err("malformed Agent record")
      }
    None => Err("result has no agent")
  }
}

///|
pub fn chat_result(detail : ChatDetail) -> @json.Json {
  detail.to_json()
}

///|
pub fn chat_from_result(json : @json.Json) -> Result[ChatDetail, String] {
  match chat_detail_from_json(json) {
    Some(value) => Ok(value)
    None => Err("malformed Chat detail")
  }
}

///|
pub fn chats_list_result(chats : Array[ChatDetail]) -> @json.Json {
  let records : Array[@json.Json] = []
  for chat in chats {
    records.push(chat.to_json())
  }
  bots_records_result("chats", records)
}

///|
pub fn chats_from_result(
  json : @json.Json,
) -> Result[Array[ChatDetail], String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("result is not an object")
  }
  let items = match object.get("chats") {
    Some(@json.Json::Array(values)) => values
    _ => return Err("result has no chats")
  }
  let out : Array[ChatDetail] = []
  for item in items {
    match chat_detail_from_json(item) {
      Some(value) => out.push(value)
      None => return Err("malformed Chat detail")
    }
  }
  Ok(out)
}

///|
pub fn chat_agent_session_result(session : AgentSession) -> @json.Json {
  json_object([("session", session.to_json())])
}

///|
pub fn chat_agent_session_from_result(
  json : @json.Json,
) -> Result[AgentSession, String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("result is not an object")
  }
  match object.get("session") {
    Some(value) =>
      match chat_agent_session_from_json(value) {
        Some(record) => Ok(record)
        None => Err("malformed AgentSession record")
      }
    None => Err("result has no session")
  }
}

///|
pub fn chat_messages_result(messages : Array[ChatMessage]) -> @json.Json {
  let records : Array[@json.Json] = []
  for message in messages {
    records.push(message.to_json())
  }
  bots_records_result("messages", records)
}

///|
pub fn chat_messages_from_result(
  json : @json.Json,
) -> Result[Array[ChatMessage], String] {
  let object = match as_object(json) {
    Some(value) => value
    None => return Err("result is not an object")
  }
  let items = match object.get("messages") {
    Some(@json.Json::Array(values)) => values
    _ => return Err("result has no messages")
  }
  let out : Array[ChatMessage] = []
  for item in items {
    match chat_message_from_json(item) {
      Some(record) => out.push(record)
      None => return Err("malformed Chat message")
    }
  }
  Ok(out)
}

///|
pub fn chat_send_result(
  message : ChatMessage,
  session : AgentSession,
) -> @json.Json {
  ChatSendResult::{ message, session, }.to_json()
}

///|
pub fn chat_stop_result(session : AgentSession, stopped : Bool) -> @json.Json {
  ChatStopResult::{ session, stopped, }.to_json()
}

///|
pub fn chat_read_result(
  session : AgentSession,
  cursor : Int64,
  text : String,
  pending_decision : String,
) -> @json.Json {
  ChatReadResult::new(
    session_id=session.id,
    runtime_session_id=session.runtime_session_id,
    cursor~,
    text~,
    state=session.state,
    pending_decision~,
  ).to_json()
}
