///|
/// ADR-0017 P0.3 Bot / Chat RPC and Chat execution bridge.
///
/// Durable mutations go through `bots_store` domain commands. The store owns
/// validation and the append-only event log; this layer publishes the newly
/// appended events to live subscribers and maps the legacy runtime handlers
/// into canonical AgentSessions.

// ---------------------------------------------------------------------------
// Event bridge
// ---------------------------------------------------------------------------

///|
/// Publish every store event appended after `after` and advance the host's
/// sequence cursor. Caller holds `state.mutex`.
fn HostState::sync_bots_events_after(
  self : HostState,
  after : Int64,
) -> Unit {
  let mut cursor = after
  for ;; {
    let events = match self.store.load_events_since(cursor, 200) {
      Ok(value) => value
      Err(message) => {
        println("monexus-host: cannot read Bot/Chat events: " + message)
        break
      }
    }
    if events.length() == 0 {
      break
    }
    for event in events {
      self.publish(event)
      cursor = event.seq
    }
    if events.length() < 200 {
      break
    }
  }
  match self.store.last_seq() {
    Ok(seq) =>
      if seq + 1L > self.next_seq {
        self.next_seq = seq + 1L
      }
    Err(message) =>
      println("monexus-host: cannot advance Bot/Chat event cursor: " + message)
  }
}

// ---------------------------------------------------------------------------
// RPC dispatch
// ---------------------------------------------------------------------------

///|
async fn handle_bots_rpc(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  match request.method {
    @contracts.METHOD_BOT_LIST => handle_bot_list(state, sink, request, client_request_id)
    @contracts.METHOD_BOT_GET => handle_bot_get(state, sink, request, client_request_id)
    @contracts.METHOD_BOT_CREATE =>
      handle_bot_create(state, sink, request, client_request_id)
    @contracts.METHOD_BOT_UPDATE =>
      handle_bot_update(state, sink, request, client_request_id)
    @contracts.METHOD_BOT_ARCHIVE =>
      handle_bot_archive(state, sink, request, client_request_id)
    @contracts.METHOD_BOT_AGENT_LIST =>
      handle_bot_agent_list(state, sink, request, client_request_id)
    @contracts.METHOD_BOT_AGENT_CREATE =>
      handle_bot_agent_create(state, sink, request, client_request_id)
    @contracts.METHOD_BOT_AGENT_SUSPEND =>
      handle_bot_agent_lifecycle(
        state,
        sink,
        request,
        client_request_id,
        suspend=true,
      )
    @contracts.METHOD_BOT_AGENT_RETIRE =>
      handle_bot_agent_lifecycle(
        state,
        sink,
        request,
        client_request_id,
        suspend=false,
      )
    @contracts.METHOD_CHAT_LIST =>
      handle_chat_list(state, sink, request, client_request_id)
    @contracts.METHOD_CHAT_GET =>
      handle_chat_get(state, sink, request, client_request_id)
    @contracts.METHOD_CHAT_CREATE =>
      handle_chat_create(state, sink, request, client_request_id)
    @contracts.METHOD_CHAT_AGENT_SESSION_START =>
      handle_chat_agent_session_start(state, sink, request, client_request_id)
    @contracts.METHOD_CHAT_AGENT_SESSION_END =>
      handle_chat_agent_session_end(state, sink, request, client_request_id)
    @contracts.METHOD_CHAT_SEND =>
      handle_chat_send(state, sink, request, client_request_id)
    @contracts.METHOD_CHAT_READ =>
      handle_chat_read(state, sink, request, client_request_id)
    @contracts.METHOD_CHAT_STOP =>
      handle_chat_stop(state, sink, request, client_request_id)
    @contracts.METHOD_CHAT_MESSAGES =>
      handle_chat_messages(state, sink, request, client_request_id)
    _ =>
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.method_not_found_error(request.method),
      )
  }
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

///|
async fn bots_param_error(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
  message : String,
) -> Unit {
  send_machine_error(
    state,
    sink,
    request,
    client_request_id,
    @contracts.bots_error(@contracts.BOTS_ERR_INVALID, message),
  )
}

///|
async fn bots_domain_error(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
  message : String,
) -> Unit {
  send_machine_error(
    state,
    sink,
    request,
    client_request_id,
    @contracts.bots_error_from_message(message),
  )
}

///|
fn bots_last_seq_or_zero(state : HostState) -> Int64 {
  match state.store.last_seq() {
    Ok(value) => value
    Err(_) => 0L
  }
}

///|
/// Project assistant-visible turn text into the canonical Chat transcript.
/// Caller holds `state.mutex`; only ACP `agent_message_chunk` text reaches it.
fn bots_record_assistant_message_locked(
  state : HostState,
  runtime_session_id : String,
  text : String,
  timestamp : String,
) -> Unit {
  let sessions = match state.store.list_all_bot_agent_sessions() {
    Ok(value) => value
    Err(message) => {
      println("monexus-host: cannot list Chat AgentSessions: " + message)
      return
    }
  }
  let mut target : @contracts.AgentSession? = None
  for session in sessions {
    if session.runtime_session_id == runtime_session_id {
      target = Some(session)
    }
  }
  match target {
    Some(session) => {
      let message = @contracts.ChatMessage::new(
        id=bots_new_message_id(@async.now()),
        chat_id=session.chat_id,
        role=@contracts.CHAT_MESSAGE_ROLE_ASSISTANT,
        body_ref="",
        body=@contracts.chat_message_body_bounded(text),
        digest=@contracts.chat_message_digest(text, ""),
        agent_session_id=session.id,
        created_at=timestamp,
      )
      let before = bots_last_seq_or_zero(state)
      match state.store.append_chat_message(message, timestamp) {
        Ok(_) => state.sync_bots_events_after(before)
        Err(message) =>
          println("monexus-host: cannot append assistant Chat message: " + message)
      }
    }
    None => ()
  }
}

///|
fn bots_new_session_id(now : Int64) -> String {
  @contracts.new_agent_session_id(now)
}

///|
fn bots_new_message_id(now : Int64) -> String {
  @contracts.new_id("msg", now)
}

///|
fn bots_active_session_of(
  sessions : Array[@contracts.AgentSession],
) -> @contracts.AgentSession? {
  let mut found : @contracts.AgentSession? = None
  for session in sessions {
    if @bots.agent_session_is_nonterminal(session.state) {
      found = Some(session)
    }
  }
  found
}

///|
fn bots_latest_session_of(
  sessions : Array[@contracts.AgentSession],
) -> @contracts.AgentSession? {
  if sessions.length() == 0 {
    return None
  }
  Some(sessions[sessions.length() - 1])
}

///|
fn HostState::chat_detail_locked(
  self : HostState,
  chat : @contracts.ChatRecord,
) -> Result[@contracts.ChatDetail, String] {
  let participants = match self.store.list_chat_participants(chat.id) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let sessions = match self.store.list_chat_agent_sessions(chat.id) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  let active = bots_active_session_of(sessions)
  let agent = match active {
    Some(session) =>
      match self.store.get_agent(session.agent_id) {
        Ok(value) => value
        Err(message) => return Err(message)
      }
    None => None
  }
  Ok(
    @contracts.ChatDetail::new(
      chat~,
      participants~,
      active_agent_session=active,
      agent~,
    ),
  )
}

// ---------------------------------------------------------------------------
// Bot RPC
// ---------------------------------------------------------------------------

///|
async fn handle_bot_list(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  state.mutex.acquire()
  let result = state.store.list_bots()
  state.mutex.release()
  match result {
    Ok(bots) =>
      send_machine_result(
        state,
        sink,
        request,
        client_request_id,
        @contracts.bots_list_result(bots),
      )
    Err(message) => bots_domain_error(state, sink, request, client_request_id, message)
  }
}

///|
async fn handle_bot_get(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let bot_id = match @contracts.bot_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      bots_param_error(state, sink, request, client_request_id, message)
      return
    }
  }
  state.mutex.acquire()
  let result = state.store.get_bot(bot_id)
  state.mutex.release()
  match result {
    Ok(Some(bot)) =>
      send_machine_result(
        state,
        sink,
        request,
        client_request_id,
        @contracts.bot_result(bot),
      )
    Ok(None) =>
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.bots_error(@contracts.BOTS_ERR_NOT_FOUND, "Bot not found: " + bot_id),
      )
    Err(message) => bots_domain_error(state, sink, request, client_request_id, message)
  }
}

///|
async fn handle_bot_create(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let bot = match @contracts.bot_record_param(request.params) {
    Ok(value) => value
    Err(message) => {
      bots_param_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let actor = @contracts.bot_actor_param(request.params)
  let source = @contracts.bot_source_param(request.params)
  let now = @contracts.format_rfc3339(@async.now())
  state.mutex.acquire()
  let before = match state.store.last_seq() {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let result = state.store.create_bot(bot, actor, source, now)
  match result {
    Ok(record) => {
      state.sync_bots_events_after(before)
      state.mutex.release()
      send_machine_result(
        state,
        sink,
        request,
        client_request_id,
        @contracts.bot_result(record),
      )
    }
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
    }
  }
}

///|
async fn handle_bot_update(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let bot = match @contracts.bot_record_param(request.params) {
    Ok(value) => value
    Err(message) => {
      bots_param_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let changed = @contracts.bot_changed_fields_param(request.params)
  let version = @contracts.bot_version_param(request.params)
  let actor = @contracts.bot_actor_param(request.params)
  let now = @contracts.format_rfc3339(@async.now())
  state.mutex.acquire()
  let before = match state.store.last_seq() {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let result = state.store.update_bot(bot, changed, version, now, actor)
  match result {
    Ok(record) => {
      state.sync_bots_events_after(before)
      state.mutex.release()
      send_machine_result(
        state,
        sink,
        request,
        client_request_id,
        @contracts.bot_result(record),
      )
    }
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
    }
  }
}

///|
async fn handle_bot_archive(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let bot_id = match @contracts.bot_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      bots_param_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let reason = @contracts.bot_reason_param(request.params)
  let actor = @contracts.bot_actor_param(request.params)
  let now = @contracts.format_rfc3339(@async.now())
  state.mutex.acquire()
  let before = match state.store.last_seq() {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let result = state.store.archive_bot(bot_id, reason, now, actor)
  match result {
    Ok(record) => {
      state.sync_bots_events_after(before)
      state.mutex.release()
      send_machine_result(
        state,
        sink,
        request,
        client_request_id,
        @contracts.bot_result(record),
      )
    }
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
    }
  }
}

///|
async fn handle_bot_agent_list(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let bot_id = match @contracts.bot_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      bots_param_error(state, sink, request, client_request_id, message)
      return
    }
  }
  state.mutex.acquire()
  let exists = match state.store.get_bot(bot_id) {
    Ok(Some(_)) => true
    Ok(None) => {
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.bots_error(@contracts.BOTS_ERR_NOT_FOUND, "Bot not found: " + bot_id),
      )
      return
    }
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let result = state.store.list_agents(bot_id)
  state.mutex.release()
  if exists {
    match result {
      Ok(agents) =>
        send_machine_result(
          state,
          sink,
          request,
          client_request_id,
          @contracts.agents_list_result(agents),
        )
      Err(message) => bots_domain_error(state, sink, request, client_request_id, message)
    }
  }
}

///|
async fn handle_bot_agent_create(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let bot_id = match @contracts.bot_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      bots_param_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let agent = match @contracts.agent_record_param(request.params) {
    Ok(value) => value
    Err(message) => {
      bots_param_error(state, sink, request, client_request_id, message)
      return
    }
  }
  if agent.bot_id != "" && agent.bot_id != bot_id {
    bots_param_error(
      state,
      sink,
      request,
      client_request_id,
      "Agent bot_id does not match the route Bot",
    )
    return
  }
  let decision_id = @contracts.bot_decision_id_param(request.params)
  let source = @contracts.bot_source_param(request.params)
  let actor = @contracts.bot_actor_param(request.params)
  let now = @contracts.format_rfc3339(@async.now())
  let record = { ..agent, bot_id, }
  state.mutex.acquire()
  let before = match state.store.last_seq() {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let result = state.store.create_agent(
    record,
    decision_id,
    actor,
    source,
    now,
  )
  match result {
    Ok(created) => {
      state.sync_bots_events_after(before)
      state.mutex.release()
      send_machine_result(
        state,
        sink,
        request,
        client_request_id,
        @contracts.agent_result(created),
      )
    }
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
    }
  }
}

///|
async fn handle_bot_agent_lifecycle(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
  suspend~ : Bool,
) -> Unit {
  let agent_id = match @contracts.bot_agent_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      bots_param_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let reason = @contracts.bot_reason_param(request.params)
  let actor = @contracts.bot_actor_param(request.params)
  let now = @contracts.format_rfc3339(@async.now())
  state.mutex.acquire()
  let before = match state.store.last_seq() {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let result = if suspend {
    state.store.suspend_agent(agent_id, reason, now, actor)
  } else {
    state.store.retire_agent(agent_id, reason, now, actor)
  }
  match result {
    Ok(record) => {
      state.sync_bots_events_after(before)
      state.mutex.release()
      send_machine_result(
        state,
        sink,
        request,
        client_request_id,
        @contracts.agent_result(record),
      )
    }
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
    }
  }
}

// ---------------------------------------------------------------------------
// Chat RPC
// ---------------------------------------------------------------------------

///|
async fn handle_chat_list(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let project_id = @contracts.chat_project_param(request.params)
  let bot_filter = @contracts.chat_filter_by_bot(request.params)
  state.mutex.acquire()
  let chats = match state.store.list_chats(project_id) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let details : Array[@contracts.ChatDetail] = []
  for chat in chats {
    let include = if bot_filter == "" {
      true
    } else {
      match state.store.get_chat_participant(chat.id, bot_filter) {
        Ok(Some(participant)) =>
          participant.state == @contracts.PARTICIPANT_STATE_ACTIVE
        _ => false
      }
    }
    if include {
      match state.chat_detail_locked(chat) {
        Ok(detail) => details.push(detail)
        Err(message) => {
          state.mutex.release()
          bots_domain_error(state, sink, request, client_request_id, message)
          return
        }
      }
    }
  }
  state.mutex.release()
  send_machine_result(
    state,
    sink,
    request,
    client_request_id,
    @contracts.chats_list_result(details),
  )
}

///|
async fn handle_chat_get(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let chat_id = match @contracts.chat_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      bots_param_error(state, sink, request, client_request_id, message)
      return
    }
  }
  state.mutex.acquire()
  let chat = match state.store.get_chat(chat_id) {
    Ok(Some(value)) => value
    Ok(None) => {
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.bots_error(@contracts.BOTS_ERR_NOT_FOUND, "Chat not found: " + chat_id),
      )
      return
    }
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let detail = state.chat_detail_locked(chat)
  state.mutex.release()
  match detail {
    Ok(value) =>
      send_machine_result(
        state,
        sink,
        request,
        client_request_id,
        @contracts.chat_result(value),
      )
    Err(message) => bots_domain_error(state, sink, request, client_request_id, message)
  }
}

///|
async fn handle_chat_create(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let chat = match @contracts.chat_record_param(request.params) {
    Ok(value) => value
    Err(message) => {
      bots_param_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let bot_id = match @contracts.bot_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      bots_param_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let actor = @contracts.bot_actor_param(request.params)
  let source = @contracts.bot_source_param(request.params)
  let now = @contracts.format_rfc3339(@async.now())
  state.mutex.acquire()
  let before = match state.store.last_seq() {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let result = state.store.create_chat(chat, [bot_id], actor, source, now)
  match result {
    Ok(record) => {
      state.sync_bots_events_after(before)
      let detail = state.chat_detail_locked(record)
      state.mutex.release()
      match detail {
        Ok(value) =>
          send_machine_result(
            state,
            sink,
            request,
            client_request_id,
            @contracts.chat_result(value),
          )
        Err(message) => bots_domain_error(state, sink, request, client_request_id, message)
      }
    }
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
    }
  }
}

///|
fn bots_permission_snapshot(
  bot : @contracts.BotRecord,
  agent : @contracts.AgentRecord,
  project_id : String,
  memberships : Array[@contracts.ProjectMembership],
) -> Result[Array[String], String] {
  let mut membership_active = false
  let mut project_policy : Array[String] = []
  if project_id != "" {
    for membership in memberships {
      if membership.bot_id == bot.id &&
        membership.state == @contracts.MEMBERSHIP_STATE_ACTIVE {
        membership_active = true
        project_policy = membership.access
      }
    }
  }
  let tool_allowlist = if agent.runtime_binding.tools.length() > 0 {
    agent.runtime_binding.tools
  } else {
    agent.permission_scope
  }
  let skill_allowlist = if agent.runtime_binding.skills.length() > 0 {
    agent.runtime_binding.skills
  } else {
    agent.permission_scope
  }
  @bots.effective_permission(
    @bots.PermissionRequest::new(
      org_policy=bot.permission_ceiling,
      bot_ceiling=bot.permission_ceiling,
      project_id~,
      project_policy~,
      project_membership_active=membership_active,
      agent_scope=agent.permission_scope,
      task_scope=agent.permission_scope,
      session_scope=agent.permission_scope,
      tool_allowlist~,
      skill_allowlist~,
    ),
  )
}

///|
async fn handle_chat_agent_session_start(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let chat_id = match @contracts.chat_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      bots_param_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let agent_id = match @contracts.chat_filter_runtime(request.params) {
    value if value != "" => value
    _ => {
      bots_param_error(state, sink, request, client_request_id, "missing agent_id")
      return
    }
  }
  let workspace_id = @contracts.chat_scope_param(request.params)
  if workspace_id == "" {
    bots_param_error(state, sink, request, client_request_id, "missing workspace_id")
    return
  }
  let requested_root = @contracts.chat_workspace_root_param(request.params)
  let now_ms = @async.now()
  let now = @contracts.format_rfc3339(now_ms)
  state.mutex.acquire()
  let chat = match state.store.get_chat(chat_id) {
    Ok(Some(value)) => value
    Ok(None) => {
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.bots_error(@contracts.BOTS_ERR_NOT_FOUND, "Chat not found: " + chat_id),
      )
      return
    }
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let agent = match state.store.get_agent(agent_id) {
    Ok(Some(value)) => value
    Ok(None) => {
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.bots_error(@contracts.BOTS_ERR_NOT_FOUND, "Agent not found: " + agent_id),
      )
      return
    }
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let bot = match state.store.get_bot(agent.bot_id) {
    Ok(Some(value)) => value
    Ok(None) => {
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.bots_error(@contracts.BOTS_ERR_NOT_FOUND, "Bot not found: " + agent.bot_id),
      )
      return
    }
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
      return
    }
  }
  if bot.state != @contracts.BOT_STATE_ACTIVE {
    state.mutex.release()
    send_machine_error(
      state,
      sink,
      request,
      client_request_id,
      @contracts.bots_error(@contracts.BOTS_ERR_CONFLICT, "Bot is not active: " + bot.state),
    )
    return
  }
  if chat.state != @contracts.CHAT_STATE_ACTIVE {
    state.mutex.release()
    send_machine_error(
      state,
      sink,
      request,
      client_request_id,
      @contracts.bots_error(@contracts.BOTS_ERR_CONFLICT, "Chat is archived"),
    )
    return
  }
  let workspace = match state.store.get_workspace(workspace_id) {
    Ok(Some(value)) => value
    Ok(None) => {
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.bots_error(@contracts.BOTS_ERR_NOT_FOUND, "Workspace not found: " + workspace_id),
      )
      return
    }
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
      return
    }
  }
  if workspace.state != @contracts.WORKSPACE_STATE_AVAILABLE ||
    workspace.root == "" {
    state.mutex.release()
    send_machine_error(
      state,
      sink,
      request,
      client_request_id,
      @contracts.bots_error(@contracts.BOTS_ERR_CONFLICT, "Workspace is not available"),
    )
    return
  }
  if requested_root != "" && requested_root != workspace.root {
    state.mutex.release()
    send_machine_error(
      state,
      sink,
      request,
      client_request_id,
      @contracts.bots_error(
        @contracts.BOTS_ERR_INVALID,
        "workspace_root does not match the Workspace record",
      ),
    )
    return
  }
  let memberships = if chat.project_id == "" {
    []
  } else {
    match state.store.list_project_memberships(chat.project_id) {
      Ok(value) => value
      Err(message) => {
        state.mutex.release()
        bots_domain_error(state, sink, request, client_request_id, message)
        return
      }
    }
  }
  let permissions = match
    bots_permission_snapshot(bot, agent, chat.project_id, memberships) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.bots_error(@contracts.BOTS_ERR_UNAUTHORIZED, message),
      )
      return
    }
  }
  let permission_hash = @contracts.bots_permission_set_hash(permissions)
  let started_at = @contracts.format_rfc3339(now_ms)
  let session = @contracts.AgentSession::new(
    id=bots_new_session_id(now_ms),
    chat_id~,
    agent_id~,
    permission_snapshot_hash=permission_hash,
    started_at~,
    project_id=chat.project_id,
    workspace_id~,
    workspace_root=workspace.root,
  )
  let before = match state.store.last_seq() {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let starting = match state.store.start_chat_agent_session(session, "owner", now) {
    Ok(value) => {
      state.sync_bots_events_after(before)
      value
    }
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
      return
    }
  }
  state.mutex.release()
  let mode = if agent.runtime_binding.launch_kind == @contracts.RUNTIME_LAUNCH_ACP {
    @contracts.AGENT_MODE_ACP
  } else {
    @contracts.AGENT_MODE_STDOUT
  }
  let start_params = @contracts.agent_start_params(
    "chat-start-" + starting.id,
    agent.id,
    mode,
    agent.runtime_binding.command,
    agent.runtime_binding.args,
    workspace.root,
    workspace.id,
    "",
    "",
    0,
    Map([]),
  )
  let runtime = match
    bot_runtime_start(
      state,
      starting.id,
      start_params,
      "chat-start-" + starting.id,
    ) {
    Ok(value) => value
    Err(message) => {
      let failed_at = @contracts.format_rfc3339(@async.now())
      state.mutex.acquire()
      let failed_before = bots_last_seq_or_zero(state)
      let _ = state.store.end_chat_agent_session(
        starting.id,
        @contracts.AGENT_SESSION_STATE_FAILED,
        @contracts.AGENT_SESSION_END_REASON_ERROR,
        "",
        "",
        failed_at,
      )
      state.sync_bots_events_after(failed_before)
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.bots_error(
          @contracts.BOTS_ERR_INTERNAL,
          "runtime start failed: " + message,
        ),
      )
      return
    }
  }
  let updated_at = @contracts.format_rfc3339(@async.now())
  state.mutex.acquire()
  let active_before = bots_last_seq_or_zero(state)
  let active = state.store.update_chat_agent_session(
    starting.id,
    @contracts.AGENT_SESSION_STATE_ACTIVE,
    runtime.id,
    "",
    0,
    0,
    updated_at,
  )
  state.sync_bots_events_after(active_before)
  state.mutex.release()
  match active {
    Ok(record) =>
      send_machine_result(
        state,
        sink,
        request,
        client_request_id,
        @contracts.chat_agent_session_result(record),
      )
    Err(message) => {
      match bot_runtime_stop(state, runtime.id) {
        Ok(_) => ()
        Err(_) => ()
      }
      let failed_at = @contracts.format_rfc3339(@async.now())
      state.mutex.acquire()
      let failed_before = bots_last_seq_or_zero(state)
      let _ = state.store.end_chat_agent_session(
        starting.id,
        @contracts.AGENT_SESSION_STATE_FAILED,
        @contracts.AGENT_SESSION_END_REASON_ERROR,
        "",
        "",
        failed_at,
      )
      state.sync_bots_events_after(failed_before)
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
    }
  }
}

///|
async fn handle_chat_agent_session_end(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let session_id = match @contracts.chat_agent_session_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      bots_param_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let end_reason = @contracts.chat_end_reason_param(request.params)
  match stop_chat_session(state, session_id, end_reason) {
    Ok((session, _)) =>
      send_machine_result(
        state,
        sink,
        request,
        client_request_id,
        @contracts.chat_agent_session_result(session),
      )
    Err(message) => bots_domain_error(state, sink, request, client_request_id, message)
  }
}

///|
async fn handle_chat_send(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let chat_id = match @contracts.chat_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      bots_param_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let text = match @contracts.chat_text_param(request.params) {
    Ok(value) => value
    Err(message) => {
      bots_param_error(state, sink, request, client_request_id, message)
      return
    }
  }
  if text.length() > @contracts.CHAT_MESSAGE_BODY_CAP {
    bots_param_error(
      state,
      sink,
      request,
      client_request_id,
      "text exceeds the Chat message cap",
    )
    return
  }
  let actor = @contracts.bot_actor_param(request.params)
  let now_ms = @async.now()
  let now = @contracts.format_rfc3339(now_ms)
  state.mutex.acquire()
  let chat = match state.store.get_chat(chat_id) {
    Ok(Some(value)) => value
    Ok(None) => {
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.bots_error(@contracts.BOTS_ERR_NOT_FOUND, "Chat not found: " + chat_id),
      )
      return
    }
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
      return
    }
  }
  if chat.state != @contracts.CHAT_STATE_ACTIVE {
    state.mutex.release()
    send_machine_error(
      state,
      sink,
      request,
      client_request_id,
      @contracts.bots_error(@contracts.BOTS_ERR_CONFLICT, "Chat is archived"),
    )
    return
  }
  let sessions = match state.store.list_chat_agent_sessions(chat.id) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let session = match bots_active_session_of(sessions) {
    Some(value) => value
    None => {
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.bots_error(
          @contracts.BOTS_ERR_CONFLICT,
          "Chat has no active AgentSession",
        ),
      )
      return
    }
  }
  if session.state != @contracts.AGENT_SESSION_STATE_ACTIVE {
    state.mutex.release()
    send_machine_error(
      state,
      sink,
      request,
      client_request_id,
      @contracts.bots_error(
        @contracts.BOTS_ERR_CONFLICT,
        "AgentSession is not active: " + session.state,
      ),
    )
    return
  }
  let agent = match state.store.get_agent(session.agent_id) {
    Ok(Some(value)) => value
    Ok(None) => {
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.bots_error(
          @contracts.BOTS_ERR_NOT_FOUND,
          "Agent not found: " + session.agent_id,
        ),
      )
      return
    }
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let bot = match state.store.get_bot(agent.bot_id) {
    Ok(Some(value)) => value
    Ok(None) => {
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.bots_error(
          @contracts.BOTS_ERR_NOT_FOUND,
          "Bot not found: " + agent.bot_id,
        ),
      )
      return
    }
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
      return
    }
  }
  if bot.state != @contracts.BOT_STATE_ACTIVE {
    state.mutex.release()
    send_machine_error(
      state,
      sink,
      request,
      client_request_id,
      @contracts.bots_error(
        @contracts.BOTS_ERR_CONFLICT,
        "Bot is not active: " + bot.state,
      ),
    )
    return
  }
  if session.runtime_session_id == "" ||
    !state.agent_sessions.contains(session.runtime_session_id) {
    state.mutex.release()
    send_machine_error(
      state,
      sink,
      request,
      client_request_id,
      @contracts.bots_error(
        @contracts.BOTS_ERR_CONFLICT,
        "AgentSession runtime is not running; start the session again",
      ),
    )
    return
  }
  let message = @contracts.ChatMessage::new(
    id=bots_new_message_id(now_ms),
    chat_id~,
    role=@contracts.CHAT_MESSAGE_ROLE_USER,
    body_ref="",
    body=text,
    digest=@contracts.chat_message_digest(text, ""),
    actor~,
    created_at=now,
  )
  let before = bots_last_seq_or_zero(state)
  let appended = state.store.append_chat_message(message, now)
  match appended {
    Ok(record) => {
      state.sync_bots_events_after(before)
      state.mutex.release()
      match bot_runtime_send(state, session.runtime_session_id, text) {
        Ok(_) =>
          send_machine_result(
            state,
            sink,
            request,
            client_request_id,
            @contracts.chat_send_result(record, session),
          )
        Err(error) =>
          send_machine_error(
            state,
            sink,
            request,
            client_request_id,
            @contracts.bots_error(@contracts.BOTS_ERR_INTERNAL, error),
          )
      }
    }
    Err(error) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, error)
    }
  }
}

///|
async fn handle_chat_read(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let chat_id = match @contracts.chat_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      bots_param_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let requested = @contracts.chat_cursor_param(request.params)
  state.mutex.acquire()
  let chat = match state.store.get_chat(chat_id) {
    Ok(Some(value)) => value
    Ok(None) => {
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.bots_error(@contracts.BOTS_ERR_NOT_FOUND, "Chat not found: " + chat_id),
      )
      return
    }
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let sessions = match state.store.list_chat_agent_sessions(chat.id) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let session = match bots_active_session_of(sessions) {
    Some(value) => Some(value)
    None => bots_latest_session_of(sessions)
  }
  let current = match session {
    Some(value) => value
    None => {
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.bots_error(
          @contracts.BOTS_ERR_NOT_FOUND,
          "Chat has no AgentSession",
        ),
      )
      return
    }
  }
  let runtime_id = current.runtime_session_id
  let transcript : AgentTranscript? = if runtime_id == "" {
    None
  } else {
    match state.agent_sessions.get(runtime_id) {
      Some(runtime) => Some(runtime.transcript.val)
      None =>
        match state.agent_transcripts.get(runtime_id) {
          Some(value) => Some(value)
          None => None
        }
    }
  }
  let mut cursor = requested
  let mut text = ""
  match transcript {
    Some(value) => {
      let start = value.base
      let end = start + value.text.length().to_int64()
      let from = if requested < start {
        start
      } else if requested > end {
        end
      } else {
        requested
      }
      if from < end {
        let offset = (from - start).to_int()
        text = value.text.substring(start=offset)
      }
      // Match agent.read: the returned cursor is the end of the runtime
      // transcript, so a poll loop advances even when it receives no text.
      cursor = end
    }
    None => ()
  }
  let pending = if runtime_id == "" {
    ""
  } else {
    match
      state.store.list_decisions(
        @contracts.DECISION_STATUS_PENDING,
        runtime_id,
      ) {
      Ok(records) => if records.length() > 0 { records[0].id } else { "" }
      Err(_) => ""
    }
  }
  let session_state = match state.agent_sessions.get(runtime_id) {
    Some(runtime) =>
      if runtime.pending.size() > 0 {
        @contracts.AGENT_SESSION_STATE_WAITING
      } else {
        current.state
      }
    None => current.state
  }
  let projected = { ..current, state: session_state, }
  state.mutex.release()
  send_machine_result(
    state,
    sink,
    request,
    client_request_id,
    @contracts.chat_read_result(projected, cursor, text, pending),
  )
}

///|
async fn handle_chat_stop(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let chat_id = match @contracts.chat_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      bots_param_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let session_id = @contracts.chat_session_id_param(request.params)
  let end_reason = @contracts.chat_end_reason_param(request.params)
  state.mutex.acquire()
  let chat = match state.store.get_chat(chat_id) {
    Ok(Some(value)) => value
    Ok(None) => {
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.bots_error(@contracts.BOTS_ERR_NOT_FOUND, "Chat not found: " + chat_id),
      )
      return
    }
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let sessions = match state.store.list_chat_agent_sessions(chat.id) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let selected = if session_id != "" {
    let mut found : @contracts.AgentSession? = None
    for candidate in sessions {
      if candidate.id == session_id {
        found = Some(candidate)
      }
    }
    found
  } else {
    match bots_active_session_of(sessions) {
      Some(value) => Some(value)
      None => bots_latest_session_of(sessions)
    }
  }
  let target = match selected {
    Some(value) => value
    None => {
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.bots_error(
          @contracts.BOTS_ERR_NOT_FOUND,
          "Chat has no AgentSession",
        ),
      )
      return
    }
  }
  state.mutex.release()
  match stop_existing_chat_session(state, target, end_reason) {
    Ok((session, stopped)) =>
      send_machine_result(
        state,
        sink,
        request,
        client_request_id,
        @contracts.chat_stop_result(session, stopped),
      )
    Err(message) => bots_domain_error(state, sink, request, client_request_id, message)
  }
}

///|
async fn handle_chat_messages(
  state : HostState,
  sink : Sink,
  request : @contracts.RpcRequest,
  client_request_id : String,
) -> Unit {
  let chat_id = match @contracts.chat_id_param(request.params) {
    Ok(value) => value
    Err(message) => {
      bots_param_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let after = @contracts.chat_after_param(request.params)
  let limit = @contracts.chat_limit_param(request.params)
  state.mutex.acquire()
  let exists = match state.store.get_chat(chat_id) {
    Ok(Some(_)) => true
    Ok(None) => {
      state.mutex.release()
      send_machine_error(
        state,
        sink,
        request,
        client_request_id,
        @contracts.bots_error(@contracts.BOTS_ERR_NOT_FOUND, "Chat not found: " + chat_id),
      )
      return
    }
    Err(message) => {
      state.mutex.release()
      bots_domain_error(state, sink, request, client_request_id, message)
      return
    }
  }
  let result = state.store.list_chat_messages(chat_id, after, limit)
  state.mutex.release()
  if exists {
    match result {
      Ok(messages) =>
        send_machine_result(
          state,
          sink,
          request,
          client_request_id,
          @contracts.chat_messages_result(messages),
        )
      Err(message) => bots_domain_error(state, sink, request, client_request_id, message)
    }
  }
}

// ---------------------------------------------------------------------------
// Legacy runtime bridge
// ---------------------------------------------------------------------------

///|
async fn bot_runtime_start(
  state : HostState,
  session_id : String,
  params : Map[String, @json.Json],
  client_request_id : String,
) -> Result[@contracts.AgentSessionRecord, String] {
  let queue : @aqueue.Queue[String] = @aqueue.Queue(kind=Unbounded)
  let sink : Sink = { queue, subscribed: Ref(false), closed: Ref(false), }
  let request : @contracts.RpcRequest = {
    id: "chat-start-" + session_id,
    method: @contracts.METHOD_AGENT_START,
    params,
  }
  handle_agent_start(state, sink, request, client_request_id)
  let response = @async.with_timeout_opt(
    @agent.agent_timeout_ms() + 10_000,
    async fn() { queue.get() },
  )
  let text = match response {
    Some(value) => value
    None => return Err("agent.start did not respond")
  }
  let parsed = @json.parse(text) catch {
    _ => return Err("agent.start returned malformed JSON")
  }
  let response = match @contracts.parse_response(parsed) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  match response.error {
    Some(error) => return Err(error.message)
    None => ()
  }
  let result = match response.result {
    Some(value) => value
    None => return Err("agent.start returned no result")
  }
  match @contracts.agent_session_from_result(result) {
    Ok(record) => Ok(record)
    Err(message) => Err(message)
  }
}

///|
async fn bot_runtime_send(
  state : HostState,
  runtime_session_id : String,
  text : String,
) -> Result[Unit, String] {
  let queue : @aqueue.Queue[String] = @aqueue.Queue(kind=Unbounded)
  let sink : Sink = { queue, subscribed: Ref(false), closed: Ref(false), }
  let request_id = "chat-send-" + runtime_session_id + "-" +
    @async.now().to_string()
  let params = @contracts.agent_send_params(request_id, runtime_session_id, text)
  let request : @contracts.RpcRequest = {
    id: request_id,
    method: @contracts.METHOD_AGENT_SEND,
    params,
  }
  handle_agent_send(state, sink, request, request_id)
  let response = @async.with_timeout_opt(10_000, async fn() { queue.get() })
  let text = match response {
    Some(value) => value
    None => return Err("agent.send did not respond")
  }
  let parsed = @json.parse(text) catch {
    _ => return Err("agent.send returned malformed JSON")
  }
  let parsed = match @contracts.parse_response(parsed) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  match parsed.error {
    Some(error) => Err(error.message)
    None => Ok(())
  }
}

///|
async fn bot_runtime_stop(
  state : HostState,
  runtime_session_id : String,
) -> Result[Unit, String] {
  let queue : @aqueue.Queue[String] = @aqueue.Queue(kind=Unbounded)
  let sink : Sink = { queue, subscribed: Ref(false), closed: Ref(false), }
  let request_id = "chat-stop-" + runtime_session_id + "-" +
    @async.now().to_string()
  let params = @contracts.agent_stop_params(request_id, runtime_session_id)
  let request : @contracts.RpcRequest = {
    id: request_id,
    method: @contracts.METHOD_AGENT_STOP,
    params,
  }
  handle_agent_stop(state, sink, request, request_id)
  let response = @async.with_timeout_opt(15_000, async fn() { queue.get() })
  let text = match response {
    Some(value) => value
    None => return Err("agent.stop did not respond")
  }
  let parsed = @json.parse(text) catch {
    _ => return Err("agent.stop returned malformed JSON")
  }
  let parsed = match @contracts.parse_response(parsed) {
    Ok(value) => value
    Err(message) => return Err(message)
  }
  match parsed.error {
    Some(error) => Err(error.message)
    None => Ok(())
  }
}

///|
async fn stop_existing_chat_session(
  state : HostState,
  target : @contracts.AgentSession,
  end_reason : String,
) -> Result[(@contracts.AgentSession, Bool), String] {
  if @bots.agent_session_is_terminal(target.state) {
    return Ok((target, false))
  }
  let runtime_id = target.runtime_session_id
  state.mutex.acquire()
  let runtime_present = runtime_id != "" &&
    state.agent_sessions.contains(runtime_id)
  state.mutex.release()
  let mut runtime_error = ""
  if runtime_present {
    match bot_runtime_stop(state, runtime_id) {
      Ok(_) => ()
      Err(message) => runtime_error = message
    }
  }
  let now = @contracts.format_rfc3339(@async.now())
  let final_state = if target.state == @contracts.AGENT_SESSION_STATE_STARTING ||
    runtime_error != "" {
    @contracts.AGENT_SESSION_STATE_FAILED
  } else {
    @contracts.AGENT_SESSION_STATE_ENDED
  }
  let reason = if runtime_error != "" {
    @contracts.AGENT_SESSION_END_REASON_ERROR
  } else {
    end_reason
  }
  state.mutex.acquire()
  let before = bots_last_seq_or_zero(state)
  let mut transition_error = ""
  if final_state == @contracts.AGENT_SESSION_STATE_ENDED &&
    target.state != @contracts.AGENT_SESSION_STATE_ENDING {
    match
      state.store.update_chat_agent_session(
        target.id,
        @contracts.AGENT_SESSION_STATE_ENDING,
        "",
        "",
        0,
        0,
        now,
      ) {
      Ok(_) => ()
      Err(message) => transition_error = message
    }
  }
  let ended = if transition_error != "" {
    Err(transition_error)
  } else {
    state.store.end_chat_agent_session(
      target.id,
      final_state,
      reason,
      "",
      "",
      now,
    )
  }
  state.sync_bots_events_after(before)
  state.mutex.release()
  match ended {
    Ok(record) => Ok((record, runtime_present && runtime_error == ""))
    Err(message) => Err(message)
  }
}

///|
async fn stop_chat_session(
  state : HostState,
  session_id : String,
  end_reason : String,
) -> Result[(@contracts.AgentSession, Bool), String] {
  state.mutex.acquire()
  let current = match state.store.get_bot_agent_session(session_id) {
    Ok(Some(value)) => value
    Ok(None) => {
      state.mutex.release()
      return Err("AgentSession not found: " + session_id)
    }
    Err(message) => {
      state.mutex.release()
      return Err(message)
    }
  }
  state.mutex.release()
  stop_existing_chat_session(state, current, end_reason)
}
