///|
fn p1_bot(
  id : String,
  name : String,
  software_allowlist : Array[String],
) -> @contracts.BotRecord {
  @contracts.BotRecord::new(
    id~,
    org_id="org_1",
    name~,
    created_at="2026-01-01T00:00:00Z",
    software_allowlist~,
  )
}

///|
fn p1_agent(
  id : String,
  bot_id : String,
  name : String,
  software : String,
  state : String,
) -> @contracts.AgentRecord {
  let binding = @contracts.RuntimeBinding::new(
    software_id=software,
    adapter_id="acp",
    launch_kind=@contracts.RUNTIME_LAUNCH_ACP,
    command="",
    args=[],
    model_profile="",
    hash="sha256:test",
  )
  @contracts.AgentRecord::new(
    id~,
    org_id="org_1",
    bot_id~,
    name~,
    runtime_binding=binding,
    created_at="2026-01-01T00:00:00Z",
    state~,
  )
}

///|
fn p1_workspace(
  id : String,
  name : String,
) -> @contracts.WorkspaceRecord {
  {
    id,
    machine_id: "",
    kind: @contracts.WORKSPACE_KIND_LOCAL,
    root: "/tmp/" + name,
    name,
    git_root: "/tmp/" + name,
    is_git: true,
    state: @contracts.WORKSPACE_STATE_AVAILABLE,
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
  }
}

///|
fn p1_project(id : String, name : String) -> @contracts.ProjectRecord {
  @contracts.ProjectRecord::new(
    id~,
    name~,
    repo_url="",
    default_branch="main",
    verify=[],
    created_at="2026-01-01T00:00:00Z",
  )
}

///|
fn p1_membership(
  project_id : String,
  bot_id : String,
  state : String,
) -> @contracts.ProjectMembership {
  @contracts.ProjectMembership::new(
    project_id~,
    bot_id~,
    added_at="2026-01-01T00:00:00Z",
    access=[],
    state~,
  )
}

///|
fn p1_session(
  chat_id : String,
  agent_id : String,
  workspace_id : String,
  state : String,
) -> @contracts.AgentSession {
  @contracts.AgentSession::new(
    id="asn_" + chat_id,
    chat_id~,
    agent_id~,
    permission_snapshot_hash="sha256:test",
    started_at="2026-01-01T00:00:00Z",
    workspace_id~,
    state~,
  )
}

///|
fn p1_chat_detail(
  chat_id : String,
  bot_id : String,
  title : String,
  project_id : String,
  agent_id : String,
  session_state : String,
) -> @contracts.ChatDetail {
  let chat = @contracts.ChatRecord::new(
    id=chat_id,
    org_id="org_1",
    title~,
    created_at="2026-01-01T00:00:00Z",
    project_id~,
  )
  let agent = p1_agent(
    agent_id,
    bot_id,
    "Ada · coding",
    "claude-code",
    @contracts.AGENT_LIFECYCLE_ACTIVE,
  )
  let session = p1_session(chat_id, agent_id, "ws_1", session_state)
  @contracts.ChatDetail::new(
    chat={ ..chat, updated_at: "2026-01-02T00:00:00Z" },
    participants=[
      @contracts.ChatParticipant::new(
        chat_id=chat_id,
        bot_id~,
        added_at="2026-01-01T00:00:00Z",
      ),
    ],
    active_agent_session=Some(session),
    agent=Some(agent),
  )
}

///|
fn p1_message(
  id : String,
  chat_id : String,
  role : String,
  body : String,
) -> @contracts.ChatMessage {
  @contracts.ChatMessage::new(
    id~,
    chat_id~,
    role~,
    body_ref="",
    digest="",
    created_at="2026-01-02T00:00:00Z",
    body~,
  )
}

///|
fn p1_chat_before_agent_session(
  chat_id : String,
  bot_id : String,
  title : String,
) -> @contracts.ChatDetail {
  let chat = @contracts.ChatRecord::new(
    id=chat_id,
    org_id="org_1",
    title~,
    created_at="2026-01-01T00:00:00Z",
  )
  @contracts.ChatDetail::new(
    chat={ ..chat, updated_at: "2026-01-02T00:00:00Z" },
    participants=[
      @contracts.ChatParticipant::new(
        chat_id=chat_id,
        bot_id~,
        added_at="2026-01-01T00:00:00Z",
      ),
    ],
  )
}

///|
test "P1 bot.list and chat.list results parse into typed projections" {
  let bot = p1_bot("bot_a", "Ada", ["claude-code"])
  let detail = p1_chat_detail(
    "chat_a",
    "bot_a",
    "Plan the release",
    "",
    "agent_1",
    @contracts.AGENT_SESSION_STATE_ACTIVE,
  )
  let bots = match @contracts.bots_from_result(
    @contracts.bots_list_result([bot]),
  ) {
    Ok(records) => records
    Err(message) => {
      fail("bot.list parse failed: " + message)
      []
    }
  }
  let chats = match @contracts.chats_from_result(
    @contracts.chats_list_result([detail]),
  ) {
    Ok(records) => records
    Err(message) => {
      fail("chat.list parse failed: " + message)
      []
    }
  }
  let model = update(
    update(Model::new(), BotsLoaded(bots)),
    ChatsLoaded(chats),
  )
  assert_true(model.bots_loaded)
  assert_true(model.chats_loaded)
  assert_eq(model.bots.length(), 1)
  assert_eq(model.chats.length(), 1)
  assert_eq(model.chats[0].title, "Plan the release")
  assert_eq(model.chats[0].agent_name, "Ada · coding")
  assert_eq(model.chats[0].agent_session_id, "asn_chat_a")
  assert_eq(model.chat_details.length(), 1)
}

///|
test "opening a Chat loads messages and appends chat.read cursor without duplicates" {
  let bot = p1_bot("bot_a", "Ada", ["claude-code"])
  let detail = p1_chat_detail(
    "chat_a",
    "bot_a",
    "Plan the release",
    "",
    "agent_1",
    @contracts.AGENT_SESSION_STATE_ACTIVE,
  )
  let model = update(
    update(Model::new(), BotsLoaded([bot])),
    ChatsLoaded([detail]),
  )
  let (opened, open_commands) = update_full(model, ChatOpened(detail))
  assert_eq(opened.selected_chat, "chat_a")
  assert_true(opened.chat_messages_loaded == false)
  assert_eq(open_commands.length(), 2)
  match open_commands[0] {
    ChatMessages(chat_id, after, limit) => {
      assert_eq(chat_id, "chat_a")
      assert_eq(after, "")
      assert_eq(limit, 50)
    }
    _ => fail("expected initial chat.messages")
  }
  match open_commands[1] {
    ChatRead(chat_id, cursor) => {
      assert_eq(chat_id, "chat_a")
      assert_eq(cursor, 0L)
    }
    _ => fail("expected initial chat.read")
  }
  let first = p1_message(
    "msg_1",
    "chat_a",
    @contracts.CHAT_MESSAGE_ROLE_USER,
    "first",
  )
  let second = p1_message(
    "msg_2",
    "chat_a",
    @contracts.CHAT_MESSAGE_ROLE_ASSISTANT,
    "second",
  )
  let (paged, page_commands) = update_full(
    opened,
    ChatMessagesLoaded("chat_a", [first], "msg_1", true),
  )
  assert_eq(paged.chat_messages.length(), 1)
  assert_eq(page_commands.length(), 1)
  match page_commands[0] {
    ChatMessages(chat_id, after, limit) => {
      assert_eq(chat_id, "chat_a")
      assert_eq(after, "msg_1")
      assert_eq(limit, 50)
    }
    _ => fail("expected paged chat.messages")
  }
  let (complete, complete_commands) = update_full(
    paged,
    ChatMessagesLoaded("chat_a", [second], "msg_2", false),
  )
  assert_eq(complete.chat_messages.length(), 2)
  assert_eq(complete.chat_messages_after, "msg_2")
  assert_false(complete.chat_messages_in_flight)
  assert_eq(complete_commands.length(), 0)
  let (deduped, _) = update_full(
    complete,
    ChatMessagesLoaded("chat_a", [first, second], "msg_2", false),
  )
  assert_eq(deduped.chat_messages.length(), 2)
  let read_one = @contracts.ChatReadResult::new(
    session_id="asn_chat_a",
    runtime_session_id="",
    cursor=7L,
    text="live ",
    state=@contracts.AGENT_SESSION_STATE_ACTIVE,
    pending_decision="dec_1",
  )
  let (live_one, live_commands) = update_full(
    deduped,
    ChatReadLoaded("chat_a", read_one),
  )
  assert_eq(live_one.chat_live_text, "live ")
  assert_eq(live_one.chat_read_cursor, 7L)
  assert_eq(live_one.chat_pending_decision, "dec_1")
  assert_eq(live_commands.length(), 1)
  match live_commands[0] {
    DecisionList(_) => ()
    _ => fail("expected decision.list for the new pending Decision")
  }
  let read_two = @contracts.ChatReadResult::new(
    session_id="asn_chat_a",
    runtime_session_id="",
    cursor=12L,
    text="tail",
    state=@contracts.AGENT_SESSION_STATE_WAITING,
  )
  let (live_two, _) = update_full(live_one, ChatReadLoaded("chat_a", read_two))
  assert_eq(live_two.chat_live_text, "live tail")
  assert_eq(live_two.chat_read_cursor, 12L)
  assert_eq(live_two.chat_session_state, @contracts.AGENT_SESSION_STATE_WAITING)
  let (live_replay, _) = update_full(
    live_two,
    ChatReadLoaded("chat_a", read_two),
  )
  assert_eq(live_replay.chat_live_text, "live tail")
  assert_eq(live_replay.chat_read_cursor, 12L)
  let (polled, poll_commands) = update_full(live_two, ChatPoll)
  assert_eq(poll_commands.length(), 2)
  assert_true(polled.chat_poll_in_flight)
  let (overlap, overlap_commands) = update_full(polled, ChatPoll)
  assert_eq(overlap_commands.length(), 0)
  assert_eq(overlap.chat_read_cursor, 12L)
  let (away, _) = update_full(live_two, SelectPage(BotDetail))
  let (_, away_commands) = update_full(away, ChatPoll)
  assert_eq(away_commands.length(), 0)
}

///|
test "composer sends to the selected Chat and stops its AgentSession" {
  let bot = p1_bot("bot_a", "Ada", ["claude-code"])
  let detail = p1_chat_detail(
    "chat_a",
    "bot_a",
    "Plan the release",
    "",
    "agent_1",
    @contracts.AGENT_SESSION_STATE_ACTIVE,
  )
  let model = update(
    update(Model::new(), BotsLoaded([bot])),
    ChatsLoaded([detail]),
  )
  let (opened, _) = update_full(model, ChatOpened(detail))
  let (drafted, _) = update_full(opened, AgentInputDraft("  ship it  "))
  let (sent, send_commands) = update_full(drafted, ComposerSend)
  assert_eq(sent.agent.input, "")
  assert_eq(send_commands.length(), 1)
  match send_commands[0] {
    ChatSend(chat_id, text) => {
      assert_eq(chat_id, "chat_a")
      assert_eq(text, "ship it")
    }
    _ => fail("expected chat.send")
  }
  let (stopping, stop_commands) = update_full(opened, AgentStopSession)
  assert_eq(stopping.chat_session_state, "ending")
  assert_eq(stop_commands.length(), 1)
  match stop_commands[0] {
    ChatStop(chat_id, session_id) => {
      assert_eq(chat_id, "chat_a")
      assert_eq(session_id, "asn_chat_a")
    }
    _ => fail("expected chat.stop")
  }
}

///|
test "New Chat creates from names, starts the AgentSession, and enters the real Chat" {
  let bot = p1_bot("bot_a", "Ada", ["claude-code"])
  let agent = p1_agent(
    "agent_1",
    "bot_a",
    "Ada · coding",
    "claude-code",
    @contracts.AGENT_LIFECYCLE_ACTIVE,
  )
  let workspace = p1_workspace("ws_1", "demo")
  let model = update(Model::new(), NewChat)
  assert_true(model.composing_new_chat)
  assert_eq(model.selected_chat, "")
  let model = update(model, BotsLoaded([bot]))
  let model = update(model, ProjectWorkspaces([workspace]))
  let model = update(model, BotAgentsLoaded("bot_a", [agent]))
  assert_eq(model.chat_draft.bot_id, "bot_a")
  assert_eq(model.chat_draft.agent_id, "agent_1")
  assert_eq(model.chat_draft.workspace_id, "ws_1")
  let draft_harness = test_harness_for_model(model)
  assert_true(draft_harness.has_text("Create Chat"))
  assert_true(draft_harness.has_text("Ada"))
  assert_false(draft_harness.has_text("bot_a"))
  assert_false(draft_harness.has_text("agent_1"))
  assert_false(draft_harness.has_text("ws_1"))
  let (submitted, submit_commands) = update_full(model, ChatCreateSubmit)
  assert_true(submitted.chat_draft.busy)
  assert_eq(submit_commands.length(), 1)
  match submit_commands[0] {
    ChatCreate(bot_id, title, project_id, agent_id, workspace_id, org_id) => {
      assert_eq(bot_id, "bot_a")
      assert_eq(title, "Chat with Ada")
      assert_eq(project_id, "")
      assert_eq(agent_id, "agent_1")
      assert_eq(workspace_id, "ws_1")
      assert_eq(org_id, "org_1")
    }
    _ => fail("expected chat.create")
  }
  let detail = p1_chat_detail(
    "chat_new",
    "bot_a",
    "Chat with Ada",
    "",
    "agent_1",
    @contracts.AGENT_SESSION_STATE_STARTING,
  )
  let (opened, _) = update_full(submitted, ChatOpened(detail))
  assert_true(opened.page == Workroom)
  assert_false(opened.composing_new_chat)
  assert_eq(opened.selected_chat, "chat_new")
  assert_eq(opened.selected_bot, "bot_a")
  let session = match detail.active_agent_session {
    Some(record) => record
    None => fail("fixture has no AgentSession")
  }
  let active = { ..session, state: @contracts.AGENT_SESSION_STATE_ACTIVE }
  let (started, _) = update_full(opened, ChatAgentSessionStarted(active))
  assert_eq(started.chat_session_state, @contracts.AGENT_SESSION_STATE_ACTIVE)
  assert_eq(started.selected_chat, "chat_new")
  let open_harness = test_harness_for_model(started)
  assert_true(open_harness.has_text("Chat with Ada"))
  assert_false(open_harness.has_text("chat_new"))
}

///|
test "the first AgentSession start projects the selected Agent into a new Chat" {
  let bot = p1_bot("bot_a", "Ada", ["claude-code"])
  let agent = p1_agent(
    "agent_1",
    "bot_a",
    "Ada · coding",
    "claude-code",
    @contracts.AGENT_LIFECYCLE_ACTIVE,
  )
  let workspace = p1_workspace("ws_1", "demo")
  let model = update(Model::new(), NewChat)
  let model = update(model, BotsLoaded([bot]))
  let model = update(model, ProjectWorkspaces([workspace]))
  let model = update(model, BotAgentsLoaded("bot_a", [agent]))
  let (submitted, _) = update_full(model, ChatCreateSubmit)
  let detail = p1_chat_before_agent_session(
    "chat_new",
    "bot_a",
    "Chat with Ada",
  )
  let (opened, _) = update_full(submitted, ChatOpened(detail))
  assert_eq(opened.chats[0].agent_name, "")
  let session = p1_session(
    "chat_new",
    "agent_1",
    "ws_1",
    @contracts.AGENT_SESSION_STATE_ACTIVE,
  )
  let (started, _) = update_full(opened, ChatAgentSessionStarted(session))
  assert_eq(started.chats[0].agent_name, "Ada · coding")
  assert_eq(started.chats[0].software_id, "claude-code")
  assert_eq(started.chats[0].agent_session_id, "asn_chat_new")
  match started.chat_details[0].agent {
    Some(record) => assert_eq(record.id, "agent_1")
    None => fail("AgentSession start did not project the Agent")
  }
  let harness = test_harness_for_model(started)
  assert_false(harness.has_text("agent_1"))
}

///|
test "late chat.get responses do not steal a newer Chat or route" {
  let bot_a = p1_bot("bot_a", "Ada", ["claude-code"])
  let bot_b = p1_bot("bot_b", "Beta", ["claude-code"])
  let detail_a = p1_chat_detail(
    "chat_a",
    "bot_a",
    "Chat A",
    "",
    "agent_a",
    @contracts.AGENT_SESSION_STATE_ACTIVE,
  )
  let detail_b = p1_chat_detail(
    "chat_b",
    "bot_b",
    "Chat B",
    "",
    "agent_b",
    @contracts.AGENT_SESSION_STATE_ACTIVE,
  )
  let model = update(
    update(Model::new(), BotsLoaded([bot_a, bot_b])),
    ChatsLoaded([detail_a, detail_b]),
  )
  let (opened_a, _) = update_full(model, SelectChat("chat_a"))
  let (opened_b, _) = update_full(opened_a, SelectChat("chat_b"))
  let (late_a, late_commands) = update_full(opened_b, ChatOpened(detail_a))
  assert_eq(late_a.selected_chat, "chat_b")
  assert_eq(late_commands.length(), 0)
  let (away, _) = update_full(opened_a, SelectPage(BotDetail))
  let (late_away, away_commands) = update_full(away, ChatOpened(detail_a))
  assert_true(late_away.page == BotDetail)
  assert_eq(away_commands.length(), 0)
}

///|
test "Project view filters Chats by Project and Bot and excludes no-project Chats" {
  let bot_a = p1_bot("bot_a", "Ada", ["claude-code"])
  let bot_b = p1_bot("bot_b", "Beta", ["claude-code"])
  let project = p1_project("prj_1", "Release")
  let in_project = p1_chat_detail(
    "chat_p1",
    "bot_a",
    "Release chat",
    "prj_1",
    "agent_1",
    @contracts.AGENT_SESSION_STATE_ACTIVE,
  )
  let no_project = p1_chat_detail(
    "chat_none",
    "bot_a",
    "Scratch chat",
    "",
    "agent_2",
    @contracts.AGENT_SESSION_STATE_ACTIVE,
  )
  let model = update(Model::new(), BotsLoaded([bot_a, bot_b]))
  let model = update(model, ProjectCatalogLoaded([project]))
  let model = update(model, SelectProject("prj_1"))
  let model = update(model, ChatsLoaded([in_project, no_project]))
  let model = update(
    model,
    ProjectMembershipsLoaded([
      p1_membership("prj_1", "bot_a", @contracts.MEMBERSHIP_STATE_ACTIVE),
    ]),
  )
  let harness = test_harness_for_model(model)
  assert_true(harness.has_text("Chats in this Project"))
  assert_true(harness.has_text("Release chat"))
  assert_true(harness.has_text("Bot members"))
  assert_true(harness.has_text("Ada"))
  assert_false(harness.has_text("bot_a"))
  let filtered = update(model, ProjectChatBotFilter("bot_b"))
  let filtered_harness = test_harness_for_model(filtered)
  assert_true(
    filtered_harness.has_text(
      "No Chat matches this Project and Bot filter yet.",
    ),
  )
  let (new_chat, _) = update_full(model, NewChat)
  assert_true(new_chat.composing_new_chat)
  assert_eq(new_chat.chat_draft.project_id, "prj_1")
  // `bot_a` is the only Bot with active Project membership in the projection.
  assert_eq(new_chat.chat_draft.bot_id, "bot_a")
  let non_member = update(new_chat, ChatDraftBot("bot_b"))
  assert_eq(non_member.chat_draft.bot_id, "")
  assert_true(non_member.chat_draft.message.contains("no active membership"))
}

///|
test "Project page manages membership by Bot name without raw ids" {
  let bot_a = p1_bot("bot_a", "Ada", ["claude-code"])
  let bot_b = p1_bot("bot_b", "Beta", ["claude-code"])
  let project = p1_project("prj_1", "Release")
  let model = update(Model::new(), BotsLoaded([bot_a, bot_b]))
  let model = update(model, ProjectCatalogLoaded([project]))
  let model = update(model, SelectProject("prj_1"))
  let model = update(
    model,
    ProjectMembershipsLoaded([
      p1_membership("prj_1", "bot_a", @contracts.MEMBERSHIP_STATE_ACTIVE),
    ]),
  )
  let harness = test_harness_for_model(model)
  assert_true(harness.has_text("Bot members"))
  assert_true(harness.has_text("Ada"))
  assert_true(harness.has_text("Beta"))
  assert_true(harness.has_text("Add a Bot by name"))
  assert_true(harness.has_text("Remove"))
  assert_true(harness.has_text("Add"))
  assert_false(harness.has_text("bot_a"))
  assert_false(harness.has_text("bot_b"))
  assert_false(harness.has_text("prj_1"))
  let removed = update(
    model,
    ProjectMembershipRemoved(
      p1_membership("prj_1", "bot_a", @contracts.MEMBERSHIP_STATE_REMOVED),
    ),
  )
  let removed_harness = test_harness_for_model(removed)
  assert_true(
    removed_harness.has_text(
      "No Bot is a member of this Project yet. Add one below by name.",
    ),
  )
  assert_true(removed_harness.has_text("Add a Bot by name"))
}

///|
test "Bot and Chat deep links round-trip through route metadata" {
  assert_eq(route_path(RouteChat("chat_a")), "chat/chat_a")
  assert_eq(route_path(RouteBot("bot_a")), "bot/bot_a")
  assert_eq(route_path(RouteProjects("prj_1")), "project/prj_1")
  match parse_route("chat/chat_a") {
    RouteChat(id) => assert_eq(id, "chat_a")
    _ => fail("expected chat route")
  }
  match parse_route("bot/bot_a") {
    RouteBot(id) => assert_eq(id, "bot_a")
    _ => fail("expected bot route")
  }
  match parse_route("project/prj_1") {
    RouteProjects(id) => assert_eq(id, "prj_1")
    _ => fail("expected project route")
  }
  let (chat_model, _) = update_full(Model::new(), RouteArrived(RouteChat("chat_a")))
  assert_eq(model_route(chat_model), "chat/chat_a")
  let bot = p1_bot("bot_a", "Ada", ["claude-code"])
  let detail = p1_chat_detail(
    "chat_a",
    "bot_a",
    "Plan the release",
    "",
    "agent_1",
    @contracts.AGENT_SESSION_STATE_ACTIVE,
  )
  // A late chat.list must not steal a Bot route and jump to the Workroom.
  let (bot_route, _) = update_full(Model::new(), RouteArrived(RouteBot("bot_a")))
  let bot_loaded = update(update(bot_route, BotsLoaded([bot])), ChatsLoaded([detail]))
  assert_true(bot_loaded.page == BotDetail)
  assert_eq(bot_loaded.selected_bot, "bot_a")
  // A late chat.list must not steal a Project route either.
  let project = p1_project("prj_1", "Release")
  let (project_route, _) = update_full(
    Model::new(),
    RouteArrived(RouteProjects("prj_1")),
  )
  let project_loaded = update(
    update(project_route, ProjectCatalogLoaded([project])),
    ChatsLoaded([detail]),
  )
  assert_true(project_loaded.page == Manage)
  assert_eq(project_loaded.project.selected_project, "prj_1")
}

///|
test "Agent lifecycle uses bot.agent RPC commands and name-only creation" {
  let bot = p1_bot("bot_a", "Ada", ["claude-code"])
  let agent = p1_agent(
    "agent_1",
    "bot_a",
    "Ada · coding",
    "claude-code",
    @contracts.AGENT_LIFECYCLE_ACTIVE,
  )
  let model = update(Model::new(), BotsLoaded([bot]))
  let model = update(model, OpenBotDetail("bot_a"))
  let model = update(model, SelectBotTab(BotAgents))
  let model = update(model, BotAgentsLoaded("bot_a", [agent]))
  let harness = test_harness_for_model(model)
  assert_true(harness.has_text("Create Agent"))
  assert_true(harness.has_text("Ada · coding"))
  assert_true(harness.has_text("claude-code"))
  assert_false(harness.has_text("agent_1"))
  let (suspend, suspend_commands) = update_full(
    model,
    SuspendBotAgent("agent_1"),
  )
  assert_eq(suspend_commands.length(), 1)
  match suspend_commands[0] {
    BotAgentSuspend(agent_id, _) => assert_eq(agent_id, "agent_1")
    _ => fail("expected bot.agent.suspend")
  }
  let suspended = {
    ..agent,
    state: @contracts.AGENT_LIFECYCLE_SUSPENDED,
    updated_at: "2026-01-03T00:00:00Z",
  }
  let (mutated, _) = update_full(suspend, BotAgentMutated(suspended))
  assert_eq(
    mutated.bot_agents[0].state,
    @contracts.AGENT_LIFECYCLE_SUSPENDED,
  )
  let (retired, retire_commands) = update_full(
    mutated,
    RetireBotAgent("agent_1"),
  )
  assert_eq(retire_commands.length(), 1)
  match retire_commands[0] {
    BotAgentRetire(agent_id, _) => assert_eq(agent_id, "agent_1")
    _ => fail("expected bot.agent.retire")
  }
  let (drafted, _) = update_full(
    update(model, AgentDraftName("Builder")),
    AgentDraftSoftware("claude-code"),
  )
  let (creating, create_commands) = update_full(drafted, BotAgentCreateSubmit)
  assert_true(creating.agent_draft.busy)
  assert_eq(create_commands.length(), 1)
  match create_commands[0] {
    BotAgentCreate(
      bot_id,
      org_id,
      name,
      software,
      launch_kind,
      args,
      command,
    ) => {
      assert_eq(bot_id, "bot_a")
      assert_eq(org_id, "org_1")
      assert_eq(name, "Builder")
      assert_eq(software, "claude-code")
      assert_eq(launch_kind, @contracts.RUNTIME_LAUNCH_ACP)
      assert_eq(args.length(), 0)
      assert_eq(command, "")
    }
    _ => fail("expected bot.agent.create")
  }
}

///|
test "startup route metadata round-trips for base and id routes" {
  defer @env.unset_env_var("MONEXUS_ROUTE")
  defer @env.unset_env_var("MONEXUS_SCENE_PAGE")
  @env.unset_env_var("MONEXUS_SCENE_PAGE")
  @env.set_env_var("MONEXUS_ROUTE", "bot")
  let bot_route = Model::new()
  assert_true(bot_route.page == BotDetail)
  assert_eq(model_route(bot_route), "bot")
  @env.set_env_var("MONEXUS_ROUTE", "project")
  let project_route = Model::new()
  assert_true(project_route.page == Manage)
  assert_true(project_route.manage_tab == ManageProjects)
  assert_eq(model_route(project_route), "project")
  @env.set_env_var("MONEXUS_ROUTE", "bot/bot_a")
  let bot_id_route = Model::new()
  assert_true(bot_id_route.page == BotDetail)
  assert_eq(model_route(bot_id_route), "bot/bot_a")
  @env.set_env_var("MONEXUS_ROUTE", "project/prj_1")
  let project_id_route = Model::new()
  assert_true(project_id_route.page == Manage)
  assert_eq(model_route(project_id_route), "project/prj_1")
  @env.set_env_var("MONEXUS_ROUTE", "chat/chat_a")
  let chat_route = Model::new()
  assert_true(chat_route.page == Workroom)
  assert_eq(model_route(chat_route), "chat/chat_a")
}
