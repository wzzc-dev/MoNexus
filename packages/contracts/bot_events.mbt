///|
/// ADR-0017 §6 Bot, Chat, AgentSession and Project-membership events.
///
/// These builders return the payload object only. The host wraps it in the
/// existing `EventEnvelope`, which remains the single append-only authority.

// ---------------------------------------------------------------------------
// Event types
// ---------------------------------------------------------------------------

///|
pub const EVENT_BOT_CREATED : String = "bot.created"

///|
pub const EVENT_BOT_UPDATED : String = "bot.updated"

///|
pub const EVENT_BOT_POLICY_CHANGED : String = "bot.policy.changed"

///|
pub const EVENT_BOT_PERMISSIONS_CHANGED : String = "bot.permissions.changed"

///|
pub const EVENT_BOT_ARCHIVED : String = "bot.archived"

///|
pub const EVENT_BOT_AGENT_CREATED : String = "bot.agent.created"

///|
pub const EVENT_BOT_AGENT_SUSPENDED : String = "bot.agent.suspended"

///|
pub const EVENT_BOT_AGENT_RETIRED : String = "bot.agent.retired"

///|
pub const EVENT_BOT_AGENT_UPDATED : String = "bot.agent.updated"

///|
pub const EVENT_BOT_AGENT_CREATION_DENIED : String = "bot.agent.creation_denied"

///|
pub const EVENT_BOT_MEMORY_WRITE_REQUESTED : String = "bot.memory.write.requested"

///|
pub const EVENT_BOT_MEMORY_WRITE_COMMITTED : String = "bot.memory.write.committed"

///|
pub const EVENT_BOT_MEMORY_WRITE_DENIED : String = "bot.memory.write.denied"

///|
pub const EVENT_CHAT_CREATED : String = "chat.created"

///|
pub const EVENT_CHAT_PARTICIPANT_ADDED : String = "chat.participant.added"

///|
pub const EVENT_CHAT_PARTICIPANT_REMOVED : String = "chat.participant.removed"

///|
pub const EVENT_CHAT_PROJECT_CHANGED : String = "chat.project.changed"

///|
pub const EVENT_CHAT_MESSAGE_APPENDED : String = "chat.message.appended"

///|
pub const EVENT_CHAT_AGENT_SELECTED : String = "chat.agent.selected"

///|
pub const EVENT_CHAT_AGENT_SWITCHED : String = "chat.agent.switched"

///|
pub const EVENT_CHAT_AGENT_SELECTION_DENIED : String =
  "chat.agent.selection_denied"

///|
pub const EVENT_CHAT_AGENT_SESSION_STARTED : String =
  "chat.agent_session.started"

///|
pub const EVENT_CHAT_AGENT_SESSION_UPDATED : String =
  "chat.agent_session.updated"

///|
pub const EVENT_CHAT_AGENT_SESSION_ENDED : String =
  "chat.agent_session.ended"

///|
pub const EVENT_PROJECT_MEMBER_ADDED : String = "project.member.added"

///|
pub const EVENT_PROJECT_MEMBER_REMOVED : String = "project.member.removed"

// ---------------------------------------------------------------------------
// Event subjects
// ---------------------------------------------------------------------------

///|
pub fn bot_event_subject(bot_id : String) -> String {
  "bot/" + bot_id
}

///|
pub fn chat_event_subject(chat_id : String) -> String {
  "chat/" + chat_id
}

///|
pub fn project_event_subject(project_id : String) -> String {
  "project/" + project_id
}

// ---------------------------------------------------------------------------
// Bot payloads
// ---------------------------------------------------------------------------

///|
pub fn bot_created_payload(
  bot : BotRecord,
  permission_ceiling_hash : String,
  actor : String,
  source : String,
) -> @json.Json {
  json_object([
    ("bot_id", json_string(bot.id)),
    ("org_id", json_string(bot.org_id)),
    ("persona_ref", json_string(bot.persona_ref)),
    ("memory_ref", json_string(bot.memory_ref)),
    ("permission_ceiling_hash", json_string(permission_ceiling_hash)),
    ("create_policy", json_string(bot.create_policy)),
    ("actor", json_string(actor)),
    ("source", json_string(source)),
    ("record", bot.to_json()),
  ])
}

///|
pub fn bot_updated_payload(
  bot : BotRecord,
  changed_fields : Array[String],
  version : Int,
  actor : String,
) -> @json.Json {
  json_object([
    ("bot_id", json_string(bot.id)),
    ("changed_fields", json_string_array(changed_fields)),
    ("version", json_int(version)),
    ("actor", json_string(actor)),
    ("record", bot.to_json()),
  ])
}

///|
pub fn bot_policy_changed_payload(
  bot : BotRecord,
  old_policy : String,
  new_policy : String,
  software_allowlist_hash : String,
  actor : String,
) -> @json.Json {
  json_object([
    ("bot_id", json_string(bot.id)),
    ("old_policy", json_string(old_policy)),
    ("new_policy", json_string(new_policy)),
    ("agent_count_cap", json_int(bot.agent_count_cap)),
    ("agent_concurrency_cap", json_int(bot.agent_concurrency_cap)),
    ("software_allowlist_hash", json_string(software_allowlist_hash)),
    ("actor", json_string(actor)),
    ("record", bot.to_json()),
  ])
}

///|
pub fn bot_permissions_changed_payload(
  bot : BotRecord,
  old_ceiling_hash : String,
  new_ceiling_hash : String,
  actor : String,
) -> @json.Json {
  json_object([
    ("bot_id", json_string(bot.id)),
    ("old_ceiling_hash", json_string(old_ceiling_hash)),
    ("new_ceiling_hash", json_string(new_ceiling_hash)),
    ("actor", json_string(actor)),
    ("record", bot.to_json()),
  ])
}

///|
pub fn bot_archived_payload(
  bot : BotRecord,
  reason : String,
  active_session_count : Int,
  actor : String,
) -> @json.Json {
  json_object([
    ("bot_id", json_string(bot.id)),
    ("reason", json_string(reason)),
    ("active_session_count", json_int(active_session_count)),
    ("actor", json_string(actor)),
    ("record", bot.to_json()),
  ])
}

///|
pub fn bot_agent_created_payload(
  bot_id : String,
  agent : AgentRecord,
  permission_scope_hash : String,
  create_policy : String,
  decision_id : String,
  actor : String,
  source : String,
) -> @json.Json {
  json_object([
    ("bot_id", json_string(bot_id)),
    ("agent_id", json_string(agent.id)),
    ("runtime_binding_hash", json_string(agent.runtime_binding.hash)),
    ("permission_scope_hash", json_string(permission_scope_hash)),
    ("create_policy", json_string(create_policy)),
    ("decision_id", json_string(decision_id)),
    ("actor", json_string(actor)),
    ("source", json_string(source)),
    ("record", agent.to_json()),
  ])
}

///|
pub fn bot_agent_suspended_payload(
  bot_id : String,
  agent : AgentRecord,
  reason : String,
  actor : String,
) -> @json.Json {
  json_object([
    ("bot_id", json_string(bot_id)),
    ("agent_id", json_string(agent.id)),
    ("reason", json_string(reason)),
    ("actor", json_string(actor)),
    ("record", agent.to_json()),
  ])
}

///|
pub fn bot_agent_retired_payload(
  bot_id : String,
  agent : AgentRecord,
  reason : String,
  actor : String,
) -> @json.Json {
  bot_agent_suspended_payload(bot_id, agent, reason, actor)
}

///|
pub fn bot_agent_updated_payload(
  agent : AgentRecord,
  changed_fields : Array[String],
  actor : String,
) -> @json.Json {
  json_object([
    ("bot_id", json_string(agent.bot_id)),
    ("agent_id", json_string(agent.id)),
    ("changed_fields", json_string_array(changed_fields)),
    ("runtime_binding_hash", json_string(agent.runtime_binding.hash)),
    ("actor", json_string(actor)),
    ("record", agent.to_json()),
  ])
}

///|
pub fn bot_agent_creation_denied_payload(
  bot_id : String,
  requested_software : String,
  reason : String,
  policy_snapshot_hash : String,
  decision_id : String,
  actor : String,
) -> @json.Json {
  json_object([
    ("bot_id", json_string(bot_id)),
    ("requested_software", json_string(requested_software)),
    ("reason", json_string(reason)),
    ("policy_snapshot_hash", json_string(policy_snapshot_hash)),
    ("decision_id", json_string(decision_id)),
    ("actor", json_string(actor)),
  ])
}

///|
pub fn bot_memory_write_requested_payload(
  bot_id : String,
  entry_id : String,
  agent_session_id : String,
  agent_id : String,
  digest : String,
  requested_scope : String,
  actor : String,
) -> @json.Json {
  json_object([
    ("bot_id", json_string(bot_id)),
    ("entry_id", json_string(entry_id)),
    ("agent_session_id", json_string(agent_session_id)),
    ("agent_id", json_string(agent_id)),
    ("digest", json_string(digest)),
    ("requested_scope", json_string(requested_scope)),
    ("actor", json_string(actor)),
  ])
}

///|
pub fn bot_memory_write_committed_payload(
  bot_id : String,
  entry_id : String,
  agent_session_id : String,
  agent_id : String,
  bytes : Int,
  digest : String,
  decision_id : String,
  artifact_id : String,
) -> @json.Json {
  json_object([
    ("bot_id", json_string(bot_id)),
    ("entry_id", json_string(entry_id)),
    ("agent_session_id", json_string(agent_session_id)),
    ("agent_id", json_string(agent_id)),
    ("bytes", json_int(bytes)),
    ("digest", json_string(digest)),
    ("decision_id", json_string(decision_id)),
    ("artifact_id", json_string(artifact_id)),
  ])
}

///|
pub fn bot_memory_write_denied_payload(
  bot_id : String,
  reason : String,
  agent_session_id : String,
  digest : String,
  decision_id : String,
) -> @json.Json {
  json_object([
    ("bot_id", json_string(bot_id)),
    ("reason", json_string(reason)),
    ("agent_session_id", json_string(agent_session_id)),
    ("digest", json_string(digest)),
    ("decision_id", json_string(decision_id)),
  ])
}

// ---------------------------------------------------------------------------
// Chat payloads
// ---------------------------------------------------------------------------

///|
pub fn chat_created_payload(
  chat : ChatRecord,
  participants : Array[ChatParticipant],
  actor : String,
  source : String,
) -> @json.Json {
  let participant_bot_ids : Array[String] = []
  let participant_json : Array[@json.Json] = []
  for participant in participants {
    participant_bot_ids.push(participant.bot_id)
    participant_json.push(participant.to_json())
  }
  json_object([
    ("chat_id", json_string(chat.id)),
    ("participant_bot_ids", json_string_array(participant_bot_ids)),
    ("participants", json_array(participant_json)),
    ("project_id", json_string(chat.project_id)),
    ("title", json_string(chat.title)),
    ("actor", json_string(actor)),
    ("source", json_string(source)),
    ("record", chat.to_json()),
  ])
}

///|
pub fn chat_participant_added_payload(
  participant : ChatParticipant,
  project_access_check : String,
  actor : String,
) -> @json.Json {
  json_object([
    ("chat_id", json_string(participant.chat_id)),
    ("bot_id", json_string(participant.bot_id)),
    ("role", json_string(participant.role)),
    ("project_access_check", json_string(project_access_check)),
    ("actor", json_string(actor)),
    ("record", participant.to_json()),
  ])
}

///|
pub fn chat_participant_removed_payload(
  participant : ChatParticipant,
  reason : String,
  active_session_ended : Bool,
  actor : String,
) -> @json.Json {
  json_object([
    ("chat_id", json_string(participant.chat_id)),
    ("bot_id", json_string(participant.bot_id)),
    ("reason", json_string(reason)),
    ("active_session_ended", json_bool(active_session_ended)),
    ("actor", json_string(actor)),
    ("record", participant.to_json()),
  ])
}

///|
pub fn chat_project_changed_payload(
  chat : ChatRecord,
  old_project_id : String,
  membership_check : String,
  actor : String,
) -> @json.Json {
  json_object([
    ("chat_id", json_string(chat.id)),
    ("old_project_id", json_string(old_project_id)),
    ("new_project_id", json_string(chat.project_id)),
    ("membership_check", json_string(membership_check)),
    ("actor", json_string(actor)),
    ("record", chat.to_json()),
  ])
}

///|
pub fn chat_message_appended_payload(
  message : ChatMessage,
) -> @json.Json {
  json_object([
    ("chat_id", json_string(message.chat_id)),
    ("message_id", json_string(message.id)),
    ("role", json_string(message.role)),
    ("agent_session_id", json_string(message.agent_session_id)),
    ("body_ref", json_string(message.body_ref)),
    ("digest", json_string(message.digest)),
    ("actor", json_string(message.actor)),
  ])
}

///|
pub fn chat_agent_selected_payload(
  chat_id : String,
  bot_id : String,
  agent : AgentRecord,
  permission_snapshot_hash : String,
  actor : String,
  decision_id : String,
) -> @json.Json {
  json_object([
    ("chat_id", json_string(chat_id)),
    ("bot_id", json_string(bot_id)),
    ("agent_id", json_string(agent.id)),
    ("runtime_binding_hash", json_string(agent.runtime_binding.hash)),
    ("permission_snapshot_hash", json_string(permission_snapshot_hash)),
    ("actor", json_string(actor)),
    ("decision_id", json_string(decision_id)),
    ("record", agent.to_json()),
  ])
}

///|
pub fn chat_agent_switched_payload(
  chat : ChatRecord,
  from_agent_id : String,
  to_agent_id : String,
  from_session_id : String,
  to_session_id : String,
  boundary_id : String,
  old_permission_snapshot_hash : String,
  new_permission_snapshot_hash : String,
  actor : String,
) -> @json.Json {
  json_object([
    ("chat_id", json_string(chat.id)),
    ("from_agent_id", json_string(from_agent_id)),
    ("to_agent_id", json_string(to_agent_id)),
    ("from_session_id", json_string(from_session_id)),
    ("to_session_id", json_string(to_session_id)),
    ("boundary_id", json_string(boundary_id)),
    (
      "old_permission_snapshot_hash",
      json_string(old_permission_snapshot_hash),
    ),
    (
      "new_permission_snapshot_hash",
      json_string(new_permission_snapshot_hash),
    ),
    ("actor", json_string(actor)),
    ("record", chat.to_json()),
  ])
}

///|
pub fn chat_agent_selection_denied_payload(
  chat_id : String,
  requested_agent_id : String,
  reason : String,
  policy_snapshot_hash : String,
  actor : String,
) -> @json.Json {
  json_object([
    ("chat_id", json_string(chat_id)),
    ("requested_agent_id", json_string(requested_agent_id)),
    ("reason", json_string(reason)),
    ("policy_snapshot_hash", json_string(policy_snapshot_hash)),
    ("actor", json_string(actor)),
  ])
}

// ---------------------------------------------------------------------------
// AgentSession payloads
// ---------------------------------------------------------------------------

///|
pub fn chat_agent_session_started_payload(
  session : AgentSession,
  bot_id : String,
  runtime_binding_hash : String,
  inherited_summary_ref : String,
) -> @json.Json {
  json_object([
    ("chat_id", json_string(session.chat_id)),
    ("agent_session_id", json_string(session.id)),
    ("agent_id", json_string(session.agent_id)),
    ("bot_id", json_string(bot_id)),
    ("runtime_binding_hash", json_string(runtime_binding_hash)),
    (
      "range",
      json_object([
        ("project_id", json_string(session.project_id)),
        ("workspace_id", json_string(session.workspace_id)),
        ("workspace_root", json_string(session.workspace_root)),
      ]),
    ),
    (
      "permission_snapshot_hash",
      json_string(session.permission_snapshot_hash),
    ),
    ("inherited_summary_ref", json_string(inherited_summary_ref)),
    ("started_at", json_string(session.started_at)),
    ("record", session.to_json()),
  ])
}

///|
pub fn chat_agent_session_updated_payload(
  session : AgentSession,
  turns : Int,
  decisions : Int,
) -> @json.Json {
  json_object([
    ("chat_id", json_string(session.chat_id)),
    ("agent_session_id", json_string(session.id)),
    ("state", json_string(session.state)),
    ("turns", json_int(turns)),
    ("decisions", json_int(decisions)),
    ("updated_at", json_string(session.updated_at)),
    ("record", session.to_json()),
  ])
}

///|
pub fn chat_agent_session_ended_payload(
  session : AgentSession,
  next_session_id : String,
) -> @json.Json {
  json_object([
    ("chat_id", json_string(session.chat_id)),
    ("agent_session_id", json_string(session.id)),
    ("end_reason", json_string(session.end_reason)),
    ("summary_ref", json_string(session.summary_ref)),
    ("ended_at", json_string(session.ended_at)),
    ("next_session_id", json_string(next_session_id)),
    ("record", session.to_json()),
  ])
}

// ---------------------------------------------------------------------------
// Project membership payloads
// ---------------------------------------------------------------------------

///|
pub fn project_member_added_payload(
  membership : ProjectMembership,
  actor : String,
) -> @json.Json {
  json_object([
    ("project_id", json_string(membership.project_id)),
    ("bot_id", json_string(membership.bot_id)),
    ("access", json_string_array(membership.access)),
    ("reason", json_string(membership.reason)),
    ("actor", json_string(actor)),
    ("record", membership.to_json()),
  ])
}

///|
pub fn project_member_removed_payload(
  membership : ProjectMembership,
  actor : String,
) -> @json.Json {
  json_object([
    ("project_id", json_string(membership.project_id)),
    ("bot_id", json_string(membership.bot_id)),
    ("access", json_string_array(membership.access)),
    ("reason", json_string(membership.reason)),
    ("actor", json_string(actor)),
    ("record", membership.to_json()),
  ])
}

// ---------------------------------------------------------------------------
// Full-record decoders
// ---------------------------------------------------------------------------

///|
fn payload_record(payload : @json.Json) -> @json.Json? {
  let object = match as_object(payload) {
    Some(value) => value
    None => return None
  }
  object.get("record")
}

///|
pub fn bot_created_record(payload : @json.Json) -> BotRecord? {
  match payload_record(payload) {
    Some(value) => bot_from_json(value)
    None => None
  }
}

///|
pub fn bot_updated_record(payload : @json.Json) -> BotRecord? {
  bot_created_record(payload)
}

///|
pub fn bot_policy_changed_record(payload : @json.Json) -> BotRecord? {
  bot_created_record(payload)
}

///|
pub fn bot_permissions_changed_record(payload : @json.Json) -> BotRecord? {
  bot_created_record(payload)
}

///|
pub fn bot_archived_record(payload : @json.Json) -> BotRecord? {
  bot_created_record(payload)
}

///|
pub fn bot_agent_created_record(payload : @json.Json) -> AgentRecord? {
  match payload_record(payload) {
    Some(value) => agent_from_json(value)
    None => None
  }
}

///|
pub fn bot_agent_suspended_record(payload : @json.Json) -> AgentRecord? {
  bot_agent_created_record(payload)
}

///|
pub fn bot_agent_retired_record(payload : @json.Json) -> AgentRecord? {
  bot_agent_created_record(payload)
}

///|
pub fn bot_agent_updated_record(payload : @json.Json) -> AgentRecord? {
  bot_agent_created_record(payload)
}

///|
pub fn chat_created_record(payload : @json.Json) -> ChatRecord? {
  match payload_record(payload) {
    Some(value) => chat_from_json(value)
    None => None
  }
}

///|
pub fn chat_created_participants(
  payload : @json.Json,
) -> Array[ChatParticipant] {
  let out : Array[ChatParticipant] = []
  let object = match as_object(payload) {
    Some(value) => value
    None => return out
  }
  match object.get("participants") {
    Some(@json.Json::Array(items)) => {
      for item in items {
        match chat_participant_from_json(item) {
          Some(participant) => out.push(participant)
          None => ()
        }
      }
    }
    _ => ()
  }
  out
}

///|
pub fn chat_participant_added_record(
  payload : @json.Json,
) -> ChatParticipant? {
  match payload_record(payload) {
    Some(value) => chat_participant_from_json(value)
    None => None
  }
}

///|
pub fn chat_participant_removed_record(
  payload : @json.Json,
) -> ChatParticipant? {
  chat_participant_added_record(payload)
}

///|
pub fn chat_project_changed_record(payload : @json.Json) -> ChatRecord? {
  chat_created_record(payload)
}

///|
pub fn chat_agent_switched_record(payload : @json.Json) -> ChatRecord? {
  chat_created_record(payload)
}

///|
pub fn chat_agent_selected_record(payload : @json.Json) -> AgentRecord? {
  match payload_record(payload) {
    Some(value) => agent_from_json(value)
    None => None
  }
}

///|
pub fn chat_agent_session_started_record(
  payload : @json.Json,
) -> AgentSession? {
  match payload_record(payload) {
    Some(value) => chat_agent_session_from_json(value)
    None => None
  }
}

///|
pub fn chat_agent_session_updated_record(
  payload : @json.Json,
) -> AgentSession? {
  chat_agent_session_started_record(payload)
}

///|
pub fn chat_agent_session_ended_record(
  payload : @json.Json,
) -> AgentSession? {
  chat_agent_session_started_record(payload)
}

///|
pub fn project_member_added_record(
  payload : @json.Json,
) -> ProjectMembership? {
  match payload_record(payload) {
    Some(value) => project_membership_from_json(value)
    None => None
  }
}

///|
pub fn project_member_removed_record(
  payload : @json.Json,
) -> ProjectMembership? {
  project_member_added_record(payload)
}
