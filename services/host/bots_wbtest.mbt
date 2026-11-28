///|
/// ADR-0017 P0.3 whitebox tests: host-visible Bot/Chat RPC round-trips,
/// idempotency, canonical guards and the Chat execution bridge.

///|
fn bots_host_response(text : String) -> @contracts.RpcResponse raise {
  let json = @json.parse(text) catch {
    _ => fail("RPC response is not JSON: " + text)
  }
  match @contracts.parse_response(json) {
    Ok(value) => value
    Err(message) => fail("RPC response is malformed: " + message)
  }
}

///|
fn bots_host_result(text : String) -> @json.Json raise {
  let response = bots_host_response(text)
  match response.error {
    Some(error) => fail("RPC error: " + error.message)
    None => ()
  }
  match response.result {
    Some(value) => value
    None => fail("RPC response has no result")
  }
}

///|
fn bots_host_error(text : String) -> @contracts.RpcError raise {
  let response = bots_host_response(text)
  match response.error {
    Some(error) => error
    None => fail("RPC response has no error")
  }
}

///|
fn bots_host_bot() -> @contracts.BotRecord {
  @contracts.BotRecord::new(
    id=@contracts.new_bot_id(7_100L),
    org_id=@contracts.ORG_LOCAL,
    name="Host Builder",
    created_at="2026-11-27T04:00:00Z",
    persona_ref="persona/builder",
    instructions_ref="instructions/builder",
    memory_ref="bot/host/memory",
    home="/tmp/monexus-host-bot-home",
    permission_ceiling=["repo:read", "tool:shell"],
    create_policy=@contracts.BOT_CREATE_POLICY_AUTO,
    agent_count_cap=4,
    agent_concurrency_cap=2,
    software_allowlist=["mock-acp"],
  )
}

///|
fn bots_host_binding(args : Array[String]) -> @contracts.RuntimeBinding {
  @contracts.RuntimeBinding::new(
    software_id="mock-acp",
    adapter_id="acp",
    launch_kind=@contracts.RUNTIME_LAUNCH_ACP,
    command="node",
    args~,
    model_profile="test",
    hash="sha256:host-rpc-binding",
  )
}

///|
fn bots_host_agent(bot : @contracts.BotRecord) -> @contracts.AgentRecord {
  @contracts.AgentRecord::new(
    id=@contracts.new_agent_id(7_101L),
    org_id=bot.org_id,
    bot_id=bot.id,
    name="Host Worker",
    runtime_binding=bots_host_binding(["tests/agent/mock_acp_agent.mjs"]),
    created_at="2026-11-27T04:00:01Z",
    specialty="test",
    tags=["p0.3"],
    permission_scope=["repo:read"],
    state=@contracts.AGENT_LIFECYCLE_ACTIVE,
  )
}

///|
fn bots_host_chat(title : String) -> @contracts.ChatRecord {
  @contracts.ChatRecord::new(
    id=@contracts.new_chat_id(7_102L),
    org_id=@contracts.ORG_LOCAL,
    title~,
    created_at="2026-11-27T04:00:02Z",
  )
}

///|
fn bots_host_message(
  chat : @contracts.ChatRecord,
  session_id : String,
  role : String,
  body : String,
  now : String,
) -> @contracts.ChatMessage {
  @contracts.ChatMessage::new(
    id=@contracts.new_id("msg", 7_103L),
    chat_id=chat.id,
    role~,
    body_ref="",
    body~,
    digest=@contracts.chat_message_digest(body, ""),
    agent_session_id=session_id,
    created_at=now,
  )
}

///|
async fn bots_host_call(
  state : HostState,
  request : @contracts.RpcRequest,
) -> String raise {
  let sink = host_test_sink()
  handle_request(state, sink, request)
  sink.queue.get() catch { _ => fail("no RPC response") }
}

///|
async test "Bot and Chat RPC round-trip with idempotent create" {
  let state = host_test_state("/tmp/monexus-host-bots-rpc-test", false) catch {
    error => fail(error.to_string())
  }
  let bot = bots_host_bot()
  let create_request = @contracts.RpcRequest::new(
    "req_bot_create",
    @contracts.METHOD_BOT_CREATE,
    @contracts.bot_create_params("cid_bot_create", bot),
  )
  let first = bots_host_call(state, create_request) catch {
    error => fail(error.to_string())
  }
  let created = match
    @contracts.bot_from_result(bots_host_result(first)) {
    Ok(value) => value
    Err(message) => fail("bot.create result: " + message)
  }
  assert_eq(created.id, bot.id)
  // The existing response cache is the idempotency authority.
  let second = bots_host_call(state, create_request) catch {
    error => fail(error.to_string())
  }
  assert_eq(first, second)
  let bots = match
    state.store.list_bots() {
    Ok(value) => value
    Err(message) => fail(message)
  }
  assert_eq(bots.length(), 1)

  let get_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_bot_get",
      @contracts.METHOD_BOT_GET,
      @contracts.bot_get_params("cid_bot_get", bot.id),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let fetched = match
    @contracts.bot_from_result(bots_host_result(get_text)) {
    Ok(value) => value
    Err(message) => fail("bot.get result: " + message)
  }
  assert_eq(fetched.name, "Host Builder")

  let agent = bots_host_agent(created)
  let agent_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_agent_create",
      @contracts.METHOD_BOT_AGENT_CREATE,
      @contracts.bot_agent_create_params("cid_agent_create", bot.id, agent),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let created_agent = match
    @contracts.agent_from_result(bots_host_result(agent_text)) {
    Ok(value) => value
    Err(message) => fail("bot.agent.create result: " + message)
  }
  assert_eq(created_agent.bot_id, bot.id)
  let list_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_agent_list",
      @contracts.METHOD_BOT_AGENT_LIST,
      @contracts.bot_agent_list_params("cid_agent_list", bot.id),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let agents = match
    @contracts.agents_from_result(bots_host_result(list_text)) {
    Ok(value) => value
    Err(message) => fail("bot.agent.list result: " + message)
  }
  assert_eq(agents.length(), 1)
  assert_eq(agents[0].id, created_agent.id)

  let chat = bots_host_chat("Host RPC Chat")
  let chat_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_chat_create",
      @contracts.METHOD_CHAT_CREATE,
      @contracts.chat_create_params("cid_chat_create", chat, bot.id),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let detail = match
    @contracts.chat_from_result(bots_host_result(chat_text)) {
    Ok(value) => value
    Err(message) => fail("chat.create result: " + message)
  }
  assert_eq(detail.chat.id, chat.id)
  assert_eq(detail.participants.length(), 1)
  assert_eq(detail.participants[0].bot_id, bot.id)
  match detail.active_agent_session {
    Some(_) => fail("new Chat has an active AgentSession")
    None => ()
  }

  let get_chat_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_chat_get",
      @contracts.METHOD_CHAT_GET,
      @contracts.chat_get_params("cid_chat_get", chat.id),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let got_chat = match
    @contracts.chat_from_result(bots_host_result(get_chat_text)) {
    Ok(value) => value
    Err(message) => fail("chat.get result: " + message)
  }
  assert_eq(got_chat.chat.title, "Host RPC Chat")
  assert_eq(got_chat.participants[0].bot_id, bot.id)

  let list_chats_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_chat_list",
      @contracts.METHOD_CHAT_LIST,
      @contracts.chat_list_params("cid_chat_list", "", ""),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let chats = match
    @contracts.chats_from_result(bots_host_result(list_chats_text)) {
    Ok(value) => value
    Err(message) => fail("chat.list result: " + message)
  }
  assert_eq(chats.length(), 1)
  assert_eq(chats[0].chat.id, chat.id)

  let messages_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_chat_messages",
      @contracts.METHOD_CHAT_MESSAGES,
      @contracts.chat_messages_params("cid_chat_messages", chat.id),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let messages = match
    @contracts.chat_messages_from_result(bots_host_result(messages_text)) {
    Ok(value) => value
    Err(message) => fail("chat.messages result: " + message)
  }
  assert_eq(messages.length(), 0)

  let suspend_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_agent_suspend",
      @contracts.METHOD_BOT_AGENT_SUSPEND,
      @contracts.bot_agent_suspend_params(
        "cid_agent_suspend",
        created_agent.id,
        "maintenance",
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let suspended = match
    @contracts.agent_from_result(bots_host_result(suspend_text)) {
    Ok(value) => value
    Err(message) => fail("bot.agent.suspend result: " + message)
  }
  assert_eq(suspended.state, @contracts.AGENT_LIFECYCLE_SUSPENDED)

  let retire_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_agent_retire",
      @contracts.METHOD_BOT_AGENT_RETIRE,
      @contracts.bot_agent_retire_params(
        "cid_agent_retire",
        created_agent.id,
        "replaced",
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let retired = match
    @contracts.agent_from_result(bots_host_result(retire_text)) {
    Ok(value) => value
    Err(message) => fail("bot.agent.retire result: " + message)
  }
  assert_eq(retired.state, @contracts.AGENT_LIFECYCLE_RETIRED)

  let archive_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_bot_archive",
      @contracts.METHOD_BOT_ARCHIVE,
      @contracts.bot_archive_params("cid_bot_archive", bot.id, "done"),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let archived = match
    @contracts.bot_from_result(bots_host_result(archive_text)) {
    Ok(value) => value
    Err(message) => fail("bot.archive result: " + message)
  }
  assert_eq(archived.state, @contracts.BOT_STATE_ARCHIVED)
  let all_bots_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_bot_list",
      @contracts.METHOD_BOT_LIST,
      @contracts.bot_list_params("cid_bot_list"),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let all_bots = match
    @contracts.bots_from_result(bots_host_result(all_bots_text)) {
    Ok(value) => value
    Err(message) => fail("bot.list result: " + message)
  }
  assert_eq(all_bots.length(), 1)
  assert_eq(all_bots[0].state, @contracts.BOT_STATE_ARCHIVED)
}

///|
async fn bots_host_seed_project(
  state : HostState,
  project_id : String,
  now : String,
) -> Unit raise {
  let record = @contracts.ProjectRecord::new(
    id=project_id,
    name="Membership project",
    repo_url="",
    default_branch="main",
    verify=[],
    created_at=now,
  )
  state.mutex.acquire()
  let appended = state.append_project_event(
    @contracts.EVENT_PROJECT_CREATED,
    "project/" + project_id,
    record.to_json(),
    record,
  )
  state.mutex.release()
  match appended {
    Ok(_) => ()
    Err(message) => fail("append_project_event failed: " + message)
  }
}

///|
async fn bots_host_seed_bot(
  state : HostState,
  bot : @contracts.BotRecord,
  now : String,
) -> @contracts.BotRecord raise {
  state.mutex.acquire()
  let result = state.store.create_bot(bot, "owner", "test", now)
  state.mutex.release()
  match result {
    Ok(value) => value
    Err(message) => fail("create_bot failed: " + message)
  }
}

///|
async test "Project membership RPC lists active records and add is idempotent" {
  let state = host_test_state("/tmp/monexus-host-project-membership-test", false) catch {
    error => fail(error.to_string())
  }
  let now = "2026-11-27T04:30:00Z"
  let first_project = @contracts.new_project_id(7_200L)
  let second_project = @contracts.new_project_id(7_201L)
  bots_host_seed_project(state, first_project, now) catch {
    error => fail(error.to_string())
  }
  bots_host_seed_project(state, second_project, now) catch {
    error => fail(error.to_string())
  }
  let first_bot = bots_host_seed_bot(
    state,
    { ..bots_host_bot(), id: @contracts.new_bot_id(7_202L) },
    now,
  ) catch {
    error => fail(error.to_string())
  }
  let second_bot = bots_host_seed_bot(
    state,
    {
      ..bots_host_bot(),
      id: @contracts.new_bot_id(7_203L),
      name: "Second Host Builder",
    },
    now,
  ) catch {
    error => fail(error.to_string())
  }
  let empty_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_membership_list_empty",
      @contracts.METHOD_PROJECT_MEMBERSHIP_LIST,
      @contracts.project_membership_list_params("cid_membership_list_empty"),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let empty = match
    @contracts.project_memberships_from_result(bots_host_result(empty_text)) {
    Ok(value) => value
    Err(message) => fail("project.membership.list: " + message)
  }
  assert_eq(empty.length(), 0)
  let add_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_membership_add_first",
      @contracts.METHOD_PROJECT_MEMBERSHIP_ADD,
      @contracts.project_membership_add_params(
        "cid_membership_add_first",
        first_project,
        first_bot.id,
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let first = match
    @contracts.project_membership_from_result(bots_host_result(add_text)) {
    Ok(value) => value
    Err(message) => fail("project.membership.add: " + message)
  }
  assert_eq(first.state, @contracts.MEMBERSHIP_STATE_ACTIVE)
  assert_eq(first.project_id, first_project)
  assert_eq(first.bot_id, first_bot.id)
  assert_eq(first.access.length(), 0)
  state.mutex.acquire()
  let stored_bot = state.store.get_bot(first_bot.id)
  state.mutex.release()
  match stored_bot {
    Ok(Some(value)) =>
      assert_eq(value.permission_ceiling, first_bot.permission_ceiling)
    Ok(None) => fail("membership add lost the Bot")
    Err(message) => fail("get_bot after membership add: " + message)
  }
  let add_again_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_membership_add_first_again",
      @contracts.METHOD_PROJECT_MEMBERSHIP_ADD,
      @contracts.project_membership_add_params(
        "cid_membership_add_first_again",
        first_project,
        first_bot.id,
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let again = match
    @contracts.project_membership_from_result(
      bots_host_result(add_again_text),
    ) {
    Ok(value) => value
    Err(message) => fail("idempotent project.membership.add: " + message)
  }
  assert_eq(again.added_at, first.added_at)
  let added_events = bots_host_events_of_type(
    state,
    0L,
    @contracts.EVENT_PROJECT_MEMBER_ADDED,
  ) catch {
    error => fail(error.to_string())
  }
  assert_eq(added_events.length(), 1)
  let second_add_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_membership_add_second",
      @contracts.METHOD_PROJECT_MEMBERSHIP_ADD,
      @contracts.project_membership_add_params(
        "cid_membership_add_second",
        second_project,
        second_bot.id,
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let second = match
    @contracts.project_membership_from_result(
      bots_host_result(second_add_text),
    ) {
    Ok(value) => value
    Err(message) => fail("second project.membership.add: " + message)
  }
  assert_eq(second.access.length(), 0)
  let unknown_remove_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_membership_remove_unknown",
      @contracts.METHOD_PROJECT_MEMBERSHIP_REMOVE,
      @contracts.project_membership_remove_params(
        "cid_membership_remove_unknown",
        first_project,
        second_bot.id,
        reason="owner revoke",
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let unknown_remove = bots_host_error(unknown_remove_text)
  assert_eq(bots_host_error_kind(unknown_remove), "not_found")
  assert_true(unknown_remove.message.contains("not found"))
  let all_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_membership_list_all",
      @contracts.METHOD_PROJECT_MEMBERSHIP_LIST,
      @contracts.project_membership_list_params("cid_membership_list_all"),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let all = match
    @contracts.project_memberships_from_result(bots_host_result(all_text)) {
    Ok(value) => value
    Err(message) => fail("project.membership.list all: " + message)
  }
  assert_eq(all.length(), 2)
  let filtered_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_membership_list_first",
      @contracts.METHOD_PROJECT_MEMBERSHIP_LIST,
      @contracts.project_membership_list_params(
        "cid_membership_list_first",
        project_id=first_project,
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let filtered = match
    @contracts.project_memberships_from_result(
      bots_host_result(filtered_text),
    ) {
    Ok(value) => value
    Err(message) => fail("project.membership.list filter: " + message)
  }
  assert_eq(filtered.length(), 1)
  assert_eq(filtered[0].bot_id, first_bot.id)
  let missing_project_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_membership_add_missing_project",
      @contracts.METHOD_PROJECT_MEMBERSHIP_ADD,
      @contracts.project_membership_add_params(
        "cid_membership_add_missing_project",
        @contracts.new_project_id(7_204L),
        first_bot.id,
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let missing_project = bots_host_error(missing_project_text)
  assert_eq(bots_host_error_kind(missing_project), "not_found")
  assert_true(missing_project.message.contains("Project not found"))
  let missing_bot_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_membership_add_missing_bot",
      @contracts.METHOD_PROJECT_MEMBERSHIP_ADD,
      @contracts.project_membership_add_params(
        "cid_membership_add_missing_bot",
        first_project,
        @contracts.new_bot_id(7_205L),
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let missing_bot = bots_host_error(missing_bot_text)
  assert_eq(bots_host_error_kind(missing_bot), "not_found")
  assert_true(missing_bot.message.contains("Bot not found"))
  let archived_bot = bots_host_seed_bot(
    state,
    {
      ..bots_host_bot(),
      id: @contracts.new_bot_id(7_206L),
      name: "Archived Host Builder",
    },
    now,
  ) catch {
    error => fail(error.to_string())
  }
  state.mutex.acquire()
  let archive_result = state.store.archive_bot(archived_bot.id, "done", now, "owner")
  state.mutex.release()
  match archive_result {
    Ok(_) => ()
    Err(message) => fail("archive_bot failed: " + message)
  }
  let archived_add_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_membership_add_archived_bot",
      @contracts.METHOD_PROJECT_MEMBERSHIP_ADD,
      @contracts.project_membership_add_params(
        "cid_membership_add_archived_bot",
        first_project,
        archived_bot.id,
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let archived_add = bots_host_error(archived_add_text)
  assert_eq(bots_host_error_kind(archived_add), "conflict")
  assert_true(archived_add.message.contains("archived"))
}

///|
async test "Project membership removal waits for the non-terminal AgentSession" {
  let state = host_test_state(
    "/tmp/monexus-host-project-membership-remove-test",
    false,
  ) catch {
    error => fail(error.to_string())
  }
  let now = "2026-11-27T04:40:00Z"
  let project_id = @contracts.new_project_id(7_210L)
  bots_host_seed_project(state, project_id, now) catch {
    error => fail(error.to_string())
  }
  let bot = bots_host_seed_bot(
    state,
    { ..bots_host_bot(), id: @contracts.new_bot_id(7_211L) },
    now,
  ) catch {
    error => fail(error.to_string())
  }
  let add_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_membership_remove_add",
      @contracts.METHOD_PROJECT_MEMBERSHIP_ADD,
      @contracts.project_membership_add_params(
        "cid_membership_remove_add",
        project_id,
        bot.id,
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let _ = bots_host_result(add_text)
  state.mutex.acquire()
  let agent = match
    state.store.create_agent(bots_host_agent(bot), "", "owner", "test", now) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      fail("create_agent failed: " + message)
    }
  }
  let chat = match
    state.store.create_chat(
      @contracts.ChatRecord::new(
        id=@contracts.new_chat_id(7_212L),
        org_id=@contracts.ORG_LOCAL,
        title="Membership session",
        created_at=now,
        project_id~,
      ),
      [bot.id],
      "owner",
      "test",
      now,
    ) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      fail("create_chat failed: " + message)
    }
  }
  let session = @contracts.AgentSession::new(
    id=@contracts.new_agent_session_id(7_213L),
    chat_id=chat.id,
    agent_id=agent.id,
    permission_snapshot_hash="sha256:membership-test",
    started_at=now,
    project_id~,
  )
  match
    state.store.start_chat_agent_session(
      {
        ..session,
        workspace_id: "",
      },
      "owner",
      now,
    ) {
    Ok(_) => ()
    Err(message) => {
      state.mutex.release()
      fail("start_chat_agent_session failed: " + message)
    }
  }
  state.mutex.release()
  let blocked_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_membership_remove_blocked",
      @contracts.METHOD_PROJECT_MEMBERSHIP_REMOVE,
      @contracts.project_membership_remove_params(
        "cid_membership_remove_blocked",
        project_id,
        bot.id,
        reason="owner revoke",
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let blocked = bots_host_error(blocked_text)
  assert_eq(bots_host_error_kind(blocked), "conflict")
  assert_true(blocked.message.contains("non-terminal AgentSession"))
  state.mutex.acquire()
  let ended = state.store.end_chat_agent_session(
    session.id,
    @contracts.AGENT_SESSION_STATE_FAILED,
    @contracts.AGENT_SESSION_END_REASON_ERROR,
    "",
    "",
    now,
  )
  state.mutex.release()
  match ended {
    Ok(_) => ()
    Err(message) => fail("end_chat_agent_session failed: " + message)
  }
  let remove_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_membership_remove_after_end",
      @contracts.METHOD_PROJECT_MEMBERSHIP_REMOVE,
      @contracts.project_membership_remove_params(
        "cid_membership_remove_after_end",
        project_id,
        bot.id,
        reason="owner revoke",
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let removed = match
    @contracts.project_membership_from_result(
      bots_host_result(remove_text),
    ) {
    Ok(value) => value
    Err(message) => fail("project.membership.remove after end: " + message)
  }
  assert_eq(removed.state, @contracts.MEMBERSHIP_STATE_REMOVED)
  assert_eq(removed.reason, "owner revoke")
  let list_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_membership_list_after_remove",
      @contracts.METHOD_PROJECT_MEMBERSHIP_LIST,
      @contracts.project_membership_list_params(
        "cid_membership_list_after_remove",
        project_id=project_id,
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let active = match
    @contracts.project_memberships_from_result(bots_host_result(list_text)) {
    Ok(value) => value
    Err(message) => fail("project.membership.list after remove: " + message)
  }
  assert_eq(active.length(), 0)
}

///|
async test "Project membership re-add after removal drops historical access" {
  let state = host_test_state(
    "/tmp/monexus-host-project-membership-readd-test",
    false,
  ) catch {
    error => fail(error.to_string())
  }
  let now = "2026-11-27T04:50:00Z"
  let project_id = @contracts.new_project_id(7_220L)
  bots_host_seed_project(state, project_id, now) catch {
    error => fail(error.to_string())
  }
  let bot = bots_host_seed_bot(
    state,
    { ..bots_host_bot(), id: @contracts.new_bot_id(7_221L) },
    now,
  ) catch {
    error => fail(error.to_string())
  }
  state.mutex.acquire()
  let seeded = state.store.add_project_membership(
    @contracts.ProjectMembership::new(
      project_id~,
      bot_id=bot.id,
      added_at=now,
      access=["repo:read"],
      reason="legacy grant",
    ),
    "owner",
    now,
  )
  state.mutex.release()
  match seeded {
    Ok(value) => assert_eq(value.access[0], "repo:read")
    Err(message) => fail("seed legacy membership failed: " + message)
  }
  let remove_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_membership_readd_remove",
      @contracts.METHOD_PROJECT_MEMBERSHIP_REMOVE,
      @contracts.project_membership_remove_params(
        "cid_membership_readd_remove",
        project_id,
        bot.id,
        reason="owner revoke",
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let removed = match
    @contracts.project_membership_from_result(bots_host_result(remove_text)) {
    Ok(value) => value
    Err(message) => fail("project.membership.remove: " + message)
  }
  assert_eq(removed.state, @contracts.MEMBERSHIP_STATE_REMOVED)
  assert_eq(removed.access[0], "repo:read")
  let readd_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_membership_readd_add",
      @contracts.METHOD_PROJECT_MEMBERSHIP_ADD,
      @contracts.project_membership_add_params(
        "cid_membership_readd_add",
        project_id,
        bot.id,
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let readded = match
    @contracts.project_membership_from_result(bots_host_result(readd_text)) {
    Ok(value) => value
    Err(message) => fail("project.membership.add after remove: " + message)
  }
  assert_eq(readded.state, @contracts.MEMBERSHIP_STATE_ACTIVE)
  assert_eq(readded.access.length(), 0)
  assert_eq(readded.reason, "")
  assert_eq(readded.removed_at, "")
  state.mutex.acquire()
  let stored = state.store.get_project_membership(project_id, bot.id)
  state.mutex.release()
  match stored {
    Ok(Some(value)) => {
      assert_eq(value.state, @contracts.MEMBERSHIP_STATE_ACTIVE)
      assert_eq(value.access.length(), 0)
      assert_eq(value.reason, "")
    }
    Ok(None) => fail("re-added ProjectMembership disappeared")
    Err(message) => fail("get_project_membership after re-add: " + message)
  }
}

///|
async fn bots_host_repo_file(relative : String) -> String raise {
  let cwd = match @env.current_dir() {
    Some(value) => value
    None => fail("test process has no current directory")
  }
  let mut base = cwd
  for _ in 0..<10 {
    let candidate = base + "/" + relative
    let exists = @fs.exists(candidate) catch {
      _ => false
    }
    if exists {
      return candidate
    }
    base = base + "/.."
  }
  fail("cannot locate repository file: " + relative)
}

///|
fn bots_host_workspace(
  id : String,
  root : String,
  now : String,
) -> @contracts.WorkspaceRecord {
  {
    id,
    machine_id: "",
    kind: @contracts.WORKSPACE_KIND_LOCAL,
    root,
    name: "Chat E2E",
    git_root: "",
    is_git: false,
    state: @contracts.WORKSPACE_STATE_AVAILABLE,
    created_at: now,
    updated_at: now,
  }
}

///|
async fn bots_host_chat_messages(
  state : HostState,
  chat_id : String,
) -> Array[@contracts.ChatMessage] raise {
  state.mutex.acquire()
  let result = state.store.list_chat_messages(chat_id, "", 10)
  state.mutex.release()
  match result {
    Ok(value) => value
    Err(message) => fail("list_chat_messages failed: " + message)
  }
}

///|
async test "fake ACP Chat bridge start/send/read/stop" {
  let dir = @fs.tmpdir(prefix="monexus-bots-chat-e2e-") catch {
    _ => fail("cannot create a temp directory")
  }
  defer @async.protect_from_cancel(async fn() {
    @fs.rmdir(dir, recursive=true) catch { _ => () }
  })
  let done : @aqueue.Queue[Unit] = @aqueue.Queue(kind=Unbounded)
  let inner_group : Ref[@async.TaskGroup[Unit]?] = Ref(None)
  let state_ref : Ref[HostState?] = Ref(None)
  @async.with_task_group(async fn(outer) {
    outer.spawn_bg(
      no_wait=true,
      allow_failure=true,
      async fn() {
        done.get()
        match inner_group.val {
          Some(inner) => inner.return_immediately(())
          None => ()
        }
      },
    )
    @async.with_task_group(async fn(group) {
      let state = host_test_state(dir + "/state", false) catch {
        error => fail(error.to_string())
      }
      state_ref.val = Some(state)
      state.group.val = Some(group)
      inner_group.val = Some(group)
    let workspace_root = dir + "/workspace"
    @fs.mkdir(workspace_root, permission=0o700, recursive=true, allow_exist=true) catch {
      _ => fail("cannot create the workspace directory")
    }
    let now = "2026-11-27T05:00:00Z"
    let script = bots_host_repo_file("tests/agent/mock_acp_agent.mjs") catch {
      error => fail(error.to_string())
    }
    let bot = @contracts.BotRecord::new(
      id=@contracts.new_bot_id(7_200L),
      org_id=@contracts.ORG_LOCAL,
      name="Chat E2E Bot",
      created_at=now,
      memory_ref="bot/chat-e2e/memory",
      home=dir + "/bot-home",
      permission_ceiling=["repo:read"],
      create_policy=@contracts.BOT_CREATE_POLICY_AUTO,
      agent_count_cap=2,
      agent_concurrency_cap=1,
      software_allowlist=["mock-acp"],
    )
    let agent = @contracts.AgentRecord::new(
      id=@contracts.new_agent_id(7_201L),
      org_id=bot.org_id,
      bot_id=bot.id,
      name="Chat E2E Worker",
      runtime_binding=@contracts.RuntimeBinding::new(
        software_id="mock-acp",
        adapter_id="acp",
        launch_kind=@contracts.RUNTIME_LAUNCH_ACP,
        command="node",
        args=[script],
        model_profile="test",
        hash="sha256:chat-e2e-binding",
      ),
      created_at=now,
      permission_scope=["repo:read"],
      state=@contracts.AGENT_LIFECYCLE_ACTIVE,
    )
    let chat = @contracts.ChatRecord::new(
      id=@contracts.new_chat_id(7_202L),
      org_id=@contracts.ORG_LOCAL,
      title="Chat E2E",
      created_at=now,
    )
    let second_chat = @contracts.ChatRecord::new(
      id=@contracts.new_chat_id(7_203L),
      org_id=@contracts.ORG_LOCAL,
      title="Chat E2E Second",
      created_at=now,
    )
    let workspace = bots_host_workspace("ws_chat_e2e", workspace_root, now)
    state.mutex.acquire()
    match
      state.append_workspace_event(
        @contracts.EVENT_WORKSPACE_OPENED,
        "workspace/" + workspace.id,
        @contracts.workspace_event_payload(workspace),
        Some(workspace),
        None,
      ) {
      Ok(_) => ()
      Err(message) => {
        state.mutex.release()
        fail("cannot seed the workspace: " + message)
      }
    }
    let created_bot = match state.store.create_bot(bot, "owner", "test", now) {
      Ok(value) => value
      Err(message) => {
        state.mutex.release()
        fail("cannot create the Bot: " + message)
      }
    }
    let created_agent = match
      state.store.create_agent(agent, "", "owner", "test", now) {
      Ok(value) => value
      Err(message) => {
        state.mutex.release()
        fail("cannot create the Agent: " + message)
      }
    }
    let created_chat = match
      state.store.create_chat(chat, [created_bot.id], "owner", "test", now) {
      Ok(value) => value
      Err(message) => {
        state.mutex.release()
        fail("cannot create the Chat: " + message)
      }
    }
    let created_second_chat = match
      state.store.create_chat(
        second_chat,
        [created_bot.id],
        "owner",
        "test",
        now,
      ) {
      Ok(value) => value
      Err(message) => {
        state.mutex.release()
        fail("cannot create the second Chat: " + message)
      }
    }
    state.mutex.release()

    let start_text = bots_host_call(
      state,
      @contracts.RpcRequest::new(
        "req_chat_start",
        @contracts.METHOD_CHAT_AGENT_SESSION_START,
        @contracts.chat_agent_session_start_params(
          "cid_chat_start",
          created_chat.id,
          created_agent.id,
          workspace.id,
          workspace.root,
        ),
      ),
    ) catch {
      error => fail(error.to_string())
    }
    let session = match
      @contracts.chat_agent_session_from_result(bots_host_result(start_text)) {
      Ok(value) => value
      Err(message) => fail("chat.agent_session.start result: " + message)
    }
    assert_eq(session.state, @contracts.AGENT_SESSION_STATE_ACTIVE)
    assert_true(session.runtime_session_id != "")
    assert_true(session.permission_snapshot_hash != "")
    assert_eq(session.project_id, "")
    assert_eq(session.workspace_id, workspace.id)

    // Give the mock ACP process a moment to finish its handshake before the
    // first prompt; the polls below still have a hard deadline.
    @async.sleep(500)

    let detail_text = bots_host_call(
      state,
      @contracts.RpcRequest::new(
        "req_chat_get_e2e",
        @contracts.METHOD_CHAT_GET,
        @contracts.chat_get_params("cid_chat_get_e2e", created_chat.id),
      ),
    ) catch {
      error => fail(error.to_string())
    }
    let detail = match
      @contracts.chat_from_result(bots_host_result(detail_text)) {
      Ok(value) => value
      Err(message) => fail("chat.get result: " + message)
    }
    match detail.active_agent_session {
      Some(active) => assert_eq(active.id, session.id)
      None => fail("chat.get lost the active AgentSession")
    }
    match detail.agent {
      Some(bound) => assert_eq(bound.id, created_agent.id)
      None => fail("chat.get lost the bound Agent")
    }

    let send_text = bots_host_call(
      state,
      @contracts.RpcRequest::new(
        "req_chat_send",
        @contracts.METHOD_CHAT_SEND,
        @contracts.chat_send_params(
          "cid_chat_send",
          created_chat.id,
          "hello mock",
        ),
      ),
    ) catch {
      error => fail(error.to_string())
    }
    let sent = match
      @contracts.chat_send_result_from_json(bots_host_result(send_text)) {
      Some(value) => value
      None => fail("chat.send result did not decode")
    }
    assert_eq(sent.message.role, @contracts.CHAT_MESSAGE_ROLE_USER)
    assert_eq(sent.message.body, "hello mock")
    assert_eq(sent.session.id, session.id)

    let mut cursor = 0L
    let mut transcript = ""
    let mut saw_done = false
    let read_deadline = @async.now() + 10_000L
    let mut attempt = 0
    while @async.now() < read_deadline {
      let read_text = bots_host_call(
        state,
        @contracts.RpcRequest::new(
          "req_chat_read_" + attempt.to_string(),
          @contracts.METHOD_CHAT_READ,
          @contracts.chat_read_params(
            "cid_chat_read_" + attempt.to_string(),
            created_chat.id,
            cursor,
          ),
        ),
      ) catch {
        error => fail(error.to_string())
      }
      let read = match
        @contracts.chat_read_result_from_json(bots_host_result(read_text)) {
        Some(value) => value
        None => fail("chat.read result did not decode")
      }
      assert_true(read.cursor >= cursor)
      assert_eq(read.session_id, session.id)
      transcript = transcript + read.text
      cursor = read.cursor
      if transcript.contains("done") {
        saw_done = true
        break
      }
      attempt = attempt + 1
      @async.sleep(50)
    }
    if !saw_done {
      fail("chat.read never saw done; transcript=" + transcript)
    }
    assert_true(transcript.contains("MOCK#1 start"))
    assert_true(!transcript.contains("jsonrpc"))

    // The cursor is the end of the runtime delta, so a follow-up poll must be
    // empty instead of replaying the already-delivered transcript.
    let tail_text = bots_host_call(
      state,
      @contracts.RpcRequest::new(
        "req_chat_read_tail",
        @contracts.METHOD_CHAT_READ,
        @contracts.chat_read_params("cid_chat_read_tail", created_chat.id, cursor),
      ),
    ) catch {
      error => fail(error.to_string())
    }
    let tail = match
      @contracts.chat_read_result_from_json(bots_host_result(tail_text)) {
      Some(value) => value
      None => fail("chat.read tail result did not decode")
    }
    assert_eq(tail.cursor, cursor)
    assert_eq(tail.text, "")

    let mut messages : Array[@contracts.ChatMessage] = []
    let messages_deadline = @async.now() + 10_000L
    while @async.now() < messages_deadline {
      messages = bots_host_chat_messages(state, created_chat.id) catch {
        error => fail(error.to_string())
      }
      if messages.length() >= 2 {
        break
      }
      @async.sleep(50)
    }
    assert_eq(messages.length(), 2)
    assert_eq(messages[0].role, @contracts.CHAT_MESSAGE_ROLE_USER)
    assert_eq(messages[0].body, "hello mock")
    assert_eq(messages[1].role, @contracts.CHAT_MESSAGE_ROLE_ASSISTANT)
    assert_eq(messages[1].agent_session_id, session.id)
    assert_true(messages[1].body.contains("done"))
    // Raw ACP frames and hidden prompt text never become Chat messages.
    assert_true(!messages[1].body.contains("jsonrpc"))
    assert_true(!messages[1].body.contains("session/update"))

    let paged_text = bots_host_call(
      state,
      @contracts.RpcRequest::new(
        "req_chat_messages_e2e",
        @contracts.METHOD_CHAT_MESSAGES,
        @contracts.chat_messages_params(
          "cid_chat_messages_e2e",
          created_chat.id,
          after=messages[0].id,
        ),
      ),
    ) catch {
      error => fail(error.to_string())
    }
    let paged = match
      @contracts.chat_messages_from_result(bots_host_result(paged_text)) {
      Ok(value) => value
      Err(message) => fail("chat.messages result: " + message)
    }
    assert_eq(paged.length(), 1)
    assert_eq(paged[0].id, messages[1].id)

    let stop_text = bots_host_call(
      state,
      @contracts.RpcRequest::new(
        "req_chat_stop",
        @contracts.METHOD_CHAT_STOP,
        @contracts.chat_stop_params(
          "cid_chat_stop",
          created_chat.id,
          end_reason=@contracts.AGENT_SESSION_END_REASON_TURN_END,
          session_id=session.id,
        ),
      ),
    ) catch {
      error => fail(error.to_string())
    }
    let stopped = match
      @contracts.chat_stop_result_from_json(bots_host_result(stop_text)) {
      Some(value) => value
      None => fail("chat.stop result did not decode")
    }
    assert_true(stopped.stopped)
    assert_eq(stopped.session.state, @contracts.AGENT_SESSION_STATE_ENDED)
    assert_eq(
      stopped.session.end_reason,
      @contracts.AGENT_SESSION_END_REASON_TURN_END,
    )

    let stopped_detail_text = bots_host_call(
      state,
      @contracts.RpcRequest::new(
        "req_chat_get_stopped",
        @contracts.METHOD_CHAT_GET,
        @contracts.chat_get_params("cid_chat_get_stopped", created_chat.id),
      ),
    ) catch {
      error => fail(error.to_string())
    }
    let stopped_detail = match
      @contracts.chat_from_result(bots_host_result(stopped_detail_text)) {
      Ok(value) => value
      Err(message) => fail("chat.get after stop: " + message)
    }
    match stopped_detail.active_agent_session {
      Some(_) => fail("ended AgentSession is still returned as active")
      None => ()
    }

    // Two starts must not share the cached agent.start response. The cache
    // keys are session-scoped, so a second Chat gets its own runtime.
    let second_start_text = bots_host_call(
      state,
      @contracts.RpcRequest::new(
        "req_chat_start_second",
        @contracts.METHOD_CHAT_AGENT_SESSION_START,
        @contracts.chat_agent_session_start_params(
          "cid_chat_start_second",
          created_second_chat.id,
          created_agent.id,
          workspace.id,
          workspace.root,
        ),
      ),
    ) catch {
      error => fail(error.to_string())
    }
    let second_session = match
      @contracts.chat_agent_session_from_result(
        bots_host_result(second_start_text),
      ) {
      Ok(value) => value
      Err(message) => fail("second chat.agent_session.start: " + message)
    }
    assert_eq(second_session.state, @contracts.AGENT_SESSION_STATE_ACTIVE)
    assert_true(second_session.id != session.id)
    assert_true(second_session.runtime_session_id != session.runtime_session_id)
    match state.cache.get("chat-start-" + session.id) {
      Some(_) => ()
      None => fail("first chat.start did not use the per-session cache key")
    }
    match state.cache.get("chat-start-" + second_session.id) {
      Some(_) => ()
      None => fail("second chat.start did not use the per-session cache key")
    }
    let second_stop_text = bots_host_call(
      state,
      @contracts.RpcRequest::new(
        "req_chat_stop_second",
        @contracts.METHOD_CHAT_STOP,
        @contracts.chat_stop_params(
          "cid_chat_stop_second",
          created_second_chat.id,
          end_reason=@contracts.AGENT_SESSION_END_REASON_TURN_END,
          session_id=second_session.id,
        ),
      ),
    ) catch {
      error => fail(error.to_string())
    }
    let second_stopped = match
      @contracts.chat_stop_result_from_json(bots_host_result(second_stop_text)) {
      Some(value) => value
      None => fail("second chat.stop result did not decode")
    }
    assert_true(second_stopped.stopped)
    assert_eq(second_stopped.session.state, @contracts.AGENT_SESSION_STATE_ENDED)

    // Continue the first Chat in a new AgentSession. Visible history is
    // injected once as a hidden prompt prefix; the current message, system
    // boundaries and any other non user/assistant rows stay out.
    let system_message = bots_host_message(
      created_chat,
      session.id,
      @contracts.CHAT_MESSAGE_ROLE_SYSTEM,
      "CHAT-SYSTEM-BOUNDARY must not enter continuation context",
      now,
    )
    state.mutex.acquire()
    let system_before = bots_last_seq_or_zero(state)
    match state.store.append_chat_message(system_message, now) {
      Ok(_) => state.sync_bots_events_after(system_before)
      Err(message) => {
        state.mutex.release()
        fail("cannot seed the system boundary message: " + message)
      }
    }
    state.mutex.release()
    let continuation_start_text = bots_host_call(
      state,
      @contracts.RpcRequest::new(
        "req_chat_continue_start",
        @contracts.METHOD_CHAT_AGENT_SESSION_START,
        @contracts.chat_agent_session_start_params(
          "cid_chat_continue_start",
          created_chat.id,
          created_agent.id,
          workspace.id,
          workspace.root,
        ),
      ),
    ) catch {
      error => fail(error.to_string())
    }
    let continuation = match
      @contracts.chat_agent_session_from_result(
        bots_host_result(continuation_start_text),
      ) {
      Ok(value) => value
      Err(message) => fail("continuation chat.start: " + message)
    }
    assert_eq(
      continuation.state,
      @contracts.AGENT_SESSION_STATE_ACTIVE,
    )
    assert_eq(continuation.handoff_from_session_id, session.id)
    @async.sleep(500)
    let first_continue_send = bots_host_call(
      state,
      @contracts.RpcRequest::new(
        "req_chat_continue_send_1",
        @contracts.METHOD_CHAT_SEND,
        @contracts.chat_send_params(
          "cid_chat_continue_send_1",
          created_chat.id,
          "continue please",
        ),
      ),
    ) catch {
      error => fail(error.to_string())
    }
    let first_continue_sent = match
      @contracts.chat_send_result_from_json(
        bots_host_result(first_continue_send),
      ) {
      Some(value) => value
      None => fail("first continuation chat.send result did not decode")
    }
    assert_eq(first_continue_sent.session.id, continuation.id)
    assert_eq(first_continue_sent.message.body, "continue please")
    let mut continue_cursor = 0L
    let mut first_continue_live = ""
    let continue_deadline = @async.now() + 10_000L
    let mut continue_attempt = 0
    while @async.now() < continue_deadline {
      let read_text = bots_host_call(
        state,
        @contracts.RpcRequest::new(
          "req_chat_continue_read_1_" + continue_attempt.to_string(),
          @contracts.METHOD_CHAT_READ,
          @contracts.chat_read_params(
            "cid_chat_continue_read_1_" + continue_attempt.to_string(),
            created_chat.id,
            continue_cursor,
          ),
        ),
      ) catch {
        error => fail(error.to_string())
      }
      let read = match
        @contracts.chat_read_result_from_json(bots_host_result(read_text)) {
        Some(value) => value
        None => fail("first continuation chat.read did not decode")
      }
      assert_eq(read.session_id, continuation.id)
      first_continue_live = first_continue_live + read.text
      continue_cursor = read.cursor
      if first_continue_live.contains("done") {
        break
      }
      continue_attempt = continue_attempt + 1
      @async.sleep(50)
    }
    assert_true(first_continue_live.contains("RECOVERY_CONTEXT_SEEN"))
    assert_false(first_continue_live.contains("SYSTEM_CONTEXT_LEAK"))
    let mut continued_messages : Array[@contracts.ChatMessage] = []
    let messages_deadline = @async.now() + 10_000L
    while @async.now() < messages_deadline {
      continued_messages = bots_host_chat_messages(state, created_chat.id) catch {
        error => fail(error.to_string())
      }
      if continued_messages.length() >= 5 &&
        continued_messages[4].body.contains("done") {
        break
      }
      @async.sleep(50)
    }
    assert_eq(continued_messages.length(), 5)
    assert_eq(continued_messages[2].id, system_message.id)
    assert_eq(
      continued_messages[2].role,
      @contracts.CHAT_MESSAGE_ROLE_SYSTEM,
    )
    assert_eq(continued_messages[3].body, "continue please")
    assert_eq(
      continued_messages[3].role,
      @contracts.CHAT_MESSAGE_ROLE_USER,
    )
    assert_true(continued_messages[4].body.contains("RECOVERY_CONTEXT_SEEN"))
    assert_false(continued_messages[4].body.contains("SYSTEM_CONTEXT_LEAK"))
    for message in continued_messages {
      assert_false(
        message.body.contains("[MoNexus Chat continuation context]"),
      )
    }
    let persisted_transcript = match
      state.store.load_chat_transcript(continuation.id) {
      Ok(Some(value)) => value
      Ok(None) => fail("continuation transcript was not persisted")
      Err(message) => fail("load_chat_transcript failed: " + message)
    }
    assert_true(persisted_transcript.context_injected)
    assert_true(
      persisted_transcript.text.contains("RECOVERY_CONTEXT_SEEN"),
    )
    assert_false(
      persisted_transcript.text.contains(
        "[MoNexus Chat continuation context]",
      ),
    )
    let recent_events = match state.store.load_recent_events(1_000) {
      Ok(value) => value
      Err(message) => fail("load_recent_events failed: " + message)
    }
    for event in recent_events {
      assert_false(
        event.payload.stringify().contains(
          "[MoNexus Chat continuation context]",
        ),
      )
    }
    let second_continue_send = bots_host_call(
      state,
      @contracts.RpcRequest::new(
        "req_chat_continue_send_2",
        @contracts.METHOD_CHAT_SEND,
        @contracts.chat_send_params(
          "cid_chat_continue_send_2",
          created_chat.id,
          "again",
        ),
      ),
    ) catch {
      error => fail(error.to_string())
    }
    let second_continue_sent = match
      @contracts.chat_send_result_from_json(
        bots_host_result(second_continue_send),
      ) {
      Some(value) => value
      None => fail("second continuation chat.send result did not decode")
    }
    assert_eq(second_continue_sent.message.body, "again")
    let mut second_continue_live = ""
    let second_deadline = @async.now() + 10_000L
    let mut second_attempt = 0
    while @async.now() < second_deadline {
      let read_text = bots_host_call(
        state,
        @contracts.RpcRequest::new(
          "req_chat_continue_read_2_" + second_attempt.to_string(),
          @contracts.METHOD_CHAT_READ,
          @contracts.chat_read_params(
            "cid_chat_continue_read_2_" + second_attempt.to_string(),
            created_chat.id,
            continue_cursor,
          ),
        ),
      ) catch {
        error => fail(error.to_string())
      }
      let read = match
        @contracts.chat_read_result_from_json(bots_host_result(read_text)) {
        Some(value) => value
        None => fail("second continuation chat.read did not decode")
      }
      second_continue_live = second_continue_live + read.text
      continue_cursor = read.cursor
      if second_continue_live.contains("done") {
        break
      }
      second_attempt = second_attempt + 1
      @async.sleep(50)
    }
    assert_true(second_continue_live.contains("done"))
    assert_false(
      second_continue_live.contains("RECOVERY_CONTEXT_SEEN"),
    )
    let mut final_messages : Array[@contracts.ChatMessage] = []
    let final_deadline = @async.now() + 10_000L
    while @async.now() < final_deadline {
      final_messages = bots_host_chat_messages(state, created_chat.id) catch {
        error => fail(error.to_string())
      }
      if final_messages.length() >= 7 &&
        final_messages[6].body.contains("done") {
        break
      }
      @async.sleep(50)
    }
    assert_eq(final_messages.length(), 7)
    assert_eq(final_messages[5].body, "again")
    assert_true(final_messages[6].body.contains("done"))
    assert_false(final_messages[6].body.contains("RECOVERY_CONTEXT_SEEN"))
    let continuation_stop_text = bots_host_call(
      state,
      @contracts.RpcRequest::new(
        "req_chat_continue_stop",
        @contracts.METHOD_CHAT_STOP,
        @contracts.chat_stop_params(
          "cid_chat_continue_stop",
          created_chat.id,
          end_reason=@contracts.AGENT_SESSION_END_REASON_TURN_END,
          session_id=continuation.id,
        ),
      ),
    ) catch {
      error => fail(error.to_string())
    }
    let continuation_stopped = match
      @contracts.chat_stop_result_from_json(
        bots_host_result(continuation_stop_text),
      ) {
      Some(value) => value
      None => fail("continuation chat.stop result did not decode")
    }
    assert_true(continuation_stopped.stopped)

    // A host restart drops the in-memory runtime and transcript. chat.read
    // must not reset the client cursor or invent text when both are missing.
    state.mutex.acquire()
    state.agent_transcripts.remove(session.runtime_session_id)
    state.agent_transcripts.remove(continuation.runtime_session_id)
    state.mutex.release()
    let missing_text = bots_host_call(
      state,
      @contracts.RpcRequest::new(
        "req_chat_read_missing",
        @contracts.METHOD_CHAT_READ,
        @contracts.chat_read_params(
          "cid_chat_read_missing",
          created_chat.id,
          cursor,
        ),
      ),
    ) catch {
      error => fail(error.to_string())
    }
    let missing = match
      @contracts.chat_read_result_from_json(bots_host_result(missing_text)) {
      Some(value) => value
      None => fail("chat.read after missing runtime did not decode")
    }
    assert_eq(missing.cursor, cursor)
    assert_eq(missing.text, "")
    assert_eq(missing.state, @contracts.AGENT_SESSION_STATE_ENDED)
    match
      state.store.load_chat_transcript(continuation.id) {
      Ok(Some(_)) => ()
      Ok(None) => fail("persisted transcript disappeared across restart")
      Err(message) => fail("load_chat_transcript after restart: " + message)
    }

    done.put(())
  })
  })
  match state_ref.val {
    Some(state) => state.store.close()
    None => ()
  }
}

///|
async test "Chat session start rejects suspended Bot and archived Chat" {
  let state = host_test_state("/tmp/monexus-host-bots-guards-test", false) catch {
    error => fail(error.to_string())
  }
  let now = "2026-11-27T05:30:00Z"
  let bot = bots_host_bot()
  let agent = bots_host_agent(bot)
  let chat = bots_host_chat("Guard Chat")
  state.mutex.acquire()
  let created_bot = match state.store.create_bot(bot, "owner", "test", now) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      fail("cannot create the Bot: " + message)
    }
  }
  let created_agent = match
    state.store.create_agent(agent, "", "owner", "test", now) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      fail("cannot create the Agent: " + message)
    }
  }
  let created_chat = match
    state.store.create_chat(chat, [created_bot.id], "owner", "test", now) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      fail("cannot create the Chat: " + message)
    }
  }
  let suspended = {
    ..created_bot,
    state: @contracts.BOT_STATE_SUSPENDED,
    updated_at: now,
  }
  match
    state.store.append_bots_event(
      @contracts.EVENT_BOT_UPDATED,
      @contracts.bot_event_subject(created_bot.id),
      @contracts.bot_updated_payload(suspended, ["state"], 2, "owner"),
      now,
      created_bot.org_id,
    ) {
    Ok(_) => ()
    Err(message) => {
      state.mutex.release()
      fail("cannot persist the suspended Bot: " + message)
    }
  }
  state.mutex.release()

  let suspended_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_suspended_start",
      @contracts.METHOD_CHAT_AGENT_SESSION_START,
      @contracts.chat_agent_session_start_params(
        "cid_suspended_start",
        created_chat.id,
        created_agent.id,
        "ws_missing",
        "",
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let suspended_error = bots_host_error(suspended_text)
  assert_true(suspended_error.message.contains("Conflict"))
  assert_true(suspended_error.message.contains("Bot is not active"))

  state.mutex.acquire()
  let active_bot = {
    ..bots_host_bot(),
    id: @contracts.new_bot_id(7_300L),
    name: "Host Builder Archive",
  }
  let active_agent = {
    ..bots_host_agent(active_bot),
    id: @contracts.new_agent_id(7_301L),
  }
  let archived_chat = {
    ..bots_host_chat("Archived Chat"),
    id: @contracts.new_chat_id(7_302L),
  }
  let stored_bot = match state.store.create_bot(active_bot, "owner", "test", now) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      fail("cannot create the second Bot: " + message)
    }
  }
  let stored_agent = match
    state.store.create_agent(active_agent, "", "owner", "test", now) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      fail("cannot create the second Agent: " + message)
    }
  }
  let stored_chat = match
    state.store.create_chat(archived_chat, [stored_bot.id], "owner", "test", now) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      fail("cannot create the second Chat: " + message)
    }
  }
  let archived = { ..stored_chat, state: @contracts.CHAT_STATE_ARCHIVED }
  match
    state.store.append_bots_event(
      @contracts.EVENT_CHAT_PROJECT_CHANGED,
      @contracts.chat_event_subject(stored_chat.id),
      @contracts.chat_project_changed_payload(archived, "", "owner archive", "owner"),
      now,
      stored_chat.org_id,
    ) {
    Ok(_) => ()
    Err(message) => {
      state.mutex.release()
      fail("cannot persist the archived Chat: " + message)
    }
  }
  state.mutex.release()

  let archived_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_archived_start",
      @contracts.METHOD_CHAT_AGENT_SESSION_START,
      @contracts.chat_agent_session_start_params(
        "cid_archived_start",
        stored_chat.id,
        stored_agent.id,
        "ws_missing",
        "",
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let archived_error = bots_host_error(archived_text)
  assert_true(archived_error.message.contains("Conflict"))
  assert_true(archived_error.message.contains("Chat is archived"))
}

///|
fn bots_host_error_kind(error : @contracts.RpcError) -> String {
  let data = match error.data {
    Some(value) => value
    None => return ""
  }
  match @contracts.as_object(data) {
    Some(object) => @contracts.string_field_or(object, "kind", "")
    None => ""
  }
}

///|
fn bots_host_events_of_type(
  state : HostState,
  after : Int64,
  event_type : String,
) -> Array[@contracts.EventEnvelope] raise {
  let events = match state.store.load_events_since(after, 500) {
    Ok(value) => value
    Err(message) => fail("load_events_since failed: " + message)
  }
  events.filter(fn(event) { event.event_type == event_type })
}

///|
fn bots_host_string_array_field(
  object : Map[String, @json.Json],
  key : String,
) -> Array[String] {
  let out : Array[String] = []
  match object.get(key) {
    Some(@json.Json::Array(items)) =>
      for item in items {
        match item {
          @json.Json::String(value) => out.push(value)
          _ => ()
        }
      }
    _ => ()
  }
  out
}

///|
async fn bots_host_seed_runtime_chat(
  state : HostState,
  dir : String,
  now : String,
  seed : Int64,
  command : String,
  args : Array[String],
) -> (
  @contracts.BotRecord,
  @contracts.AgentRecord,
  @contracts.ChatRecord,
  @contracts.WorkspaceRecord,
) raise {
  let root = dir + "/workspace-" + seed.to_string()
  @fs.mkdir(root, permission=0o700, recursive=true, allow_exist=true) catch {
    _ => fail("cannot create the workspace directory")
  }
  let workspace = bots_host_workspace("ws_host_" + seed.to_string(), root, now)
  let bot = @contracts.BotRecord::new(
    id=@contracts.new_bot_id(seed),
    org_id=@contracts.ORG_LOCAL,
    name="Host Runtime Bot " + seed.to_string(),
    created_at=now,
    memory_ref="bot/host-runtime/memory",
    home=dir + "/bot-home-" + seed.to_string(),
    permission_ceiling=["repo:read"],
    create_policy=@contracts.BOT_CREATE_POLICY_AUTO,
    agent_count_cap=2,
    agent_concurrency_cap=2,
    software_allowlist=["mock-acp"],
  )
  let agent = @contracts.AgentRecord::new(
    id=@contracts.new_agent_id(seed + 1L),
    org_id=bot.org_id,
    bot_id=bot.id,
    name="Host Runtime Worker " + seed.to_string(),
    runtime_binding=@contracts.RuntimeBinding::new(
      software_id="mock-acp",
      adapter_id="acp",
      launch_kind=@contracts.RUNTIME_LAUNCH_ACP,
      command~,
      args~,
      model_profile="test",
      hash="sha256:host-runtime-binding-" + seed.to_string(),
    ),
    created_at=now,
    permission_scope=["repo:read"],
    state=@contracts.AGENT_LIFECYCLE_ACTIVE,
  )
  let chat = @contracts.ChatRecord::new(
    id=@contracts.new_chat_id(seed + 2L),
    org_id=@contracts.ORG_LOCAL,
    title="Host Runtime Chat " + seed.to_string(),
    created_at=now,
  )
  state.mutex.acquire()
  match
    state.append_workspace_event(
      @contracts.EVENT_WORKSPACE_OPENED,
      "workspace/" + workspace.id,
      @contracts.workspace_event_payload(workspace),
      Some(workspace),
      None,
    ) {
    Ok(_) => ()
    Err(message) => {
      state.mutex.release()
      fail("cannot seed the workspace: " + message)
    }
  }
  let created_bot = match state.store.create_bot(bot, "owner", "test", now) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      fail("cannot create the Bot: " + message)
    }
  }
  let created_agent = match
    state.store.create_agent(agent, "", "owner", "test", now) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      fail("cannot create the Agent: " + message)
    }
  }
  let created_chat = match
    state.store.create_chat(chat, [created_bot.id], "owner", "test", now) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      fail("cannot create the Chat: " + message)
    }
  }
  state.mutex.release()
  (created_bot, created_agent, created_chat, workspace)
}

///|
async fn bots_host_list_chat_sessions(
  state : HostState,
  chat_id : String,
) -> Array[@contracts.AgentSession] raise {
  state.mutex.acquire()
  let result = state.store.list_chat_agent_sessions(chat_id)
  state.mutex.release()
  match result {
    Ok(value) => value
    Err(message) => fail("list_chat_agent_sessions failed: " + message)
  }
}

///|
async fn bots_host_runtime_count(state : HostState) -> Int {
  state.mutex.acquire()
  let count = state.agent_sessions.size()
  state.mutex.release()
  count
}

///|
async fn bots_host_has_runtime(state : HostState, runtime_id : String) -> Bool {
  state.mutex.acquire()
  let present = state.agent_sessions.contains(runtime_id)
  state.mutex.release()
  present
}

///|
async test "Bot update records the caller version and keeps the read-only guards" {
  let state = host_test_state("/tmp/monexus-host-bots-update-test", false) catch {
    error => fail(error.to_string())
  }
  let bot = bots_host_bot()
  let create_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_bot_update_create",
      @contracts.METHOD_BOT_CREATE,
      @contracts.bot_create_params("cid_bot_update_create", bot),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let created = match
    @contracts.bot_from_result(bots_host_result(create_text)) {
    Ok(value) => value
    Err(message) => fail("bot.create result: " + message)
  }
  let before = match state.store.last_seq() {
    Ok(value) => value
    Err(message) => fail("last_seq failed: " + message)
  }
  let renamed = { ..created, name: "Host Builder Renamed" }
  let rename_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_bot_update_rename",
      @contracts.METHOD_BOT_UPDATE,
      @contracts.bot_update_params(
        "cid_bot_update_rename",
        renamed,
        ["name"],
        2,
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let rename_result = match
    @contracts.bot_from_result(bots_host_result(rename_text)) {
    Ok(value) => value
    Err(message) => fail("bot.update result: " + message)
  }
  assert_eq(rename_result.name, "Host Builder Renamed")
  assert_true(rename_result.updated_at != "")
  let stored = match state.store.get_bot(created.id) {
    Ok(Some(value)) => value
    Ok(None) => fail("bot.update did not persist the Bot")
    Err(message) => fail("get_bot failed: " + message)
  }
  assert_eq(stored.name, "Host Builder Renamed")
  let updated_events = bots_host_events_of_type(
    state,
    before,
    @contracts.EVENT_BOT_UPDATED,
  ) catch {
    error => fail(error.to_string())
  }
  assert_eq(updated_events.length(), 1)
  let payload = match @contracts.as_object(updated_events[0].payload) {
    Some(value) => value
    None => fail("bot.updated payload is not an object")
  }
  assert_eq(@contracts.string_field_or(payload, "actor", ""), "owner")
  assert_eq(@contracts.int_field_or(payload, "version", -1), 2)
  let changed = bots_host_string_array_field(payload, "changed_fields")
  assert_eq(changed.length(), 1)
  assert_eq(changed[0], "name")
  match @contracts.bot_updated_record(updated_events[0].payload) {
    Some(record) => assert_eq(record.name, "Host Builder Renamed")
    None => fail("bot.updated record did not decode")
  }

  // A stale caller version is currently accepted and echoed verbatim. This
  // pins the existing behavior so a future optimistic-concurrency decision
  // has to change this test deliberately.
  let stale_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_bot_update_stale",
      @contracts.METHOD_BOT_UPDATE,
      @contracts.bot_update_params(
        "cid_bot_update_stale",
        { ..stored, name: "Host Builder Stale Version" },
        ["name"],
        2,
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let stale = match
    @contracts.bot_from_result(bots_host_result(stale_text)) {
    Ok(value) => value
    Err(message) => fail("stale bot.update result: " + message)
  }
  assert_eq(stale.name, "Host Builder Stale Version")

  // Archived Bots are read-only.
  let archive_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_bot_update_archive",
      @contracts.METHOD_BOT_ARCHIVE,
      @contracts.bot_archive_params(
        "cid_bot_update_archive",
        created.id,
        "done",
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let archived = match
    @contracts.bot_from_result(bots_host_result(archive_text)) {
    Ok(value) => value
    Err(message) => fail("bot.archive result: " + message)
  }
  assert_eq(archived.state, @contracts.BOT_STATE_ARCHIVED)
  let archived_update_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_bot_update_archived",
      @contracts.METHOD_BOT_UPDATE,
      @contracts.bot_update_params(
        "cid_bot_update_archived",
        { ..archived, name: "Should Not Apply" },
        ["name"],
        3,
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let archived_error = bots_host_error(archived_update_text)
  assert_eq(bots_host_error_kind(archived_error), "conflict")
  assert_true(archived_error.message.contains("read-only"))

  // A second Bot exercises the immutable/policy/permission and empty-field
  // guards, plus the fact that only archived (not suspended) is read-only.
  let guard_bot = {
    ..bots_host_bot(),
    id: @contracts.new_bot_id(7_110L),
    name: "Host Builder Guards",
  }
  let guard_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_bot_update_guard_create",
      @contracts.METHOD_BOT_CREATE,
      @contracts.bot_create_params("cid_bot_update_guard_create", guard_bot),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let guards = match
    @contracts.bot_from_result(bots_host_result(guard_text)) {
    Ok(value) => value
    Err(message) => fail("guard bot.create result: " + message)
  }
  let immutable_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_bot_update_immutable",
      @contracts.METHOD_BOT_UPDATE,
      @contracts.bot_update_params(
        "cid_bot_update_immutable",
        { ..guards, state: @contracts.BOT_STATE_SUSPENDED },
        ["state"],
        2,
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let immutable_error = bots_host_error(immutable_text)
  assert_eq(bots_host_error_kind(immutable_error), "conflict")
  assert_true(immutable_error.message.contains("immutable"))
  let policy_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_bot_update_policy",
      @contracts.METHOD_BOT_UPDATE,
      @contracts.bot_update_params(
        "cid_bot_update_policy",
        { ..guards, agent_concurrency_cap: 3 },
        ["agent_concurrency_cap"],
        2,
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  assert_true(
    bots_host_error(policy_text).message.contains("update_bot_policy"),
  )
  let permission_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_bot_update_permission",
      @contracts.METHOD_BOT_UPDATE,
      @contracts.bot_update_params(
        "cid_bot_update_permission",
        { ..guards, permission_ceiling: ["repo:read", "repo:write"] },
        ["permission_ceiling"],
        2,
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  assert_true(
    bots_host_error(permission_text).message.contains("update_bot_permissions"),
  )
  let empty_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_bot_update_empty",
      @contracts.METHOD_BOT_UPDATE,
      @contracts.bot_update_params(
        "cid_bot_update_empty",
        guards,
        [],
        2,
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let empty_error = bots_host_error(empty_text)
  assert_eq(bots_host_error_kind(empty_error), "invalid")
  assert_true(empty_error.message.contains("no changed fields"))

  // Suspended is not read-only for bot.update in the current store.
  let suspended = {
    ..guards,
    state: @contracts.BOT_STATE_SUSPENDED,
    updated_at: "2026-11-27T06:10:00Z",
  }
  state.mutex.acquire()
  match
    state.store.append_bots_event(
      @contracts.EVENT_BOT_UPDATED,
      @contracts.bot_event_subject(guards.id),
      @contracts.bot_updated_payload(suspended, ["state"], 3, "owner"),
      "2026-11-27T06:10:00Z",
      guards.org_id,
    ) {
    Ok(_) => ()
    Err(message) => {
      state.mutex.release()
      fail("cannot persist the suspended Bot: " + message)
    }
  }
  state.mutex.release()
  let suspended_text = bots_host_call(
    state,
    @contracts.RpcRequest::new(
      "req_bot_update_suspended",
      @contracts.METHOD_BOT_UPDATE,
      @contracts.bot_update_params(
        "cid_bot_update_suspended",
        { ..suspended, name: "Host Builder Suspended Renamed" },
        ["name"],
        4,
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let suspended_result = match
    @contracts.bot_from_result(bots_host_result(suspended_text)) {
    Ok(value) => value
    Err(message) => fail("suspended bot.update result: " + message)
  }
  assert_eq(suspended_result.state, @contracts.BOT_STATE_SUSPENDED)
  assert_eq(suspended_result.name, "Host Builder Suspended Renamed")
}

///|
async test "Chat agent_session.end stops the runtime and repeats idempotently" {
  let dir = @fs.tmpdir(prefix="monexus-bots-session-end-") catch {
    _ => fail("cannot create a temp directory")
  }
  defer @async.protect_from_cancel(async fn() {
    @fs.rmdir(dir, recursive=true) catch { _ => () }
  })
  let done : @aqueue.Queue[Unit] = @aqueue.Queue(kind=Unbounded)
  let inner_group : Ref[@async.TaskGroup[Unit]?] = Ref(None)
  let state_ref : Ref[HostState?] = Ref(None)
  @async.with_task_group(async fn(outer) {
    outer.spawn_bg(
      no_wait=true,
      allow_failure=true,
      async fn() {
        done.get()
        match inner_group.val {
          Some(inner) => inner.return_immediately(())
          None => ()
        }
      },
    )
    @async.with_task_group(async fn(group) {
      let state = host_test_state(dir + "/state", false) catch {
        error => fail(error.to_string())
      }
      state_ref.val = Some(state)
      state.group.val = Some(group)
      inner_group.val = Some(group)
      let script = bots_host_repo_file("tests/agent/mock_acp_agent.mjs") catch {
        error => fail(error.to_string())
      }
      let (_, agent, chat, workspace) = bots_host_seed_runtime_chat(
        state,
        dir,
        "2026-11-27T06:20:00Z",
        7_400L,
        "node",
        [script],
      ) catch {
        error => fail(error.to_string())
      }
      let start_text = bots_host_call(
        state,
        @contracts.RpcRequest::new(
          "req_session_end_start",
          @contracts.METHOD_CHAT_AGENT_SESSION_START,
          @contracts.chat_agent_session_start_params(
            "cid_session_end_start",
            chat.id,
            agent.id,
            workspace.id,
            workspace.root,
          ),
        ),
      ) catch {
        error => fail(error.to_string())
      }
      let session = match
        @contracts.chat_agent_session_from_result(
          bots_host_result(start_text),
        ) {
        Ok(value) => value
        Err(message) => fail("chat.agent_session.start result: " + message)
      }
      assert_eq(session.state, @contracts.AGENT_SESSION_STATE_ACTIVE)
      assert_true(session.runtime_session_id != "")
      let runtime_id = session.runtime_session_id
      assert_true(bots_host_has_runtime(state, runtime_id))
      assert_eq(bots_host_runtime_count(state), 1)
      let before_end = match state.store.last_seq() {
        Ok(value) => value
        Err(message) => fail("last_seq failed: " + message)
      }
      let end_text = bots_host_call(
        state,
        @contracts.RpcRequest::new(
          "req_session_end",
          @contracts.METHOD_CHAT_AGENT_SESSION_END,
          @contracts.chat_agent_session_end_params(
            "cid_session_end",
            session.id,
            @contracts.AGENT_SESSION_END_REASON_TURN_END,
          ),
        ),
      ) catch {
        error => fail(error.to_string())
      }
      let ended = match
        @contracts.chat_agent_session_from_result(bots_host_result(end_text)) {
        Ok(value) => value
        Err(message) => fail("chat.agent_session.end result: " + message)
      }
      assert_eq(ended.id, session.id)
      assert_eq(ended.state, @contracts.AGENT_SESSION_STATE_ENDED)
      assert_eq(
        ended.end_reason,
        @contracts.AGENT_SESSION_END_REASON_TURN_END,
      )
      assert_true(!bots_host_has_runtime(state, runtime_id))
      assert_eq(bots_host_runtime_count(state), 0)

      // Active -> ending -> ended is the store event trail; no second active
      // record exists and the terminal event is written exactly once.
      let updated_events = bots_host_events_of_type(
        state,
        before_end,
        @contracts.EVENT_CHAT_AGENT_SESSION_UPDATED,
      ) catch {
        error => fail(error.to_string())
      }
      assert_eq(updated_events.length(), 1)
      let ending = match
        @contracts.chat_agent_session_updated_record(
          updated_events[0].payload,
        ) {
        Some(value) => value
        None => fail("chat.agent_session.updated record did not decode")
      }
      assert_eq(ending.state, @contracts.AGENT_SESSION_STATE_ENDING)
      let ended_events = bots_host_events_of_type(
        state,
        before_end,
        @contracts.EVENT_CHAT_AGENT_SESSION_ENDED,
      ) catch {
        error => fail(error.to_string())
      }
      assert_eq(ended_events.length(), 1)
      let ended_record = match
        @contracts.chat_agent_session_ended_record(ended_events[0].payload) {
        Some(value) => value
        None => fail("chat.agent_session.ended record did not decode")
      }
      assert_eq(ended_record.id, session.id)
      assert_eq(ended_record.state, @contracts.AGENT_SESSION_STATE_ENDED)
      let sessions = bots_host_list_chat_sessions(state, chat.id) catch {
        error => fail(error.to_string())
      }
      assert_eq(sessions.length(), 1)
      assert_eq(sessions[0].id, session.id)
      assert_eq(sessions[0].state, @contracts.AGENT_SESSION_STATE_ENDED)
      let get_text = bots_host_call(
        state,
        @contracts.RpcRequest::new(
          "req_session_end_get",
          @contracts.METHOD_CHAT_GET,
          @contracts.chat_get_params("cid_session_end_get", chat.id),
        ),
      ) catch {
        error => fail(error.to_string())
      }
      let detail = match
        @contracts.chat_from_result(bots_host_result(get_text)) {
        Ok(value) => value
        Err(message) => fail("chat.get after end: " + message)
      }
      match detail.active_agent_session {
        Some(_) => fail("ended AgentSession is still returned as active")
        None => ()
      }

      // A repeated end on a terminal session returns the same terminal record
      // and appends no second terminal event.
      let before_repeat = match state.store.last_seq() {
        Ok(value) => value
        Err(message) => fail("last_seq failed: " + message)
      }
      let repeat_text = bots_host_call(
        state,
        @contracts.RpcRequest::new(
          "req_session_end_repeat",
          @contracts.METHOD_CHAT_AGENT_SESSION_END,
          @contracts.chat_agent_session_end_params(
            "cid_session_end_repeat",
            session.id,
            @contracts.AGENT_SESSION_END_REASON_CANCELLED,
          ),
        ),
      ) catch {
        error => fail(error.to_string())
      }
      let repeated = match
        @contracts.chat_agent_session_from_result(
          bots_host_result(repeat_text),
        ) {
        Ok(value) => value
        Err(message) => fail("repeated chat.agent_session.end: " + message)
      }
      assert_eq(repeated.id, session.id)
      assert_eq(repeated.state, @contracts.AGENT_SESSION_STATE_ENDED)
      assert_eq(
        repeated.end_reason,
        @contracts.AGENT_SESSION_END_REASON_TURN_END,
      )
      let repeat_events = bots_host_events_of_type(
        state,
        before_repeat,
        @contracts.EVENT_CHAT_AGENT_SESSION_ENDED,
      ) catch {
        error => fail(error.to_string())
      }
      assert_eq(repeat_events.length(), 0)
      assert_eq(bots_host_runtime_count(state), 0)

      // chat.stop on the terminal session is also idempotent: it reports
      // stopped=false, returns the same terminal record and writes nothing.
      let before_stop_repeat = match state.store.last_seq() {
        Ok(value) => value
        Err(message) => fail("last_seq failed: " + message)
      }
      let stop_repeat_text = bots_host_call(
        state,
        @contracts.RpcRequest::new(
          "req_session_stop_repeat",
          @contracts.METHOD_CHAT_STOP,
          @contracts.chat_stop_params(
            "cid_session_stop_repeat",
            chat.id,
            end_reason=@contracts.AGENT_SESSION_END_REASON_CANCELLED,
            session_id=session.id,
          ),
        ),
      ) catch {
        error => fail(error.to_string())
      }
      let stop_repeat = match
        @contracts.chat_stop_result_from_json(
          bots_host_result(stop_repeat_text),
        ) {
        Some(value) => value
        None => fail("repeated chat.stop result did not decode")
      }
      assert_true(!stop_repeat.stopped)
      assert_eq(stop_repeat.session.id, session.id)
      assert_eq(
        stop_repeat.session.state,
        @contracts.AGENT_SESSION_STATE_ENDED,
      )
      assert_eq(
        stop_repeat.session.end_reason,
        @contracts.AGENT_SESSION_END_REASON_TURN_END,
      )
      let stop_repeat_events = bots_host_events_of_type(
        state,
        before_stop_repeat,
        @contracts.EVENT_CHAT_AGENT_SESSION_ENDED,
      ) catch {
        error => fail(error.to_string())
      }
      assert_eq(stop_repeat_events.length(), 0)
      done.put(())
    })
  })
  match state_ref.val {
    Some(state) => state.store.close()
    None => ()
  }
}

///|
fn bots_handoff_message(
  role : String,
  body : String,
) -> @contracts.ChatMessage {
  @contracts.ChatMessage::new(
    id=@contracts.new_id("msg", 7_200L),
    chat_id="cht_test",
    role~,
    body_ref="",
    body~,
    digest=@contracts.chat_message_digest(body, ""),
    created_at="2026-11-27T06:00:00Z",
  )
}

///|
test "chat handoff prefix is chronological, bounded and excludes system" {
  let messages = [
    bots_handoff_message(
      @contracts.CHAT_MESSAGE_ROLE_SYSTEM,
      "CHAT-SYSTEM-BOUNDARY",
    ),
    bots_handoff_message(@contracts.CHAT_MESSAGE_ROLE_ASSISTANT, "recent"),
    bots_handoff_message(@contracts.CHAT_MESSAGE_ROLE_USER, "older"),
  ]
  let prefix = chat_handoff_prefix(messages)
  assert_true(prefix.contains("user: older"))
  assert_true(prefix.contains("assistant: recent"))
  assert_false(prefix.contains("CHAT-SYSTEM-BOUNDARY"))
  let older_at = match prefix.find("user: older") {
    Some(value) => value
    None => fail("older message missing from the prefix")
  }
  let recent_at = match prefix.find("assistant: recent") {
    Some(value) => value
    None => fail("recent message missing from the prefix")
  }
  assert_true(older_at < recent_at)
  assert_true(
    @utf8.encode(prefix).length() <= CHAT_HANDOFF_CONTEXT_CAP.to_int(),
  )
  let oversized_chunks : Array[String] = []
  for _ in 0..<4_000 {
    oversized_chunks.push("汉")
  }
  let oversized = oversized_chunks.join("")
  let trimmed = chat_handoff_prefix([
    bots_handoff_message(@contracts.CHAT_MESSAGE_ROLE_USER, oversized),
  ])
  let trimmed_bytes = @utf8.encode(trimmed)
  assert_true(trimmed_bytes.length() <= CHAT_HANDOFF_CONTEXT_CAP.to_int())
  assert_eq(
    @utf8.decode_lossy(trimmed_bytes[:], ignore_bom=false),
    trimmed,
  )
  assert_true(trimmed.contains("汉"))
  let newest = "n".repeat(5_000)
  let older = "o".repeat(5_000)
  let newest_first = chat_handoff_prefix([
    bots_handoff_message(@contracts.CHAT_MESSAGE_ROLE_ASSISTANT, newest),
    bots_handoff_message(@contracts.CHAT_MESSAGE_ROLE_USER, older),
  ])
  assert_true(newest_first.contains(newest))
  assert_false(newest_first.contains(older))
  assert_true(
    @utf8.encode(newest_first).length() <= CHAT_HANDOFF_CONTEXT_CAP.to_int(),
  )
}

///|
test "bounded transcript advances the absolute base when trimming the head" {
  let chunk = "x".repeat(131_072)
  let first = transcript_with_append({ base: 7L, text: "abc" }, chunk)
  assert_eq(first.base, 10L)
  assert_eq(first.text.length(), 131_072)
  let second = transcript_with_append(first, "yz")
  assert_eq(second.base, 12L)
  assert_eq(second.text.length(), 131_072)
  assert_true(second.text.has_suffix("yz"))
}

///|
async test "startup reconcile ends interrupted Chat sessions and writes one boundary" {
  let state = host_test_state("/tmp/monexus-host-chat-reconcile-test", false) catch {
    error => fail(error.to_string())
  }
  let now = "2026-11-27T06:10:00Z"
  let bot = { ..bots_host_bot(), agent_concurrency_cap: 4 }
  let agent = bots_host_agent(bot)
  let chats = [
    bots_host_chat("Interrupted active"),
    bots_host_chat("Interrupted waiting"),
    bots_host_chat("Interrupted starting"),
  ]
  state.mutex.acquire()
  let created_bot = match state.store.create_bot(bot, "owner", "test", now) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      fail("cannot create the Bot: " + message)
    }
  }
  let created_agent = match
    state.store.create_agent(agent, "", "owner", "test", now) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      fail("cannot create the Agent: " + message)
    }
  }
  let created_chats : Array[@contracts.ChatRecord] = []
  for chat in chats {
    let created = match
      state.store.create_chat(chat, [created_bot.id], "owner", "test", now) {
      Ok(value) => value
      Err(message) => {
        state.mutex.release()
        fail("cannot create the Chat: " + message)
      }
    }
    created_chats.push(created)
  }
  let active = match
    state.store.start_chat_agent_session(
      @contracts.AgentSession::new(
        id=@contracts.new_agent_session_id(8_100L),
        chat_id=created_chats[0].id,
        agent_id=created_agent.id,
        permission_snapshot_hash="sha256:test",
        started_at=now,
      ),
      "owner",
      now,
    ) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      fail("cannot start active session: " + message)
    }
  }
  let active = match
    state.store.update_chat_agent_session(
      active.id,
      @contracts.AGENT_SESSION_STATE_ACTIVE,
      "ags_active_runtime",
      "",
      0,
      0,
      now,
    ) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      fail("cannot activate session: " + message)
    }
  }
  let waiting = match
    state.store.start_chat_agent_session(
      @contracts.AgentSession::new(
        id=@contracts.new_agent_session_id(8_101L),
        chat_id=created_chats[1].id,
        agent_id=created_agent.id,
        permission_snapshot_hash="sha256:test",
        started_at=now,
      ),
      "owner",
      now,
    ) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      fail("cannot start waiting session: " + message)
    }
  }
  let waiting = match
    state.store.update_chat_agent_session(
      waiting.id,
      @contracts.AGENT_SESSION_STATE_ACTIVE,
      "ags_waiting_runtime",
      "",
      0,
      0,
      now,
    ) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      fail("cannot activate waiting session: " + message)
    }
  }
  let waiting = match
    state.store.update_chat_agent_session(
      waiting.id,
      @contracts.AGENT_SESSION_STATE_WAITING,
      "",
      "",
      0,
      0,
      now,
    ) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      fail("cannot move session to waiting: " + message)
    }
  }
  let starting = match
    state.store.start_chat_agent_session(
      @contracts.AgentSession::new(
        id=@contracts.new_agent_session_id(8_102L),
        chat_id=created_chats[2].id,
        agent_id=created_agent.id,
        permission_snapshot_hash="sha256:test",
        started_at=now,
      ),
      "owner",
      now,
    ) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      fail("cannot start starting session: " + message)
    }
  }
  let decisions = [
    @contracts.DecisionRecord::new(
      id=@contracts.new_id("dec", 8_100L),
      kind=@contracts.DECISION_KIND_PERMISSION,
      title="Active approval",
      detail="pending across restart",
      session_id=active.runtime_session_id,
      agent_id=created_agent.id,
      options=[],
      created_at=now,
    ),
    @contracts.DecisionRecord::new(
      id=@contracts.new_id("dec", 8_101L),
      kind=@contracts.DECISION_KIND_PERMISSION,
      title="Waiting approval",
      detail="pending across restart",
      session_id=waiting.runtime_session_id,
      agent_id=created_agent.id,
      options=[],
      created_at=now,
    ),
    @contracts.DecisionRecord::new(
      id=@contracts.new_id("dec", 8_102L),
      kind=@contracts.DECISION_KIND_PERMISSION,
      title="Starting approval",
      detail="pending across restart",
      session_id=starting.id,
      agent_id=created_agent.id,
      options=[],
      created_at=now,
    ),
  ]
  for decision in decisions {
    match
      state.append_decision_event(
        @contracts.EVENT_DECISION_REQUESTED,
        decision.id,
        @contracts.decision_payload(decision),
        decision,
      ) {
      Ok(_) => ()
      Err(message) => {
        state.mutex.release()
        fail("cannot append pending Decision: " + message)
      }
    }
  }
  state.mutex.release()
  match reconcile_agent_sessions(state) {
    Ok(_) => ()
    Err(message) => fail("startup reconcile failed: " + message)
  }
  let all_sessions = match state.store.list_all_bot_agent_sessions() {
    Ok(value) => value
    Err(message) => fail("list_all_bot_agent_sessions failed: " + message)
  }
  assert_eq(all_sessions.length(), 3)
  for session in all_sessions {
    assert_eq(session.state, @contracts.AGENT_SESSION_STATE_ENDED)
    assert_eq(
      session.end_reason,
      @contracts.AGENT_SESSION_END_REASON_HOST_RESTARTED,
    )
    assert_true(session.ended_at != "")
  }
  let stored_decisions = match state.store.list_decisions("", "") {
    Ok(value) => value
    Err(message) => fail("list_decisions failed: " + message)
  }
  assert_eq(stored_decisions.length(), 3)
  for decision in stored_decisions {
    assert_eq(decision.status, @contracts.DECISION_STATUS_EXPIRED)
  }
  for chat in created_chats {
    let messages = match state.store.list_chat_messages(chat.id, "", 10) {
      Ok(value) => value
      Err(message) => fail("list_chat_messages failed: " + message)
    }
    assert_eq(messages.length(), 1)
    assert_eq(messages[0].role, @contracts.CHAT_MESSAGE_ROLE_SYSTEM)
    assert_eq(messages[0].actor, "host")
    assert_eq(
      messages[0].body,
      @contracts.CHAT_HOST_RESTART_BOUNDARY_BODY,
    )
    assert_true(messages[0].agent_session_id != "")
  }
  // A repeated reconcile must repair nothing into a second boundary.
  match reconcile_agent_sessions(state) {
    Ok(_) => ()
    Err(message) => fail("second startup reconcile failed: " + message)
  }
  for chat in created_chats {
    let messages = match state.store.list_chat_messages(chat.id, "", 10) {
      Ok(value) => value
      Err(message) => fail("second list_chat_messages failed: " + message)
    }
    assert_eq(messages.length(), 1)
  }
  state.store.close()
}

///|
async test "Concurrent Chat agent_session.start yields one active session and one conflict" {
  let dir = @fs.tmpdir(prefix="monexus-bots-session-start-race-") catch {
    _ => fail("cannot create a temp directory")
  }
  defer @async.protect_from_cancel(async fn() {
    @fs.rmdir(dir, recursive=true) catch { _ => () }
  })
  let done : @aqueue.Queue[Unit] = @aqueue.Queue(kind=Unbounded)
  let inner_group : Ref[@async.TaskGroup[Unit]?] = Ref(None)
  let state_ref : Ref[HostState?] = Ref(None)
  @async.with_task_group(async fn(outer) {
    outer.spawn_bg(
      no_wait=true,
      allow_failure=true,
      async fn() {
        done.get()
        match inner_group.val {
          Some(inner) => inner.return_immediately(())
          None => ()
        }
      },
    )
    @async.with_task_group(async fn(group) {
      let state = host_test_state(dir + "/state", false) catch {
        error => fail(error.to_string())
      }
      state_ref.val = Some(state)
      state.group.val = Some(group)
      inner_group.val = Some(group)
      let script = bots_host_repo_file("tests/agent/mock_acp_agent.mjs") catch {
        error => fail(error.to_string())
      }
      let (_, agent, chat, workspace) = bots_host_seed_runtime_chat(
        state,
        dir,
        "2026-11-27T06:40:00Z",
        7_500L,
        "node",
        [script],
      ) catch {
        error => fail(error.to_string())
      }
      let start_params = fn(client_request_id : String) {
        @contracts.chat_agent_session_start_params(
          client_request_id,
          chat.id,
          agent.id,
          workspace.id,
          workspace.root,
        )
      }
      let request_one = @contracts.RpcRequest::new(
        "req_concurrent_start_one",
        @contracts.METHOD_CHAT_AGENT_SESSION_START,
        start_params("cid_concurrent_start_one"),
      )
      let request_two = @contracts.RpcRequest::new(
        "req_concurrent_start_two",
        @contracts.METHOD_CHAT_AGENT_SESSION_START,
        start_params("cid_concurrent_start_two"),
      )
      let results : @aqueue.Queue[String] = @aqueue.Queue(kind=Unbounded)
      let finished : Ref[Bool] = Ref(false)
      let max_runtimes : Ref[Int] = Ref(0)
      // Sample the live runtime map while both starts are in flight so a
      // second runtime from a leaked loser would be observed directly.
      group.spawn_bg(
        no_wait=true,
        allow_failure=true,
        async fn() {
          while true {
            let count = bots_host_runtime_count(state)
            if count > max_runtimes.val {
              max_runtimes.val = count
            }
            if finished.val {
              break
            }
            @async.sleep(1)
          }
        },
      )
      group.spawn_bg(
        no_wait=true,
        allow_failure=true,
        async fn() {
          let sink = host_test_sink()
          handle_request(state, sink, request_one)
          let text = sink.queue.get() catch { _ => "" }
          results.put(text)
        },
      )
      group.spawn_bg(
        no_wait=true,
        allow_failure=true,
        async fn() {
          let sink = host_test_sink()
          handle_request(state, sink, request_two)
          let text = sink.queue.get() catch { _ => "" }
          results.put(text)
        },
      )
      let text_one = results.get() catch { _ => fail("no response for start one") }
      let text_two = results.get() catch { _ => fail("no response for start two") }
      finished.val = true
      @async.sleep(20)
      let response_one = bots_host_response(text_one) catch {
        error => fail(error.to_string())
      }
      let response_two = bots_host_response(text_two) catch {
        error => fail(error.to_string())
      }
      let mut winner_text = ""
      let mut loser_text = ""
      match (response_one.error, response_two.error) {
        (None, Some(_)) => {
          winner_text = text_one
          loser_text = text_two
        }
        (Some(_), None) => {
          winner_text = text_two
          loser_text = text_one
        }
        _ => fail("expected exactly one successful concurrent start")
      }
      let loser_error = bots_host_error(loser_text)
      assert_eq(bots_host_error_kind(loser_error), "conflict")
      assert_true(loser_error.message.contains("at most one"))
      let winner = match
        @contracts.chat_agent_session_from_result(
          bots_host_result(winner_text),
        ) {
        Ok(value) => value
        Err(message) => fail("winning chat.agent_session.start: " + message)
      }
      assert_eq(winner.state, @contracts.AGENT_SESSION_STATE_ACTIVE)
      let sessions = bots_host_list_chat_sessions(state, chat.id) catch {
        error => fail(error.to_string())
      }
      assert_eq(sessions.length(), 1)
      assert_eq(sessions[0].id, winner.id)
      assert_eq(sessions[0].state, @contracts.AGENT_SESSION_STATE_ACTIVE)
      assert_true(bots_host_has_runtime(state, winner.runtime_session_id))
      assert_eq(bots_host_runtime_count(state), 1)
      assert_true(max_runtimes.val >= 1)
      assert_true(max_runtimes.val <= 1)
      // End the winner so the fixture leaves no runtime behind.
      let end_text = bots_host_call(
        state,
        @contracts.RpcRequest::new(
          "req_concurrent_start_end",
          @contracts.METHOD_CHAT_AGENT_SESSION_END,
          @contracts.chat_agent_session_end_params(
            "cid_concurrent_start_end",
            winner.id,
            @contracts.AGENT_SESSION_END_REASON_TURN_END,
          ),
        ),
      ) catch {
        error => fail(error.to_string())
      }
      let ended = match
        @contracts.chat_agent_session_from_result(bots_host_result(end_text)) {
        Ok(value) => value
        Err(message) => fail("winner chat.agent_session.end: " + message)
      }
      assert_eq(ended.state, @contracts.AGENT_SESSION_STATE_ENDED)
      assert_eq(bots_host_runtime_count(state), 0)
      done.put(())
    })
  })
  match state_ref.val {
    Some(state) => state.store.close()
    None => ()
  }
}

///|
async test "Chat agent_session.end during start fails the session and stops the runtime" {
  let dir = @fs.tmpdir(prefix="monexus-bots-session-start-end-race-") catch {
    _ => fail("cannot create a temp directory")
  }
  defer @async.protect_from_cancel(async fn() {
    @fs.rmdir(dir, recursive=true) catch { _ => () }
  })
  let done : @aqueue.Queue[Unit] = @aqueue.Queue(kind=Unbounded)
  let inner_group : Ref[@async.TaskGroup[Unit]?] = Ref(None)
  let state_ref : Ref[HostState?] = Ref(None)
  @async.with_task_group(async fn(outer) {
    outer.spawn_bg(
      no_wait=true,
      allow_failure=true,
      async fn() {
        done.get()
        match inner_group.val {
          Some(inner) => inner.return_immediately(())
          None => ()
        }
      },
    )
    @async.with_task_group(async fn(group) {
      let state = host_test_state(dir + "/state", false) catch {
        error => fail(error.to_string())
      }
      state_ref.val = Some(state)
      state.group.val = Some(group)
      inner_group.val = Some(group)
      let now = "2026-11-27T06:55:00Z"
      let script = bots_host_repo_file("tests/agent/mock_acp_agent.mjs") catch {
        error => fail(error.to_string())
      }
      // Delay the ACP handshake so the Bot session remains `starting` while
      // the end request runs; the runtime launch itself happens outside the
      // host mutex.
      let (_, agent, chat, workspace) = bots_host_seed_runtime_chat(
        state,
        dir,
        now,
        7_550L,
        "sh",
        ["-c", "sleep 1; exec node " + script],
      ) catch {
        error => fail(error.to_string())
      }
      let start_queue : @aqueue.Queue[String] = @aqueue.Queue(kind=Unbounded)
      group.spawn_bg(
        no_wait=true,
        allow_failure=true,
        async fn() {
          let sink = host_test_sink()
          handle_request(
            state,
            sink,
            @contracts.RpcRequest::new(
              "req_session_start_end_race",
              @contracts.METHOD_CHAT_AGENT_SESSION_START,
              @contracts.chat_agent_session_start_params(
                "cid_session_start_end_race",
                chat.id,
                agent.id,
                workspace.id,
                workspace.root,
              ),
            ),
          )
          let text = sink.queue.get() catch { _ => "" }
          start_queue.put(text)
        },
      )
      let starting_deadline = @async.now() + 10_000L
      let mut starting : @contracts.AgentSession? = None
      while @async.now() < starting_deadline {
        let sessions = bots_host_list_chat_sessions(state, chat.id) catch {
          error => fail(error.to_string())
        }
        if sessions.length() == 1 &&
          sessions[0].state == @contracts.AGENT_SESSION_STATE_STARTING {
          starting = Some(sessions[0])
          break
        }
        @async.sleep(5)
      }
      let target = match starting {
        Some(value) => value
        None => fail("start never exposed a starting AgentSession")
      }
      let end_text = bots_host_call(
        state,
        @contracts.RpcRequest::new(
          "req_session_start_end_race_end",
          @contracts.METHOD_CHAT_AGENT_SESSION_END,
          @contracts.chat_agent_session_end_params(
            "cid_session_start_end_race_end",
            target.id,
            @contracts.AGENT_SESSION_END_REASON_TURN_END,
          ),
        ),
      ) catch {
        error => fail(error.to_string())
      }
      let ended = match
        @contracts.chat_agent_session_from_result(bots_host_result(end_text)) {
        Ok(value) => value
        Err(message) => fail("chat.agent_session.end during start: " + message)
      }
      assert_eq(ended.id, target.id)
      assert_eq(ended.state, @contracts.AGENT_SESSION_STATE_FAILED)
      let start_response = match
        @async.with_timeout_opt(15_000, async fn() { start_queue.get() }) {
        Some(value) => value
        None => fail("start did not respond after the end won")
      }
      let start_error = bots_host_error(start_response)
      assert_true(start_error.message.contains("transition"))
      assert_eq(bots_host_runtime_count(state), 0)
      let sessions = bots_host_list_chat_sessions(state, chat.id) catch {
        error => fail(error.to_string())
      }
      assert_eq(sessions.length(), 1)
      assert_eq(sessions[0].id, target.id)
      assert_eq(sessions[0].state, @contracts.AGENT_SESSION_STATE_FAILED)
      let get_text = bots_host_call(
        state,
        @contracts.RpcRequest::new(
          "req_session_start_end_race_get",
          @contracts.METHOD_CHAT_GET,
          @contracts.chat_get_params("cid_session_start_end_race_get", chat.id),
        ),
      ) catch {
        error => fail(error.to_string())
      }
      let detail = match
        @contracts.chat_from_result(bots_host_result(get_text)) {
        Ok(value) => value
        Err(message) => fail("chat.get after start/end race: " + message)
      }
      match detail.active_agent_session {
        Some(_) => fail("failed AgentSession is still returned as active")
        None => ()
      }
      done.put(())
    })
  })
  match state_ref.val {
    Some(state) => state.store.close()
    None => ()
  }
}

///|
async test "Chat agent_session.start failure records a failed session and no runtime" {
  let dir = @fs.tmpdir(prefix="monexus-bots-session-start-fail-") catch {
    _ => fail("cannot create a temp directory")
  }
  defer @async.protect_from_cancel(async fn() {
    @fs.rmdir(dir, recursive=true) catch { _ => () }
  })
  let done : @aqueue.Queue[Unit] = @aqueue.Queue(kind=Unbounded)
  let inner_group : Ref[@async.TaskGroup[Unit]?] = Ref(None)
  let state_ref : Ref[HostState?] = Ref(None)
  @async.with_task_group(async fn(outer) {
    outer.spawn_bg(
      no_wait=true,
      allow_failure=true,
      async fn() {
        done.get()
        match inner_group.val {
          Some(inner) => inner.return_immediately(())
          None => ()
        }
      },
    )
    @async.with_task_group(async fn(group) {
      let state = host_test_state(dir + "/state", false) catch {
        error => fail(error.to_string())
      }
      state_ref.val = Some(state)
      state.group.val = Some(group)
      inner_group.val = Some(group)
      let now = "2026-11-27T07:00:00Z"
      let (bot, failing_agent, chat, workspace) = bots_host_seed_runtime_chat(
        state,
        dir,
        now,
        7_600L,
        "node",
        ["-e", "process.exit(1)"],
      ) catch {
        error => fail(error.to_string())
      }
      let start_text = bots_host_call(
        state,
        @contracts.RpcRequest::new(
          "req_session_start_fail",
          @contracts.METHOD_CHAT_AGENT_SESSION_START,
          @contracts.chat_agent_session_start_params(
            "cid_session_start_fail",
            chat.id,
            failing_agent.id,
            workspace.id,
            workspace.root,
          ),
        ),
      ) catch {
        error => fail(error.to_string())
      }
      let start_error = bots_host_error(start_text)
      assert_true(start_error.message.contains("runtime start failed"))
      let sessions = bots_host_list_chat_sessions(state, chat.id) catch {
        error => fail(error.to_string())
      }
      assert_eq(sessions.length(), 1)
      assert_eq(sessions[0].state, @contracts.AGENT_SESSION_STATE_FAILED)
      assert_eq(
        sessions[0].end_reason,
        @contracts.AGENT_SESSION_END_REASON_ERROR,
      )
      assert_eq(sessions[0].runtime_session_id, "")
      assert_eq(bots_host_runtime_count(state), 0)

      // The failed session is terminal, but M1 still forbids switching the
      // Agent inside one Chat: the owner must start a new Chat.
      let script = bots_host_repo_file("tests/agent/mock_acp_agent.mjs") catch {
        error => fail(error.to_string())
      }
      let healthy_agent = @contracts.AgentRecord::new(
        id=@contracts.new_agent_id(7_603L),
        org_id=bot.org_id,
        bot_id=bot.id,
        name="Host Runtime Healthy Worker",
        runtime_binding=bots_host_binding([script]),
        created_at=now,
        permission_scope=["repo:read"],
        state=@contracts.AGENT_LIFECYCLE_ACTIVE,
      )
      state.mutex.acquire()
      match
        state.store.create_agent(healthy_agent, "", "owner", "test", now) {
      Ok(_) => ()
      Err(message) => {
        state.mutex.release()
        fail("cannot create the healthy Agent: " + message)
      }
      }
      state.mutex.release()
      let retry_text = bots_host_call(
        state,
        @contracts.RpcRequest::new(
          "req_session_start_retry",
          @contracts.METHOD_CHAT_AGENT_SESSION_START,
          @contracts.chat_agent_session_start_params(
            "cid_session_start_retry",
            chat.id,
            healthy_agent.id,
            workspace.id,
            workspace.root,
          ),
        ),
      ) catch {
        error => fail(error.to_string())
      }
      let retry_error = bots_host_error(retry_text)
      assert_true(retry_error.message.contains("Conflict"))
      assert_true(retry_error.message.contains("Agent switching is P1"))
      assert_eq(bots_host_runtime_count(state), 0)
      let retry_sessions = bots_host_list_chat_sessions(state, chat.id) catch {
        error => fail(error.to_string())
      }
      assert_eq(retry_sessions.length(), 1)
      assert_eq(retry_sessions[0].state, @contracts.AGENT_SESSION_STATE_FAILED)
      done.put(())
    })
  })
  match state_ref.val {
    Some(state) => state.store.close()
    None => ()
  }
}
