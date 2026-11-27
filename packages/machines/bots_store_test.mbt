///|
/// ADR-0017 P0.2 host persistence tests: event/projection atomicity,
/// restart replay, typed legacy aliases and domain invariant rejections.

///|
fn bots_test_binding(hash : String) -> @contracts.RuntimeBinding {
  @contracts.RuntimeBinding::new(
    software_id="claude-code",
    adapter_id="acp",
    launch_kind=@contracts.RUNTIME_LAUNCH_ACP,
    command="/usr/bin/claude",
    args=["--acp"],
    model_profile="balanced",
    hash~,
    tools=["shell"],
    skills=["review"],
  )
}

///|
fn bots_test_bot(name : String, now : String) -> @contracts.BotRecord {
  @contracts.BotRecord::new(
    id=@contracts.new_bot_id(1_000L),
    org_id=@contracts.ORG_LOCAL,
    name~,
    created_at=now,
    persona_ref="persona/builder",
    instructions_ref="instructions/builder",
    memory_ref="bot/memory",
    home="/tmp/bot-home",
    permission_ceiling=["repo:read", "tool:shell"],
    create_policy=@contracts.BOT_CREATE_POLICY_AUTO,
    agent_count_cap=8,
    agent_concurrency_cap=2,
    software_allowlist=["claude-code"],
  )
}

///|
fn bots_test_agent(
  bot : @contracts.BotRecord,
  name : String,
  now : String,
) -> @contracts.AgentRecord {
  @contracts.AgentRecord::new(
    id=@contracts.new_agent_id(1_001L),
    org_id=bot.org_id,
    bot_id=bot.id,
    name~,
    runtime_binding=bots_test_binding("sha256:binding-a"),
    created_at=now,
    specialty="implementation",
    tags=["p0.2"],
    permission_scope=["repo:read"],
    state=@contracts.AGENT_LIFECYCLE_ACTIVE,
  )
}

///|
fn bots_test_chat(
  project_id : String,
  title : String,
  now : String,
) -> @contracts.ChatRecord {
  @contracts.ChatRecord::new(
    id=@contracts.new_chat_id(1_002L),
    org_id=@contracts.ORG_LOCAL,
    title~,
    created_at=now,
    project_id~,
  )
}

///|
fn bots_test_session(
  chat : @contracts.ChatRecord,
  agent : @contracts.AgentRecord,
  now : String,
) -> @contracts.AgentSession {
  @contracts.AgentSession::new(
    id=@contracts.new_agent_session_id(1_003L),
    chat_id=chat.id,
    agent_id=agent.id,
    permission_snapshot_hash="sha256:permission",
    started_at=now,
    project_id=chat.project_id,
  )
}

///|
fn bots_test_membership(
  project_id : String,
  bot_id : String,
  now : String,
) -> @contracts.ProjectMembership {
  @contracts.ProjectMembership::new(
    project_id~,
    bot_id~,
    added_at=now,
    access=["repo:read"],
    reason="owner grant",
  )
}

///|
fn bots_test_open() -> MachineStore raise {
  match MachineStore::open(":memory:") {
    Ok(value) => value
    Err(message) => fail("cannot open in-memory store: " + message)
  }
}

///|
fn bots_test_reset_file(path : String) -> Unit raise {
  let conn = @sqlite3.Connection::open(path) catch {
    error => fail("cannot open test database for reset: " + error.to_string())
  }
  try {
    for table in [
      "search_fts", "search_docs", "webhook_nonces", "webhook_keys",
      "trigger_fires", "triggers", "leases", "decisions", "artifacts",
      "evidence", "runs", "tasks", "projects", "worktrees", "workspaces",
      "legacy_aliases", "project_memberships", "chat_participants", "chats",
      "agents", "bots", "agent_sessions", "machines", "events", "meta",
    ] {
      exec_raise(conn, "DROP TABLE IF EXISTS " + table)
    }
  } catch {
    error => {
      conn.close() catch { _ => () }
      fail("cannot reset test database: " + error.to_string())
    }
  }
  conn.close() catch { _ => () }
}

///|
fn bots_test_seed(
  store : MachineStore,
  now : String,
) -> (@contracts.BotRecord, @contracts.AgentRecord, @contracts.ChatRecord) raise {
  let bot_record = bots_test_bot("Builder", now)
  let bot = match store.create_bot(bot_record, "owner", "test", now) {
    Ok(value) => value
    Err(message) => fail("create_bot failed: " + message)
  }
  let agent_record = bots_test_agent(bot, "Worker", now)
  let agent = match store.create_agent(agent_record, "", "owner", "test", now) {
    Ok(value) => value
    Err(message) => fail("create_agent failed: " + message)
  }
  let chat_record = bots_test_chat("", "P0.2", now)
  let chat = match
    store.create_chat(chat_record, [bot.id], "owner", "test", now) {
    Ok(value) => value
    Err(message) => fail("create_chat failed: " + message)
  }
  (bot, agent, chat)
}

///|
test "bot events replay every complete projection record" {
  let store = bots_test_open()
  let now = "2026-11-27T02:00:00Z"
  let (bot, agent, chat) = bots_test_seed(store, now)
  let project_id = @contracts.new_project_id(1_010L)
  let membership = match
    store.add_project_membership(
      bots_test_membership(project_id, bot.id, now),
      "owner",
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("add_project_membership failed: " + message)
  }
  let renamed_bot = match
    store.update_bot(
      { ..bot, name: "Builder 2" },
      ["name"],
      2,
      now,
      "owner",
    ) {
    Ok(value) => value
    Err(message) => fail("update_bot failed: " + message)
  }
  let renamed_agent = match
    store.update_agent(
      { ..agent, name: "Worker 2" },
      ["name"],
      now,
      "owner",
    ) {
    Ok(value) => value
    Err(message) => fail("update_agent failed: " + message)
  }
  let session_record = bots_test_session(chat, renamed_agent, now)
  let session = match
    store.start_chat_agent_session(session_record, "owner", now) {
    Ok(value) => value
    Err(message) => fail("start_chat_agent_session failed: " + message)
  }
  let active = match
    store.update_chat_agent_session(
      session.id,
      @contracts.AGENT_SESSION_STATE_ACTIVE,
      "rt_1",
      "",
      1,
      0,
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("update_chat_agent_session failed: " + message)
  }
  assert_eq(active.runtime_session_id, "rt_1")
  let first = match store.reconcile_bots_projection() {
    Ok(value) => value
    Err(message) => fail("reconcile_bots_projection failed: " + message)
  }
  assert_eq(first.bots, 1)
  assert_eq(first.agents, 1)
  assert_eq(first.chats, 1)
  assert_eq(first.participants, 1)
  assert_eq(first.sessions, 1)
  assert_eq(first.memberships, 1)
  let replay_bot = match store.get_bot(bot.id) {
    Ok(Some(value)) => value
    Ok(None) => fail("Bot missing after replay")
    Err(message) => fail("get_bot failed: " + message)
  }
  assert_eq(
    replay_bot.to_json().stringify(),
    renamed_bot.to_json().stringify(),
  )
  let replay_agent = match store.get_agent(agent.id) {
    Ok(Some(value)) => value
    Ok(None) => fail("Agent missing after replay")
    Err(message) => fail("get_agent failed: " + message)
  }
  assert_eq(
    replay_agent.to_json().stringify(),
    renamed_agent.to_json().stringify(),
  )
  let replay_session = match store.get_bot_agent_session(session.id) {
    Ok(Some(value)) => value
    Ok(None) => fail("AgentSession missing after replay")
    Err(message) => fail("get_bot_agent_session failed: " + message)
  }
  assert_eq(
    replay_session.to_json().stringify(),
    active.to_json().stringify(),
  )
  let replay_membership = match
    store.get_project_membership(project_id, bot.id) {
    Ok(Some(value)) => value
    Ok(None) => fail("ProjectMembership missing after replay")
    Err(message) => fail("get_project_membership failed: " + message)
  }
  assert_eq(
    replay_membership.to_json().stringify(),
    membership.to_json().stringify(),
  )
  // A second replay replaces the projection instead of duplicating rows.
  let second = match store.reconcile_bots_projection() {
    Ok(value) => value
    Err(message) => fail("second reconcile failed: " + message)
  }
  assert_eq(second.bots, 1)
  assert_eq(second.agents, 1)
  assert_eq(second.chats, 1)
  assert_eq(second.participants, 1)
  assert_eq(second.sessions, 1)
  assert_eq(second.memberships, 1)
  let bots = match store.list_bots() {
    Ok(value) => value
    Err(message) => fail("list_bots failed: " + message)
  }
  assert_eq(bots.length(), 1)
  let sessions = match store.list_chat_agent_sessions(chat.id) {
    Ok(value) => value
    Err(message) => fail("list_chat_agent_sessions failed: " + message)
  }
  assert_eq(sessions.length(), 1)
  store.close()
}

///|
test "bot projection survives close and reopen" {
  let path = "/tmp/monexus-bots-store-" + @contracts.new_id("test", 0L) + ".db"
  let now = "2026-11-27T02:10:00Z"
  bots_test_reset_file(path)
  let first = match MachineStore::open(path) {
    Ok(value) => value
    Err(message) => fail("cannot open file store: " + message)
  }
  let (bot, agent, chat) = bots_test_seed(first, now)
  let project_id = @contracts.new_project_id(1_030L)
  let membership = match
    first.add_project_membership(
      bots_test_membership(project_id, bot.id, now),
      "owner",
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("add_project_membership failed: " + message)
  }
  let project_chat_record = bots_test_chat(project_id, "Project chat", now)
  let project_chat = match
    first.create_chat(project_chat_record, [bot.id], "owner", "test", now) {
    Ok(value) => value
    Err(message) => fail("project create_chat failed: " + message)
  }
  let session = match
    first.start_chat_agent_session(
      bots_test_session(project_chat, agent, now),
      "owner",
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("start_chat_agent_session failed: " + message)
  }
  first.close()
  let second = match MachineStore::open(path) {
    Ok(value) => value
    Err(message) => fail("cannot reopen file store: " + message)
  }
  let persisted_bot = match second.get_bot(bot.id) {
    Ok(Some(value)) => value
    Ok(None) => fail("Bot missing after reopen")
    Err(message) => fail("get_bot failed: " + message)
  }
  assert_eq(
    persisted_bot.to_json().stringify(),
    bot.to_json().stringify(),
  )
  let persisted_agent = match second.get_agent(agent.id) {
    Ok(Some(value)) => value
    Ok(None) => fail("Agent missing after reopen")
    Err(message) => fail("get_agent failed: " + message)
  }
  assert_eq(
    persisted_agent.to_json().stringify(),
    agent.to_json().stringify(),
  )
  let persisted_chat = match second.get_chat(chat.id) {
    Ok(Some(value)) => value
    Ok(None) => fail("Chat missing after reopen")
    Err(message) => fail("get_chat failed: " + message)
  }
  assert_eq(
    persisted_chat.to_json().stringify(),
    chat.to_json().stringify(),
  )
  let persisted_membership = match
    second.get_project_membership(project_id, bot.id) {
    Ok(Some(value)) => value
    Ok(None) => fail("ProjectMembership missing after reopen")
    Err(message) => fail("get_project_membership failed: " + message)
  }
  assert_eq(
    persisted_membership.to_json().stringify(),
    membership.to_json().stringify(),
  )
  let persisted_session = match second.get_bot_agent_session(session.id) {
    Ok(Some(value)) => value
    Ok(None) => fail("AgentSession missing after reopen")
    Err(message) => fail("get_bot_agent_session failed: " + message)
  }
  assert_eq(
    persisted_session.to_json().stringify(),
    session.to_json().stringify(),
  )
  // Replay must produce the same rows from the durable log.
  match second.reconcile_bots_projection() {
    Ok(_) => ()
    Err(message) => fail("reconcile after reopen failed: " + message)
  }
  let replayed_bot = match second.get_bot(bot.id) {
    Ok(Some(value)) => value
    Ok(None) => fail("Bot missing after reopen replay")
    Err(message) => fail("get_bot failed: " + message)
  }
  assert_eq(
    replayed_bot.to_json().stringify(),
    bot.to_json().stringify(),
  )
  let replayed_membership = match
    second.get_project_membership(project_id, bot.id) {
    Ok(Some(value)) => value
    Ok(None) => fail("ProjectMembership missing after reopen replay")
    Err(message) => fail("get_project_membership failed: " + message)
  }
  assert_eq(
    replayed_membership.to_json().stringify(),
    membership.to_json().stringify(),
  )
  let replayed_session = match second.get_bot_agent_session(session.id) {
    Ok(Some(value)) => value
    Ok(None) => fail("AgentSession missing after reopen replay")
    Err(message) => fail("get_bot_agent_session failed: " + message)
  }
  assert_eq(
    replayed_session.to_json().stringify(),
    session.to_json().stringify(),
  )
  second.close()
}

///|
test "crash between event and projection is repaired by reconcile" {
  let store = bots_test_open()
  let now = "2026-11-27T02:20:00Z"
  let bot = bots_test_bot("Crash-safe", now)
  let payload = @contracts.bot_created_payload(
    bot,
    @contracts.bots_permission_set_hash(bot.permission_ceiling),
    "owner",
    "crash-test",
  )
  let event = @contracts.EventEnvelope::new(
    id=@contracts.new_id("evt", 1L),
    org_id=@contracts.ORG_LOCAL,
    event_type=@contracts.EVENT_BOT_CREATED,
    ts=now,
    subject=@contracts.bot_event_subject(bot.id),
    seq=1L,
    payload~,
    idempotency_key="evt/crash-bot-1",
  )
  match store.append_event(event) {
    Ok(inserted) => assert_true(inserted)
    Err(message) => fail("append_event failed: " + message)
  }
  match store.get_bot(bot.id) {
    Ok(Some(_)) => fail("projection should not exist after crash simulation")
    Ok(None) => ()
    Err(message) => fail("get_bot failed: " + message)
  }
  let counts = match store.reconcile_bots_projection() {
    Ok(value) => value
    Err(message) => fail("reconcile failed: " + message)
  }
  assert_eq(counts.bots, 1)
  let restored = match store.get_bot(bot.id) {
    Ok(Some(value)) => value
    Ok(None) => fail("crash event was not replayed")
    Err(message) => fail("get_bot failed: " + message)
  }
  assert_eq(restored.to_json().stringify(), bot.to_json().stringify())
  store.close()
}

///|
test "incomplete bot event rolls back the event and projection" {
  let store = bots_test_open()
  let bot = bots_test_bot("Incomplete", "2026-11-27T02:30:00Z")
  let payload = @contracts.json_object([
    ("bot_id", @contracts.json_string(bot.id)),
  ])
  let event = @contracts.EventEnvelope::new(
    id=@contracts.new_id("evt", 2L),
    org_id=@contracts.ORG_LOCAL,
    event_type=@contracts.EVENT_BOT_CREATED,
    ts="2026-11-27T02:30:00Z",
    subject=@contracts.bot_event_subject(bot.id),
    seq=1L,
    payload~,
    idempotency_key="evt/bad-bot-1",
  )
  match store.append_bot_event(event) {
    Ok(_) => fail("incomplete event was accepted")
    Err(_) => ()
  }
  let seq = match store.last_seq() {
    Ok(value) => value
    Err(message) => fail("last_seq failed: " + message)
  }
  assert_eq(seq, 0L)
  let recent = match store.load_recent_events(10) {
    Ok(value) => value
    Err(message) => fail("load_recent_events failed: " + message)
  }
  assert_eq(recent.length(), 0)
  store.close()
}

///|
test "legacy alias resolution is typed and never guesses" {
  let store = bots_test_open()
  let now = "2026-11-27T02:40:00Z"
  let (bot, agent, chat) = bots_test_seed(store, now)
  let session = match
    store.start_chat_agent_session(
      bots_test_session(chat, agent, now),
      "owner",
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("start_chat_agent_session failed: " + message)
  }
  let value = "agt_legacy_shared"
  match
    store.put_legacy_alias(
      "agent_identity",
      value,
      "bot",
      bot.id,
      "mig_1",
      now,
    ) {
    Ok(_) => ()
    Err(message) => fail("agent_identity alias failed: " + message)
  }
  match
    store.put_legacy_alias(
      "agent_session",
      value,
      "agent_session",
      session.id,
      "mig_1",
      now,
    ) {
    Ok(_) => ()
    Err(message) => fail("agent_session alias failed: " + message)
  }
  match
    store.put_legacy_alias(
      "architecture_session",
      value,
      "agent_session",
      session.id,
      "mig_1",
      now,
    ) {
    Ok(_) => ()
    Err(message) => fail("architecture_session alias failed: " + message)
  }
  let as_bot = match store.resolve_legacy_alias("agent_identity", value) {
    Ok(Some(target)) => target
    Ok(None) => fail("agent_identity alias missing")
    Err(message) => fail("resolve agent_identity failed: " + message)
  }
  assert_eq(as_bot.canonical_kind, "bot")
  assert_eq(as_bot.canonical_id, bot.id)
  let as_session = match store.resolve_legacy_alias("agent_session", value) {
    Ok(Some(target)) => target
    Ok(None) => fail("agent_session alias missing")
    Err(message) => fail("resolve agent_session failed: " + message)
  }
  assert_eq(as_session.canonical_kind, "agent_session")
  assert_eq(as_session.canonical_id, session.id)
  let as_architecture = match
    store.resolve_legacy_alias("architecture_session", value) {
    Ok(Some(target)) => target
    Ok(None) => fail("architecture_session alias missing")
    Err(message) => fail("resolve architecture_session failed: " + message)
  }
  assert_eq(as_architecture.canonical_id, session.id)
  match store.resolve_legacy_alias("", value) {
    Ok(_) => fail("untyped alias lookup guessed a target")
    Err(_) => ()
  }
  match store.resolve_legacy_alias("unknown_kind", value) {
    Ok(_) => fail("unknown alias kind was accepted")
    Err(_) => ()
  }
  let other_bot = bots_test_bot("Other", now)
  match
    store.put_legacy_alias(
      "agent_identity",
      value,
      "bot",
      other_bot.id,
      "mig_2",
      now,
    ) {
    Ok(_) => fail("alias overwrite to a different target was accepted")
    Err(_) => ()
  }
  store.close()
}

///|
test "Agent cannot move to a second Bot" {
  let store = bots_test_open()
  let now = "2026-11-27T02:50:00Z"
  let (_, agent, _) = bots_test_seed(store, now)
  let second_bot_record = bots_test_bot("Second", now)
  let second_bot = match
    store.create_bot(second_bot_record, "owner", "test", now) {
    Ok(value) => value
    Err(message) => fail("second create_bot failed: " + message)
  }
  match
    store.update_agent(
      { ..agent, bot_id: second_bot.id },
      ["bot_id"],
      now,
      "owner",
    ) {
    Ok(_) => fail("Agent moved to a second Bot")
    Err(_) => ()
  }
  match
    store.create_agent(
      { ..agent, bot_id: second_bot.id },
      "",
      "owner",
      "test",
      now,
    ) {
    Ok(_) => fail("a second Bot reused an existing Agent id")
    Err(_) => ()
  }
  store.close()
}

///|
test "Chat requires exactly one active Bot participant" {
  let store = bots_test_open()
  let now = "2026-11-27T03:00:00Z"
  let (bot, _, _) = bots_test_seed(store, now)
  let second_bot_record = bots_test_bot("Second", now)
  let second_bot = match
    store.create_bot(second_bot_record, "owner", "test", now) {
    Ok(value) => value
    Err(message) => fail("second create_bot failed: " + message)
  }
  match
    store.create_chat(bots_test_chat("", "Empty", now), [], "owner", "test", now) {
    Ok(_) => fail("Chat with zero participants was accepted")
    Err(_) => ()
  }
  match
    store.create_chat(
      bots_test_chat("", "Two", now),
      [bot.id, second_bot.id],
      "owner",
      "test",
      now,
    ) {
    Ok(_) => fail("Chat with two active participants was accepted")
    Err(_) => ()
  }
  match
    store.create_chat(
      bots_test_chat("", "Duplicate", now),
      [bot.id, bot.id],
      "owner",
      "test",
      now,
    ) {
    Ok(_) => fail("Chat with a duplicate participant was accepted")
    Err(_) => ()
  }
  store.close()
}

///|
test "project Chat requires an active membership" {
  let store = bots_test_open()
  let now = "2026-11-27T03:10:00Z"
  let (bot, _, _) = bots_test_seed(store, now)
  let second_bot_record = bots_test_bot("Second", now)
  let second_bot = match
    store.create_bot(second_bot_record, "owner", "test", now) {
    Ok(value) => value
    Err(message) => fail("second create_bot failed: " + message)
  }
  let project_id = @contracts.new_project_id(1_020L)
  match
    store.add_project_membership(
      bots_test_membership(project_id, bot.id, now),
      "owner",
      now,
    ) {
    Ok(_) => ()
    Err(message) => fail("add_project_membership failed: " + message)
  }
  match
    store.create_chat(
      bots_test_chat(project_id, "No membership", now),
      [second_bot.id],
      "owner",
      "test",
      now,
    ) {
    Ok(_) => fail("project Chat without membership was accepted")
    Err(_) => ()
  }
  match
    store.create_chat(
      bots_test_chat(project_id, "With membership", now),
      [bot.id],
      "owner",
      "test",
      now,
    ) {
    Ok(_) => ()
    Err(message) => fail("authorized project Chat failed: " + message)
  }
  store.close()
}

///|
test "Chat allows only one non-terminal AgentSession" {
  let store = bots_test_open()
  let now = "2026-11-27T03:20:00Z"
  let (_, agent, chat) = bots_test_seed(store, now)
  let first = match
    store.start_chat_agent_session(
      bots_test_session(chat, agent, now),
      "owner",
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("first session failed: " + message)
  }
  match
    store.start_chat_agent_session(
      bots_test_session(chat, agent, now),
      "owner",
      now,
    ) {
    Ok(_) => fail("second non-terminal AgentSession was accepted")
    Err(_) => ()
  }
  match
    store.update_chat_agent_session(
      first.id,
      @contracts.AGENT_SESSION_STATE_ACTIVE,
      "rt_1",
      "",
      1,
      0,
      now,
    ) {
    Ok(_) => ()
    Err(message) => fail("session activation failed: " + message)
  }
  match
    store.update_chat_agent_session(
      first.id,
      @contracts.AGENT_SESSION_STATE_ENDING,
      "",
      "chat/summary-1.md",
      2,
      1,
      now,
    ) {
    Ok(_) => ()
    Err(message) => fail("session ending failed: " + message)
  }
  let ended = match
    store.end_chat_agent_session(
      first.id,
      @contracts.AGENT_SESSION_STATE_ENDED,
      @contracts.AGENT_SESSION_END_REASON_TURN_END,
      "chat/summary-1.md",
      "",
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("end session failed: " + message)
  }
  assert_eq(ended.state, @contracts.AGENT_SESSION_STATE_ENDED)
  match
    store.start_chat_agent_session(
      bots_test_session(chat, agent, now),
      "owner",
      now,
    ) {
    Ok(_) => ()
    Err(message) => fail("session after terminal was rejected: " + message)
  }
  match store.reconcile_bots_projection() {
    Ok(_) => ()
    Err(message) => fail("reconcile sessions failed: " + message)
  }
  let sessions = match store.list_chat_agent_sessions(chat.id) {
    Ok(value) => value
    Err(message) => fail("list sessions failed: " + message)
  }
  assert_eq(sessions.length(), 2)
  store.close()
}

///|
test "project membership removal waits for the AgentSession to end" {
  let store = bots_test_open()
  let now = "2026-11-27T03:25:00Z"
  let (bot, agent, _) = bots_test_seed(store, now)
  let project_id = @contracts.new_project_id(1_040L)
  match
    store.add_project_membership(
      bots_test_membership(project_id, bot.id, now),
      "owner",
      now,
    ) {
    Ok(_) => ()
    Err(message) => fail("add_project_membership failed: " + message)
  }
  let project_chat = match
    store.create_chat(
      bots_test_chat(project_id, "Project chat", now),
      [bot.id],
      "owner",
      "test",
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("project create_chat failed: " + message)
  }
  let session = match
    store.start_chat_agent_session(
      bots_test_session(project_chat, agent, now),
      "owner",
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("start_chat_agent_session failed: " + message)
  }
  match
    store.remove_project_membership(
      project_id,
      bot.id,
      "owner revoke",
      "owner",
      now,
    ) {
    Ok(_) => fail("membership removed while a non-terminal session existed")
    Err(_) => ()
  }
  match
    store.end_chat_agent_session(
      session.id,
      @contracts.AGENT_SESSION_STATE_FAILED,
      @contracts.AGENT_SESSION_END_REASON_ERROR,
      "",
      "",
      now,
    ) {
    Ok(_) => ()
    Err(message) => fail("end session failed: " + message)
  }
  let removed = match
    store.remove_project_membership(
      project_id,
      bot.id,
      "owner revoke",
      "owner",
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("membership removal after session end failed: " + message)
  }
  assert_eq(removed.state, @contracts.MEMBERSHIP_STATE_REMOVED)
  match store.reconcile_bots_projection() {
    Ok(_) => ()
    Err(message) => fail("reconcile failed: " + message)
  }
  let replayed = match store.get_project_membership(project_id, bot.id) {
    Ok(Some(value)) => value
    Ok(None) => fail("removed membership tombstone disappeared")
    Err(message) => fail("get_project_membership failed: " + message)
  }
  assert_eq(replayed.state, @contracts.MEMBERSHIP_STATE_REMOVED)
  store.close()
}

///|
test "runtime binding is immutable" {
  let store = bots_test_open()
  let now = "2026-11-27T03:30:00Z"
  let (_, agent, _) = bots_test_seed(store, now)
  let changed_binding = bots_test_binding("sha256:binding-b")
  match
    store.update_agent(
      { ..agent, runtime_binding: changed_binding },
      ["runtime_binding"],
      now,
      "owner",
    ) {
    Ok(_) => fail("runtime binding change was accepted")
    Err(_) => ()
  }
  let current = match store.get_agent(agent.id) {
    Ok(Some(value)) => value
    Ok(None) => fail("Agent missing")
    Err(message) => fail("get_agent failed: " + message)
  }
  assert_eq(
    current.runtime_binding.hash,
    agent.runtime_binding.hash,
  )
  store.close()
}

///|
test "Bot and Agent permissions cannot widen silently" {
  let store = bots_test_open()
  let now = "2026-11-27T03:40:00Z"
  let (bot, _, _) = bots_test_seed(store, now)
  match
    store.update_bot_permissions(
      bot.id,
      ["repo:read", "tool:shell", "tool:network"],
      false,
      now,
      "owner",
    ) {
    Ok(_) => fail("Bot permission widening was accepted")
    Err(_) => ()
  }
  let original = match store.get_bot(bot.id) {
    Ok(Some(value)) => value
    Ok(None) => fail("Bot missing")
    Err(message) => fail("get_bot failed: " + message)
  }
  assert_eq(original.permission_ceiling.length(), 2)
  let widened_agent = bots_test_agent(bot, "Overreach", now)
  match
    store.create_agent(
      { ..widened_agent, permission_scope: ["repo:read", "tool:network"] },
      "",
      "owner",
      "test",
      now,
    ) {
    Ok(_) => fail("Agent permission scope above the Bot ceiling was accepted")
    Err(_) => ()
  }
  store.close()
}

///|
test "archived Bot is readable but immutable and unusable" {
  let store = bots_test_open()
  let now = "2026-11-27T03:50:00Z"
  let (bot, agent, chat) = bots_test_seed(store, now)
  let archived = match store.archive_bot(bot.id, "owner archive", now, "owner") {
    Ok(value) => value
    Err(message) => fail("archive_bot failed: " + message)
  }
  assert_eq(archived.state, @contracts.BOT_STATE_ARCHIVED)
  let readable = match store.get_bot(bot.id) {
    Ok(Some(value)) => value
    Ok(None) => fail("archived Bot was not readable")
    Err(message) => fail("get_bot failed: " + message)
  }
  assert_eq(readable.state, @contracts.BOT_STATE_ARCHIVED)
  match
    store.update_bot(
      { ..readable, state: @contracts.BOT_STATE_ACTIVE, name: "Restored" },
      ["name", "state"],
      2,
      now,
      "owner",
    ) {
    Ok(_) => fail("archived Bot was restored")
    Err(_) => ()
  }
  match
    store.update_bot_permissions(
      bot.id,
      ["repo:read"],
      false,
      now,
      "owner",
    ) {
    Ok(_) => fail("archived Bot permissions were changed")
    Err(_) => ()
  }
  match
    store.start_chat_agent_session(
      bots_test_session(chat, agent, now),
      "owner",
      now,
    ) {
    Ok(_) => fail("archived Bot started an AgentSession")
    Err(_) => ()
  }
  let replacement = bots_test_agent(bot, "Replacement", now)
  match
    store.create_agent(replacement, "", "owner", "test", now) {
    Ok(_) => fail("archived Bot created an Agent")
    Err(_) => ()
  }
  store.close()
}
