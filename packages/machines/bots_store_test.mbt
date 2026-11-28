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
fn bots_test_ensure_project(
  store : MachineStore,
  project_id : String,
  now : String,
) -> Unit raise {
  match store.get_project(project_id) {
    Ok(Some(_)) => return
    Ok(None) => ()
    Err(message) => fail("get_project failed: " + message)
  }
  let seq = match store.last_seq() {
    Ok(value) => value
    Err(message) => fail("last_seq failed: " + message)
  }
  let record = @contracts.ProjectRecord::new(
    id=project_id,
    name="Membership project",
    repo_url="",
    default_branch="main",
    verify=[],
    created_at=now,
  )
  let event = @contracts.EventEnvelope::new(
    id="evt_" + project_id,
    org_id=@contracts.ORG_LOCAL,
    event_type=@contracts.EVENT_PROJECT_CREATED,
    ts=now,
    subject="project/" + project_id,
    seq=seq + 1L,
    payload=record.to_json(),
    idempotency_key="evt/" + project_id,
  )
  match store.record_project_event(event, record) {
    Ok(_) => ()
    Err(message) => fail("record_project_event failed: " + message)
  }
}

///|
fn bots_test_sqlite_text(error : Error) -> String {
  error.to_string()
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
    error =>
      fail("cannot open test database for reset: " + bots_test_sqlite_text(error))
  }
  try {
    for table in [
      "search_fts", "search_docs", "webhook_nonces", "webhook_keys",
      "trigger_fires", "triggers", "leases", "decisions", "artifacts",
      "evidence", "runs", "tasks", "projects", "worktrees", "workspaces",
      "legacy_aliases", "project_memberships", "chat_participants", "chats",
      "chat_messages", "chat_transcripts", "agents", "bots", "agent_sessions",
      "machines", "events", "meta",
    ] {
      let stmt = conn.prepare("DROP TABLE IF EXISTS " + table)
      let _ = stmt.step()
      stmt.finalize()
    }
  } catch {
    error => {
      conn.close() catch { _ => () }
      fail("cannot reset test database: " + bots_test_sqlite_text(error))
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
  bots_test_ensure_project(store, project_id, now)
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
  bots_test_ensure_project(first, project_id, now)
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
  // A later raw append must also be picked up by the next reconcile, which
  // reads the full log after taking the writer lock.
  let later_bot = bots_test_bot("Crash-safe 2", now)
  let later_payload = @contracts.bot_created_payload(
    later_bot,
    @contracts.bots_permission_set_hash(later_bot.permission_ceiling),
    "owner",
    "crash-test",
  )
  let later_event = @contracts.EventEnvelope::new(
    id=@contracts.new_id("evt", 2L),
    org_id=@contracts.ORG_LOCAL,
    event_type=@contracts.EVENT_BOT_CREATED,
    ts=now,
    subject=@contracts.bot_event_subject(later_bot.id),
    seq=2L,
    payload=later_payload,
    idempotency_key="evt/crash-bot-2",
  )
  match store.append_event(later_event) {
    Ok(inserted) => assert_true(inserted)
    Err(message) => fail("second append_event failed: " + message)
  }
  let second_counts = match store.reconcile_bots_projection() {
    Ok(value) => value
    Err(message) => fail("second reconcile failed: " + message)
  }
  assert_eq(second_counts.bots, 2)
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
  bots_test_ensure_project(store, project_id, now)
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
  bots_test_ensure_project(store, project_id, now)
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
test "membership add rejects unknown Project, unknown Bot and archived Bot" {
  let store = bots_test_open()
  let now = "2026-11-27T03:27:00Z"
  let (bot, _, _) = bots_test_seed(store, now)
  let missing_project = @contracts.new_project_id(1_041L)
  match
    store.add_project_membership(
      @contracts.ProjectMembership::new(
        project_id=missing_project,
        bot_id=bot.id,
        added_at=now,
        access=[],
      ),
      "owner",
      now,
    ) {
    Ok(_) => fail("membership accepted an unknown Project")
    Err(message) => assert_true(message.contains("Project not found"))
  }
  let project_id = @contracts.new_project_id(1_042L)
  bots_test_ensure_project(store, project_id, now)
  let missing_bot = @contracts.new_bot_id(1_043L)
  match
    store.add_project_membership(
      @contracts.ProjectMembership::new(
        project_id~,
        bot_id=missing_bot,
        added_at=now,
        access=[],
      ),
      "owner",
      now,
    ) {
    Ok(_) => fail("membership accepted an unknown Bot")
    Err(message) => assert_true(message.contains("Bot not found"))
  }
  let archived = match
    store.create_bot(
      { ..bots_test_bot("Archived", now), id: @contracts.new_bot_id(1_044L) },
      "owner",
      "test",
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("create archived Bot failed: " + message)
  }
  match store.archive_bot(archived.id, "retired", now, "owner") {
    Ok(_) => ()
    Err(message) => fail("archive_bot failed: " + message)
  }
  match
    store.add_project_membership(
      @contracts.ProjectMembership::new(
        project_id~,
        bot_id=archived.id,
        added_at=now,
        access=[],
      ),
      "owner",
      now,
    ) {
    Ok(_) => fail("membership accepted an archived Bot")
    Err(message) => assert_true(message.contains("archived"))
  }
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

///|
test "Bot Agent concurrency cap is enforced when a session starts" {
  let store = bots_test_open()
  let now = "2026-11-27T04:00:00Z"
  let bot = match
    store.create_bot(
      { ..bots_test_bot("Concurrency", now), agent_concurrency_cap: 1 },
      "owner",
      "test",
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("create_bot failed: " + message)
  }
  let first_agent = match
    store.create_agent(
      bots_test_agent(bot, "First", now),
      "",
      "owner",
      "test",
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("first create_agent failed: " + message)
  }
  let second_agent = match
    store.create_agent(
      bots_test_agent(bot, "Second", now),
      "",
      "owner",
      "test",
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("second create_agent failed: " + message)
  }
  let first_chat = match
    store.create_chat(
      bots_test_chat("", "First chat", now),
      [bot.id],
      "owner",
      "test",
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("first create_chat failed: " + message)
  }
  let second_chat = match
    store.create_chat(
      bots_test_chat("", "Second chat", now),
      [bot.id],
      "owner",
      "test",
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("second create_chat failed: " + message)
  }
  let first_session = match
    store.start_chat_agent_session(
      bots_test_session(first_chat, first_agent, now),
      "owner",
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("first session failed: " + message)
  }
  let rejection = match
    store.start_chat_agent_session(
      bots_test_session(second_chat, second_agent, now),
      "owner",
      now,
    ) {
    Ok(_) => fail("second Bot-wide AgentSession exceeded the concurrency cap")
    Err(message) => message
  }
  assert_true(rejection.contains("concurrency"))
  match
    store.end_chat_agent_session(
      first_session.id,
      @contracts.AGENT_SESSION_STATE_FAILED,
      @contracts.AGENT_SESSION_END_REASON_ERROR,
      "",
      "",
      now,
    ) {
    Ok(_) => ()
    Err(message) => fail("end first session failed: " + message)
  }
  let second_session = match
    store.start_chat_agent_session(
      bots_test_session(second_chat, second_agent, now),
      "owner",
      now,
    ) {
    Ok(value) => value
    Err(message) =>
      fail("session after a terminal session was rejected: " + message)
  }
  assert_eq(second_session.agent_id, second_agent.id)
  store.close()
}

///|
test "membership removal uses the Bot org and reactivation clears access" {
  let store = bots_test_open()
  let now = "2026-11-27T04:10:00Z"
  let bot = match
    store.create_bot(
      { ..bots_test_bot("Org Bot", now), org_id: "org_alpha" },
      "owner",
      "test",
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("create_bot failed: " + message)
  }
  let project_id = @contracts.new_project_id(1_050L)
  bots_test_ensure_project(store, project_id, now)
  let membership = match
    store.add_project_membership(
      bots_test_membership(project_id, bot.id, now),
      "owner",
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("add_project_membership failed: " + message)
  }
  assert_eq(membership.access.length(), 1)
  let removed = match
    store.remove_project_membership(
      project_id,
      bot.id,
      "owner revoke",
      "owner",
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("remove_project_membership failed: " + message)
  }
  let events = match store.load_recent_events(20) {
    Ok(value) => value
    Err(message) => fail("load_recent_events failed: " + message)
  }
  let mut removed_org = ""
  for event in events {
    if event.event_type == @contracts.EVENT_PROJECT_MEMBER_REMOVED {
      removed_org = event.org_id
    }
  }
  assert_eq(removed_org, "org_alpha")
  let restored = match
    store.add_project_membership(
      @contracts.ProjectMembership::new(
        project_id~,
        bot_id=bot.id,
        added_at=now,
        access=[],
        reason="",
      ),
      "owner",
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("reactivating membership failed: " + message)
  }
  assert_eq(restored.state, @contracts.MEMBERSHIP_STATE_ACTIVE)
  assert_eq(restored.access.length(), 0)
  assert_eq(restored.reason, "")
  assert_eq(restored.removed_at, "")
  store.close()
}

///|
test "project change and participant removal replay generic records" {
  let store = bots_test_open()
  let now = "2026-11-27T04:20:00Z"
  let (bot, _, chat) = bots_test_seed(store, now)
  let project_id = @contracts.new_project_id(1_060L)
  bots_test_ensure_project(store, project_id, now)
  match
    store.add_project_membership(
      bots_test_membership(project_id, bot.id, now),
      "owner",
      now,
    ) {
    Ok(_) => ()
    Err(message) => fail("add_project_membership failed: " + message)
  }
  let moved_chat = { ..chat, project_id, updated_at: now }
  let project_payload = @contracts.chat_project_changed_payload(
    moved_chat,
    chat.project_id,
    "active membership",
    "owner",
  )
  match
    store.append_bots_event(
      @contracts.EVENT_CHAT_PROJECT_CHANGED,
      @contracts.chat_event_subject(chat.id),
      project_payload,
      now,
      chat.org_id,
    ) {
    Ok(_) => ()
    Err(message) => fail("chat.project.changed append failed: " + message)
  }
  let active_participant = @contracts.ChatParticipant::new(
    chat_id=chat.id,
    bot_id=bot.id,
    added_at=now,
  )
  let removed_participant = {
    ..active_participant,
    state: @contracts.PARTICIPANT_STATE_REMOVED,
    removed_at: now,
  }
  let removal_payload = @contracts.chat_participant_removed_payload(
    removed_participant,
    "owner removal",
    false,
    "owner",
  )
  match
    store.append_bots_event(
      @contracts.EVENT_CHAT_PARTICIPANT_REMOVED,
      @contracts.chat_event_subject(chat.id),
      removal_payload,
      now,
      chat.org_id,
    ) {
    Ok(_) => ()
    Err(message) => fail("chat.participant.removed append failed: " + message)
  }
  match store.reconcile_bots_projection() {
    Ok(_) => ()
    Err(message) => fail("reconcile failed: " + message)
  }
  let replayed_chat = match store.get_chat(chat.id) {
    Ok(Some(value)) => value
    Ok(None) => fail("Chat missing after replay")
    Err(message) => fail("get_chat failed: " + message)
  }
  assert_eq(replayed_chat.project_id, project_id)
  let replayed_participant = match
    store.get_chat_participant(chat.id, bot.id) {
    Ok(Some(value)) => value
    Ok(None) => fail("participant tombstone missing after replay")
    Err(message) => fail("get_chat_participant failed: " + message)
  }
  assert_eq(replayed_participant.state, @contracts.PARTICIPANT_STATE_REMOVED)
  assert_eq(replayed_participant.removed_at, now)
  store.close()
}

///|
fn bots_test_message(
  chat : @contracts.ChatRecord,
  session_id : String,
  role : String,
  body : String,
  now : String,
) -> @contracts.ChatMessage {
  let seed = if role == @contracts.CHAT_MESSAGE_ROLE_USER {
    2_001L
  } else {
    2_002L
  }
  @contracts.ChatMessage::new(
    id=@contracts.new_id("msg", seed),
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
test "chat messages project, paginate and replay from full record snapshots" {
  let store = bots_test_open()
  let now = "2026-11-27T02:20:00Z"
  let (_bot, agent, chat) = bots_test_seed(store, now)
  let session = match
    store.start_chat_agent_session(
      bots_test_session(chat, agent, now),
      "owner",
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("start_chat_agent_session failed: " + message)
  }
  let active = match
    store.update_chat_agent_session(
      session.id,
      @contracts.AGENT_SESSION_STATE_ACTIVE,
      "rt_msg",
      "",
      0,
      0,
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("update_chat_agent_session failed: " + message)
  }
  assert_eq(active.runtime_session_id, "rt_msg")
  let user = match
    store.append_chat_message(
      bots_test_message(chat, "", @contracts.CHAT_MESSAGE_ROLE_USER, "hello", now),
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("append user message failed: " + message)
  }
  let assistant = match
    store.append_chat_message(
      bots_test_message(
        chat,
        session.id,
        @contracts.CHAT_MESSAGE_ROLE_ASSISTANT,
        "hi there",
        now,
      ),
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("append assistant message failed: " + message)
  }
  assert_true(user.digest != "")
  assert_true(assistant.digest != "")
  let all = match store.list_chat_messages(chat.id, "", 10) {
    Ok(value) => value
    Err(message) => fail("list_chat_messages failed: " + message)
  }
  assert_eq(all.length(), 2)
  assert_eq(all[0].id, user.id)
  assert_eq(all[1].id, assistant.id)
  assert_eq(all[1].agent_session_id, session.id)
  let after_user = match store.list_chat_messages(chat.id, user.id, 10) {
    Ok(value) => value
    Err(message) => fail("paged list_chat_messages failed: " + message)
  }
  assert_eq(after_user.length(), 1)
  assert_eq(after_user[0].id, assistant.id)
  match store.append_chat_message(user, now) {
    Ok(_) => fail("duplicate ChatMessage was appended")
    Err(message) => assert_true(message.contains("already exists"))
  }
  // The payload carries the full record, so replay reconstructs the projection.
  match store.reconcile_bots_projection() {
    Ok(_) => ()
    Err(message) => fail("reconcile failed: " + message)
  }
  let replayed = match store.list_chat_messages(chat.id, "", 10) {
    Ok(value) => value
    Err(message) => fail("replayed list_chat_messages failed: " + message)
  }
  assert_eq(replayed.length(), 2)
  assert_eq(replayed[0].body, "hello")
  assert_eq(replayed[1].body, "hi there")
  match store.get_chat_message(assistant.id) {
    Ok(Some(value)) => assert_eq(value.agent_session_id, session.id)
    Ok(None) => fail("assistant message missing after replay")
    Err(message) => fail("get_chat_message failed: " + message)
  }
  store.close()
}

///|
test "invalid runtime binding cannot start a Chat AgentSession" {
  let store = bots_test_open()
  let now = "2026-11-27T02:30:00Z"
  let bot = match
    store.create_bot(bots_test_bot("Builder", now), "owner", "test", now) {
    Ok(value) => value
    Err(message) => fail("create_bot failed: " + message)
  }
  // A binding with a hash but no canonical launch details passes Agent
  // creation and must still be rejected when a session tries to run it.
  let invalid_binding = @contracts.RuntimeBinding::new(
    software_id="claude-code",
    adapter_id="acp",
    launch_kind=@contracts.RUNTIME_LAUNCH_COMMAND,
    command="",
    args=[],
    model_profile="balanced",
    hash="sha256:invalid-binding",
  )
  let agent = match
    store.create_agent(
      @contracts.AgentRecord::new(
        id=@contracts.new_agent_id(2_101L),
        org_id=bot.org_id,
        bot_id=bot.id,
        name="Broken worker",
        runtime_binding=invalid_binding,
        created_at=now,
        permission_scope=["repo:read"],
        state=@contracts.AGENT_LIFECYCLE_ACTIVE,
      ),
      "",
      "owner",
      "test",
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("create_agent failed: " + message)
  }
  let chat = match
    store.create_chat(
      @contracts.ChatRecord::new(
        id=@contracts.new_chat_id(2_102L),
        org_id=bot.org_id,
        title="Broken runtime",
        created_at=now,
      ),
      [bot.id],
      "owner",
      "test",
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("create_chat failed: " + message)
  }
  match
    store.start_chat_agent_session(
      bots_test_session(chat, agent, now),
      "owner",
      now,
    ) {
    Ok(_) => fail("invalid runtime binding started an AgentSession")
    Err(message) => assert_true(message.contains("runtime binding is invalid"))
  }
  store.close()
}

///|
test "suspended Bot cannot start a Chat AgentSession" {
  let store = bots_test_open()
  let now = "2026-11-27T02:40:00Z"
  let (bot, agent, chat) = bots_test_seed(store, now)
  let suspended = {
    ..bot,
    state: @contracts.BOT_STATE_SUSPENDED,
    updated_at: now,
  }
  let payload = @contracts.bot_updated_payload(
    suspended,
    ["state"],
    2,
    "owner",
  )
  match
    store.append_bots_event(
      @contracts.EVENT_BOT_UPDATED,
      @contracts.bot_event_subject(bot.id),
      payload,
      now,
      bot.org_id,
    ) {
    Ok(_) => ()
    Err(message) => fail("cannot persist suspended Bot: " + message)
  }
  let stored = match store.get_bot(bot.id) {
    Ok(Some(value)) => value
    Ok(None) => fail("suspended Bot disappeared")
    Err(message) => fail("get_bot failed: " + message)
  }
  assert_eq(stored.state, @contracts.BOT_STATE_SUSPENDED)
  match
    store.start_chat_agent_session(
      bots_test_session(chat, agent, now),
      "owner",
      now,
    ) {
    Ok(_) => fail("suspended Bot started an AgentSession")
    Err(message) => assert_true(message.contains("Bot is not active"))
  }
  store.close()
}

///|
test "archived Chat rejects sessions and new messages" {
  let store = bots_test_open()
  let now = "2026-11-27T02:50:00Z"
  let (bot, agent, chat) = bots_test_seed(store, now)
  let archived = { ..chat, state: @contracts.CHAT_STATE_ARCHIVED, updated_at: now }
  let payload = @contracts.chat_project_changed_payload(
    archived,
    "",
    "owner archive",
    "owner",
  )
  match
    store.append_bots_event(
      @contracts.EVENT_CHAT_PROJECT_CHANGED,
      @contracts.chat_event_subject(chat.id),
      payload,
      now,
      chat.org_id,
    ) {
    Ok(_) => ()
    Err(message) => fail("cannot persist archived Chat: " + message)
  }
  let stored = match store.get_chat(chat.id) {
    Ok(Some(value)) => value
    Ok(None) => fail("archived Chat disappeared")
    Err(message) => fail("get_chat failed: " + message)
  }
  assert_eq(stored.state, @contracts.CHAT_STATE_ARCHIVED)
  match
    store.start_chat_agent_session(
      bots_test_session(chat, agent, now),
      "owner",
      now,
    ) {
    Ok(_) => fail("archived Chat started an AgentSession")
    Err(message) => assert_true(message.contains("archived Chat is read-only"))
  }
  match
    store.append_chat_message(
      bots_test_message(chat, "", @contracts.CHAT_MESSAGE_ROLE_USER, "hello", now),
      now,
    ) {
    Ok(_) => fail("archived Chat accepted a new message")
    Err(message) => assert_true(message.contains("archived Chat is read-only"))
  }
  store.close()
}

///|
test "chat transcript persists across reopen and degrades safely" {
  let path = "/tmp/monexus-chat-transcript-" +
    @contracts.new_id("test", 0L) +
    ".db"
  bots_test_reset_file(path)
  let now = "2026-11-27T03:00:00Z"
  let first = match MachineStore::open(path) {
    Ok(value) => value
    Err(message) => fail("cannot open file store: " + message)
  }
  let (_bot, agent, chat) = bots_test_seed(first, now)
  let session = match
    first.start_chat_agent_session(
      bots_test_session(chat, agent, now),
      "owner",
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("start_chat_agent_session failed: " + message)
  }
  match first.save_chat_transcript(session.id, 1_024L, "first", now) {
    Ok(_) => ()
    Err(message) => fail("save_chat_transcript failed: " + message)
  }
  let claimed = match
    first.claim_chat_context_injection(session.id, now) {
    Ok(value) => value
    Err(message) => fail("claim_chat_context_injection failed: " + message)
  }
  assert_true(claimed)
  let claimed_again = match
    first.claim_chat_context_injection(session.id, now) {
    Ok(value) => value
    Err(message) => fail("second claim failed: " + message)
  }
  assert_false(claimed_again)
  match
    first.save_chat_transcript(session.id, 2_048L, "last-汉", "2026-11-27T03:01:00Z") {
    Ok(_) => ()
    Err(message) => fail("second save_chat_transcript failed: " + message)
  }
  let missing = match first.load_chat_transcript("asn_missing") {
    Ok(value) => value
    Err(_) => fail("missing transcript must degrade to None")
  }
  match missing {
    Some(_) => fail("missing transcript returned a record")
    None => ()
  }
  first.close()
  let second = match MachineStore::open(path) {
    Ok(value) => value
    Err(message) => fail("cannot reopen file store: " + message)
  }
  let restored = match second.load_chat_transcript(session.id) {
    Ok(Some(value)) => value
    Ok(None) => fail("chat transcript missing after reopen")
    Err(message) => fail("load_chat_transcript failed: " + message)
  }
  assert_eq(restored.base, 2_048L)
  assert_eq(restored.text, "last-汉")
  assert_true(restored.context_injected)
  let stmt = second.conn.prepare(
    "UPDATE chat_transcripts SET base=-1 WHERE session_id=?1",
  )
  stmt.bind(index=1, session.id)
  let _ = stmt.step()
  stmt.finalize()
  let corrupt = match second.load_chat_transcript(session.id) {
    Ok(value) => value
    Err(_) => fail("corrupt transcript must degrade to None")
  }
  match corrupt {
    Some(_) => fail("corrupt transcript returned a record")
    None => ()
  }
  second.close()
}

///|
test "chat handoff history is newest-first and excludes system/current" {
  let store = bots_test_open()
  let now = "2026-11-27T03:10:00Z"
  let (_bot, agent, chat) = bots_test_seed(store, now)
  let session = match
    store.start_chat_agent_session(
      bots_test_session(chat, agent, now),
      "owner",
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("start_chat_agent_session failed: " + message)
  }
  let older = match
    store.append_chat_message(
      bots_test_message(chat, session.id, @contracts.CHAT_MESSAGE_ROLE_USER, "older", now),
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("append older failed: " + message)
  }
  match
    store.append_chat_message(
      bots_test_message(
        chat,
        session.id,
        @contracts.CHAT_MESSAGE_ROLE_SYSTEM,
        "boundary",
        now,
      ),
      now,
    ) {
    Ok(_) => ()
    Err(message) => fail("append system failed: " + message)
  }
  let reply = match
    store.append_chat_message(
      bots_test_message(
        chat,
        session.id,
        @contracts.CHAT_MESSAGE_ROLE_ASSISTANT,
        "reply",
        now,
      ),
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("append assistant failed: " + message)
  }
  let current = match
    store.append_chat_message(
      bots_test_message(
        chat,
        session.id,
        @contracts.CHAT_MESSAGE_ROLE_USER,
        "current",
        now,
      ),
      now,
    ) {
    Ok(value) => value
    Err(message) => fail("append current failed: " + message)
  }
  let before_current = match
    store.list_chat_messages_before(chat.id, current.id, 10) {
    Ok(value) => value
    Err(message) => fail("list_chat_messages_before failed: " + message)
  }
  assert_eq(before_current.length(), 2)
  assert_eq(before_current[0].id, reply.id)
  assert_eq(before_current[1].id, older.id)
  let latest = match store.list_chat_messages_before(chat.id, "", 10) {
    Ok(value) => value
    Err(message) => fail("latest history read failed: " + message)
  }
  assert_eq(latest.length(), 3)
  assert_eq(latest[0].id, current.id)
  assert_eq(latest[1].id, reply.id)
  assert_eq(latest[2].id, older.id)
  store.close()
}
