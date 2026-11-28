///|
/// M1a-3 whitebox tests: Chat AgentSessions run in isolated worktrees, Git
/// review reads that worktree only, and removal refuses live Chat sessions.

///|
async fn wt_host_state(dir : String) -> HostState raise {
  @fs.mkdir(dir, permission=0o700, recursive=true, allow_exist=true) catch {
    error => fail("cannot create state dir: " + error.to_string())
  }
  let store = match @machines.MachineStore::open(":memory:") {
    Ok(value) => value
    Err(message) => fail("cannot open store: " + message)
  }
  let options = HostOptions::new(state_dir=dir, trigger_enabled=false)
  let verifier : @recipes.VerifierProbe = {
    tool: "",
    found: false,
    version: "",
    supports_signatures: false,
    usable: false,
    detail: "not probed in unit test",
  }
  HostState::new(options, 0, store, @recipes.TrustStore::empty(), verifier)
}

///|
fn wt_host_sink() -> Sink {
  let queue : @aqueue.Queue[String] = @aqueue.Queue(kind=Unbounded)
  { queue, subscribed: Ref(false), closed: Ref(false) }
}

///|
async fn wt_host_call(
  state : HostState,
  request : @contracts.RpcRequest,
) -> String raise {
  let sink = wt_host_sink()
  handle_request(state, sink, request)
  sink.queue.get() catch { _ => fail("no RPC response") }
}

///|
fn wt_host_response(text : String) -> @contracts.RpcResponse raise {
  let json = @json.parse(text) catch {
    _ => fail("RPC response is not JSON: " + text)
  }
  match @contracts.parse_response(json) {
    Ok(value) => value
    Err(message) => fail("RPC response is malformed: " + message)
  }
}

///|
fn wt_host_result(text : String) -> @json.Json raise {
  let response = wt_host_response(text)
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
fn wt_host_error(text : String) -> @contracts.RpcError raise {
  let response = wt_host_response(text)
  match response.error {
    Some(error) => error
    None => fail("RPC response has no error")
  }
}

///|
async fn wt_repo_file(relative : String) -> String raise {
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
fn wt_workspace(
  id : String,
  machine_id : String,
  root : String,
  now : String,
) -> @contracts.WorkspaceRecord {
  {
    id,
    machine_id,
    kind: @contracts.WORKSPACE_KIND_LOCAL,
    root,
    name: "Worktree Test",
    git_root: "",
    is_git: false,
    state: @contracts.WORKSPACE_STATE_AVAILABLE,
    created_at: now,
    updated_at: now,
  }
}

///|
fn wt_worktree(
  id : String,
  workspace_id : String,
  machine_id : String,
  branch : String,
  path : String,
  state : String,
  now : String,
) -> @contracts.WorktreeRecord {
  {
    id,
    workspace_id,
    machine_id,
    branch,
    path,
    base: "",
    state,
    created_at: now,
    updated_at: now,
  }
}

///|
async fn wt_seed_workspace(
  state : HostState,
  record : @contracts.WorkspaceRecord,
) -> Unit raise {
  state.mutex.acquire()
  let result = state.append_workspace_event(
    @contracts.EVENT_WORKSPACE_OPENED,
    "workspace/" + record.id,
    @contracts.workspace_event_payload(record),
    Some(record),
    None,
  )
  state.mutex.release()
  match result {
    Ok(_) => ()
    Err(message) => fail("cannot seed workspace: " + message)
  }
}

///|
async fn wt_seed_worktree(
  state : HostState,
  record : @contracts.WorktreeRecord,
) -> Unit raise {
  state.mutex.acquire()
  let result = state.store.put_worktree(record)
  state.mutex.release()
  match result {
    Ok(_) => ()
    Err(message) => fail("cannot seed worktree: " + message)
  }
}

///|
async fn wt_seed_chat(
  state : HostState,
  workspace : @contracts.WorkspaceRecord,
  seed : Int64,
  now : String,
  args : Array[String],
) -> (
  @contracts.BotRecord,
  @contracts.AgentRecord,
  @contracts.ChatRecord,
) raise {
  let bot = @contracts.BotRecord::new(
    id=@contracts.new_bot_id(seed),
    org_id=@contracts.ORG_LOCAL,
    name="Worktree Bot " + seed.to_string(),
    created_at=now,
    memory_ref="bot/worktree/memory",
    home="/tmp/monexus-worktree-bot-" + seed.to_string(),
    permission_ceiling=["repo:read", "tool:shell"],
    create_policy=@contracts.BOT_CREATE_POLICY_AUTO,
    agent_count_cap=4,
    agent_concurrency_cap=2,
    software_allowlist=["mock-acp"],
  )
  let agent = @contracts.AgentRecord::new(
    id=@contracts.new_agent_id(seed + 1L),
    org_id=bot.org_id,
    bot_id=bot.id,
    name="Worktree Worker " + seed.to_string(),
    runtime_binding=@contracts.RuntimeBinding::new(
      software_id="mock-acp",
      adapter_id="acp",
      launch_kind=@contracts.RUNTIME_LAUNCH_ACP,
      command="node",
      args~,
      model_profile="test",
      hash="sha256:worktree-binding-" + seed.to_string(),
    ),
    created_at=now,
    permission_scope=["repo:read"],
    state=@contracts.AGENT_LIFECYCLE_ACTIVE,
  )
  let chat = @contracts.ChatRecord::new(
    id=@contracts.new_chat_id(seed + 2L),
    org_id=@contracts.ORG_LOCAL,
    title="Worktree Chat " + seed.to_string(),
    created_at=now,
  )
  state.mutex.acquire()
  let created_bot = match state.store.create_bot(bot, "owner", "test", now) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      fail("cannot create Bot: " + message)
    }
  }
  let created_agent = match
    state.store.create_agent(agent, "", "owner", "test", now) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      fail("cannot create Agent: " + message)
    }
  }
  let created_chat = match
    state.store.create_chat(chat, [created_bot.id], "owner", "test", now) {
    Ok(value) => value
    Err(message) => {
      state.mutex.release()
      fail("cannot create Chat: " + message)
    }
  }
  state.mutex.release()
  (created_bot, created_agent, created_chat)
}

///|
async fn wt_seed_session(
  state : HostState,
  chat : @contracts.ChatRecord,
  agent : @contracts.AgentRecord,
  workspace : @contracts.WorkspaceRecord,
  worktree_id : String,
  session_root : String,
  seed : Int64,
  now : String,
) -> @contracts.AgentSession raise {
  let session = @contracts.AgentSession::new(
    id=@contracts.new_agent_session_id(seed),
    chat_id=chat.id,
    agent_id=agent.id,
    permission_snapshot_hash="sha256:worktree-permission",
    started_at=now,
    project_id=chat.project_id,
    workspace_id=workspace.id,
    workspace_root=session_root,
    worktree_id~,
  )
  state.mutex.acquire()
  let result = state.store.start_chat_agent_session(session, "owner", now)
  state.mutex.release()
  match result {
    Ok(value) => value
    Err(message) => fail("cannot seed AgentSession: " + message)
  }
}

///|
async fn wt_git(cwd : String, args : Array[String]) -> String raise {
  let env : Map[String, String] = Map([])
  env["GIT_CONFIG_NOSYSTEM"] = "1"
  env["GIT_CONFIG_GLOBAL"] = "/dev/null"
  env["LC_ALL"] = "C"
  let (code, out, err) = @process.collect_output(
    "git",
    args,
    cwd=cwd,
    extra_env=env,
    inherit_env=true,
  ) catch {
    _ => fail("cannot spawn git")
  }
  if code != 0 {
    fail("git " + args.join(" ") + " failed: " + err.text())
  }
  out.text()
}

///|
async fn wt_git_repo(dir : String) -> (String, String) raise {
  let root = dir + "/repo"
  @fs.mkdir(root, permission=0o700, recursive=true, allow_exist=true) catch {
    error => fail("cannot create repo: " + error.to_string())
  }
  let _ = wt_git(root, ["init"])
  let _ = wt_git(root, ["config", "user.email", "test@example.invalid"])
  let _ = wt_git(root, ["config", "user.name", "MoNexus Test"])
  @fs.write_file(root + "/tracked.txt", "base\n", permission=0o644) catch {
    error => fail("cannot write tracked file: " + error.to_string())
  }
  let _ = wt_git(root, ["add", "tracked.txt"])
  let _ = wt_git(root, ["commit", "-m", "initial"])
  let worktree = dir + "/worktree"
  let _ = wt_git(root, [
    "worktree", "add", "-b", "wt-test", worktree,
  ])
  (root, worktree)
}

///|
fn wt_has_change(
  status : @contracts.GitStatus,
  path : String,
) -> Bool {
  let mut found = false
  for change in status.changes {
    if change.path == path {
      found = true
    }
  }
  found
}

///|
async fn wt_start_session(
  state : HostState,
  request_id : String,
  chat_id : String,
  agent_id : String,
  workspace_id : String,
  worktree_id : String,
) -> String raise {
  wt_host_call(
    state,
    @contracts.RpcRequest::new(
      request_id,
      @contracts.METHOD_CHAT_AGENT_SESSION_START,
      @contracts.chat_agent_session_start_params(
        request_id + "-cid",
        chat_id,
        agent_id,
        workspace_id,
        "",
        worktree_id~,
      ),
    ),
  )
}

///|
async test "chat.agent_session.start validates worktree existence, scope, readiness, path and machine" {
  let dir = @fs.tmpdir(prefix="monexus-wt-start-validate-") catch {
    error => fail(error.to_string())
  }
  defer @fs.rmdir(dir, recursive=true)
  let state = wt_host_state(dir + "/state") catch {
    error => fail(error.to_string())
  }
  let now = "2026-12-01T00:00:00Z"
  let workspace = wt_workspace("ws_wt_validate", "", dir + "/workspace", now)
  wt_seed_workspace(state, workspace) catch {
    error => fail(error.to_string())
  }
  @fs.mkdir(workspace.root, permission=0o700, recursive=true, allow_exist=true)
    catch {
      error => fail(error.to_string())
    }
  let (_, agent, chat) = wt_seed_chat(
    state,
    workspace,
    31_000L,
    now,
    ["tests/agent/mock_acp_agent.mjs"],
  ) catch {
    error => fail(error.to_string())
  }
  let worktrees = [
    wt_worktree(
      "wt_cross",
      "ws_other",
      "",
      "monexus/cross",
      dir + "/wt-cross",
      @contracts.WORKTREE_STATE_READY,
      now,
    ),
    wt_worktree(
      "wt_archived",
      workspace.id,
      "",
      "monexus/archived",
      dir + "/wt-archived",
      @contracts.WORKTREE_STATE_ARCHIVED,
      now,
    ),
    wt_worktree(
      "wt_empty",
      workspace.id,
      "",
      "monexus/empty",
      "",
      @contracts.WORKTREE_STATE_READY,
      now,
    ),
    wt_worktree(
      "wt_relative",
      workspace.id,
      "",
      "monexus/relative",
      "relative/worktree",
      @contracts.WORKTREE_STATE_READY,
      now,
    ),
    wt_worktree(
      "wt_machine",
      workspace.id,
      "mch_other",
      "monexus/machine",
      dir + "/wt-machine",
      @contracts.WORKTREE_STATE_READY,
      now,
    ),
  ]
  for record in worktrees {
    wt_seed_worktree(state, record) catch {
      error => fail(error.to_string())
    }
  }

  let cross = wt_host_error(
    wt_start_session(
      state,
      "req-wt-cross",
      chat.id,
      agent.id,
      workspace.id,
      "wt_cross",
    ) catch {
      error => fail(error.to_string())
    },
  )
  assert_true(cross.message.contains("Conflict"))
  assert_true(cross.message.contains("does not belong"))

  let archived = wt_host_error(
    wt_start_session(
      state,
      "req-wt-archived",
      chat.id,
      agent.id,
      workspace.id,
      "wt_archived",
    ) catch {
      error => fail(error.to_string())
    },
  )
  assert_true(archived.message.contains("Conflict"))
  assert_true(archived.message.contains("not ready"))

  for id in ["wt_empty", "wt_relative"] {
    let error = wt_host_error(
      wt_start_session(
        state,
        "req-" + id,
        chat.id,
        agent.id,
        workspace.id,
        id,
      ) catch {
        error => fail(error.to_string())
      },
    )
    assert_true(error.message.contains("InvalidRequest"))
    assert_true(error.message.contains("absolute"))
  }

  let machine = wt_host_error(
    wt_start_session(
      state,
      "req-wt-machine",
      chat.id,
      agent.id,
      workspace.id,
      "wt_machine",
    ) catch {
      error => fail(error.to_string())
    },
  )
  assert_true(machine.message.contains("Conflict"))
  assert_true(machine.message.contains("machine"))

  let missing = wt_host_error(
    wt_start_session(
      state,
      "req-wt-missing",
      chat.id,
      agent.id,
      workspace.id,
      "wt_missing",
    ) catch {
      error => fail(error.to_string())
    },
  )
  assert_true(missing.message.contains("NotFound"))
  assert_true(missing.message.contains("Worktree not found"))

  state.mutex.acquire()
  let sessions = state.store.list_chat_agent_sessions(chat.id)
  state.mutex.release()
  match sessions {
    Ok(value) => assert_eq(value.length(), 0)
    Err(message) => fail(message)
  }
}

///|
async test "chat.agent_session.start runs in the selected worktree and refuses Agent switching" {
  let dir = @fs.tmpdir(prefix="monexus-wt-start-runtime-") catch {
    error => fail(error.to_string())
  }
  defer @fs.rmdir(dir, recursive=true)
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
  let state = wt_host_state(dir + "/state") catch {
    error => fail(error.to_string())
  }
  state_ref.val = Some(state)
  state.group.val = Some(group)
  inner_group.val = Some(group)
  let now = "2026-12-01T01:00:00Z"
  let root = dir + "/workspace"
  @fs.mkdir(root, permission=0o700, recursive=true, allow_exist=true) catch {
    error => fail(error.to_string())
  }
  let workspace = wt_workspace("ws_wt_runtime", "", root, now)
  wt_seed_workspace(state, workspace) catch {
    error => fail(error.to_string())
  }
  let script = wt_repo_file("tests/agent/mock_acp_agent.mjs") catch {
    error => fail(error.to_string())
  }
  let (bot, agent, chat) = wt_seed_chat(
    state,
    workspace,
    32_000L,
    now,
    [script, "--cwd"],
  ) catch {
    error => fail(error.to_string())
  }
  let second_agent = @contracts.AgentRecord::new(
    id=@contracts.new_agent_id(32_101L),
    org_id=bot.org_id,
    bot_id=bot.id,
    name="Second Worktree Worker",
    runtime_binding=@contracts.RuntimeBinding::new(
      software_id="mock-acp",
      adapter_id="acp",
      launch_kind=@contracts.RUNTIME_LAUNCH_ACP,
      command="node",
      args=[script, "--cwd"],
      model_profile="test",
      hash="sha256:worktree-second-binding",
    ),
    created_at=now,
    permission_scope=["repo:read"],
    state=@contracts.AGENT_LIFECYCLE_ACTIVE,
  )
  state.mutex.acquire()
  let created_second = state.store.create_agent(
    second_agent,
    "",
    "owner",
    "test",
    now,
  )
  state.mutex.release()
  match created_second {
    Ok(_) => ()
    Err(message) => fail("cannot create second Agent: " + message)
  }
  let worktree_path = dir + "/worktree-runtime"
  @fs.mkdir(
    worktree_path,
    permission=0o700,
    recursive=true,
    allow_exist=true,
  ) catch {
    error => fail(error.to_string())
  }
  let worktree = wt_worktree(
    "wt_runtime",
    workspace.id,
    "",
    "monexus/runtime",
    worktree_path,
    @contracts.WORKTREE_STATE_READY,
    now,
  )
  wt_seed_worktree(state, worktree) catch {
    error => fail(error.to_string())
  }

  let start_text = wt_start_session(
    state,
    "req-wt-runtime-start",
    chat.id,
    agent.id,
    workspace.id,
    worktree.id,
  ) catch {
    error => fail(error.to_string())
  }
  let session = match
    @contracts.chat_agent_session_from_result(wt_host_result(start_text)) {
    Ok(value) => value
    Err(message) => fail("chat.agent_session.start result: " + message)
  }
  assert_eq(session.state, @contracts.AGENT_SESSION_STATE_ACTIVE)
  assert_eq(session.workspace_id, workspace.id)
  assert_eq(session.workspace_root, worktree.path)
  assert_eq(session.worktree_id, worktree.id)

  @async.sleep(500)
  let send_text = wt_host_call(
    state,
    @contracts.RpcRequest::new(
      "req-wt-send",
      @contracts.METHOD_CHAT_SEND,
      @contracts.chat_send_params(
        "cid-wt-send",
        chat.id,
        "hello worktree",
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let sent = match
    @contracts.chat_send_result_from_json(wt_host_result(send_text)) {
    Some(value) => value
    None => fail("chat.send result did not decode")
  }
  assert_eq(sent.session.worktree_id, worktree.id)

  let mut cursor = 0L
  let mut transcript = ""
  let deadline = @async.now() + 10_000L
  let mut attempt = 0
  while @async.now() < deadline {
    let read_text = wt_host_call(
      state,
      @contracts.RpcRequest::new(
        "req-wt-read-" + attempt.to_string(),
        @contracts.METHOD_CHAT_READ,
        @contracts.chat_read_params(
          "cid-wt-read-" + attempt.to_string(),
          chat.id,
          cursor,
        ),
      ),
    ) catch {
      error => fail(error.to_string())
    }
    let read = match
      @contracts.chat_read_result_from_json(wt_host_result(read_text)) {
      Some(value) => value
      None => fail("chat.read result did not decode")
    }
    transcript = transcript + read.text
    cursor = read.cursor
    if transcript.contains("CWD=") && transcript.contains("done") {
      break
    }
    attempt = attempt + 1
    @async.sleep(50)
  }
  let real_worktree_path = @fs.realpath(worktree.path) catch {
    error => fail("cannot resolve worktree path: " + error.to_string())
  }
  assert_true(transcript.contains("CWD=" + real_worktree_path))

  let end_text = wt_host_call(
    state,
    @contracts.RpcRequest::new(
      "req-wt-end",
      @contracts.METHOD_CHAT_AGENT_SESSION_END,
      @contracts.chat_agent_session_end_params(
        "cid-wt-end",
        session.id,
        @contracts.AGENT_SESSION_END_REASON_TURN_END,
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let ended = match
    @contracts.chat_agent_session_from_result(wt_host_result(end_text)) {
    Ok(value) => value
    Err(message) => fail("chat.agent_session.end result: " + message)
  }
  assert_eq(ended.state, @contracts.AGENT_SESSION_STATE_ENDED)

  let switch_error = wt_host_error(
    wt_start_session(
      state,
      "req-wt-switch",
      chat.id,
      second_agent.id,
      workspace.id,
      worktree.id,
    ) catch {
      error => fail(error.to_string())
    },
  )
  assert_true(switch_error.message.contains("Conflict"))
  assert_true(switch_error.message.contains("Agent switching is P1"))
  assert_true(switch_error.message.contains("start a new Chat"))

  state.mutex.acquire()
  let sessions = state.store.list_chat_agent_sessions(chat.id)
  state.mutex.release()
  match sessions {
    Ok(value) => assert_eq(value.length(), 1)
    Err(message) => fail(message)
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
async test "workspace.gitStatus and gitDiff root at the worktree and ignore the main checkout" {
  let dir = @fs.tmpdir(prefix="monexus-wt-git-review-") catch {
    error => fail(error.to_string())
  }
  defer @fs.rmdir(dir, recursive=true)
  let (root, worktree_path) = wt_git_repo(dir) catch {
    error => fail(error.to_string())
  }
  let now = "2026-12-01T02:00:00Z"
  let state = wt_host_state(dir + "/state") catch {
    error => fail(error.to_string())
  }
  let workspace = wt_workspace("ws_wt_git", "", root, now)
  wt_seed_workspace(state, workspace) catch {
    error => fail(error.to_string())
  }
  let worktree = wt_worktree(
    "wt_git",
    workspace.id,
    "",
    "wt-test",
    worktree_path,
    @contracts.WORKTREE_STATE_READY,
    now,
  )
  wt_seed_worktree(state, worktree) catch {
    error => fail(error.to_string())
  }
  @fs.write_file(root + "/main-only.txt", "main\n", permission=0o644) catch {
    error => fail("cannot write main change: " + error.to_string())
  }
  @fs.write_file(
    root + "/tracked.txt",
    "base\nmain-change\n",
    permission=0o644,
  ) catch {
    error => fail("cannot modify main tracked file: " + error.to_string())
  }
  @fs.write_file(
    worktree_path + "/worktree-only.txt",
    "worktree\n",
    permission=0o644,
  ) catch {
    error => fail("cannot write worktree change: " + error.to_string())
  }
  @fs.write_file(
    worktree_path + "/tracked.txt",
    "base\nworktree-change\n",
    permission=0o644,
  ) catch {
    error => fail("cannot modify worktree tracked file: " + error.to_string())
  }

  let worktree_status_text = wt_host_call(
    state,
    @contracts.RpcRequest::new(
      "req-wt-status",
      @contracts.METHOD_WORKSPACE_GIT_STATUS,
      @contracts.workspace_git_status_params(
        "cid-wt-status",
        workspace.id,
        worktree_id=worktree.id,
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let worktree_status = match
    @contracts.git_status_result_value(wt_host_result(worktree_status_text)) {
    Ok(value) => value
    Err(message) => fail("gitStatus result: " + message)
  }
  assert_true(worktree_status.is_git)
  assert_eq(worktree_status.branch, "wt-test")
  assert_true(wt_has_change(worktree_status, "worktree-only.txt"))
  assert_true(!wt_has_change(worktree_status, "main-only.txt"))

  let worktree_diff_text = wt_host_call(
    state,
    @contracts.RpcRequest::new(
      "req-wt-diff",
      @contracts.METHOD_WORKSPACE_GIT_DIFF,
      @contracts.workspace_git_diff_params(
        "cid-wt-diff",
        workspace.id,
        "",
        false,
        "",
        worktree_id=worktree.id,
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let worktree_diff = match
    @contracts.git_diff_result_value(wt_host_result(worktree_diff_text)) {
    Ok(value) => value
    Err(message) => fail("gitDiff result: " + message)
  }
  assert_true(worktree_diff.text.contains("+worktree-change"))
  assert_true(!worktree_diff.text.contains("+main-change"))

  let main_status_text = wt_host_call(
    state,
    @contracts.RpcRequest::new(
      "req-main-status",
      @contracts.METHOD_WORKSPACE_GIT_STATUS,
      @contracts.workspace_git_status_params("cid-main-status", workspace.id),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let main_status = match
    @contracts.git_status_result_value(wt_host_result(main_status_text)) {
    Ok(value) => value
    Err(message) => fail("main gitStatus result: " + message)
  }
  assert_true(wt_has_change(main_status, "main-only.txt"))
  assert_true(!wt_has_change(main_status, "worktree-only.txt"))

  let main_diff_text = wt_host_call(
    state,
    @contracts.RpcRequest::new(
      "req-main-diff",
      @contracts.METHOD_WORKSPACE_GIT_DIFF,
      @contracts.workspace_git_diff_params(
        "cid-main-diff",
        workspace.id,
        "",
        false,
        "",
      ),
    ),
  ) catch {
    error => fail(error.to_string())
  }
  let main_diff = match
    @contracts.git_diff_result_value(wt_host_result(main_diff_text)) {
    Ok(value) => value
    Err(message) => fail("main gitDiff result: " + message)
  }
  assert_true(main_diff.text.contains("+main-change"))
  assert_true(!main_diff.text.contains("+worktree-change"))
}

///|
async test "environment-backed workspaces reject worktree Git review explicitly" {
  let dir = @fs.tmpdir(prefix="monexus-wt-env-") catch {
    error => fail(error.to_string())
  }
  defer @fs.rmdir(dir, recursive=true)
  let now = "2026-12-01T03:00:00Z"
  let state = wt_host_state(dir + "/state") catch {
    error => fail(error.to_string())
  }
  let workspace = wt_workspace("ws_wt_env", "", dir + "/env-root", now)
  wt_seed_workspace(state, workspace) catch {
    error => fail(error.to_string())
  }
  let worktree = wt_worktree(
    "wt_env",
    workspace.id,
    "",
    "monexus/env",
    dir + "/env-worktree",
    @contracts.WORKTREE_STATE_READY,
    now,
  )
  wt_seed_worktree(state, worktree) catch {
    error => fail(error.to_string())
  }
  let environment : @contracts.EnvironmentRecord = {
    id: "env_wt_test",
    workspace_id: workspace.id,
    worktree_id: "",
    machine_id: "",
    backend: @contracts.ENVIRONMENT_BACKEND_DOCKER,
    recipe: "tiny@0.1.0",
    recipe_hash: "sha256:" +
      "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    container_name: "monexus-env-wt-test",
    state: @contracts.ENVIRONMENT_STATE_RUNNING,
    plan_digest: "sha256:" +
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    workdir: "/workspace/project",
    user: "1000:1000",
    network: "none",
    mounts: [],
    env_names: [],
    risk: @contracts.RISK_MEDIUM,
    approval_id: "",
    ephemeral: false,
    ttl_s: 0,
    client_request_id: "creq_wt_env",
    created_at: now,
    updated_at: now,
    started_at: now,
    stopped_at: "",
    last_error: "",
    cleanup_ok: true,
    cleanup_detail: "",
  }
  state.mutex.acquire()
  let put = state.store.put_environment(environment)
  state.mutex.release()
  match put {
    Ok(_) => ()
    Err(message) => fail("cannot seed environment: " + message)
  }

  let status_error = wt_host_error(
    wt_host_call(
      state,
      @contracts.RpcRequest::new(
        "req-env-status",
        @contracts.METHOD_WORKSPACE_GIT_STATUS,
        @contracts.workspace_git_status_params(
          "cid-env-status",
          workspace.id,
          worktree_id=worktree.id,
        ),
      ),
    ) catch {
      error => fail(error.to_string())
    },
  )
  assert_true(status_error.message.contains("Unsupported"))
  assert_true(status_error.message.contains("environment-backed"))

  let diff_error = wt_host_error(
    wt_host_call(
      state,
      @contracts.RpcRequest::new(
        "req-env-diff",
        @contracts.METHOD_WORKSPACE_GIT_DIFF,
        @contracts.workspace_git_diff_params(
          "cid-env-diff",
          workspace.id,
          "",
          false,
          "",
          worktree_id=worktree.id,
        ),
      ),
    ) catch {
      error => fail(error.to_string())
    },
  )
  assert_true(diff_error.message.contains("Unsupported"))
  assert_true(diff_error.message.contains("environment-backed"))
}

///|
async test "worktree.remove refuses non-terminal Chat AgentSessions and allows removal after end" {
  let dir = @fs.tmpdir(prefix="monexus-wt-remove-") catch {
    error => fail(error.to_string())
  }
  defer @fs.rmdir(dir, recursive=true)
  let (root, worktree_path) = wt_git_repo(dir) catch {
    error => fail(error.to_string())
  }
  let now = "2026-12-01T04:00:00Z"
  let state = wt_host_state(dir + "/state") catch {
    error => fail(error.to_string())
  }
  let workspace = wt_workspace("ws_wt_remove", "", root, now)
  wt_seed_workspace(state, workspace) catch {
    error => fail(error.to_string())
  }
  let worktree = wt_worktree(
    "wt_remove",
    workspace.id,
    "",
    "wt-test",
    worktree_path,
    @contracts.WORKTREE_STATE_READY,
    now,
  )
  wt_seed_worktree(state, worktree) catch {
    error => fail(error.to_string())
  }
  let (_, agent, chat) = wt_seed_chat(
    state,
    workspace,
    33_000L,
    now,
    ["tests/agent/mock_acp_agent.mjs"],
  ) catch {
    error => fail(error.to_string())
  }
  let session = wt_seed_session(
    state,
    chat,
    agent,
    workspace,
    worktree.id,
    worktree.path,
    33_100L,
    now,
  ) catch {
    error => fail(error.to_string())
  }

  let blocked = wt_host_error(
    wt_host_call(
      state,
      @contracts.RpcRequest::new(
        "req-wt-remove-blocked",
        @contracts.METHOD_WORKTREE_REMOVE,
        @contracts.worktree_remove_params(
          "cid-wt-remove-blocked",
          worktree.id,
          false,
        ),
      ),
    ) catch {
      error => fail(error.to_string())
    },
  )
  assert_true(blocked.message.contains("Conflict"))
  assert_true(blocked.message.contains("Chat AgentSession"))
  assert_true(@fs.exists(worktree_path) catch { _ => false })

  state.mutex.acquire()
  let ended = state.store.end_chat_agent_session(
    session.id,
    @contracts.AGENT_SESSION_STATE_FAILED,
    @contracts.AGENT_SESSION_END_REASON_ERROR,
    "",
    "",
    @contracts.format_rfc3339(@async.now()),
  )
  state.mutex.release()
  match ended {
    Ok(_) => ()
    Err(message) => fail("cannot end session: " + message)
  }

  let removed = wt_host_result(
    wt_host_call(
      state,
      @contracts.RpcRequest::new(
        "req-wt-remove-allowed",
        @contracts.METHOD_WORKTREE_REMOVE,
        @contracts.worktree_remove_params(
          "cid-wt-remove-allowed",
          worktree.id,
          false,
        ),
      ),
    ) catch {
      error => fail(error.to_string())
    },
  )
  assert_true(removed.stringify().contains(workspace.id))
  assert_true(!(@fs.exists(worktree_path) catch { _ => true }))
}
