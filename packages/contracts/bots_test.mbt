///|
/// ADR-0017 wire contract tests: canonical IDs, JSON round-trips and event
/// payload builders. The state machine and invariant tests live in
/// `packages/bots`.

///|
fn round_trip_json(value : @json.Json) -> @json.Json {
  @json.parse(value.stringify()) catch {
    _ => @json.Json::null()
  }
}

///|
test "ADR-0017 IDs use canonical prefixes and reject legacy prefixes" {
  let bot_id = new_bot_id(1_700_000_000_000L)
  let agent_id = new_agent_id(1_700_000_000_001L)
  let chat_id = new_chat_id(1_700_000_000_002L)
  let session_id = new_agent_session_id(1_700_000_000_003L)
  let project_id = new_project_id(1_700_000_000_004L)
  assert_true(bot_id.has_prefix("bot_"))
  assert_true(agent_id.has_prefix("agw_"))
  assert_true(chat_id.has_prefix("cht_"))
  assert_true(session_id.has_prefix("asn_"))
  assert_true(project_id.has_prefix("prj_"))
  assert_true(is_bot_id(bot_id))
  assert_true(is_agent_id(agent_id))
  assert_true(is_chat_id(chat_id))
  assert_true(is_agent_session_id(session_id))
  assert_true(is_project_id(project_id))
  assert_true(is_canonical_object_id(bot_id))
  assert_true(!is_canonical_object_id("agt_01H"))
  assert_true(!is_canonical_object_id("ses_01H"))
  let ulid = "0123456789ABCDEFGHJKMNPQRS"
  assert_true(!is_agent_id("agt_" + ulid))
  assert_true(!is_agent_session_id("ses_" + ulid))
  assert_true(is_legacy_agent_id("agt_01H"))
  assert_true(is_legacy_session_id("ses_01H"))
  match new_canonical_id("agt", 0L) {
    Ok(_) => fail("agt must be rejected for new objects")
    Err(reason) => assert_true(reason.contains("legacy prefix"))
  }
  match new_canonical_id("ses", 0L) {
    Ok(_) => fail("ses must be rejected for new objects")
    Err(reason) => assert_true(reason.contains("legacy prefix"))
  }
  match new_canonical_id("prj", 0L) {
    Ok(value) => assert_true(is_project_id(value))
    Err(reason) => fail("prj should stay canonical: " + reason)
  }
}

///|
test "ADR-0017 Bot and Agent records round-trip through JSON" {
  let binding = RuntimeBinding::new(
    software_id="claude-code",
    adapter_id="acp",
    launch_kind=RUNTIME_LAUNCH_ACP,
    command="/usr/bin/claude",
    args=["--acp"],
    model_profile="balanced",
    hash="sha256:binding",
    tools=["shell", "git"],
    skills=["review"],
    version="1.2.3",
  )
  let bot = BotRecord::new(
    id=new_bot_id(1L),
    org_id="org_local",
    name="Builder",
    created_at="2026-11-27T00:00:00Z",
    persona_ref="bot/persona.md",
    instructions_ref="bot/AGENTS.md",
    memory_ref="bot/memory",
    home="/state/bots/bot_1",
    permission_ceiling=["repo:read", "tool:shell"],
    create_policy=BOT_CREATE_POLICY_ASK,
    agent_count_cap=4,
    agent_concurrency_cap=1,
    software_allowlist=["claude-code"],
  )
  let parsed_bot = bot_from_json(round_trip_json(bot.to_json()))
  match parsed_bot {
    Some(value) => {
      assert_eq(value.id, bot.id)
      assert_eq(value.name, "Builder")
      assert_eq(value.memory_ref, "bot/memory")
      assert_eq(value.permission_ceiling.length(), 2)
      assert_eq(value.permission_ceiling[0], "repo:read")
      assert_eq(value.create_policy, BOT_CREATE_POLICY_ASK)
      assert_eq(value.agent_count_cap, 4)
    }
    None => fail("BotRecord did not decode")
  }
  let agent = AgentRecord::new(
    id=new_agent_id(2L),
    org_id="org_local",
    bot_id=bot.id,
    name="Claude worker",
    runtime_binding=binding,
    created_at="2026-11-27T00:01:00Z",
    specialty="implementation",
    tags=["coding"],
    permission_scope=["repo:read"],
    state=AGENT_LIFECYCLE_ACTIVE,
  )
  let parsed_agent = agent_from_json(round_trip_json(agent.to_json()))
  match parsed_agent {
    Some(value) => {
      assert_eq(value.id, agent.id)
      assert_eq(value.bot_id, bot.id)
      assert_eq(value.runtime_binding.hash, "sha256:binding")
      assert_eq(value.runtime_binding.args[0], "--acp")
      assert_eq(value.runtime_binding.tools[1], "git")
      assert_eq(value.permission_scope[0], "repo:read")
    }
    None => fail("AgentRecord did not decode")
  }
}

///|
test "ADR-0017 Chat, participant and message records round-trip through JSON" {
  let chat = ChatRecord::new(
    id=new_chat_id(3L),
    org_id="org_local",
    title="Implement P0.1",
    created_at="2026-11-27T00:02:00Z",
    project_id=new_project_id(4L),
    summary_ref="chat/summary.md",
  )
  let parsed_chat = chat_from_json(round_trip_json(chat.to_json()))
  match parsed_chat {
    Some(value) => {
      assert_eq(value.id, chat.id)
      assert_eq(value.project_id, chat.project_id)
      assert_eq(value.state, CHAT_STATE_ACTIVE)
      assert_eq(value.summary_ref, "chat/summary.md")
    }
    None => fail("ChatRecord did not decode")
  }
  let participant = ChatParticipant::new(
    chat_id=chat.id,
    bot_id=new_bot_id(5L),
    added_at="2026-11-27T00:03:00Z",
  )
  let parsed_participant = chat_participant_from_json(
    round_trip_json(participant.to_json()),
  )
  match parsed_participant {
    Some(value) => {
      assert_eq(value.chat_id, chat.id)
      assert_eq(value.bot_id, participant.bot_id)
      assert_eq(value.role, CHAT_PARTICIPANT_ROLE_BOT)
      assert_eq(value.state, PARTICIPANT_STATE_ACTIVE)
    }
    None => fail("ChatParticipant did not decode")
  }
  let message = ChatMessage::new(
    id="msg_1",
    chat_id=chat.id,
    role=CHAT_MESSAGE_ROLE_ASSISTANT,
    body_ref="chat/message-1.txt",
    digest="sha256:message",
    created_at="2026-11-27T00:04:00Z",
    agent_session_id=new_agent_session_id(6L),
    actor="agent",
  )
  let parsed_message = chat_message_from_json(
    round_trip_json(message.to_json()),
  )
  match parsed_message {
    Some(value) => {
      assert_eq(value.id, "msg_1")
      assert_eq(value.chat_id, chat.id)
      assert_eq(value.role, CHAT_MESSAGE_ROLE_ASSISTANT)
      assert_eq(value.agent_session_id, message.agent_session_id)
      assert_eq(value.digest, "sha256:message")
    }
    None => fail("ChatMessage did not decode")
  }
}

///|
test "ADR-0017 AgentSession and ProjectMembership round-trip through JSON" {
  let session = AgentSession::new(
    id=new_agent_session_id(7L),
    chat_id=new_chat_id(8L),
    agent_id=new_agent_id(9L),
    permission_snapshot_hash="sha256:permission",
    started_at="2026-11-27T00:05:00Z",
    runtime_session_id="rt_1",
    project_id=new_project_id(10L),
    workspace_id="wsp_1",
    workspace_root="/repo",
    handoff_from_session_id=new_agent_session_id(11L),
  )
  let parsed_session = chat_agent_session_from_json(
    round_trip_json(session.to_json()),
  )
  match parsed_session {
    Some(value) => {
      assert_eq(value.id, session.id)
      assert_eq(value.chat_id, session.chat_id)
      assert_eq(value.agent_id, session.agent_id)
      assert_eq(value.runtime_session_id, "rt_1")
      assert_eq(value.project_id, session.project_id)
      assert_eq(value.permission_snapshot_hash, "sha256:permission")
      assert_eq(value.handoff_from_session_id, session.handoff_from_session_id)
      assert_eq(value.state, AGENT_SESSION_STATE_STARTING)
    }
    None => fail("AgentSession did not decode")
  }
  let membership = ProjectMembership::new(
    project_id=session.project_id,
    bot_id=new_bot_id(12L),
    added_at="2026-11-27T00:06:00Z",
    access=["repo:read", "chat:write"],
    reason="owner added",
  )
  let parsed_membership = project_membership_from_json(
    round_trip_json(membership.to_json()),
  )
  match parsed_membership {
    Some(value) => {
      assert_eq(value.project_id, membership.project_id)
      assert_eq(value.bot_id, membership.bot_id)
      assert_eq(value.access.length(), 2)
      assert_eq(value.access[1], "chat:write")
      assert_eq(value.state, MEMBERSHIP_STATE_ACTIVE)
      assert_eq(value.reason, "owner added")
    }
    None => fail("ProjectMembership did not decode")
  }
}

///|
test "ADR-0017 event constants and payload builders match the ADR catalog" {
  assert_eq(EVENT_BOT_CREATED, "bot.created")
  assert_eq(EVENT_BOT_AGENT_CREATED, "bot.agent.created")
  assert_eq(EVENT_CHAT_CREATED, "chat.created")
  assert_eq(EVENT_CHAT_AGENT_SWITCHED, "chat.agent.switched")
  assert_eq(EVENT_CHAT_AGENT_SESSION_STARTED, "chat.agent_session.started")
  assert_eq(EVENT_CHAT_AGENT_SESSION_UPDATED, "chat.agent_session.updated")
  assert_eq(EVENT_CHAT_AGENT_SESSION_ENDED, "chat.agent_session.ended")
  assert_eq(EVENT_PROJECT_MEMBER_ADDED, "project.member.added")
  assert_eq(EVENT_PROJECT_MEMBER_REMOVED, "project.member.removed")
  let bot = BotRecord::new(
    id=new_bot_id(13L),
    org_id="org_local",
    name="Builder",
    created_at="2026-11-27T00:07:00Z",
    memory_ref="bot/memory",
    create_policy=BOT_CREATE_POLICY_AUTO,
  )
  let payload = round_trip_json(
    bot_created_payload(bot, "sha256:ceiling", "owner", "manual"),
  )
  let object = match as_object(payload) {
    Some(value) => value
    None => fail("bot.created payload is not an object")
  }
  assert_eq(string_field_or(object, "bot_id", ""), bot.id)
  assert_eq(
    string_field_or(object, "permission_ceiling_hash", ""),
    "sha256:ceiling",
  )
  assert_eq(string_field_or(object, "create_policy", ""), BOT_CREATE_POLICY_AUTO)
  assert_eq(bot_event_subject(bot.id), "bot/" + bot.id)
}

///|
test "ADR-0017 event payloads replay the complete post-change record" {
  let binding = RuntimeBinding::new(
    software_id="claude-code",
    adapter_id="acp",
    launch_kind=RUNTIME_LAUNCH_ACP,
    command="/usr/bin/claude",
    args=["--acp"],
    model_profile="balanced",
    hash="sha256:binding",
    tools=["shell"],
    skills=["review"],
  )
  let bot = BotRecord::new(
    id=new_bot_id(1_000L),
    org_id="org_local",
    name="Builder",
    created_at="2026-11-27T01:00:00Z",
    memory_ref="bot/memory",
    permission_ceiling=["repo:read", "tool:shell"],
    create_policy=BOT_CREATE_POLICY_AUTO,
    software_allowlist=["claude-code"],
  )
  let created = round_trip_json(
    bot_created_payload(bot, "sha256:ceiling", "owner", "manual"),
  )
  match bot_created_record(created) {
    Some(value) => {
      assert_eq(value.id, bot.id)
      assert_eq(value.name, "Builder")
      assert_eq(value.permission_ceiling.length(), 2)
      assert_eq(value.create_policy, BOT_CREATE_POLICY_AUTO)
      assert_eq(value.software_allowlist[0], "claude-code")
    }
    None => fail("bot.created record did not decode")
  }
  let renamed = { ..bot, name: "Builder 2" }
  let updated = round_trip_json(
    bot_updated_payload(renamed, ["name"], 2, "owner"),
  )
  match bot_updated_record(updated) {
    Some(value) => assert_eq(value.name, "Builder 2")
    None => fail("bot.updated record did not decode")
  }
  let agent = AgentRecord::new(
    id=new_agent_id(1_001L),
    org_id="org_local",
    bot_id=bot.id,
    name="Claude worker",
    runtime_binding=binding,
    created_at="2026-11-27T01:01:00Z",
    permission_scope=["repo:read"],
    state=AGENT_LIFECYCLE_ACTIVE,
  )
  let agent_payload = round_trip_json(
    bot_agent_created_payload(
      bot.id,
      agent,
      "sha256:scope",
      BOT_CREATE_POLICY_AUTO,
      "",
      "owner",
      "manual",
    ),
  )
  match bot_agent_created_record(agent_payload) {
    Some(value) => {
      assert_eq(value.id, agent.id)
      assert_eq(value.bot_id, bot.id)
      assert_eq(value.runtime_binding.command, "/usr/bin/claude")
      assert_eq(value.runtime_binding.tools[0], "shell")
    }
    None => fail("bot.agent.created record did not decode")
  }
  let suspended = {
    ..agent,
    state: AGENT_LIFECYCLE_SUSPENDED,
    updated_at: "2026-11-27T01:02:00Z",
  }
  let suspended_payload = round_trip_json(
    bot_agent_suspended_payload(bot.id, suspended, "owner pause", "owner"),
  )
  match bot_agent_suspended_record(suspended_payload) {
    Some(value) => assert_eq(value.state, AGENT_LIFECYCLE_SUSPENDED)
    None => fail("bot.agent.suspended record did not decode")
  }
  let chat = ChatRecord::new(
    id=new_chat_id(1_002L),
    org_id="org_local",
    title="P0.2",
    created_at="2026-11-27T01:03:00Z",
  )
  let participant = ChatParticipant::new(
    chat_id=chat.id,
    bot_id=bot.id,
    added_at="2026-11-27T01:03:00Z",
  )
  let chat_payload = round_trip_json(
    chat_created_payload(chat, [participant], "owner", "manual"),
  )
  match chat_created_record(chat_payload) {
    Some(value) => assert_eq(value.title, "P0.2")
    None => fail("chat.created record did not decode")
  }
  let participants = chat_created_participants(chat_payload)
  assert_eq(participants.length(), 1)
  assert_eq(participants[0].bot_id, bot.id)
  let project_id = new_project_id(1_003L)
  let moved = { ..chat, project_id }
  let moved_payload = round_trip_json(
    chat_project_changed_payload(moved, "", "membership_ok", "owner"),
  )
  match chat_project_changed_record(moved_payload) {
    Some(value) => assert_eq(value.project_id, project_id)
    None => fail("chat.project.changed record did not decode")
  }
  let switched_payload = round_trip_json(
    chat_agent_switched_payload(
      moved,
      agent.id,
      agent.id,
      new_agent_session_id(1_004L),
      new_agent_session_id(1_005L),
      "bnd_1",
      "sha256:old",
      "sha256:new",
      "owner",
    ),
  )
  match chat_agent_switched_record(switched_payload) {
    Some(value) => assert_eq(value.id, chat.id)
    None => fail("chat.agent.switched record did not decode")
  }
  let selected_payload = round_trip_json(
    chat_agent_selected_payload(
      chat.id,
      bot.id,
      agent,
      "sha256:permission",
      "owner",
      "",
    ),
  )
  match chat_agent_selected_record(selected_payload) {
    Some(value) => assert_eq(value.runtime_binding.command, "/usr/bin/claude")
    None => fail("chat.agent.selected record did not decode")
  }
  let session = AgentSession::new(
    id=new_agent_session_id(1_006L),
    chat_id=chat.id,
    agent_id=agent.id,
    permission_snapshot_hash="sha256:permission",
    started_at="2026-11-27T01:04:00Z",
    runtime_session_id="rt_1",
    project_id=project_id,
  )
  let started_payload = round_trip_json(
    chat_agent_session_started_payload(
      session,
      bot.id,
      agent.runtime_binding.hash,
      "",
    ),
  )
  match chat_agent_session_started_record(started_payload) {
    Some(value) => {
      assert_eq(value.id, session.id)
      assert_eq(value.runtime_session_id, "rt_1")
      assert_eq(value.permission_snapshot_hash, "sha256:permission")
    }
    None => fail("chat.agent_session.started record did not decode")
  }
  let ended = {
    ..session,
    state: AGENT_SESSION_STATE_ENDED,
    summary_ref: "chat/summary-1.md",
    ended_at: "2026-11-27T01:05:00Z",
  }
  let ended_payload = round_trip_json(
    chat_agent_session_ended_payload(ended, ""),
  )
  match chat_agent_session_ended_record(ended_payload) {
    Some(value) => {
      assert_eq(value.state, AGENT_SESSION_STATE_ENDED)
      assert_eq(value.summary_ref, "chat/summary-1.md")
    }
    None => fail("chat.agent_session.ended record did not decode")
  }
  let membership = ProjectMembership::new(
    project_id=project_id,
    bot_id=bot.id,
    added_at="2026-11-27T01:06:00Z",
    access=["repo:read"],
    reason="owner added",
  )
  let membership_payload = round_trip_json(
    project_member_added_payload(membership, "owner"),
  )
  match project_member_added_record(membership_payload) {
    Some(value) => {
      assert_eq(value.project_id, project_id)
      assert_eq(value.bot_id, bot.id)
      assert_eq(value.access[0], "repo:read")
    }
    None => fail("project.member.added record did not decode")
  }
}

///|
fn bots_rpc_test_bot() -> BotRecord {
  BotRecord::new(
    id=new_bot_id(9_001L),
    org_id=ORG_LOCAL,
    name="RPC Builder",
    created_at="2026-11-27T03:00:00Z",
    persona_ref="persona/builder",
    instructions_ref="instructions/builder",
    memory_ref="bot/rpc/memory",
    home="/tmp/rpc-bot-home",
    permission_ceiling=["repo:read", "tool:shell"],
    create_policy=BOT_CREATE_POLICY_AUTO,
    agent_count_cap=4,
    agent_concurrency_cap=1,
    software_allowlist=["mock-acp"],
  )
}

///|
fn bots_rpc_test_agent(bot : BotRecord) -> AgentRecord {
  AgentRecord::new(
    id=new_agent_id(9_002L),
    org_id=bot.org_id,
    bot_id=bot.id,
    name="RPC Worker",
    runtime_binding=RuntimeBinding::new(
      software_id="mock-acp",
      adapter_id="acp",
      launch_kind=RUNTIME_LAUNCH_ACP,
      command="node",
      args=["mock.mjs"],
      model_profile="test",
      hash="sha256:rpc-binding",
    ),
    created_at="2026-11-27T03:00:01Z",
    specialty="test",
    tags=["p0.3"],
    permission_scope=["repo:read"],
    state=AGENT_LIFECYCLE_ACTIVE,
  )
}

///|
fn bots_rpc_test_chat() -> ChatRecord {
  ChatRecord::new(
    id=new_chat_id(9_003L),
    org_id=ORG_LOCAL,
    title="RPC Chat",
    created_at="2026-11-27T03:00:02Z",
  )
}

///|
fn bots_rpc_test_session(
  chat : ChatRecord,
  agent : AgentRecord,
) -> AgentSession {
  AgentSession::new(
    id=new_agent_session_id(9_004L),
    chat_id=chat.id,
    agent_id=agent.id,
    permission_snapshot_hash="sha256:rpc-permission",
    started_at="2026-11-27T03:00:03Z",
    runtime_session_id="agt_rpc_runtime",
    state=AGENT_SESSION_STATE_ACTIVE,
  )
}

///|
fn bots_rpc_test_message(
  chat : ChatRecord,
  session_id : String,
) -> ChatMessage {
  ChatMessage::new(
    id=new_id("msg", 9_005L),
    chat_id=chat.id,
    role=CHAT_MESSAGE_ROLE_ASSISTANT,
    agent_session_id=session_id,
    body_ref="",
    body="hello from the mock agent",
    digest=chat_message_digest("hello from the mock agent", ""),
    created_at="2026-11-27T03:00:04Z",
  )
}

///|
test "ADR-0017 P0.3 RPC result records round-trip" {
  let bot = bots_rpc_test_bot()
  let agent = bots_rpc_test_agent(bot)
  let chat = bots_rpc_test_chat()
  let session = bots_rpc_test_session(chat, agent)
  let message = bots_rpc_test_message(chat, session.id)
  let participant = ChatParticipant::new(
    chat_id=chat.id,
    bot_id=bot.id,
    added_at="2026-11-27T03:00:02Z",
  )
  match
    bots_from_result(round_trip_json(bots_list_result([bot]))) {
    Ok(values) => assert_eq(values[0].id, bot.id)
    Err(reason) => fail("bots.list result did not decode: " + reason)
  }
  match bot_from_result(round_trip_json(bot_result(bot))) {
    Ok(value) => assert_eq(value.name, bot.name)
    Err(reason) => fail("bot result did not decode: " + reason)
  }
  match
    agents_from_result(round_trip_json(agents_list_result([agent]))) {
    Ok(values) => assert_eq(values[0].runtime_binding.hash, "sha256:rpc-binding")
    Err(reason) => fail("bot.agent.list result did not decode: " + reason)
  }
  match agent_from_result(round_trip_json(agent_result(agent))) {
    Ok(value) => assert_eq(value.bot_id, bot.id)
    Err(reason) => fail("bot.agent result did not decode: " + reason)
  }
  let detail = ChatDetail::new(
    chat~,
    participants=[participant],
    active_agent_session=Some(session),
    agent=Some(agent),
  )
  match chat_from_result(round_trip_json(chat_result(detail))) {
    Ok(value) => {
      assert_eq(value.chat.id, chat.id)
      assert_eq(value.participants.length(), 1)
      assert_eq(value.participants[0].bot_id, bot.id)
      match value.active_agent_session {
        Some(active) => assert_eq(active.runtime_session_id, "agt_rpc_runtime")
        None => fail("chat.get lost the active AgentSession")
      }
      match value.agent {
        Some(bound) => assert_eq(bound.id, agent.id)
        None => fail("chat.get lost the bound Agent")
      }
    }
    Err(reason) => fail("chat.get result did not decode: " + reason)
  }
  match
    chats_from_result(round_trip_json(chats_list_result([detail]))) {
    Ok(values) => assert_eq(values[0].chat.id, chat.id)
    Err(reason) => fail("chat.list result did not decode: " + reason)
  }
  match
    chat_agent_session_from_result(
      round_trip_json(chat_agent_session_result(session)),
    ) {
    Ok(value) => assert_eq(value.id, session.id)
    Err(reason) => fail("AgentSession result did not decode: " + reason)
  }
  match
    chat_messages_from_result(
      round_trip_json(chat_messages_result([message])),
    ) {
    Ok(values) => {
      assert_eq(values[0].role, CHAT_MESSAGE_ROLE_ASSISTANT)
      assert_eq(values[0].body, "hello from the mock agent")
    }
    Err(reason) => fail("chat.messages result did not decode: " + reason)
  }
  match
    chat_send_result_from_json(
      round_trip_json(chat_send_result(message, session)),
    ) {
    Some(value) => {
      assert_eq(value.message.id, message.id)
      assert_eq(value.session.id, session.id)
    }
    None => fail("chat.send result did not decode")
  }
  match
    chat_stop_result_from_json(
      round_trip_json(chat_stop_result(session, true)),
    ) {
    Some(value) => assert_true(value.stopped)
    None => fail("chat.stop result did not decode")
  }
  match
    chat_read_result_from_json(
      round_trip_json(chat_read_result(session, 42L, "delta", "dec_1")),
    ) {
    Some(value) => {
      assert_eq(value.session_id, session.id)
      assert_eq(value.runtime_session_id, "agt_rpc_runtime")
      assert_eq(value.cursor, 42L)
      assert_eq(value.text, "delta")
      assert_eq(value.pending_decision, "dec_1")
    }
    None => fail("chat.read result did not decode")
  }
}

///|
test "Project membership RPC params and results round-trip" {
  let membership = ProjectMembership::new(
    project_id="prj_test",
    bot_id="bot_test",
    added_at="2026-11-27T03:10:00Z",
    access=[],
  )
  assert_eq(membership.access.length(), 0)
  let list_result = round_trip_json(
    project_memberships_result([membership]),
  )
  match project_memberships_from_result(list_result) {
    Ok(values) => {
      assert_eq(values.length(), 1)
      assert_eq(values[0].project_id, "prj_test")
      assert_eq(values[0].bot_id, "bot_test")
      assert_eq(values[0].state, MEMBERSHIP_STATE_ACTIVE)
      assert_eq(values[0].access.length(), 0)
    }
    Err(reason) => fail("project.membership.list result did not decode: " + reason)
  }
  match
    project_membership_from_result(
      round_trip_json(project_membership_result(membership)),
    ) {
    Ok(value) => {
      assert_eq(value.project_id, "prj_test")
      assert_eq(value.bot_id, "bot_test")
    }
    Err(reason) => fail("project.membership result did not decode: " + reason)
  }
  let list_params = project_membership_list_params("cid_list")
  assert_eq(project_membership_filter_param(list_params), "")
  assert_eq(
    project_membership_filter_param(
      project_membership_list_params("cid_list", project_id="prj_test"),
    ),
    "prj_test",
  )
  let add_params = project_membership_add_params(
    "cid_add",
    "prj_test",
    "bot_test",
  )
  match project_id_param(add_params) {
    Ok(value) => assert_eq(value, "prj_test")
    Err(reason) => fail("project.membership.add project_id: " + reason)
  }
  match bot_id_param(add_params) {
    Ok(value) => assert_eq(value, "bot_test")
    Err(reason) => fail("project.membership.add bot_id: " + reason)
  }
  let remove_params = project_membership_remove_params(
    "cid_remove",
    "prj_test",
    "bot_test",
    reason="owner revoke",
  )
  assert_eq(bot_reason_param(remove_params), "owner revoke")
  match project_id_param(Map([("bot_id", json_string("bot_test"))])) {
    Ok(_) => fail("missing project_id was accepted")
    Err(reason) => assert_true(reason.contains("missing project_id"))
  }
}

///|
test "ADR-0017 P0.3 RPC params validate and map errors" {
  let bot = bots_rpc_test_bot()
  let agent = bots_rpc_test_agent(bot)
  let chat = bots_rpc_test_chat()
  match bot_record_param(bot_create_params("cid_bot", bot)) {
    Ok(value) => assert_eq(value.id, bot.id)
    Err(reason) => fail("bot.create params did not decode: " + reason)
  }
  match
    agent_record_param(
      bot_agent_create_params("cid_agent", bot.id, agent, source="manual"),
    ) {
    Ok(value) => assert_eq(value.id, agent.id)
    Err(reason) => fail("bot.agent.create params did not decode: " + reason)
  }
  match chat_record_param(chat_create_params("cid_chat", chat, bot.id)) {
    Ok(value) => assert_eq(value.title, "RPC Chat")
    Err(reason) => fail("chat.create params did not decode: " + reason)
  }
  let start_params = chat_agent_session_start_params(
    "cid_start",
    chat.id,
    agent.id,
    "ws_test",
    "/tmp/ws",
  )
  assert_eq(chat_filter_runtime(start_params), agent.id)
  assert_eq(chat_scope_param(start_params), "ws_test")
  assert_eq(chat_workspace_root_param(start_params), "/tmp/ws")
  assert_eq(chat_cursor_param(Map([("cursor", json_int64(-5L))])), 0L)
  assert_eq(chat_limit_param(Map([("limit", json_int(0))])), 1)
  assert_eq(chat_limit_param(Map([("limit", json_int(1_000))])), 200)
  match chat_text_param(Map([("text", json_string("   "))])) {
    Ok(_) => fail("blank Chat text was accepted")
    Err(reason) => assert_true(reason.contains("missing text"))
  }
  assert_eq(
    chat_end_reason_param(chat_stop_params("cid_stop", chat.id)),
    AGENT_SESSION_END_REASON_CANCELLED,
  )
  let not_found = bots_error_from_message("Bot not found: bot_1")
  assert_true(not_found.message.contains("NotFound"))
  let unauthorized = bots_error_from_message("project membership is required")
  assert_true(unauthorized.message.contains("Unauthorized"))
  let membership_conflict = bots_error_from_message(
    "ProjectMembership cannot be removed while the Bot has a non-terminal AgentSession",
  )
  assert_true(membership_conflict.message.contains("Conflict"))
  let conflict = bots_error_from_message("Bot Agent concurrency cap reached")
  assert_true(conflict.message.contains("Conflict"))
  let invalid = bots_error_from_message("bot_id is required")
  assert_true(invalid.message.contains("InvalidRequest"))
}
