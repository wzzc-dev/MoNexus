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
