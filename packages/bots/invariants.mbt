///|
/// ADR-0017 §1.2 hard invariants that can be checked without host storage.

// ---------------------------------------------------------------------------
// Participants and project access
// ---------------------------------------------------------------------------

///|
pub fn chat_participant_identity_valid(
  participant : @contracts.ChatParticipant,
) -> Bool {
  participant.role == @contracts.CHAT_PARTICIPANT_ROLE_BOT &&
  @contracts.is_bot_id(participant.bot_id)
}

///|
pub fn validate_chat_participant_identity(
  participant : @contracts.ChatParticipant,
) -> Result[Unit, String] {
  if participant.role != @contracts.CHAT_PARTICIPANT_ROLE_BOT {
    return Err("Chat participants must have role=bot")
  }
  if @contracts.is_agent_id(participant.bot_id) ||
    @contracts.is_legacy_agent_id(participant.bot_id) ||
    !@contracts.is_bot_id(participant.bot_id) {
    return Err("Agent cannot be a Chat participant")
  }
  Ok(())
}

///|
pub fn project_membership_active(
  project_id : String,
  bot_id : String,
  memberships : Array[@contracts.ProjectMembership],
) -> Bool {
  for membership in memberships {
    if membership.project_id == project_id &&
      membership.bot_id == bot_id &&
      membership.state == @contracts.MEMBERSHIP_STATE_ACTIVE {
      return true
    }
  }
  false
}

///|
pub fn chat_has_active_bot_participant(
  chat_id : String,
  bot_id : String,
  participants : Array[@contracts.ChatParticipant],
) -> Bool {
  for participant in participants {
    if participant.chat_id == chat_id &&
      participant.bot_id == bot_id &&
      participant.role == @contracts.CHAT_PARTICIPANT_ROLE_BOT &&
      participant.state == @contracts.PARTICIPANT_STATE_ACTIVE {
      return true
    }
  }
  false
}

///|
pub fn validate_project_chat_participants(
  chat : @contracts.ChatRecord,
  participants : Array[@contracts.ChatParticipant],
  memberships : Array[@contracts.ProjectMembership],
) -> Result[Unit, String] {
  if chat.project_id == "" {
    return Ok(())
  }
  for participant in participants {
    if participant.chat_id != chat.id ||
      participant.state != @contracts.PARTICIPANT_STATE_ACTIVE {
      continue
    }
    if !project_membership_active(
      chat.project_id,
      participant.bot_id,
      memberships,
    ) {
      return Err(
        "project Chat participant has no active Project membership: " +
        participant.bot_id,
      )
    }
  }
  Ok(())
}

// ---------------------------------------------------------------------------
// AgentSession invariants
// ---------------------------------------------------------------------------

///|
pub fn nonterminal_agent_session_count(
  chat_id : String,
  sessions : Array[@contracts.AgentSession],
) -> Int {
  let mut count = 0
  for session in sessions {
    if session.chat_id == chat_id &&
      agent_session_is_nonterminal(session.state) {
      count = count + 1
    }
  }
  count
}

///|
pub fn bot_has_nonterminal_agent_session(
  bot_id : String,
  agents : Array[@contracts.AgentRecord],
  sessions : Array[@contracts.AgentSession],
) -> Bool {
  for session in sessions {
    if !agent_session_is_nonterminal(session.state) {
      continue
    }
    let agent = match find_agent(session.agent_id, agents) {
      Some(found) => found
      None => continue
    }
    if agent.bot_id == bot_id {
      return true
    }
  }
  false
}

///|
fn find_agent(
  agent_id : String,
  agents : Array[@contracts.AgentRecord],
) -> @contracts.AgentRecord? {
  for agent in agents {
    if agent.id == agent_id {
      return Some(agent)
    }
  }
  None
}

///|
pub fn validate_bot_archive(
  bot : @contracts.BotRecord,
  agents : Array[@contracts.AgentRecord],
  sessions : Array[@contracts.AgentSession],
) -> Result[Unit, String] {
  if !bot_transition_allowed(bot.state, @contracts.BOT_STATE_ARCHIVED) {
    return Err("Bot cannot transition to archived from its current state")
  }
  if bot_has_nonterminal_agent_session(bot.id, agents, sessions) {
    return Err("Bot cannot be archived while an AgentSession is non-terminal")
  }
  Ok(())
}

///|
pub fn validate_agent_retirement(
  agent : @contracts.AgentRecord,
  sessions : Array[@contracts.AgentSession],
) -> Result[Unit, String] {
  if !agent_transition_allowed(
    agent.state,
    @contracts.AGENT_LIFECYCLE_RETIRED,
  ) {
    return Err("Agent cannot transition to retired from its current state")
  }
  for session in sessions {
    if session.agent_id == agent.id &&
      agent_session_is_nonterminal(session.state) {
      return Err("Agent cannot be retired while its AgentSession is non-terminal")
    }
  }
  Ok(())
}

///|
pub fn validate_chat_archive(
  chat : @contracts.ChatRecord,
  sessions : Array[@contracts.AgentSession],
) -> Result[Unit, String] {
  if !chat_transition_allowed(chat.state, @contracts.CHAT_STATE_ARCHIVED) {
    return Err("Chat cannot transition to archived from its current state")
  }
  if nonterminal_agent_session_count(chat.id, sessions) > 0 {
    return Err("Chat cannot be archived while an AgentSession is non-terminal")
  }
  Ok(())
}

///|
pub fn validate_chat_project_change(
  chat : @contracts.ChatRecord,
  sessions : Array[@contracts.AgentSession],
) -> Result[Unit, String] {
  if chat.state != @contracts.CHAT_STATE_ACTIVE {
    return Err("archived Chat is read-only")
  }
  if nonterminal_agent_session_count(chat.id, sessions) > 0 {
    return Err("Chat project cannot change while an AgentSession is non-terminal")
  }
  Ok(())
}

///|
pub fn validate_agent_session_scope(
  chat : @contracts.ChatRecord,
  agent : @contracts.AgentRecord,
  session : @contracts.AgentSession,
  participants : Array[@contracts.ChatParticipant],
  memberships : Array[@contracts.ProjectMembership],
) -> Result[Unit, String] {
  if session.chat_id != chat.id {
    return Err("AgentSession belongs to a different Chat")
  }
  if session.agent_id != agent.id {
    return Err("AgentSession belongs to a different Agent")
  }
  if agent.state != @contracts.AGENT_LIFECYCLE_ACTIVE {
    return Err("AgentSession requires an active Agent")
  }
  if !chat_has_active_bot_participant(
    chat.id,
    agent.bot_id,
    participants,
  ) {
    return Err("AgentSession Bot is not an active Chat participant")
  }
  if session.project_id != chat.project_id {
    return Err("AgentSession project scope does not match the Chat")
  }
  if chat.project_id != "" &&
    !project_membership_active(chat.project_id, agent.bot_id, memberships) {
    return Err("AgentSession Bot has no active Project membership")
  }
  Ok(())
}

///|
/// Gate used before inserting a new AgentSession. The caller still owns the
/// transaction, idempotency key and event append.
pub fn validate_agent_session_start(
  chat : @contracts.ChatRecord,
  agent : @contracts.AgentRecord,
  session : @contracts.AgentSession,
  participants : Array[@contracts.ChatParticipant],
  memberships : Array[@contracts.ProjectMembership],
  existing_sessions : Array[@contracts.AgentSession],
) -> Result[Unit, String] {
  if chat.state != @contracts.CHAT_STATE_ACTIVE {
    return Err("archived Chat is read-only; AgentSession cannot start")
  }
  if session.state != @contracts.AGENT_SESSION_STATE_STARTING {
    return Err("a new AgentSession must start in state=starting")
  }
  if nonterminal_agent_session_count(chat.id, existing_sessions) > 0 {
    return Err("V1 allows at most one non-terminal AgentSession per Chat")
  }
  validate_agent_session_scope(
    chat,
    agent,
    session,
    participants,
    memberships,
  )
}

///|
/// Full V1 Chat invariant check: exactly one active Bot participant, at most
/// one non-terminal AgentSession, project access for every active participant,
/// and no Agent-as-participant relation.
pub fn validate_v1_chat(
  chat : @contracts.ChatRecord,
  participants : Array[@contracts.ChatParticipant],
  agents : Array[@contracts.AgentRecord],
  sessions : Array[@contracts.AgentSession],
  memberships : Array[@contracts.ProjectMembership],
) -> Result[Unit, String] {
  let mut active_participants = 0
  for participant in participants {
    if participant.chat_id != chat.id {
      continue
    }
    match validate_chat_participant_identity(participant) {
      Ok(_) => ()
      Err(reason) => return Err(reason)
    }
    if participant.state == @contracts.PARTICIPANT_STATE_ACTIVE {
      active_participants = active_participants + 1
    }
  }
  if active_participants != 1 {
    return Err("V1 requires exactly one active Bot participant per Chat")
  }
  match validate_project_chat_participants(chat, participants, memberships) {
    Ok(_) => ()
    Err(reason) => return Err(reason)
  }
  let nonterminal = nonterminal_agent_session_count(chat.id, sessions)
  if nonterminal > 1 {
    return Err("V1 allows at most one non-terminal AgentSession per Chat")
  }
  if chat.state == @contracts.CHAT_STATE_ARCHIVED && nonterminal > 0 {
    return Err("archived Chat cannot have an active AgentSession")
  }
  for session in sessions {
    if session.chat_id != chat.id ||
      !agent_session_is_nonterminal(session.state) {
      continue
    }
    let agent = match find_agent(session.agent_id, agents) {
      Some(found) => found
      None => return Err("AgentSession references an unknown Agent")
    }
    match validate_agent_session_scope(
      chat,
      agent,
      session,
      participants,
      memberships,
    ) {
      Ok(_) => ()
      Err(reason) => return Err(reason)
    }
  }
  Ok(())
}

// ---------------------------------------------------------------------------
// Immutable runtime binding
// ---------------------------------------------------------------------------

///|
/// The runtime binding is fixed when the Agent is created. A no-op comparison
/// is valid; any changed field requires creating another Agent.
pub fn validate_runtime_binding_update(
  current : @contracts.RuntimeBinding,
  proposed : @contracts.RuntimeBinding,
) -> Result[Unit, String] {
  if !current.same_as(proposed) {
    return Err("runtime binding is immutable after Agent creation")
  }
  Ok(())
}

// ---------------------------------------------------------------------------
// Shared Bot memory
// ---------------------------------------------------------------------------

///|
pub fn bot_memory_namespace(bot_id : String) -> String {
  "bot/" + bot_id + "/memory"
}

///|
/// Every Agent of a Bot resolves to the same namespace. There is deliberately
/// no Agent-specific memory helper.
pub fn agent_memory_namespace(agent : @contracts.AgentRecord) -> String {
  bot_memory_namespace(agent.bot_id)
}

///|
pub fn validate_shared_memory_access(
  bot : @contracts.BotRecord,
  agent : @contracts.AgentRecord,
  requested_namespace : String,
) -> Result[Unit, String] {
  if agent.bot_id != bot.id {
    return Err("Agent does not belong to this Bot")
  }
  if bot.memory_ref != bot_memory_namespace(bot.id) {
    return Err("Bot memory_ref is not the canonical shared namespace")
  }
  if requested_namespace != bot.memory_ref {
    return Err("Agents may only access the shared Bot memory namespace")
  }
  Ok(())
}

// ---------------------------------------------------------------------------
// Chat transcript
// ---------------------------------------------------------------------------

///|
pub fn validate_chat_message(
  message : @contracts.ChatMessage,
  sessions : Array[@contracts.AgentSession],
) -> Result[Unit, String] {
  if message.role != @contracts.CHAT_MESSAGE_ROLE_ASSISTANT {
    return Ok(())
  }
  if message.agent_session_id == "" {
    return Err("assistant Chat message requires agent_session_id")
  }
  for session in sessions {
    if session.id == message.agent_session_id &&
      session.chat_id == message.chat_id {
      return Ok(())
    }
  }
  Err("assistant Chat message references an AgentSession in another Chat")
}
