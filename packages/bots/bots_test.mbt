///|
/// ADR-0017 P0.1 pure-domain tests: state guards, immutability, V1 Chat
/// invariants, project access, permission intersection, shared memory and
/// approval scoping.

///|
fn sample_binding() -> @contracts.RuntimeBinding {
  @contracts.RuntimeBinding::new(
    software_id="claude-code",
    adapter_id="acp",
    launch_kind=@contracts.RUNTIME_LAUNCH_ACP,
    command="/usr/bin/claude",
    args=["--acp"],
    model_profile="balanced",
    hash="sha256:binding",
    tools=["shell"],
    skills=["review"],
    version="1.2.3",
  )
}

///|
fn sample_bot() -> @contracts.BotRecord {
  let id = @contracts.new_bot_id(100L)
  @contracts.BotRecord::new(
    id=id,
    org_id="org_local",
    name="Builder",
    created_at="2026-11-27T00:00:00Z",
    persona_ref="bot/persona.md",
    instructions_ref="bot/AGENTS.md",
    memory_ref=bot_memory_namespace(id),
    permission_ceiling=["repo:read", "tool:shell"],
    create_policy=@contracts.BOT_CREATE_POLICY_ASK,
    agent_count_cap=4,
    agent_concurrency_cap=1,
    software_allowlist=["claude-code"],
  )
}

///|
fn sample_agent(
  bot_id : String,
  ms : Int64,
) -> @contracts.AgentRecord {
  @contracts.AgentRecord::new(
    id=@contracts.new_agent_id(ms),
    org_id="org_local",
    bot_id=bot_id,
    name="Claude worker",
    runtime_binding=sample_binding(),
    created_at="2026-11-27T00:01:00Z",
    permission_scope=["repo:read"],
    state=@contracts.AGENT_LIFECYCLE_ACTIVE,
  )
}

///|
fn sample_chat(project_id : String) -> @contracts.ChatRecord {
  @contracts.ChatRecord::new(
    id=@contracts.new_chat_id(200L),
    org_id="org_local",
    title="Implement P0.1",
    created_at="2026-11-27T00:02:00Z",
    project_id=project_id,
  )
}

///|
fn sample_participant(
  chat_id : String,
  bot_id : String,
) -> @contracts.ChatParticipant {
  @contracts.ChatParticipant::new(
    chat_id=chat_id,
    bot_id=bot_id,
    added_at="2026-11-27T00:03:00Z",
  )
}

///|
fn sample_membership(
  project_id : String,
  bot_id : String,
) -> @contracts.ProjectMembership {
  @contracts.ProjectMembership::new(
    project_id=project_id,
    bot_id=bot_id,
    added_at="2026-11-27T00:04:00Z",
    access=["repo:read"],
    reason="owner added",
  )
}

///|
fn sample_session(
  chat_id : String,
  agent_id : String,
  state : String,
  ms : Int64,
) -> @contracts.AgentSession {
  @contracts.AgentSession::new(
    id=@contracts.new_agent_session_id(ms),
    chat_id=chat_id,
    agent_id=agent_id,
    permission_snapshot_hash="sha256:permission",
    started_at="2026-11-27T00:05:00Z",
    state=state,
  )
}

///|
test "ADR-0017 state transitions reject terminal revival and no-ops" {
  assert_true(
    bot_transition_allowed(
      @contracts.BOT_STATE_ACTIVE,
      @contracts.BOT_STATE_SUSPENDED,
    ),
  )
  assert_true(
    bot_transition_allowed(
      @contracts.BOT_STATE_ACTIVE,
      @contracts.BOT_STATE_ARCHIVED,
    ),
  )
  assert_true(
    bot_transition_allowed(
      @contracts.BOT_STATE_SUSPENDED,
      @contracts.BOT_STATE_ACTIVE,
    ),
  )
  assert_true(
    !bot_transition_allowed(
      @contracts.BOT_STATE_ARCHIVED,
      @contracts.BOT_STATE_ACTIVE,
    ),
  )
  assert_true(
    !bot_transition_allowed(
      @contracts.BOT_STATE_ACTIVE,
      @contracts.BOT_STATE_ACTIVE,
    ),
  )
  assert_true(
    agent_transition_allowed(
      @contracts.AGENT_LIFECYCLE_PROVISIONING,
      @contracts.AGENT_LIFECYCLE_ACTIVE,
    ),
  )
  assert_true(
    agent_transition_allowed(
      @contracts.AGENT_LIFECYCLE_ACTIVE,
      @contracts.AGENT_LIFECYCLE_RETIRED,
    ),
  )
  assert_true(
    !agent_transition_allowed(
      @contracts.AGENT_LIFECYCLE_RETIRED,
      @contracts.AGENT_LIFECYCLE_ACTIVE,
    ),
  )
  assert_true(
    chat_transition_allowed(
      @contracts.CHAT_STATE_ARCHIVED,
      @contracts.CHAT_STATE_ACTIVE,
    ),
  )
  assert_true(
    participant_transition_allowed(
      @contracts.PARTICIPANT_STATE_ACTIVE,
      @contracts.PARTICIPANT_STATE_REMOVED,
    ),
  )
  assert_true(
    agent_session_transition_allowed(
      @contracts.AGENT_SESSION_STATE_STARTING,
      @contracts.AGENT_SESSION_STATE_ACTIVE,
    ),
  )
  assert_true(
    agent_session_transition_allowed(
      @contracts.AGENT_SESSION_STATE_ACTIVE,
      @contracts.AGENT_SESSION_STATE_WAITING,
    ),
  )
  assert_true(
    agent_session_transition_allowed(
      @contracts.AGENT_SESSION_STATE_ENDING,
      @contracts.AGENT_SESSION_STATE_ENDED,
    ),
  )
  assert_true(
    !agent_session_transition_allowed(
      @contracts.AGENT_SESSION_STATE_ENDED,
      @contracts.AGENT_SESSION_STATE_ACTIVE,
    ),
  )
  assert_true(
    membership_transition_allowed(
      @contracts.MEMBERSHIP_STATE_ACTIVE,
      @contracts.MEMBERSHIP_STATE_REMOVED,
    ),
  )
  assert_true(
    project_transition_allowed(
      @contracts.PROJECT_STATE_ARCHIVED,
      @contracts.PROJECT_STATE_ACTIVE,
    ),
  )
}

///|
test "archived objects are read-only and retired Agents are not revived" {
  assert_true(!bot_content_mutable(@contracts.BOT_STATE_ARCHIVED))
  assert_true(bot_content_mutable(@contracts.BOT_STATE_ACTIVE))
  assert_true(!chat_content_mutable(@contracts.CHAT_STATE_ARCHIVED))
  assert_true(chat_content_mutable(@contracts.CHAT_STATE_ACTIVE))
  assert_true(!project_content_mutable(@contracts.PROJECT_STATE_ARCHIVED))
  assert_true(!agent_metadata_mutable(@contracts.AGENT_LIFECYCLE_RETIRED))
  assert_true(agent_metadata_mutable(@contracts.AGENT_LIFECYCLE_SUSPENDED))
  assert_true(
    !agent_transition_allowed(
      @contracts.AGENT_LIFECYCLE_RETIRED,
      @contracts.AGENT_LIFECYCLE_ACTIVE,
    ),
  )
}

///|
test "runtime binding cannot change after Agent creation" {
  let original = sample_binding()
  match validate_runtime_binding_update(original, sample_binding()) {
    Ok(_) => ()
    Err(reason) => fail("identical binding should be accepted: " + reason)
  }
  let changed = @contracts.RuntimeBinding::new(
    software_id="claude-code",
    adapter_id="acp",
    launch_kind=@contracts.RUNTIME_LAUNCH_ACP,
    command="/usr/bin/claude",
    args=["--acp"],
    model_profile="fast",
    hash="sha256:other-binding",
    tools=["shell"],
    skills=["review"],
    version="1.2.3",
  )
  match validate_runtime_binding_update(original, changed) {
    Ok(_) => fail("runtime binding change was accepted")
    Err(reason) => assert_true(reason.contains("immutable"))
  }
}

///|
test "archive and retirement guards require non-terminal sessions to end" {
  let bot = sample_bot()
  let agent = sample_agent(bot.id, 107L)
  let chat = sample_chat("")
  let session = sample_session(
    chat.id,
    agent.id,
    @contracts.AGENT_SESSION_STATE_ACTIVE,
    203L,
  )
  match validate_bot_archive(bot, [agent], [session]) {
    Ok(_) => fail("Bot archived with a non-terminal AgentSession")
    Err(reason) => assert_true(reason.contains("non-terminal"))
  }
  match validate_agent_retirement(agent, [session]) {
    Ok(_) => fail("Agent retired with a non-terminal AgentSession")
    Err(reason) => assert_true(reason.contains("non-terminal"))
  }
  match validate_chat_archive(chat, [session]) {
    Ok(_) => fail("Chat archived with a non-terminal AgentSession")
    Err(reason) => assert_true(reason.contains("non-terminal"))
  }
  match validate_chat_project_change(chat, [session]) {
    Ok(_) => fail("Chat project changed with a non-terminal AgentSession")
    Err(reason) => assert_true(reason.contains("non-terminal"))
  }
  let ended = { ..session, state: @contracts.AGENT_SESSION_STATE_ENDED }
  match validate_bot_archive(bot, [agent], [ended]) {
    Ok(_) => ()
    Err(reason) => fail("Bot archive should be allowed after session ends: " + reason)
  }
  match validate_agent_retirement(agent, [ended]) {
    Ok(_) => ()
    Err(reason) => fail("Agent retirement should be allowed after session ends: " + reason)
  }
  match validate_chat_archive(chat, [ended]) {
    Ok(_) => ()
    Err(reason) => fail("Chat archive should be allowed after session ends: " + reason)
  }
  match validate_chat_project_change(chat, [ended]) {
    Ok(_) => ()
    Err(reason) => fail("Chat project change should be allowed after session ends: " + reason)
  }
  let archived = { ..chat, state: @contracts.CHAT_STATE_ARCHIVED }
  match validate_chat_project_change(archived, [ended]) {
    Ok(_) => fail("archived Chat accepted a project change")
    Err(reason) => assert_true(reason.contains("read-only"))
  }
}

///|
test "V1 Chat enforces one active Bot participant and one session" {
  let bot = sample_bot()
  let agent = sample_agent(bot.id, 101L)
  let chat = sample_chat("")
  let participant = sample_participant(chat.id, bot.id)
  let session = sample_session(
    chat.id,
    agent.id,
    @contracts.AGENT_SESSION_STATE_ACTIVE,
    201L,
  )
  match validate_v1_chat(
    chat,
    [participant],
    [agent],
    [session],
    [],
  ) {
    Ok(_) => ()
    Err(reason) => fail("valid V1 Chat was rejected: " + reason)
  }
  let second_bot = @contracts.new_bot_id(102L)
  let second_participant = sample_participant(chat.id, second_bot)
  match validate_v1_chat(
    chat,
    [participant, second_participant],
    [agent],
    [session],
    [],
  ) {
    Ok(_) => fail("two active Bot participants were accepted")
    Err(reason) => assert_true(reason.contains("exactly one"))
  }
  let second_session = sample_session(
    chat.id,
    agent.id,
    @contracts.AGENT_SESSION_STATE_STARTING,
    202L,
  )
  match validate_v1_chat(
    chat,
    [participant],
    [agent],
    [session, second_session],
    [],
  ) {
    Ok(_) => fail("two non-terminal AgentSessions were accepted")
    Err(reason) => assert_true(reason.contains("at most one"))
  }
  let archived = { ..chat, state: @contracts.CHAT_STATE_ARCHIVED }
  match validate_v1_chat(
    archived,
    [participant],
    [agent],
    [session],
    [],
  ) {
    Ok(_) => fail("archived Chat accepted an active AgentSession")
    Err(reason) => assert_true(reason.contains("archived"))
  }
}

///|
test "Agent cannot be a Chat participant" {
  let bot = sample_bot()
  let agent = sample_agent(bot.id, 103L)
  let chat = sample_chat("")
  let agent_participant = sample_participant(chat.id, agent.id)
  match validate_chat_participant_identity(agent_participant) {
    Ok(_) => fail("Agent participant identity was accepted")
    Err(reason) => assert_true(reason.contains("Agent cannot"))
  }
  match validate_v1_chat(chat, [agent_participant], [agent], [], []) {
    Ok(_) => fail("Chat with only an Agent participant was accepted")
    Err(reason) => assert_true(reason.contains("Agent cannot"))
  }
}

///|
test "project membership is a hard gate for project Chat and AgentSession" {
  let bot = sample_bot()
  let agent = sample_agent(bot.id, 104L)
  let project_id = @contracts.new_project_id(300L)
  let chat = sample_chat(project_id)
  let participant = sample_participant(chat.id, bot.id)
  let session = @contracts.AgentSession::new(
    id=@contracts.new_agent_session_id(301L),
    chat_id=chat.id,
    agent_id=agent.id,
    permission_snapshot_hash="sha256:permission",
    started_at="2026-11-27T00:05:00Z",
    project_id=project_id,
  )
  match validate_v1_chat(chat, [participant], [agent], [session], []) {
    Ok(_) => fail("project Chat without membership was accepted")
    Err(reason) => assert_true(reason.contains("Project membership"))
  }
  match validate_agent_session_start(
    chat,
    agent,
    session,
    [participant],
    [],
    [],
  ) {
    Ok(_) => fail("project AgentSession without membership was accepted")
    Err(reason) => assert_true(reason.contains("Project membership"))
  }
  let membership = sample_membership(project_id, bot.id)
  match validate_agent_session_start(
    chat,
    agent,
    session,
    [participant],
    [membership],
    [],
  ) {
    Ok(_) => ()
    Err(reason) => fail("valid project AgentSession was rejected: " + reason)
  }
  match validate_v1_chat(
    chat,
    [participant],
    [agent],
    [session],
    [membership],
  ) {
    Ok(_) => ()
    Err(reason) => fail("valid project Chat was rejected: " + reason)
  }
}

///|
test "effective permission is intersection-only and cannot widen ceilings" {
  let request = PermissionRequest::new(
    org_policy=["repo:read", "tool:shell", "project:admin"],
    bot_ceiling=["repo:read", "tool:shell"],
    project_id=@contracts.new_project_id(400L),
    project_policy=["repo:read", "project:admin"],
    project_membership_active=true,
    agent_scope=["repo:read", "tool:shell", "project:admin"],
    task_scope=["repo:read", "tool:shell", "project:admin"],
    session_scope=["repo:read", "tool:shell", "project:admin"],
    tool_allowlist=["repo:read", "tool:shell", "project:admin"],
    skill_allowlist=["repo:read", "tool:shell", "project:admin"],
  )
  match effective_permission(request) {
    Ok(allowed) => {
      assert_eq(allowed.length(), 1)
      assert_eq(allowed[0], "repo:read")
      assert_true(permission_covers(allowed, "repo:read"))
      assert_true(!permission_covers(allowed, "tool:shell"))
      assert_true(!permission_covers(allowed, "project:admin"))
    }
    Err(reason) => fail("permission intersection failed: " + reason)
  }
  let missing_membership = PermissionRequest::new(
    org_policy=["repo:read"],
    bot_ceiling=["repo:read"],
    project_id=@contracts.new_project_id(401L),
    project_policy=["repo:read"],
    project_membership_active=false,
    agent_scope=["repo:read"],
    task_scope=["repo:read"],
    session_scope=["repo:read"],
    tool_allowlist=["repo:read"],
    skill_allowlist=["repo:read"],
  )
  match effective_permission(missing_membership) {
    Ok(_) => fail("missing project membership granted permission")
    Err(reason) => assert_true(reason.contains("membership"))
  }
}

///|
test "all Agents share exactly one Bot memory namespace" {
  let bot = sample_bot()
  let first = sample_agent(bot.id, 105L)
  let second = sample_agent(bot.id, 106L)
  assert_eq(agent_memory_namespace(first), bot.memory_ref)
  assert_eq(agent_memory_namespace(second), bot.memory_ref)
  match validate_shared_memory_access(bot, first, bot.memory_ref) {
    Ok(_) => ()
    Err(reason) => fail("shared memory access was rejected: " + reason)
  }
  let per_agent = "agent/" + first.id + "/memory"
  match validate_shared_memory_access(bot, first, per_agent) {
    Ok(_) => fail("per-Agent memory namespace was accepted")
    Err(reason) => assert_true(reason.contains("shared Bot memory"))
  }
}

///|
test "an approval from an old AgentSession cannot authorize a new one" {
  let old_session = @contracts.new_agent_session_id(500L)
  let new_session = @contracts.new_agent_session_id(501L)
  let approval = SessionApproval::new(
    decision_id="dec_approval",
    agent_session_id=old_session,
    action="tool:shell",
  )
  assert_true(approval_authorizes(approval, old_session, "tool:shell"))
  assert_true(!approval_authorizes(approval, new_session, "tool:shell"))
  assert_true(!approval_applies_to_session(approval, new_session))
}
