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

    // A host restart drops the in-memory runtime and transcript. chat.read
    // must not reset the client cursor or invent text when both are missing.
    state.mutex.acquire()
    state.agent_transcripts.remove(session.runtime_session_id)
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
